import Darwin
import Foundation
import XCTest
@testable import AppSift

final class SystemResidueFixtureTests: XCTestCase {
    func testRealDirectoryFixturesFindLegacyUsersAndOnlyUnparseablePreferences() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftResidueFixtures")
        defer { try? FileManager.default.removeItem(at: root) }
        let usersRoot = root.appendingPathComponent("Users", isDirectory: true)
        let home = root.appendingPathComponent("Home", isDirectory: true)
        try FileManager.default.createDirectory(at: usersRoot, withIntermediateDirectories: true)
        let active = usersRoot.appendingPathComponent("active", isDirectory: true)
        let orphan = usersRoot.appendingPathComponent("orphan", isDirectory: true)
        let deletedUsers = usersRoot.appendingPathComponent("Deleted Users", isDirectory: true)
        let wrongOwner = usersRoot.appendingPathComponent("wrong-owner", isDirectory: true)
        for directory in [active, orphan, deletedUsers, wrongOwner] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0x44, count: 1_024).write(
                to: directory.appendingPathComponent("payload.bin")
            )
        }
        let diskImage = usersRoot.appendingPathComponent("former.dmg")
        try Data(repeating: 0x45, count: 2_048).write(to: diskImage)

        let preferences = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        let valid = preferences.appendingPathComponent("com.example.valid.plist")
        let broken = preferences.appendingPathComponent("com.example.broken.plist")
        let empty = preferences.appendingPathComponent("com.example.empty.plist")
        try writeQAPlist(["enabled": true], to: valid)
        try Data("not a property list".utf8).write(to: broken)
        try Data().write(to: empty)

        let currentUID = UInt32(getuid())
        let scanner = SystemResidueScanner(
            usersRootURL: usersRoot,
            homeURL: home,
            documentRoots: [],
            localAccountsProvider: {
                [
                    "active": currentUID,
                    "wrong-owner": currentUID &+ 1,
                ]
            }
        )

        let result = try await scanner.scan()
        let residueKinds = Dictionary(uniqueKeysWithValues: result.legacyUsers.map {
            ($0.url.lastPathComponent, $0.kind)
        })
        XCTAssertNil(residueKinds["active"])
        XCTAssertEqual(residueKinds["orphan"], .missingAccount)
        XCTAssertEqual(residueKinds["Deleted Users"], .deletedUsersFolder)
        XCTAssertEqual(residueKinds["former.dmg"], .deletedUserDiskImage)
        XCTAssertEqual(residueKinds["wrong-owner"], .ownerMismatch)
        XCTAssertEqual(Set(result.corruptPreferences.map(\.url)), Set([broken, empty]))
        XCTAssertEqual(result.statistics.preferenceFilesChecked, 3)
        XCTAssertEqual(result.statistics.inaccessibleCount, 0)
        XCTAssertFalse(result.statistics.wasTruncated)

        try writeQAPlist(["repaired": true], to: broken)
        let revalidated = await scanner.revalidatePreferences(result.corruptPreferences)
        XCTAssertEqual(revalidated.map(\.url), [empty])
    }
}

final class SystemMaintenancePermissionTests: XCTestCase {
    func testDNSAuthorizationCancellationRunsOnlyTheReviewedCommand() async throws {
        let recorder = QACommandRecorder()
        let service = SystemMaintenanceService(authorizedCommandRunner: { command in
            recorder.append(command)
            throw SystemMaintenanceService.ServiceError.authorizationCancelled
        })

        do {
            try await service.flushDNSCache()
            XCTFail("Cancellation must be surfaced without running a fallback command.")
        } catch SystemMaintenanceService.ServiceError.authorizationCancelled {
            // Expected.
        }

        XCTAssertEqual(
            recorder.snapshot(),
            ["/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder"]
        )
    }

    func testSpotlightDisconnectBetweenRefreshAndRunStopsBeforeAuthorization() async throws {
        let volume = SpotlightVolume(
            id: "/Volumes/QA External",
            url: URL(fileURLWithPath: "/Volumes/QA External", isDirectory: true),
            name: "QA External",
            isInternal: false,
            isReadOnly: false,
            indexState: .enabled,
            statusDetail: "Indexing enabled."
        )
        let snapshots = QASpotlightSnapshotProvider([[volume], []])
        let commands = QACommandRecorder()
        let service = SystemMaintenanceService(
            spotlightVolumeProvider: { snapshots.next() },
            authorizedCommandRunner: { command in commands.append(command) }
        )
        let initial = await service.scan()
        XCTAssertEqual(initial.spotlightVolumes, [volume])

        do {
            try await service.rebuildSpotlight(volumeID: volume.id)
            XCTFail("An unmounted volume must stop before authorization.")
        } catch SystemMaintenanceService.ServiceError.volumeChanged {
            // Expected.
        }

        XCTAssertTrue(commands.snapshot().isEmpty)
    }

    func testSpotlightReadOnlyVolumeStopsBeforeAuthorization() async throws {
        let volume = SpotlightVolume(
            id: "/Volumes/QA Read Only",
            url: URL(fileURLWithPath: "/Volumes/QA Read Only", isDirectory: true),
            name: "QA Read Only",
            isInternal: false,
            isReadOnly: true,
            indexState: .enabled,
            statusDetail: "Indexing enabled."
        )
        let commands = QACommandRecorder()
        let service = SystemMaintenanceService(
            spotlightVolumeProvider: { [volume] },
            authorizedCommandRunner: { command in commands.append(command) }
        )

        do {
            try await service.rebuildSpotlight(volumeID: volume.id)
            XCTFail("A read-only volume must not reach the privileged runner.")
        } catch SystemMaintenanceService.ServiceError.readOnlyVolume {
            // Expected.
        }

        XCTAssertTrue(commands.snapshot().isEmpty)
    }

