import XCTest
@testable import AppSift

final class TimeMachineSnapshotServiceTests: XCTestCase {
    func testParseSnapshotsKeepsOnlyValidTimeMachineLocalSnapshotsNewestFirst() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-07-03-091500.local
        com.apple.os.update-123456
        com.apple.TimeMachine.invalid.local
        com.apple.TimeMachine.2026-07-04-224501.local
        """

        let snapshots = TimeMachineSnapshotService.parseSnapshots(output)

        XCTAssertEqual(snapshots.map(\.dateToken), [
            "2026-07-04-224501",
            "2026-07-03-091500",
        ])
    }

    func testParseSnapshotsRejectsImpossibleDates() {
        let output = """
        com.apple.TimeMachine.2026-02-30-120000.local
        com.apple.TimeMachine.2026-07-04-256100.local
        """

        XCTAssertTrue(TimeMachineSnapshotService.parseSnapshots(output).isEmpty)
    }

    func testParseSnapshotsAppliesKnownPrivateSizes() {
        let output = "com.apple.TimeMachine.2026-07-04-224501.local"

        let snapshots = TimeMachineSnapshotService.parseSnapshots(
            output,
            privateSizes: ["com.apple.TimeMachine.2026-07-04-224501.local": 872_087_552]
        )

        XCTAssertEqual(snapshots.first?.privateSize, 872_087_552)
    }

    func testParseBackupRunningRecognizesTmutilStatus() {
        XCTAssertTrue(TimeMachineSnapshotService.parseBackupRunning("Running = 1;"))
        XCTAssertTrue(TimeMachineSnapshotService.parseBackupRunning("  Running = 1 ;\n"))
        XCTAssertFalse(TimeMachineSnapshotService.parseBackupRunning("Running = 0;"))
    }

    func testDateTokenValidationRejectsShellInput() {
        XCTAssertTrue(TimeMachineSnapshotService.isValidDateToken("2026-07-04-224501"))
        XCTAssertFalse(TimeMachineSnapshotService.isValidDateToken("2026-07-04-224501; rm -rf /"))
        XCTAssertFalse(TimeMachineSnapshotService.isValidDateToken("/"))
    }
}
