import Combine
import Foundation
import AppKit
@preconcurrency import NetworkExtension
import Security
import SystemExtensions
import Darwin

enum NetworkAccessExtensionState: Equatable {
    case unavailable
    case inactive
    case localReady
    case localMonitoring
    case activating
    case awaitingUserApproval
    case active
    case failed(String)

    var titleKey: String {
        switch self {
        case .unavailable: return "Unavailable"
        case .inactive: return "Not enabled"
        case .localReady: return "Local traffic available"
        case .localMonitoring: return "Local traffic view"
        case .activating: return "Starting…"
        case .awaitingUserApproval: return "Approval required"
        case .active: return "Monitoring active"
        case .failed: return "Unavailable"
        }
    }

    var detailKey: String {
        switch self {
        case .unavailable:
            return "Network monitoring is unavailable in this build."
        case .inactive:
            return "Enable monitoring to inspect socket traffic by app."
        case .localReady:
            return "This local build can view per-app byte totals without a system extension. Start local traffic view here; blocking apps requires a Network Extension provisioning profile."
        case .localMonitoring:
            return "Local traffic view is running through macOS process counters. App blocking requires a provisioned Network Extension build."
        case .activating:
            return "macOS is preparing the local filter."
        case .awaitingUserApproval:
            return "Approve AppSift in System Settings, then return here."
        case .active:
            return "Traffic stays on this Mac and is stored only in the App Group."
        case let .failed(message):
            return message
        }
    }

    var failureMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }

    var isOperational: Bool {
        if case .active = self { return true }
        return false
    }

    var isLocalOnly: Bool {
        if case .localMonitoring = self { return true }
        return false
    }

    var supportsLocalTrafficView: Bool {
        switch self {
        case .localReady, .localMonitoring:
            return true
        case .unavailable, .inactive, .activating, .awaitingUserApproval, .active, .failed:
            return false
        }
    }
}

/// Host-side coordinator for the optional Network Extension. The UI remains
/// useful when the extension cannot be activated: it shows persisted flow
/// records and explains the exact approval boundary instead of pretending that
/// a process-level network sampler can block other apps.
@MainActor
final class NetworkAccessController: NSObject, ObservableObject {
    static let shared = NetworkAccessController()

    @Published private(set) var policy: AppSiftNetworkPolicy
    @Published private(set) var flows: [AppSiftNetworkFlowRecord]
    @Published private(set) var extensionState: NetworkAccessExtensionState = .inactive
    @Published var actionMessage: String?

    private var pollTimer: Timer?
    private var activationDelegate: NetworkAccessExtensionRequestDelegate?
    private var localSampleInFlight = false

    override init() {
        policy = AppSiftNetworkAccessStore.readPolicy()
        flows = AppSiftNetworkAccessStore.readFlows()
        super.init()
        if Self.hasSystemExtensionInstallEntitlement {
            extensionState = .inactive
        } else {
            extensionState = policy.enabled ? .localMonitoring : .localReady
        }
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
    }

    var isEnabled: Bool {
        guard policy.enabled else { return false }
        switch extensionState {
        case .activating, .awaitingUserApproval, .active:
            return true
        case .localMonitoring:
            return true
        case .localReady, .unavailable, .inactive, .failed:
            return false
        }
    }

    var totalFlowCount: Int {
        flows.count
    }

    var totalReceivedBytes: UInt64 {
        flows.reduce(0) { $0 &+ $1.bytesReceived }
    }

    var totalSentBytes: UInt64 {
        flows.reduce(0) { $0 &+ $1.bytesSent }
    }

    func isBlocked(bundleIdentifier: String) -> Bool {
        policy.isBlocked(bundleIdentifier: bundleIdentifier)
    }

