import Foundation
import XCTest
@testable import AppSift

final class ProductReviewRegressionTests: XCTestCase {
    func testPersonalCleanupMovesToIsolatedTrashAndUndoRestoresContents() async throws {
        let root = try makeQATemporaryDirectory(prefix: "ReviewRecovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home")
        let file = home.appendingPathComponent("Documents/review.dat")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = Data(repeating: 0x5a, count: 8_192)
        try contents.write(to: file)
        let service = try makeQATrashService(historyURL: root.appendingPathComponent("History/history.json"),
                                           trashRoot: root.appendingPathComponent("Trash"))
        let engine = CleaningEngine(homeURL: home, trashService: service)
        let item = CleanableItem(name: "review.dat", path: file.path, size: Int64(contents.count),
                                 category: .largeFiles, isSelected: true, lastModified: nil)
        let outcome = await engine.cleanItems([item]) { _ in }
        XCTAssertTrue(outcome.errors.isEmpty, outcome.errors.joined(separator: "\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(outcome.trashedSpace, Int64(contents.count))
        XCTAssertEqual(outcome.freedSpace, 0)
        let history = await engine.recoveryHistory()
        let record = try XCTUnwrap(history.first)
        let restored = await engine.undo(record)
        XCTAssertEqual(restored.restoredCount, 1)
        XCTAssertTrue(restored.historyPersisted)
        XCTAssertEqual(try Data(contentsOf: file), contents)
    }

    func testChangedPersonalFileIsRejectedWithoutRemovingReplacement() async throws {
        let root = try makeQATemporaryDirectory(prefix: "ReviewReplacement")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home")
        let file = home.appendingPathComponent("Downloads/review.dat")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: file)
        let item = CleanableItem(name: "review.dat", path: file.path, size: 8,
                                 category: .largeFiles, isSelected: true, lastModified: nil)
        try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("original"))
        let replacement = Data("replacement".utf8)
        try replacement.write(to: file)
        let service = try makeQATrashService(historyURL: root.appendingPathComponent("History/history.json"),
                                           trashRoot: root.appendingPathComponent("Trash"))
        let outcome = await CleaningEngine(homeURL: home, trashService: service).cleanItems([item]) { _ in }
        XCTAssertEqual(outcome.itemsCleaned, 0)
        XCTAssertFalse(outcome.errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), replacement)
    }

    func testPersonalCleanupRollsBackWhenHistoryCannotBeSaved() async throws {
        let root = try makeQATemporaryDirectory(prefix: "ReviewHistoryFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home")
        let file = home.appendingPathComponent("Documents/review.dat")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = Data("recover this file".utf8)
        try contents.write(to: file)
        let blocked = root.appendingPathComponent("BlockedHistory")
        try Data("not a directory".utf8).write(to: blocked)
        let service = try makeQATrashService(historyURL: blocked.appendingPathComponent("history.json"),
                                           trashRoot: root.appendingPathComponent("Trash"))
        let item = CleanableItem(name: "review.dat", path: file.path, size: Int64(contents.count),
                                 category: .largeFiles, isSelected: true, lastModified: nil)
        let outcome = await CleaningEngine(homeURL: home, trashService: service).cleanItems([item]) { _ in }
        XCTAssertEqual(outcome.itemsCleaned, 0)
        XCTAssertEqual(outcome.trashedSpace, 0)
        XCTAssertFalse(outcome.errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), contents)
    }

    func testLargeFileCategoryCannotRemoveAnEntireDirectory() async throws {
        let root = try makeQATemporaryDirectory(prefix: "ReviewDirectory")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home")
        let folder = home.appendingPathComponent("Documents/Keep")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("important.txt")
        try Data("keep".utf8).write(to: file)
        let item = CleanableItem(name: "Keep", path: folder.path, size: 4,
                                 category: .largeFiles, isSelected: true, lastModified: nil)
        let outcome = await CleaningEngine(homeURL: home).cleanItems([item]) { _ in }
        XCTAssertEqual(outcome.itemsCleaned, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testAIInventoryIncludesLogsAndOptionalHistoryButNeverModels() async throws {
        let home = try makeQATemporaryDirectory(prefix: "ReviewAI")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = [".ollama/logs/server.log", "Library/Caches/ollama/cache.dat",
                     ".ollama/history", ".lmstudio/server-logs/server.log",
                     ".lmstudio/conversations/review.json", ".ollama/models/keep.gguf",
                     ".lmstudio/models/keep.gguf"]
        for path in paths {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x31, count: 8_192).write(to: url)
        }
        let result = await ScanEngine(homeURL: home).scanCategory(.aiApps)
        XCTAssertEqual(result.items.count, 5)
        XCTAssertFalse(result.items.contains { $0.path.contains("/models") })
        for item in result.items where item.requiresRecoverableRemoval {
            XCTAssertFalse(item.isSelected)
            XCTAssertNotNil(item.reviewedFingerprint)
            XCTAssertFalse(item.isEligibleForAutomaticCleanup)
        }
    }

    func testArchivesMailAndTrashAreNeverPreselected() async throws {
        let home = try makeQATemporaryDirectory(prefix: "ReviewDefaults")
        defer { try? FileManager.default.removeItem(at: home) }
        for path in ["Library/Developer/Xcode/Archives/review.xcarchive/file", "Library/Mail Downloads/attachment.dat", ".Trash/review.dat"] {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 8_192).write(to: url)
        }
        let scanner = ScanEngine(homeURL: home)
        for category in [CleaningCategory.xcodeJunk, .mailAttachments, .trashBins] {
            let result = await scanner.scanCategory(category)
            XCTAssertFalse(result.items.isEmpty)
            XCTAssertTrue(result.items.allSatisfy { !$0.isSelected })
        }
    }

    @MainActor
    func testSchedulerControllerStartsStopsAndReschedulesImmediately() throws {
        let suite = "AppSiftReviewScheduler-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = SchedulerService(defaults: defaults)
        scheduler.toggleEnabled(true)
        XCTAssertNotNil(scheduler.config.nextRunDate)
        scheduler.updateSchedule(interval: .hours1)
        XCTAssertEqual(try XCTUnwrap(scheduler.config.nextRunDate).timeIntervalSinceNow, 3_600, accuracy: 2)
        scheduler.toggleEnabled(false)
        XCTAssertFalse(scheduler.config.isEnabled)
        let data = try XCTUnwrap(defaults.data(forKey: "\(ProductIdentity.name).ScheduleConfig"))
        XCTAssertFalse(try JSONDecoder().decode(ScheduleConfig.self, from: data).isEnabled)
    }
}
