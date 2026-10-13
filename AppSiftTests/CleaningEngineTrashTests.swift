import Darwin
import Foundation
import XCTest
@testable import AppSift

final class CleaningEngineTrashTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let home: URL
        let source: URL
        let trash: URL
        let history: URL
        let parentFingerprint: ReviewedTrashFingerprint
        let sentinel: URL
        let contents = Data("recoverable cache".utf8)

        init() throws {
            root = try makeTrashQATemporaryDirectory(prefix: "CleanupTrash")
            home = root.appendingPathComponent("Home")
            source = home.appendingPathComponent("Library/Caches/com.example.fixture/cache.bin")
            trash = root.appendingPathComponent("Trash")
            history = root.appendingPathComponent("History/receipt.json")
            sentinel = root.appendingPathComponent("untouched.txt")
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try contents.write(to: source)
            try Data("untouched".utf8).write(to: sentinel)
            parentFingerprint = try XCTUnwrap(ReviewedTrashFingerprint.read(at: home))
        }

        func item(_ url: URL? = nil, category: CleaningCategory = .userCache) -> CleanableItem {
            let url = url ?? source
            return CleanableItem(name: url.lastPathComponent, path: url.path,
                                 size: Int64(contents.count), category: category,
                                 isSelected: true, lastModified: nil)
        }

        func service(historyURL: URL? = nil,
                     privileged: PrivilegedAppRemovalService? = nil,
                     failedPaths: Set<String> = []) throws -> ReviewedTrashService {
            let recycler = try DisposableTrashRecycler(trashRoot: trash, failedPaths: failedPaths)
            return ReviewedTrashService(
                historyStore: ReviewedTrashHistoryStore(fileURL: historyURL ?? history),
                additionalTrashRoots: [trash], privilegedService: privileged,
                recycler: { await recycler.recycle($0) }
            )
        }

        func privileged(cancelled: Bool = false, failingPath: String? = nil) -> PrivilegedAppRemovalService {
            PrivilegedAppRemovalService(
                trashRoot: trash, allowedSourceRoots: [home], parentIsWritable: { _ in false },
                authorizationRunner: { plan in
                    if cancelled { return .authorizationCancelled }
                    var moved: Set<Int> = []
                    var failures: [Int: String] = [:]
                    for (index, item) in plan.items.enumerated() {
                        // This injected runner only moves independent fixture files.
                        guard let canonicalRoot = Self.canonicalPath(root),
                              let sourceParent = Self.canonicalPath(item.sourceURL.deletingLastPathComponent()),
                              let destinationParent = Self.canonicalPath(item.destinationURL.deletingLastPathComponent()),
                              sourceParent.hasPrefix(canonicalRoot + "/"),
                              destinationParent.hasPrefix(canonicalRoot + "/") else {
                            return .failed("fixture boundary violation")
                        }
                        if let failingPath, plan.operation == .trash,
                           Self.canonicalPath(item.sourceURL) == Self.canonicalPath(URL(fileURLWithPath: failingPath)) {
                            failures[index] = "NSPOSIXErrorDomain (13): fixture permission denied"
                            continue
                        }
                        do {
                            try FileManager.default.moveItem(at: item.sourceURL, to: item.destinationURL)
                            try Data("moved".utf8).write(to: root.appendingPathComponent("\(plan.operation.rawValue).receipt"))
                            moved.insert(index)
                        } catch { failures[index] = String(describing: error) }
                    }
                    return failures.isEmpty ? .succeeded(loadedLaunchdItemIndexes: [])
                        : .partiallySucceeded(movedItemIndexes: moved, failedItemDetails: failures,
                                              loadedLaunchdItemIndexes: [])
                }
            )
        }

        private static func canonicalPath(_ url: URL) -> String? {
            guard let pointer = realpath(url.path, nil) else { return nil }
            defer { free(pointer) }
            return String(cString: pointer)
        }

        func verifyAndRecycle(file: StaticString = #filePath, line: UInt = #line) throws {
            let parent = try XCTUnwrap(ReviewedTrashFingerprint.read(at: home), file: file, line: line)
            XCTAssertEqual(parent.device, parentFingerprint.device, file: file, line: line)
            XCTAssertEqual(parent.inode, parentFingerprint.inode, file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("untouched".utf8), file: file, line: line)
            try recycleQAFixture(root, file: file, line: line)
        }
    }

    func testCacheMovesToTrashWithDurableReceiptAndUndo() async throws {
        let fixture = try Fixture()
        defer { try? fixture.verifyAndRecycle() }
        let engine = CleaningEngine(homeURL: fixture.home, trashService: try fixture.service())
        let result = await engine.cleanItems([fixture.item()]) { _ in }
        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertEqual(result.freedSpace, 0)
        XCTAssertEqual(result.trashedSpace, Int64(fixture.contents.count))
        XCTAssertTrue(result.errors.isEmpty, result.errors.description)
        let history = await engine.recoveryHistory()
        let record = try XCTUnwrap(history.first)
        let trashPath = try XCTUnwrap(record.items.first?.trashPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: trashPath)), fixture.contents)
        let reloaded = ReviewedTrashHistoryStore(fileURL: fixture.history).snapshot()
        XCTAssertEqual(reloaded, history)
        let restored = await engine.undo(record)
        XCTAssertEqual(restored.restoredCount, 1)
        XCTAssertTrue(restored.historyPersisted)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.contents)
    }

    func testChangedCacheIsRejectedBeforeAnyMove() async throws {
        let fixture = try Fixture()
        defer { try? fixture.verifyAndRecycle() }
        let item = fixture.item()
        try FileManager.default.moveItem(at: fixture.source, to: fixture.root.appendingPathComponent("original.bin"))
        try Data("replacement".utf8).write(to: fixture.source)
        let result = await CleaningEngine(homeURL: fixture.home, trashService: try fixture.service())
            .cleanItems([item]) { _ in }
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("replacement".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    }

    func testRealFinderRecycleProvidesTrashReceiptAndUndoRestoresExactBytes() async throws {
        let fixture = try Fixture()
        defer { try? fixture.verifyAndRecycle() }
        let service = ReviewedTrashService(historyStore: ReviewedTrashHistoryStore(fileURL: fixture.history))
        let engine = CleaningEngine(homeURL: fixture.home, trashService: service)
        let result = await engine.cleanItems([fixture.item()]) { _ in }
        XCTAssertEqual(result.itemsCleaned, 1, result.errors.description)
        let history = await engine.recoveryHistory()
        let record = try XCTUnwrap(history.first)
        let destination = URL(fileURLWithPath: try XCTUnwrap(record.items.first?.trashPath))
        XCTAssertEqual(try Data(contentsOf: destination), fixture.contents)
        XCTAssertEqual(ReviewedTrashFingerprint.read(at: destination), record.items.first?.fingerprint)
        let restored = await engine.undo(record)
        XCTAssertEqual(restored.restoredCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.contents)
    }

    func testSharedRootsAndOtherApplicationsSettingsCannotEnterCleanup() async throws {
        let fixture = try Fixture()
        defer { try? fixture.verifyAndRecycle() }
        let engine = CleaningEngine(homeURL: fixture.home, trashService: try fixture.service())
        for suffix in ["Library", "Library/Caches", "Library/Logs", "Library/Containers",
                       "Library/Group Containers", "Library/Preferences", "Library/Mail",
                       "Library/Mobile Documents", "Library/Application Support",
                       "Library/Containers/com.apple.mail", "Library/Preferences/com.apple.mail.plist"] {
            let url = fixture.home.appendingPathComponent(suffix)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let marker = url.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: marker)
            let result = await engine.cleanItems([fixture.item(url)]) { _ in }
            XCTAssertEqual(result.itemsCleaned, 0, suffix)
            XCTAssertTrue(result.requiresAdmin.isEmpty, suffix)
            XCTAssertFalse(result.errors.isEmpty, suffix)
            XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8), suffix)
        }
    }

    func testSymlinkedCacheCannotReachSiblingSettings() async throws {
        let fixture = try Fixture()
        defer { try? fixture.verifyAndRecycle() }
        let settings = fixture.home.appendingPathComponent("Library/Preferences")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        let file = settings.appendingPathComponent("keep.plist")
        try Data("settings".utf8).write(to: file)
        let alias = fixture.home.appendingPathComponent("Library/Caches/link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: settings)
        let engine = CleaningEngine(homeURL: fixture.home, trashService: try fixture.service())
        let result = await engine.cleanItems([fixture.item(alias.appendingPathComponent("keep.plist"))]) { _ in }
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(try Data(contentsOf: file), Data("settings".utf8))
    }

    func testLaterItemIsRevalidatedAfterAnEarlierMoveSuspends() async throws {
        let fixture = try Fixture()
        defer { try? fixture.verifyAndRecycle() }
        let second = fixture.source.deletingLastPathComponent().appendingPathComponent("second.bin")
        try Data("old second".utf8).write(to: second)
        let items = [fixture.item(), fixture.item(second)]
        let service = ReviewedTrashService(
            historyStore: ReviewedTrashHistoryStore(fileURL: fixture.history), additionalTrashRoots: [fixture.trash],
            recycler: { urls in
                let url = urls[0]
                let destination = fixture.trash.appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.moveItem(at: url, to: destination)
                    if url == fixture.source {
                        try FileManager.default.moveItem(at: second, to: fixture.root.appendingPathComponent("old-second.bin"))
                        try Data("new second".utf8).write(to: second)
                    }
                    return [url: destination]
                } catch { return [:] }
            }
        )
        let engine = CleaningEngine(homeURL: fixture.home, trashService: service)
        let result = await engine.cleanItems(items) { _ in }
        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertTrue(result.errors.contains { $0.contains(AppFileRemovalFailure(kind: .unsafePath).localizedDescription) })
        XCTAssertEqual(try Data(contentsOf: second), Data("new second".utf8))
        let history = await engine.recoveryHistory()
        let restored = await engine.undo(try XCTUnwrap(history.first))
        XCTAssertEqual(restored.restoredCount, 1)
    }

    func testUndoNeverOverwritesANewerFileAtOriginalPath() async throws {
        let fixture = try Fixture()
        defer { try? fixture.verifyAndRecycle() }
        let engine = CleaningEngine(homeURL: fixture.home, trashService: try fixture.service())
        let result = await engine.cleanItems([fixture.item()]) { _ in }
        XCTAssertEqual(result.itemsCleaned, 1)
        let history = await engine.recoveryHistory()
        let record = try XCTUnwrap(history.first)
        try Data("new settings".utf8).write(to: fixture.source)
        let restored = await engine.undo(record)
        XCTAssertEqual(restored.restoredCount, 0)
        XCTAssertEqual(restored.failedCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("new settings".utf8))
        let trashPath = try XCTUnwrap(record.items.first?.trashPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: trashPath)), fixture.contents)
    }

    func testHistoryFailureRollsCacheBack() async throws {
        let fixture = try Fixture()
        defer { try? fixture.verifyAndRecycle() }
        let blocked = fixture.root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let engine = CleaningEngine(homeURL: fixture.home,
            trashService: try fixture.service(historyURL: blocked.appendingPathComponent("receipt.json")))
        let result = await engine.cleanItems([fixture.item()]) { _ in }
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertEqual(result.trashedSpace, 0)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.contents)
    }

    func testAdministratorCleanupUsesRecoverableMoveAndUndo() async throws {
        let fixture = try Fixture()
        defer { try? fixture.verifyAndRecycle() }
        let privileged = fixture.privileged()
        let engine = CleaningEngine(homeURL: fixture.home,
                                   trashService: try fixture.service(privileged: privileged),
                                   privilegedService: privileged)
        let regular = await engine.cleanItems([fixture.item()]) { _ in }
        XCTAssertEqual(regular.itemsCleaned, 0)
        XCTAssertEqual(regular.requiresAdmin.count, 1)
        let result = await engine.cleanWithAdminPrivileges(items: regular.requiresAdmin)
        XCTAssertEqual(result.itemsCleaned, 1, result.errors.description)
        XCTAssertEqual(result.freedSpace, 0)
        let history = await engine.recoveryHistory()
        let record = try XCTUnwrap(history.first)
        XCTAssertEqual(record.items.first?.usedAdministrator, true)
        let trashPath = try XCTUnwrap(record.items.first?.trashPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: trashPath)), fixture.contents)
        let restored = await engine.undo(record)
        XCTAssertEqual(restored.restoredCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.contents)
    }

    func testAdministratorPartialFailurePreservesSuccessAndReportsExactError() async throws {
        let fixture = try Fixture()
        defer { try? fixture.verifyAndRecycle() }
        let failing = fixture.source.deletingLastPathComponent().appendingPathComponent("failure.bin")
        try Data("leave this".utf8).write(to: failing)
        let privileged = fixture.privileged(failingPath: failing.path)
        let engine = CleaningEngine(homeURL: fixture.home,
            trashService: try fixture.service(privileged: privileged), privilegedService: privileged)
        let result = await engine.cleanWithAdminPrivileges(items: [fixture.item(), fixture.item(failing)])
        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertTrue(result.errors.contains { $0.contains(failing.path) && $0.contains("NSPOSIXErrorDomain (13)") })
        XCTAssertEqual(try Data(contentsOf: failing), Data("leave this".utf8))
        let history = await engine.recoveryHistory()
        XCTAssertEqual(history.first?.items.filter { $0.status == .movedToTrash }.count, 1)
        let restored = await engine.undo(try XCTUnwrap(history.first))
        XCTAssertEqual(restored.restoredCount, 1)
    }

    func testAdministratorHistoryFailureRestoresTheMovedFile() async throws {
        let fixture = try Fixture()
        defer { try? fixture.verifyAndRecycle() }
        let blocked = fixture.root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let privileged = fixture.privileged()
        let engine = CleaningEngine(homeURL: fixture.home,
            trashService: try fixture.service(historyURL: blocked.appendingPathComponent("receipt.json"), privileged: privileged),
            privilegedService: privileged)
        let result = await engine.cleanWithAdminPrivileges(items: [fixture.item()])
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.contents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("trash.receipt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("restore.receipt").path))
    }

    func testAuthorizationCancellationLeavesFileAndReportsCancellation() async throws {
        let fixture = try Fixture()
        defer { try? fixture.verifyAndRecycle() }
        let privileged = fixture.privileged(cancelled: true)
        let engine = CleaningEngine(homeURL: fixture.home,
            trashService: try fixture.service(privileged: privileged), privilegedService: privileged)
        let result = await engine.cleanWithAdminPrivileges(items: [fixture.item()])
        XCTAssertEqual(result.itemsCleaned, 0)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.contents)
        let history = await engine.recoveryHistory()
        XCTAssertEqual(history.first?.items.first?.failure?.kind, .administratorAuthorizationCancelled)
    }

    func testOverlappingSelectionsMoveOnceAndDoNotDoubleCount() async throws {
        let fixture = try Fixture()
        defer { try? fixture.verifyAndRecycle() }
        let parent = fixture.source.deletingLastPathComponent()
        let engine = CleaningEngine(homeURL: fixture.home, trashService: try fixture.service())
        let result = await engine.cleanItems([fixture.item(parent), fixture.item(), fixture.item()]) { _ in }
        XCTAssertEqual(result.itemsCleaned, 1)
        XCTAssertEqual(result.trashedSpace, Int64(fixture.contents.count))
        XCTAssertEqual(result.cleanedPaths, [parent.path, fixture.source.path])
        let history = await engine.recoveryHistory()
        let restored = await engine.undo(try XCTUnwrap(history.first))
        XCTAssertEqual(restored.restoredCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.contents)
    }

    @MainActor
    func testRejectedCleanupKeepsReviewInsteadOfShowingSuccess() async throws {
        let fixture = try Fixture()
        defer { try? fixture.verifyAndRecycle() }
        let item = fixture.item(fixture.home, category: .largeFiles)
        let state = AppState(performStartupTasks: false)
        state.categoryResults[.largeFiles] = CategoryResult(category: .largeFiles, items: [item], totalSize: item.size)
        state.cleanCategory(.largeFiles)
        try await waitForQACondition { !state.scanState.isActive }
        XCTAssertEqual(state.scanState, .completed)
        XCTAssertNotNil(state.cleanError)
        XCTAssertEqual(state.categoryResults[.largeFiles]?.items.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.contents)
    }

    @MainActor
    func testTrashItemsCannotBeSelectedAndConfirmationPromisesRecovery() {
        let item = CleanableItem(name: "Already trashed", path: "/unused", size: 1,
                                 category: .trashBins, isSelected: true, lastModified: nil)
        XCTAssertTrue(item.isManualAction)
        XCTAssertFalse(item.isEligibleForAutomaticCleanup)
        let state = AppState(performStartupTasks: false)
        XCTAssertFalse(state.isItemSelected(item))
        XCTAssertEqual(state.cleanupConfirmationMessage(for: [item]),
                       String(localized: "These files will move to Trash with recovery history. You can undo the removal; disk space is released when Trash is emptied."))
    }
}
