import Foundation
import XCTest
@testable import AppSift

final class DuplicateFileRemovalControllerTests: XCTestCase {
    func testMovesSelectedDuplicateAndCanUndoIt() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try Data("duplicate".utf8).write(to: first)
        try Data("duplicate".utf8).write(to: second)
        let group = try await duplicateGroup(in: root)
        let selected = try XCTUnwrap(group.files.first { $0.url == second })
        let store = DuplicateFileRemovalHistoryStore(
            fileURL: root.appendingPathComponent("history/duplicates.json")
        )
        let controller = DuplicateFileRemovalController(
            historyStore: store,
            recycler: testRecycler(trashDirectory: trash),
            trashPathValidator: { $0.path.hasPrefix(trash.path + "/") }
        )

        let removal = await controller.remove(
            groups: [group],
            selectedItemIDs: [selected.id]
        )

        XCTAssertEqual(removal.movedCount, 1)
        XCTAssertTrue(removal.historyPersisted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        let record = try XCTUnwrap(removal.record)
        XCTAssertTrue(controller.canUndo(record))

        let undo = controller.undo(record)

        XCTAssertEqual(undo.restoredCount, 1)
        XCTAssertTrue(undo.historyPersisted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertFalse(controller.canUndo(undo.record))
    }

    func testRejectsSelectionWhenNoVerifiedCopyWouldRemain() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("duplicate".utf8).write(
            to: root.appendingPathComponent("first.txt")
        )
        try Data("duplicate".utf8).write(
            to: root.appendingPathComponent("second.txt")
        )
        let group = try await duplicateGroup(in: root)
        let controller = DuplicateFileRemovalController(
            historyStore: DuplicateFileRemovalHistoryStore(
                fileURL: root.appendingPathComponent("history.json")
            ),
            recycler: { _ in
                XCTFail("Recycler must not run")
                return DuplicateFileRecycleResult(
                    recycled: [:],
                    errorDescription: nil
                )
            },
            trashPathValidator: { _ in true }
        )

        let outcome = await controller.remove(
            groups: [group],
            selectedItemIDs: Set(group.files.map(\.id))
        )

        XCTAssertEqual(outcome.movedCount, 0)
        XCTAssertEqual(outcome.failedCount, 2)
        XCTAssertTrue(outcome.items.allSatisfy { $0.status == .rejected })
    }

    func testRejectsFileThatChangedAfterScan() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try Data("duplicate".utf8).write(to: first)
        try Data("duplicate".utf8).write(to: second)
        let group = try await duplicateGroup(in: root)
        let selected = try XCTUnwrap(group.files.first { $0.url == second })
        try Data("something-else".utf8).write(to: second)
        let controller = DuplicateFileRemovalController(
            historyStore: DuplicateFileRemovalHistoryStore(
                fileURL: root.appendingPathComponent("history.json")
            ),
            recycler: { _ in
                XCTFail("Recycler must not run")
                return DuplicateFileRecycleResult(
                    recycled: [:],
                    errorDescription: nil
                )
            },
            trashPathValidator: { _ in true }
        )

        let outcome = await controller.remove(
            groups: [group],
            selectedItemIDs: [selected.id]
        )

