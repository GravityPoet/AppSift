import Foundation
import XCTest
@testable import AppSift

final class ReviewedTrashServiceHighRiskTests: XCTestCase {
    func testMovesToDisposableTrashPersistsHistoryAndRestores() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftTrashMoveUndo")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let trashRoot = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("report.txt")
        try Data("recover me".utf8).write(to: source)
        let service = try makeQATrashService(
            historyURL: root.appendingPathComponent("History/reviewed.json"),
            trashRoot: trashRoot
        )

        let outcome = await service.moveToTrash(
            [try makeQATrashCandidate(for: source, allowedRoot: sourceRoot, requiresDirectChild: true)],
            feature: "qa-move-undo"
        )

        XCTAssertTrue(outcome.historyPersisted)
        XCTAssertEqual(outcome.movedCount, 1)
        XCTAssertEqual(outcome.failedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let record = try XCTUnwrap(outcome.record)
        let trashPath = try XCTUnwrap(record.items.first?.trashPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashPath))
        let historyAfterMove = await service.history(feature: "qa-move-undo")
        XCTAssertEqual(historyAfterMove.count, 1)

        let undo = await service.undo(record)

        XCTAssertEqual(undo.restoredCount, 1)
        XCTAssertEqual(undo.failedCount, 0)
        XCTAssertTrue(undo.historyPersisted)
        XCTAssertEqual(try String(contentsOf: source), "recover me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashPath))
        let historyAfterUndo = await service.history(feature: "qa-move-undo")
        XCTAssertNotNil(historyAfterUndo.first?.items.first?.restoredAt)
    }

    func testPartialRecycleFailureOnlyMovesAndRestoresSuccessfulItems() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftTrashPartial")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let trashRoot = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let movable = sourceRoot.appendingPathComponent("movable.bin")
        let failing = sourceRoot.appendingPathComponent("failing.bin")
        try Data([1, 2, 3]).write(to: movable)
        try Data([4, 5, 6]).write(to: failing)
        let service = try makeQATrashService(
            historyURL: root.appendingPathComponent("History/reviewed.json"),
            trashRoot: trashRoot,
            failedPaths: [failing.path]
        )

        let outcome = await service.moveToTrash(
            [
                try makeQATrashCandidate(for: movable, allowedRoot: sourceRoot),
                try makeQATrashCandidate(for: failing, allowedRoot: sourceRoot),
            ],
            feature: "qa-partial"
        )

        XCTAssertEqual(outcome.movedCount, 1)
        XCTAssertEqual(outcome.failedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: movable.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failing.path))
        let undo = await service.undo(try XCTUnwrap(outcome.record))
        XCTAssertEqual(undo.restoredCount, 1)
        XCTAssertEqual(undo.failedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: movable.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failing.path))
    }

    func testChangedFingerprintIsRejectedBeforeRecyclerRuns() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftTrashFingerprint")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("changed.txt")
        try Data("before".utf8).write(to: source)
        let candidate = try makeQATrashCandidate(for: source, allowedRoot: sourceRoot)
        try Data("after and different".utf8).write(to: source, options: .atomic)
        let service = try makeQATrashService(
            historyURL: root.appendingPathComponent("History/reviewed.json"),
            trashRoot: root.appendingPathComponent("Trash", isDirectory: true)
        )

        let outcome = await service.moveToTrash([candidate], feature: "qa-fingerprint")

        XCTAssertEqual(outcome.movedCount, 0)
        XCTAssertEqual(outcome.failedCount, 1)
        XCTAssertEqual(outcome.record?.items.first?.status, .rejected)
        XCTAssertEqual(try String(contentsOf: source), "after and different")
    }

    func testHistoryPersistenceFailureRollsMovedItemBack() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftTrashRollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("must-survive.txt")
        try Data("important".utf8).write(to: source)
        let invalidHistoryURL = root.appendingPathComponent("HistoryAsDirectory", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidHistoryURL, withIntermediateDirectories: true)
        let service = try makeQATrashService(
            historyURL: invalidHistoryURL,
            trashRoot: root.appendingPathComponent("Trash", isDirectory: true)
        )

        let outcome = await service.moveToTrash(
            [try makeQATrashCandidate(for: source, allowedRoot: sourceRoot)],
            feature: "qa-history-rollback"
        )

        XCTAssertFalse(outcome.historyPersisted)
        XCTAssertEqual(outcome.record?.items.first?.status, .rolledBackAfterHistoryFailure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: source), "important")
    }

    func testUndoRefusesTrashItemWhoseFingerprintChanged() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftTrashUndoTamper")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: source)
        let service = try makeQATrashService(
            historyURL: root.appendingPathComponent("History/reviewed.json"),
            trashRoot: root.appendingPathComponent("Trash", isDirectory: true)
        )
        let outcome = await service.moveToTrash(
            [try makeQATrashCandidate(for: source, allowedRoot: sourceRoot)],
            feature: "qa-tampered-undo"
        )
        let record = try XCTUnwrap(outcome.record)
        let trashURL = URL(fileURLWithPath: try XCTUnwrap(record.items.first?.trashPath))
        try Data("tampered".utf8).write(to: trashURL, options: .atomic)

        let undo = await service.undo(record)

        XCTAssertEqual(undo.restoredCount, 0)
        XCTAssertEqual(undo.failedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.path))
    }
}
