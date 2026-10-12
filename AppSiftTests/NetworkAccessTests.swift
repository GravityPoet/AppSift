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

    func testNettopParserReadsPerProcessCounters() {
        let output = """
        time,,interface,state,bytes_in,bytes_out
        10:00:00.000000,Example App.123,,,1024,2048
        10:00:00.000001,\"Quoted, App.456\",,,3,5
        """

        XCTAssertEqual(
            AppSiftLocalNetworkTrafficSampler.parse(output),
            [
                AppSiftLocalNetworkTrafficSample(
                    processID: 123,
                    processName: "Example App.123",
                    bytesReceived: 1024,
                    bytesSent: 2048
                ),
                AppSiftLocalNetworkTrafficSample(
                    processID: 456,
                    processName: "Quoted, App.456",
                    bytesReceived: 3,
                    bytesSent: 5
                ),
            ]
        )
    }
}
