import Foundation
import XCTest
@testable import AppSift

final class NetworkAccessPolicyTests: XCTestCase {
    func testNormalizationRemovesConflictingAllowEntry() {
        let policy = AppSiftNetworkPolicy(
            enabled: true,
            protectionMode: .blockList,
            blockedBundleIDs: ["com.example.app"],
            allowedBundleIDs: ["com.example.app", "com.example.other"]
        ).normalized()

        XCTAssertEqual(policy.blockedBundleIDs, ["com.example.app"])
        XCTAssertEqual(policy.allowedBundleIDs, ["com.example.other"])
    }

    func testBlockedDecisionRequiresEnabledBlockListMode() {
        var policy = AppSiftNetworkPolicy(
            enabled: true,
            protectionMode: .blockList,
            blockedBundleIDs: ["com.example.app"]
        )
        XCTAssertTrue(policy.isBlocked(bundleIdentifier: "com.example.app"))

        policy.enabled = false
        XCTAssertFalse(policy.isBlocked(bundleIdentifier: "com.example.app"))

        policy.enabled = true
        policy.protectionMode = .monitor
        XCTAssertFalse(policy.isBlocked(bundleIdentifier: "com.example.app"))
    }

    func testFlowRecordReportsCombinedTraffic() {
        let flow = AppSiftNetworkFlowRecord(
            id: "flow-1",
            bundleIdentifier: "com.example.app",
            bytesReceived: 20,
            bytesSent: 22
        )
        XCTAssertEqual(flow.totalBytes, 42)
    }
}
