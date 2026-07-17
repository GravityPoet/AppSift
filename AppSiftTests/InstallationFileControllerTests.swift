import Darwin
import XCTest
@testable import AppSift

final class InstallationFileControllerTests: XCTestCase {
    func testTrashHistoryPermissionsAndUndoRoundTrip() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.cleanup() }
        let original = try fixture.file(
            "home/Downloads/Example.dmg",
            data: "installer"
        )
        let item = try scannedItem(at: original, home: fixture.home)
        let historyFile = fixture.historyFile
        let trash = fixture.trash
        let store = InstallationFileRemovalHistoryStore(fileURL: historyFile)
        let controller = InstallationFileController(
            homeURL: fixture.home,
            trashURL: trash,
            historyStore: store,
            recycler: { urls in
                var mapping: [URL: URL] = [:]
                for url in urls {
                    let destination = trash.appendingPathComponent(
                        UUID().uuidString + "-" + url.lastPathComponent
                    )
                    try? FileManager.default.moveItem(at: url, to: destination)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        mapping[url] = destination
                    }
                }
                return InstallationFileRecycleResult(
                    recycled: mapping,
                    errorDescription: nil
                )
            }
        )

        let removal = await controller.remove([item])
        XCTAssertEqual(removal.movedCount, 1)
        XCTAssertTrue(removal.historyPersisted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let record = try XCTUnwrap(removal.record)
        XCTAssertTrue(controller.canUndo(record))

        let historyAttributes = try FileManager.default.attributesOfItem(
            atPath: historyFile.path
        )
        let historyMode = try XCTUnwrap(
            historyAttributes[.posixPermissions] as? NSNumber
        ).uint16Value
        XCTAssertEqual(historyMode & 0o777, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: historyFile.deletingLastPathComponent().path
        )
        let directoryMode = try XCTUnwrap(
            directoryAttributes[.posixPermissions] as? NSNumber
        ).uint16Value
        XCTAssertEqual(directoryMode & 0o777, 0o700)

        let undo = controller.undo(record)
        XCTAssertEqual(undo.restoredCount, 1)
        XCTAssertEqual(undo.failedCount, 0)
        XCTAssertTrue(undo.historyPersisted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(controller.canUndo(record))
    }

    func testChangedFingerprintAndSymlinkReplacementAreRejectedBeforeTrash() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.cleanup() }
        let original = try fixture.file(
            "home/Downloads/Changed.pkg",
            data: "first"
        )
        let item = try scannedItem(at: original, home: fixture.home)
        try Data("changed-size".utf8).write(to: original)
        let recyclerCalled = LockedFlag()
        let controller = InstallationFileController(
            homeURL: fixture.home,
            trashURL: fixture.trash,
            historyStore: InstallationFileRemovalHistoryStore(
                fileURL: fixture.historyFile
            ),
            recycler: { _ in
                recyclerCalled.set()
                return InstallationFileRecycleResult(
                    recycled: [:],
                    errorDescription: nil
                )
            }
        )

        let changedOutcome = await controller.remove([item])
        XCTAssertEqual(changedOutcome.items.first?.status, .rejected)
        XCTAssertFalse(recyclerCalled.value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))

        let second = try fixture.file(
            "home/Downloads/Symlink.dmg",
            data: "second"
        )
        let secondItem = try scannedItem(at: second, home: fixture.home)
        let target = try fixture.file(
            "home/Downloads/Target.dmg",
            data: "target"
        )
        try FileManager.default.removeItem(at: second)
        try FileManager.default.createSymbolicLink(
            at: second,
            withDestinationURL: target
        )
        let symlinkOutcome = await controller.remove([secondItem])
        XCTAssertEqual(symlinkOutcome.items.first?.status, .rejected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testHistoryPersistenceFailureRollsTrashMoveBack() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.cleanup() }
        let original = try fixture.file(
            "home/Downloads/Rollback.xip",
            data: "archive"
        )
        let item = try scannedItem(at: original, home: fixture.home)
        let realHistoryDirectory = try fixture.directory("home/RealHistory")
        let linkedHistoryDirectory = fixture.home.appendingPathComponent(
            "LinkedHistory",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedHistoryDirectory,
            withDestinationURL: realHistoryDirectory
        )
        let failingStore = InstallationFileRemovalHistoryStore(
            fileURL: linkedHistoryDirectory.appendingPathComponent("history.json")
        )
        let trash = fixture.trash
        let controller = InstallationFileController(
            homeURL: fixture.home,
            trashURL: trash,
            historyStore: failingStore,
            recycler: { urls in
                var mapping: [URL: URL] = [:]
                for url in urls {
                    let destination = trash.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.moveItem(at: url, to: destination)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        mapping[url] = destination
                    }
                }
                return InstallationFileRecycleResult(
                    recycled: mapping,
                    errorDescription: nil
                )
            }
        )

        let outcome = await controller.remove([item])
        XCTAssertFalse(outcome.historyPersisted)
        XCTAssertEqual(
            outcome.items.first?.status,
            .rolledBackAfterHistoryFailure
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(controller.historySnapshot().isEmpty)
    }

    func testUndoRefusesToOverwriteNewDestination() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.cleanup() }
        let original = try fixture.file(
            "home/Downloads/Collision.dmg",
            data: "old"
        )
        let item = try scannedItem(at: original, home: fixture.home)
        let trash = fixture.trash
        let controller = InstallationFileController(
            homeURL: fixture.home,
            trashURL: trash,
            historyStore: InstallationFileRemovalHistoryStore(
                fileURL: fixture.historyFile
            ),
            recycler: { urls in
                var mapping: [URL: URL] = [:]
                for url in urls {
                    let destination = trash.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.moveItem(at: url, to: destination)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        mapping[url] = destination
                    }
                }
                return InstallationFileRecycleResult(
                    recycled: mapping,
                    errorDescription: nil
                )
            }
        )
        let removal = await controller.remove([item])
        let record = try XCTUnwrap(removal.record)
        try Data("new".utf8).write(to: original)

        let undo = controller.undo(record)
        XCTAssertEqual(undo.restoredCount, 0)
        XCTAssertGreaterThan(undo.failedCount, 0)
        XCTAssertEqual(try String(contentsOf: original), "new")
        let trashPath = try XCTUnwrap(record.items.first?.trashPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashPath))
    }

    func testUntrustedRecycleMappingIsNotRecordedAsRecoverable() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.cleanup() }
        let original = try fixture.file(
            "home/Downloads/Mapping.dmg",
            data: "installer"
        )
        let item = try scannedItem(at: original, home: fixture.home)
        let outsideTrash = try fixture.file(
            "home/Downloads/Unrelated.dmg",
            data: "unrelated"
        )
        let controller = InstallationFileController(
            homeURL: fixture.home,
            trashURL: fixture.trash,
            historyStore: InstallationFileRemovalHistoryStore(
                fileURL: fixture.historyFile
            ),
            recycler: { urls in
                InstallationFileRecycleResult(
                    recycled: [urls[0]: outsideTrash],
                    errorDescription: nil
                )
            }
        )

        let outcome = await controller.remove([item])
        XCTAssertEqual(outcome.items.first?.status, .trashFailed)
        XCTAssertNil(outcome.record)
        XCTAssertTrue(controller.historySnapshot().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testHistoryLoaderRejectsGroupReadableFile() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.cleanup() }
        let original = try fixture.file(
            "home/Downloads/History.pkg",
            data: "installer"
        )
        let item = try scannedItem(at: original, home: fixture.home)
        let trashPath = fixture.trash.appendingPathComponent("History.pkg")
        let historyItem = InstallationFileRemovalHistoryItem(
            originalPath: original.path,
            trashPath: trashPath.path,
            name: original.lastPathComponent,
            kind: .installerPackage,
            size: item.size,
            fingerprint: item.fingerprint,
            status: .movedToTrash
        )
        let record = InstallationFileRemovalRecord(items: [historyItem])
        try FileManager.default.createDirectory(
            at: fixture.historyFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode([record]).write(to: fixture.historyFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o640)],
            ofItemAtPath: fixture.historyFile.path
        )

        let store = InstallationFileRemovalHistoryStore(
            fileURL: fixture.historyFile
        )
        XCTAssertTrue(store.snapshot().isEmpty)
    }

    func testAppManagedInstallerRequiresExactExplicitApproval() async throws {
        let fixture = try ControllerFixture()
        defer { fixture.cleanup() }
        let managed = try fixture.file(
            "home/Library/Caches/com.example.updater/Update.pkg",
            data: "managed installer"
        )
        let item = try scannedItem(at: managed, home: fixture.home)
        XCTAssertEqual(
            item.removalEligibility,
            .protected(.applicationManagedCache)
        )
        let trash = fixture.trash
        let recyclerCalled = LockedFlag()
        let controller = InstallationFileController(
            homeURL: fixture.home,
            trashURL: trash,
            historyStore: InstallationFileRemovalHistoryStore(
                fileURL: fixture.historyFile
            ),
            recycler: { urls in
                recyclerCalled.set()
                var mapping: [URL: URL] = [:]
                for url in urls {
                    let destination = trash.appendingPathComponent(
                        UUID().uuidString + "-" + url.lastPathComponent
                    )
                    try? FileManager.default.moveItem(at: url, to: destination)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        mapping[url] = destination
                    }
                }
                return InstallationFileRecycleResult(
                    recycled: mapping,
                    errorDescription: nil
                )
            }
        )

        let blocked = await controller.remove([item])
        XCTAssertEqual(blocked.items.first?.status, .rejected)
        XCTAssertFalse(recyclerCalled.value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: managed.path))

        let approved = await controller.remove(
            [item],
            explicitlyApprovedItemIDs: [item.id]
        )
        XCTAssertEqual(approved.movedCount, 1)
        XCTAssertTrue(recyclerCalled.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
    }

    private func scannedItem(
        at url: URL,
        home: URL
    ) throws -> InstallationFileItem {
        let result = InstallationFileScanner.scan(
            candidateURLs: [url],
            installedApps: [],
            homeURL: home,
            signatureProvider: { _ in .unknown }
        )
        return try XCTUnwrap(result.items.first)
    }
}

private final class ControllerFixture {
    let root: URL
    let home: URL
    let trash: URL
    let historyFile: URL

    init() throws {
        root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".appsift-installation-controller-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        home = root.appendingPathComponent("home", isDirectory: true)
        trash = home.appendingPathComponent(".Trash", isDirectory: true)
        historyFile = home
            .appendingPathComponent(
                "Library/Application Support/AppSift",
                isDirectory: true
            )
            .appendingPathComponent("installation-file-removal-history.json")
        try FileManager.default.createDirectory(
            at: trash,
            withIntermediateDirectories: true
        )
    }

    func directory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    func file(_ relativePath: String, data: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(data.utf8).write(to: url)
        return url
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}