        XCTAssertEqual(outcome.movedCount, 0)
        XCTAssertEqual(outcome.failedCount, 1)
        XCTAssertEqual(outcome.items.first?.status, .rejected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testRollsBackWhenHistoryCannotBePersisted() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try Data("duplicate".utf8).write(to: first)
        try Data("duplicate".utf8).write(to: second)
        let group = try await duplicateGroup(in: root)
        let selected = try XCTUnwrap(group.files.first { $0.url == second })
        let blockedParent = root.appendingPathComponent("blocked")
        try Data("not-a-directory".utf8).write(to: blockedParent)
        let controller = DuplicateFileRemovalController(
            historyStore: DuplicateFileRemovalHistoryStore(
                fileURL: blockedParent.appendingPathComponent("history.json")
            ),
            recycler: testRecycler(trashDirectory: trash),
            trashPathValidator: { $0.path.hasPrefix(trash.path + "/") }
        )

        let outcome = await controller.remove(
            groups: [group],
            selectedItemIDs: [selected.id]
        )

        XCTAssertFalse(outcome.historyPersisted)
        XCTAssertEqual(outcome.rolledBackCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testUndoDoesNotReturnChangedRestoredFileToTrash() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(
            at: trash,
            withIntermediateDirectories: true
        )
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try Data("duplicate".utf8).write(to: first)
        try Data("duplicate".utf8).write(to: second)
        let group = try await duplicateGroup(in: root)
        let selected = try XCTUnwrap(group.files.first { $0.url == second })
        let historyDirectory = root.appendingPathComponent(
            "history",
            isDirectory: true
        )
        let store = DuplicateFileRemovalHistoryStore(
            fileURL: historyDirectory.appendingPathComponent("duplicates.json")
        )
        let controller = DuplicateFileRemovalController(
            historyStore: store,
            recycler: testRecycler(trashDirectory: trash),
            moveOperation: { source, destination in
                try FileManager.default.moveItem(
                    at: source,
                    to: destination
                )
                if source.path.hasPrefix(trash.path + "/"),
                   destination == second {
                    try Data("different".utf8).write(to: destination)
                }
            },
            trashPathValidator: { $0.path.hasPrefix(trash.path + "/") }
        )
        let removal = await controller.remove(
            groups: [group],
            selectedItemIDs: [selected.id]
        )
        let record = try XCTUnwrap(removal.record)
        try FileManager.default.removeItem(at: historyDirectory)
        try Data("blocks-history".utf8).write(to: historyDirectory)

        let undo = controller.undo(record)

        XCTAssertFalse(undo.historyPersisted)
        XCTAssertTrue(undo.rollbackFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(
            try Data(contentsOf: second),
            Data("different".utf8)
        )
        XCTAssertFalse(
            record.items.compactMap(\.trashPath).contains {
                FileManager.default.fileExists(atPath: $0)
            }
        )
    }

    func testRecognizesOnlySupportedTrashLayouts() {
        let userID = getuid()
        let homeTrashItem = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash/example.txt")

        XCTAssertTrue(DuplicateFileRemovalController.isRecognizedTrashPath(
            homeTrashItem,
            currentUserID: userID
        ))
        XCTAssertTrue(DuplicateFileRemovalController.isRecognizedTrashPath(
            URL(fileURLWithPath: "/.Trashes/\(userID)/example.txt"),
            currentUserID: userID
        ))
        XCTAssertTrue(DuplicateFileRemovalController.isRecognizedTrashPath(
            URL(
                fileURLWithPath:
                    "/Volumes/Archive/.Trashes/\(userID)/example.txt"
            ),
            currentUserID: userID
        ))
        XCTAssertTrue(DuplicateFileRemovalController.isRecognizedTrashPath(
            URL(
                fileURLWithPath:
                    "/Volumes/Archive/.Trash-\(userID)/example.txt"
            ),
            currentUserID: userID
        ))
        XCTAssertFalse(DuplicateFileRemovalController.isRecognizedTrashPath(
            URL(fileURLWithPath: "/Users/example/Documents/.Trash/file.txt"),
            currentUserID: userID
        ))
        XCTAssertFalse(DuplicateFileRemovalController.isRecognizedTrashPath(
            URL(fileURLWithPath: "/tmp/.Trashes/\(userID)/file.txt"),
            currentUserID: userID
        ))
    }

    private func duplicateGroup(in root: URL) async throws -> DuplicateFileGroup {
        let result = try await DuplicateFileScanner().scan(roots: [root])
        return try XCTUnwrap(result.groups.first)
    }

    private func testRecycler(
        trashDirectory: URL
    ) -> DuplicateFileRemovalController.Recycler {
        { urls in
            var mapping: [URL: URL] = [:]
            for source in urls {
                let destination = trashDirectory.appendingPathComponent(
                    UUID().uuidString + "-" + source.lastPathComponent
                )
                do {
                    try FileManager.default.moveItem(at: source, to: destination)
                    mapping[source] = destination
                } catch {
                    return DuplicateFileRecycleResult(
                        recycled: mapping,
                        errorDescription: error.localizedDescription
                    )
                }
            }
            return DuplicateFileRecycleResult(
                recycled: mapping,
                errorDescription: nil
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(
                "AppSift-DuplicateRemoval-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        return url
    }
}
