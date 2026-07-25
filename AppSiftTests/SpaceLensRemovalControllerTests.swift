import Darwin
import XCTest
@testable import AppSift

final class SpaceLensRemovalControllerTests: XCTestCase {
    func testMovesFileToTrashAndRestoresIt() async throws {
        let fixture = try makeFixture()
        let file = fixture.scanRoot.appendingPathComponent("video.mov")
        try Data(repeating: 0x41, count: 16_384).write(to: file)
        let result = try await SpaceLensScanner().scan(
            root: fixture.scanRoot
        )
        let node = try XCTUnwrap(
            result.root.children.first { $0.name == "video.mov" }
        )
        let controller = makeController(fixture)

        let removal = await controller.remove(
            nodes: [node],
            scanRoot: fixture.scanRoot
        )

        XCTAssertEqual(removal.movedCount, 1)
        XCTAssertTrue(removal.historyPersisted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let record = try XCTUnwrap(removal.record)
        XCTAssertTrue(controller.canUndo(record))

        let undo = controller.undo(record)

        XCTAssertEqual(undo.restoredCount, 1)
        XCTAssertTrue(undo.historyPersisted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(controller.canUndo(record))
    }

    func testMovesDirectoryTreeToTrashAndRestoresIt() async throws {
        let fixture = try makeFixture()
        let folder = fixture.scanRoot.appendingPathComponent(
            "Archive",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x42, count: 8_192).write(
            to: folder.appendingPathComponent("payload.bin")
        )
        let result = try await SpaceLensScanner().scan(
            root: fixture.scanRoot
        )
        let node = try XCTUnwrap(
            result.root.children.first { $0.name == "Archive" }
        )
        let controller = makeController(fixture)

        let removal = await controller.remove(
            nodes: [node],
            scanRoot: fixture.scanRoot
        )
        let record = try XCTUnwrap(removal.record)
        XCTAssertEqual(removal.movedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))

        let undo = controller.undo(record)

        XCTAssertEqual(undo.restoredCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("payload.bin").path
        ))
    }