    func testSpotlightPermissionFailurePreservesShellQuotingAndSurfacesError() async throws {
        let volume = SpotlightVolume(
            id: "/Volumes/QA's Disk",
            url: URL(fileURLWithPath: "/Volumes/QA's Disk", isDirectory: true),
            name: "QA's Disk",
            isInternal: false,
            isReadOnly: false,
            indexState: .enabled,
            statusDetail: "Indexing enabled."
        )
        let commands = QACommandRecorder()
        let service = SystemMaintenanceService(
            spotlightVolumeProvider: { [volume] },
            authorizedCommandRunner: { command in
                commands.append(command)
                throw SystemMaintenanceService.ServiceError.authorizationFailed("permission denied")
            }
        )

        do {
            try await service.rebuildSpotlight(volumeID: volume.id)
            XCTFail("Permission failure must be surfaced.")
        } catch SystemMaintenanceService.ServiceError.authorizationFailed(let detail) {
            XCTAssertEqual(detail, "permission denied")
        }

        XCTAssertEqual(
            commands.snapshot(),
            ["/usr/bin/mdutil -E '/Volumes/QA'\"'\"'s Disk'"]
        )
    }

    func testMailDirectoryPermissionFailureIsReportedWithoutIndexCandidates() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftMailPermission")
        defer { try? FileManager.default.removeItem(at: root) }
        let mailRoot = root.appendingPathComponent("Library/Mail", isDirectory: true)
        try FileManager.default.createDirectory(at: mailRoot, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(mailRoot.path, 0o000), 0)
        defer { _ = chmod(mailRoot.path, 0o700) }

        let snapshot = await SystemMaintenanceService(homeURL: root).scan()

        XCTAssertTrue(snapshot.mailIndex.permissionDenied)
        XCTAssertTrue(snapshot.mailIndex.files.isEmpty)
    }
}

@MainActor
final class SystemIntegrationFallbackTests: XCTestCase {
    func testMailTerminationRefusalLeavesEveryIndexFileUntouched() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftMailTermination")
        defer { try? FileManager.default.removeItem(at: root) }
        let mailData = root.appendingPathComponent("Library/Mail/V10/MailData", isDirectory: true)
        try FileManager.default.createDirectory(at: mailData, withIntermediateDirectories: true)
        let index = mailData.appendingPathComponent("Envelope Index")
        try Data(repeating: 0x51, count: 4_096).write(to: index)
        let historyStore = ReviewedTrashHistoryStore(
            fileURL: root.appendingPathComponent("History/reviewed.json")
        )
        let trashService = try makeQATrashService(
            historyStore: historyStore,
            trashRoot: root.appendingPathComponent("Trash", isDirectory: true)
        )
        let center = SystemMaintenanceCenter(
            service: SystemMaintenanceService(homeURL: root, spotlightVolumeProvider: { [] }),
            trashService: trashService,
            historyStore: historyStore,
            mailRunningProvider: { true },
            mailTerminationHandler: { false }
        )

        center.refresh()
        try await waitForQACondition { !center.isRefreshing }
        XCTAssertEqual(center.mailIndex.files.map(\.url), [index])
        center.repairMailIndex()
        try await waitForQACondition { !center.isRepairingMail }

        XCTAssertTrue(FileManager.default.fileExists(atPath: index.path))
        XCTAssertTrue(center.history.isEmpty)
        XCTAssertEqual(center.errorMessage, "Mail did not quit. No index files were changed.")
    }

    func testDeniedNotificationStillKeepsExternalDiskAlertAndHistory() throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftNotificationDenied")
        defer { try? FileManager.default.removeItem(at: root) }
        let historyStore = SystemAlertHistoryStore(
            fileURL: root.appendingPathComponent("History/alerts.json")
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var attemptedNotifications = 0
        let center = SystemAlertCenter(
            historyStore: historyStore,
            telemetryProvider: {
                SystemAlertTelemetrySnapshot(
                    volumes: [
                        SystemVolumeSnapshot(
                            path: "/Volumes/QA External",
                            name: "QA External",
                            totalBytes: 100_000_000_000,
                            availableBytes: 1_000_000_000,
                            isInternal: false,
                            isRemovable: true,
                            isReadOnly: false
                        ),
                    ],
                    battery: nil,
                    deviceBatteries: [],
                    memory: nil,
                    trash: nil,
                    capturedAt: now
                )
            },
            notificationPoster: { _ in
                attemptedNotifications += 1
                throw QANotificationError.denied
            }
        )

        center.start()
        defer { center.stop() }

        XCTAssertEqual(center.activeConditions.map(\.kind), [.lowExternalDisk])
        XCTAssertEqual(center.history.map(\.kind), [.lowExternalDisk])
        XCTAssertEqual(historyStore.snapshot().map(\.kind), [.lowExternalDisk])
        XCTAssertEqual(attemptedNotifications, 1)
        XCTAssertEqual(center.lastCheckedAt, now)
    }
}

private enum QANotificationError: Error {
    case denied
}

private final class QACommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []

    func append(_ command: String) {
        lock.lock()
        commands.append(command)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }
}

private final class QASpotlightSnapshotProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [[SpotlightVolume]]

    init(_ snapshots: [[SpotlightVolume]]) {
        self.snapshots = snapshots
    }

    func next() -> [SpotlightVolume] {
        lock.lock()
        defer { lock.unlock() }
        guard !snapshots.isEmpty else { return [] }
        return snapshots.removeFirst()
    }
}