    func setBlocked(_ blocked: Bool, bundleIdentifier: String) {
        var updated = policy
        if blocked {
            updated.blockedBundleIDs.insert(bundleIdentifier)
            updated.allowedBundleIDs.remove(bundleIdentifier)
        } else {
            updated.blockedBundleIDs.remove(bundleIdentifier)
            updated.allowedBundleIDs.insert(bundleIdentifier)
        }
        policy = updated.normalized()
        AppSiftNetworkAccessStore.writePolicy(policy)
    }

    func setMonitoringEnabled(_ enabled: Bool) {
        guard enabled else {
            var updated = policy
            updated.enabled = false
            policy = updated.normalized()
            AppSiftNetworkAccessStore.writePolicy(policy)
            if Self.hasSystemExtensionInstallEntitlement {
                disableFilter()
            } else {
                extensionState = .localReady
            }
            return
        }

        guard Self.hasSystemExtensionInstallEntitlement else {
            var updated = policy
            updated.enabled = true
            policy = updated.normalized()
            AppSiftNetworkAccessStore.writePolicy(policy)
            extensionState = .localMonitoring
            Task { @MainActor [weak self] in
                await self?.sampleLocalTrafficIfNeeded()
            }
            return
        }

        var updated = policy
        updated.enabled = enabled
        policy = updated.normalized()
        AppSiftNetworkAccessStore.writePolicy(policy)
        activateAndConfigure()
    }

    func refresh() {
        policy = AppSiftNetworkAccessStore.readPolicy()
        flows = AppSiftNetworkAccessStore.readFlows()
    }

    func clearFlows() {
        AppSiftNetworkAccessStore.writeFlows([])
        flows.removeAll()
    }

