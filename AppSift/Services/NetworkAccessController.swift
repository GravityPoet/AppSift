import Combine
import Foundation
@preconcurrency import NetworkExtension
import SystemExtensions

enum NetworkAccessExtensionState: Equatable {
    case unavailable
    case inactive
    case activating
    case awaitingUserApproval
    case active
    case failed(String)

    var title: String {
        switch self {
        case .unavailable: return "Unavailable"
        case .inactive: return "Not enabled"
        case .activating: return "Starting…"
        case .awaitingUserApproval: return "Approval required"
        case .active: return "Monitoring active"
        case .failed: return "Unavailable"
        }
    }

    var detail: String {
        switch self {
        case .unavailable:
            return "Build and install the AppSift Network Extension to see app flows."
        case .inactive:
            return "Enable monitoring to inspect socket traffic by app."
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

    var isOperational: Bool {
        if case .active = self { return true }
        return false
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

    private var pollTimer: Timer?
    private var activationDelegate: NetworkAccessExtensionRequestDelegate?

    override init() {
        policy = AppSiftNetworkAccessStore.readPolicy()
        flows = AppSiftNetworkAccessStore.readFlows()
        super.init()
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
    }

    var isEnabled: Bool {
        policy.enabled
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
        var updated = policy
        updated.enabled = enabled
        policy = updated.normalized()
        AppSiftNetworkAccessStore.writePolicy(policy)

        if enabled {
            activateAndConfigure()
        } else {
            disableFilter()
        }
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
                self?.refresh()
            }
        }
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
                    self?.extensionState = .failed(error.localizedDescription)
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
                    self.extensionState = .failed(error.localizedDescription)
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
                        self.extensionState = .failed(error.localizedDescription)
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
                    self.extensionState = .failed(error.localizedDescription)
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
