import AppKit
import Darwin
import Foundation
import NetworkExtension

@main
enum AppSiftNetworkExtensionMain {
    static func main() {
        NEProvider.startSystemExtensionMode()
    }
}

/// AppSift's data provider mirrors the useful part of the competitor's
/// network monitor: a broad filter-data rule, per-bundle decisions, and
/// periodic byte reports. It never captures payload bytes or URLs.
final class AppSiftNetworkFilter: NEFilterDataProvider {
    private let storeLock = NSLock()

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        let wildcard = NENetworkRule(
            remoteNetwork: nil,
            remotePrefix: 0,
            localNetwork: nil,
            localPrefix: 0,
            protocol: .any,
            direction: .any
        )
        let rule = NEFilterRule(networkRule: wildcard, action: .filterData)
        let settings = NEFilterSettings(rules: [rule], defaultAction: .allow)
        apply(settings) { error in
            completionHandler(error)
        }
    }

    override func stopFilter(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let identity = identity(for: flow)
        let policy = AppSiftNetworkAccessStore.readPolicy()
        let blocked = policy.isBlocked(bundleIdentifier: identity.bundleIdentifier)
        let flowRecord = AppSiftNetworkFlowRecord(
            id: flow.identifier.uuidString,
            bundleIdentifier: identity.bundleIdentifier,
            processPath: identity.processPath,
            remoteEndpoint: remoteEndpoint(for: flow),
            isBlocked: blocked
        )
        record(flowRecord)

        if blocked {
            return .drop()
        }

        let verdict = NEFilterNewFlowVerdict.allow()
        verdict.shouldReport = true
        verdict.statisticsReportFrequency = .medium
        return verdict
    }

    override func handle(_ report: NEFilterReport) {
        guard let flow = report.flow else { return }
        let identity = identity(for: flow)
        let id = flow.identifier.uuidString

        storeLock.lock()
        defer { storeLock.unlock() }
        var flows = AppSiftNetworkAccessStore.readFlows()
        let existing = flows.first(where: { $0.id == id })
        let record = AppSiftNetworkFlowRecord(
            id: id,
            bundleIdentifier: identity.bundleIdentifier,
            processPath: identity.processPath,
            remoteEndpoint: remoteEndpoint(for: flow),
            startedAt: existing?.startedAt ?? Date(),
            lastSeenAt: Date(),
            bytesReceived: UInt64(report.bytesInboundCount),
            bytesSent: UInt64(report.bytesOutboundCount),
            isBlocked: report.action == .drop
        )

        if let index = flows.firstIndex(where: { $0.id == id }) {
            flows[index] = record
        } else {
            flows.append(record)
        }
        AppSiftNetworkAccessStore.writeFlows(flows)
    }

    private func record(_ flow: AppSiftNetworkFlowRecord) {
        storeLock.lock()
        defer { storeLock.unlock() }
        AppSiftNetworkAccessStore.record(flow)
    }

    private struct FlowIdentity {
        let bundleIdentifier: String
        let processPath: String?
    }

    private func identity(for flow: NEFilterFlow) -> FlowIdentity {
        guard let data = flow.sourceAppAuditToken,
              data.count >= MemoryLayout<audit_token_t>.size else {
            return FlowIdentity(bundleIdentifier: "unknown", processPath: nil)
        }

        var token = audit_token_t()
        _ = withUnsafeMutableBytes(of: &token) { destination in
            data.copyBytes(to: destination)
        }
        let pid = audit_token_to_pid(token)
        guard pid > 0 else {
            return FlowIdentity(bundleIdentifier: "unknown", processPath: nil)
        }

        let running = NSRunningApplication(processIdentifier: pid)
        let path = running?.executableURL?.path ?? processPath(for: pid)
        let bundleIdentifier = running?.bundleIdentifier
            ?? path.flatMap { Bundle(path: $0)?.bundleIdentifier }
            ?? "pid.(pid)"
        return FlowIdentity(bundleIdentifier: bundleIdentifier, processPath: path)
    }

    private func processPath(for pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(bytes: buffer.prefix(Int(length)), encoding: .utf8)
    }

    private func remoteEndpoint(for flow: NEFilterFlow) -> String? {
        guard let socketFlow = flow as? NEFilterSocketFlow else { return nil }
        return socketFlow.remoteHostname ?? socketFlow.remoteEndpoint?.description
    }
}