    func testRejectsItemThatChangedAfterScan() async throws {
        let fixture = try makeFixture()
        let file = fixture.scanRoot.appendingPathComponent("mutable.bin")
        try Data(repeating: 0x10, count: 1_024).write(to: file)
        let result = try await SpaceLensScanner().scan(
            root: fixture.scanRoot
        )
        let node = try XCTUnwrap(result.root.children.first)
        try Data(repeating: 0x20, count: 2_048).write(to: file)
        let controller = makeController(fixture)

        let removal = await controller.remove(
            nodes: [node],
            scanRoot: fixture.scanRoot
        )

        XCTAssertEqual(removal.movedCount, 0)
        XCTAssertEqual(removal.failedCount, 1)
        XCTAssertEqual(removal.items.first?.status, .rejected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRejectsFolderContainingProtectedHardLinks() async throws {
        let fixture = try makeFixture()
        let folder = fixture.scanRoot.appendingPathComponent(
            "Linked",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let original = folder.appendingPathComponent("original.bin")
        let alias = folder.appendingPathComponent("alias.bin")
        try Data(repeating: 0x33, count: 4_096).write(to: original)
        XCTAssertEqual(link(original.path, alias.path), 0)
        let result = try await SpaceLensScanner().scan(
            root: fixture.scanRoot
        )
        let node = try XCTUnwrap(
            result.root.children.first { $0.name == "Linked" }
        )
        XCTAssertGreaterThan(node.protectedDescendantCount, 0)
        let controller = makeController(fixture)

        let removal = await controller.remove(
            nodes: [node],
            scanRoot: fixture.scanRoot
        )

        XCTAssertEqual(removal.movedCount, 0)
        XCTAssertEqual(removal.items.first?.status, .rejected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testHistoryFailureRollsMovedItemBack() async throws {
        let fixture = try makeFixture()
        let file = fixture.scanRoot.appendingPathComponent("rollback.bin")
        try Data(repeating: 0x51, count: 4_096).write(to: file)
        let result = try await SpaceLensScanner().scan(
            root: fixture.scanRoot
        )
        let node = try XCTUnwrap(result.root.children.first)

        let realHistoryDirectory = fixture.base.appendingPathComponent(
            "real-history",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: realHistoryDirectory,
            withIntermediateDirectories: true
        )
        let linkedHistoryDirectory = fixture.base.appendingPathComponent(
            "linked-history",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedHistoryDirectory,
            withDestinationURL: realHistoryDirectory
        )
        let unsafeStore = SpaceLensRemovalHistoryStore(
            fileURL: linkedHistoryDirectory.appendingPathComponent(
                "history.json"
            )
        )
        let controller = SpaceLensRemovalController(
            trashRoot: fixture.trashRoot,
            historyStore: unsafeStore,
            recycler: recycler(into: fixture.trashRoot)
        )

        let removal = await controller.remove(
            nodes: [node],
            scanRoot: fixture.scanRoot
        )

        XCTAssertFalse(removal.historyPersisted)
        XCTAssertEqual(
            removal.items.first?.status,
            .rolledBackAfterHistoryFailure
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRejectsUnrecognizedTrashLocation() async throws {
        let fixture = try makeFixture()
        let file = fixture.scanRoot.appendingPathComponent("unsafe.bin")
        try Data(repeating: 0x61, count: 4_096).write(to: file)
        let result = try await SpaceLensScanner().scan(
            root: fixture.scanRoot
        )
        let node = try XCTUnwrap(result.root.children.first)
        let unrecognizedTrash = fixture.base.appendingPathComponent(
            "nested/.Trash",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unrecognizedTrash,
            withIntermediateDirectories: true
        )
        let controller = SpaceLensRemovalController(
            trashRoot: fixture.trashRoot,
            historyStore: fixture.historyStore,
            recycler: recycler(into: unrecognizedTrash)
        )

        let removal = await controller.remove(
            nodes: [node],
            scanRoot: fixture.scanRoot
        )

        XCTAssertEqual(removal.movedCount, 0)
        XCTAssertEqual(removal.items.first?.status, .trashFailed)
        XCTAssertNil(removal.record)
    }

    func testUndoRejectsTrashItemThatChanged() async throws {
        let fixture = try makeFixture()
        let file = fixture.scanRoot.appendingPathComponent("changed.bin")
        try Data(repeating: 0x71, count: 4_096).write(to: file)
        let result = try await SpaceLensScanner().scan(
            root: fixture.scanRoot
        )
        let node = try XCTUnwrap(result.root.children.first)
        let controller = makeController(fixture)
        let removal = await controller.remove(
            nodes: [node],
            scanRoot: fixture.scanRoot
        )
        let record = try XCTUnwrap(removal.record)
        let trashPath = try XCTUnwrap(record.items.first?.trashPath)
        try Data(repeating: 0x72, count: 8_192).write(
            to: URL(fileURLWithPath: trashPath)
        )

        let undo = controller.undo(record)

        XCTAssertEqual(undo.restoredCount, 0)
        XCTAssertGreaterThan(undo.failedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    private struct Fixture {
        let base: URL
        let scanRoot: URL
        let trashRoot: URL
        let historyStore: SpaceLensRemovalHistoryStore
    }

    private func makeFixture() throws -> Fixture {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".appsift-space-lens-removal-\(UUID().uuidString)",
                isDirectory: true
            )
        let scanRoot = base.appendingPathComponent(
            "scan",
            isDirectory: true
        )
        let trashRoot = base.appendingPathComponent(
            ".Trash",
            isDirectory: true
        )
        let historyDirectory = base.appendingPathComponent(
            "history",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: scanRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: trashRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: historyDirectory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: base)
        }
        return Fixture(
            base: base,
            scanRoot: scanRoot,
            trashRoot: trashRoot,
            historyStore: SpaceLensRemovalHistoryStore(
                fileURL: historyDirectory.appendingPathComponent(
                    "history.json"
                )
            )
        )
    }

    private func makeController(
        _ fixture: Fixture
    ) -> SpaceLensRemovalController {
        SpaceLensRemovalController(
            trashRoot: fixture.trashRoot,
            historyStore: fixture.historyStore,
            recycler: recycler(into: fixture.trashRoot)
        )
    }

    private func recycler(
        into trashRoot: URL
    ) -> SpaceLensRemovalController.Recycler {
        { urls in
            var recycled: [URL: URL] = [:]
            for url in urls {
                let destination = trashRoot.appendingPathComponent(
                    "\(UUID().uuidString)-\(url.lastPathComponent)"
                )
                do {
                    try FileManager.default.moveItem(
                        at: url,
                        to: destination
                    )
                    recycled[url] = destination
                } catch {
                    return SpaceLensRecycleResult(
                        recycled: recycled,
                        errorDescription: error.localizedDescription
                    )
                }
            }
            return SpaceLensRecycleResult(
                recycled: recycled,
                errorDescription: nil
            )
        }
    }
}
