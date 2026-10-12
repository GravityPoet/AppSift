import Foundation

/// Values shared by the AppSift host app and its Network Extension. Keeping
/// the wire format small and Codable lets the extension remain independent of
/// SwiftUI and gives the host a safe read-only fallback when the extension is
/// not installed or approved yet.
enum AppSiftNetworkAccessContract {
    static let appGroupIdentifier = "group.com.gravitypoet.appsift"
    static let extensionBundleIdentifier = "com.gravitypoet.appsift.network-extension"
    static let policyKey = "AppSift.NetworkAccess.Policy.v1"
    static let flowsKey = "AppSift.NetworkAccess.Flows.v1"
    static let schemaVersion = 1
    static let maximumStoredFlows = 500
}

enum AppSiftNetworkProtectionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case monitor
    case blockList

    var id: String { rawValue }
}

struct AppSiftNetworkPolicy: Codable, Equatable, Sendable {
    var schemaVersion: Int = AppSiftNetworkAccessContract.schemaVersion
    var enabled: Bool = false
    var protectionMode: AppSiftNetworkProtectionMode = .blockList
    var blockedBundleIDs: Set<String> = []
    var allowedBundleIDs: Set<String> = []

    func normalized() -> Self {
        var copy = self
        copy.schemaVersion = AppSiftNetworkAccessContract.schemaVersion
        copy.blockedBundleIDs = Set(
            copy.blockedBundleIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
        copy.allowedBundleIDs.subtract(copy.blockedBundleIDs)
        return copy
    }

    func isBlocked(bundleIdentifier: String) -> Bool {
        let normalized = normalized()
        guard normalized.enabled else { return false }
        guard normalized.protectionMode == .blockList else { return false }
        guard !normalized.allowedBundleIDs.contains(bundleIdentifier) else { return false }
        return normalized.blockedBundleIDs.contains(bundleIdentifier)
    }
}

struct AppSiftNetworkFlowRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let bundleIdentifier: String
    let processPath: String?
    let remoteEndpoint: String?
    let startedAt: Date
    var lastSeenAt: Date
    var bytesReceived: UInt64
    var bytesSent: UInt64
    var isBlocked: Bool

    init(
        id: String,
        bundleIdentifier: String,
        processPath: String? = nil,
        remoteEndpoint: String? = nil,
        startedAt: Date = Date(),
        lastSeenAt: Date = Date(),
        bytesReceived: UInt64 = 0,
        bytesSent: UInt64 = 0,
        isBlocked: Bool = false
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.processPath = processPath
        self.remoteEndpoint = remoteEndpoint
        self.startedAt = startedAt
        self.lastSeenAt = lastSeenAt
        self.bytesReceived = bytesReceived
        self.bytesSent = bytesSent
        self.isBlocked = isBlocked
    }

    var totalBytes: UInt64 {
        bytesReceived &+ bytesSent
    }
}

enum AppSiftNetworkAccessStore {
    private static let defaults = UserDefaults(
        suiteName: AppSiftNetworkAccessContract.appGroupIdentifier
    ) ?? .standard

    static func readPolicy() -> AppSiftNetworkPolicy {
        guard let data = defaults.data(forKey: AppSiftNetworkAccessContract.policyKey),
              let policy = try? JSONDecoder().decode(AppSiftNetworkPolicy.self, from: data) else {
            return AppSiftNetworkPolicy()
        }
        return policy.normalized()
    }

    static func writePolicy(_ policy: AppSiftNetworkPolicy) {
        guard let data = try? JSONEncoder().encode(policy.normalized()) else { return }
        defaults.set(data, forKey: AppSiftNetworkAccessContract.policyKey)
    }

    static func readFlows() -> [AppSiftNetworkFlowRecord] {
        guard let data = defaults.data(forKey: AppSiftNetworkAccessContract.flowsKey),
              let flows = try? JSONDecoder().decode([AppSiftNetworkFlowRecord].self, from: data) else {
            return []
        }
        return Array(
            flows
                .sorted { $0.lastSeenAt > $1.lastSeenAt }
                .prefix(AppSiftNetworkAccessContract.maximumStoredFlows)
        )
    }

    static func writeFlows(_ flows: [AppSiftNetworkFlowRecord]) {
        let bounded = Array(
            flows
                .sorted { $0.lastSeenAt > $1.lastSeenAt }
                .prefix(AppSiftNetworkAccessContract.maximumStoredFlows)
        )
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        defaults.set(data, forKey: AppSiftNetworkAccessContract.flowsKey)
    }

    static func record(_ flow: AppSiftNetworkFlowRecord) {
        var flows = readFlows()
        if let index = flows.firstIndex(where: { $0.id == flow.id }) {
            flows[index] = flow
        } else {
            flows.append(flow)
        }
        writeFlows(flows)
    }
}