    func flows(for bundleIdentifier: String) -> [AppSiftNetworkFlowRecord] {
        flows.filter { $0.bundleIdentifier == bundleIdentifier }
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                await self.sampleLocalTrafficIfNeeded()
            }
        }
    }

    private func sampleLocalTrafficIfNeeded() async {
        guard extensionState.isLocalOnly, policy.enabled, !localSampleInFlight else { return }
        localSampleInFlight = true
        let samples = await AppSiftLocalNetworkTrafficSampler.sample()
        localSampleInFlight = false
        applyLocalTrafficSamples(samples)
    }

    private func applyLocalTrafficSamples(_ samples: [AppSiftLocalNetworkTrafficSample]) {
        var aggregates: [String: (bytesReceived: UInt64, bytesSent: UInt64, processPath: String?)] = [:]
        for sample in samples {
            guard let identity = applicationIdentity(for: sample.processID) else {
                continue
            }

            let current = aggregates[identity.bundleIdentifier] ?? (0, 0, nil)
            aggregates[identity.bundleIdentifier] = (
                current.bytesReceived &+ sample.bytesReceived,
                current.bytesSent &+ sample.bytesSent,
                current.processPath ?? identity.processPath
            )
        }

        let existingLocal = Dictionary(
            uniqueKeysWithValues: flows
                .filter { $0.id.hasPrefix("local:") }
                .map { ($0.id, $0) }
        )
        var updatedFlows = flows.filter { !$0.id.hasPrefix("local:") }
        let now = Date()
        for (bundleIdentifier, aggregate) in aggregates {
            let flowID = "local:\(bundleIdentifier)"
            let previous = existingLocal[flowID]
            updatedFlows.append(
                AppSiftNetworkFlowRecord(
                    id: flowID,
                    bundleIdentifier: bundleIdentifier,
                    processPath: aggregate.processPath,
                    startedAt: previous?.startedAt ?? now,
                    lastSeenAt: now,
                    bytesReceived: aggregate.bytesReceived,
                    bytesSent: aggregate.bytesSent,
                    isBlocked: false
                )
            )
        }

        AppSiftNetworkAccessStore.writeFlows(updatedFlows)
        flows = AppSiftNetworkAccessStore.readFlows()
    }

    private func applicationIdentity(for processID: Int32) -> (bundleIdentifier: String, processPath: String?)? {
        let runningApplication = NSRunningApplication(processIdentifier: processID)
        let executablePath = runningApplication?.executableURL?.path ?? processPath(for: processID)
        if let executablePath,
           let outerBundle = outermostApplicationBundle(forExecutablePath: executablePath),
           let bundleIdentifier = Bundle(url: outerBundle)?.bundleIdentifier {
            return (bundleIdentifier, executablePath)
        }
        if let bundleIdentifier = runningApplication?.bundleIdentifier {
            return (bundleIdentifier, executablePath)
        }
        return nil
    }

    private func processPath(for processID: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private func outermostApplicationBundle(forExecutablePath path: String) -> URL? {
        var current = URL(fileURLWithPath: path).standardizedFileURL
        var applicationBundles: [URL] = []
        while current.path != "/" {
            if current.pathExtension == "app" {
                applicationBundles.append(current)
            }
            current.deleteLastPathComponent()
        }
        return applicationBundles.last
    }

    private func activateAndConfigure() {
        extensionState = .activating
        let delegate = NetworkAccessExtensionRequestDelegate(
            onApprovalNeeded: { [weak self] in
                Task { @MainActor in self?.extensionState = .awaitingUserApproval }
            },
            onFinished: { [weak self] in
                Task { @MainActor in self?.configureFilter(enabled: true) }
            },
            onFailed: { [weak self] error in
                Task { @MainActor in
                    self?.markActivationFailed(error)
                }
            }
        )
        activationDelegate = delegate
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: AppSiftNetworkAccessContract.extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = delegate
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func configureFilter(enabled: Bool) {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] error in
            guard let self else { return }
            if let error {
                Task { @MainActor in
                    self.markActivationFailed(error)
                }
                return
            }

            let configuration = manager.providerConfiguration ?? NEFilterProviderConfiguration()
            configuration.filterSockets = true
            configuration.filterDataProviderBundleIdentifier =
                AppSiftNetworkAccessContract.extensionBundleIdentifier
            configuration.vendorConfiguration = [
                "appGroup": AppSiftNetworkAccessContract.appGroupIdentifier,
                "schemaVersion": AppSiftNetworkAccessContract.schemaVersion,
            ]
            manager.localizedDescription = "AppSift 网络访问监控"
            manager.providerConfiguration = configuration
            manager.grade = .firewall
            manager.isEnabled = enabled
            manager.saveToPreferences { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.markActivationFailed(error)
                    } else {
                        self.extensionState = enabled ? .active : .inactive
                    }
                }
            }
        }
    }

    private func disableFilter() {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] error in
            guard let self else { return }
            if let error {
                Task { @MainActor in
                    self.markActivationFailed(error)
                }
                return
            }
            manager.isEnabled = false
            manager.saveToPreferences { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.extensionState = error == nil
                        ? .inactive
                        : .failed(error?.localizedDescription ?? "Could not disable the network filter.")
                }
            }
        }
    }

    private func markActivationFailed(_ error: Error) {
        var updated = policy
        updated.enabled = false
        policy = updated.normalized()
        AppSiftNetworkAccessStore.writePolicy(policy)
        extensionState = .failed(error.localizedDescription)
    }

    private static var hasSystemExtensionInstallEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.system-extension.install" as CFString,
                nil
              ) as? Bool else {
            return false
        }
        return value
    }
}

private final class NetworkAccessExtensionRequestDelegate: NSObject, OSSystemExtensionRequestDelegate {
    private let onApprovalNeeded: () -> Void
    private let onFinished: () -> Void
    private let onFailed: (Error) -> Void

    init(
        onApprovalNeeded: @escaping () -> Void,
        onFinished: @escaping () -> Void,
        onFailed: @escaping (Error) -> Void
    ) {
        self.onApprovalNeeded = onApprovalNeeded
        self.onFinished = onFinished
        self.onFailed = onFailed
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onApprovalNeeded()
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        onFinished()
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        onFailed(error)
    }
}
