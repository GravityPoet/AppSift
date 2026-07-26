import Foundation
import XCTest
@testable import AppSift

@MainActor
final class FeatureRemovalFlowTests: XCTestCase {
    func testIOSBackupCenterDeletesOnlySelectedOlderBackupAndUndoRestoresIt() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftIOSBackupFlow")
        defer { try? FileManager.default.removeItem(at: root) }
        let backupRoot = root.appendingPathComponent("MobileSync/Backup", isDirectory: true)
        let olderURL = backupRoot.appendingPathComponent("device-old", isDirectory: true)
        let latestURL = backupRoot.appendingPathComponent("device-latest", isDirectory: true)
        try makeQAIOSBackup(
            at: olderURL,
            deviceID: "qa-device",
            deviceName: "QA iPhone",
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try makeQAIOSBackup(
            at: latestURL,
            deviceID: "qa-device",
            deviceName: "QA iPhone",
            date: Date(timeIntervalSince1970: 1_710_000_000)
        )
        let historyStore = ReviewedTrashHistoryStore(
            fileURL: root.appendingPathComponent("History/reviewed.json")
        )
        let trashService = try makeQATrashService(
            historyStore: historyStore,
            trashRoot: root.appendingPathComponent("Trash", isDirectory: true)
        )
        let center = IOSBackupCenter(
            scanner: IOSBackupScanner(rootURL: backupRoot),
            trashService: trashService
        )

        center.scan()
        try await waitForQACondition { center.hasScanned && !center.isScanning }
        XCTAssertEqual(center.backups.count, 2)
        center.selectOlderBackups()
        XCTAssertEqual(center.selectedIDs, Set([olderURL.path]))

        center.removeSelected()
        try await waitForQACondition {
            !center.isRemoving && !FileManager.default.fileExists(atPath: olderURL.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: latestURL.path))
        let record = try XCTUnwrap(center.latestUndoableRecord)
        XCTAssertEqual(record.feature, IOSBackupCenter.featureIdentifier)

        center.undoLatest()
        try await waitForQACondition {
            !center.isRemoving && FileManager.default.fileExists(atPath: olderURL.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: latestURL.path))
        XCTAssertNil(center.errorMessage)
    }

    func testDownloadCenterDeleteAndUndoUsesDisposableProfile() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftDownloadFlow")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let selectedURL = downloads.appendingPathComponent("Chrome report.pdf")
        let preservedURL = downloads.appendingPathComponent("keep.txt")
        try Data(repeating: 0x41, count: 4_096).write(to: selectedURL)
        try Data(repeating: 0x42, count: 2_048).write(to: preservedURL)
        let historyStore = ReviewedTrashHistoryStore(
            fileURL: root.appendingPathComponent("History/reviewed.json")
        )
        let trashService = try makeQATrashService(
            historyStore: historyStore,
            trashRoot: root.appendingPathComponent("Trash", isDirectory: true)
        )
        let center = DownloadSourceCenter(
            rootURL: downloads,
            scanner: DownloadSourceScanner(rootURL: downloads, homeURL: home),
            trashService: trashService,
            historyStore: historyStore
        )

        center.scan(force: true)
        try await waitForQACondition { center.hasScanned && !center.isScanning }
        let selectedItem = try XCTUnwrap(center.items.first { $0.url == selectedURL })
        center.toggleSelection(selectedItem)
        center.removeSelected()
        try await waitForQACondition {
            !center.isRemoving && !FileManager.default.fileExists(atPath: selectedURL.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedURL.path))
        let record = try XCTUnwrap(center.latestUndoableRecord)

        center.undo(record)
        try await waitForQACondition {
            !center.isRemoving && FileManager.default.fileExists(atPath: selectedURL.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedURL.path))
        XCTAssertNil(center.errorMessage)
    }

    func testSimilarImageSuggestionsKeepBestImageAndUndoRestoresRemovedImage() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftSimilarFlow")
        defer { try? FileManager.default.removeItem(at: root) }
        let images = root.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let highResolution = images.appendingPathComponent("high.png")
        let lowResolution = images.appendingPathComponent("low.png")
        try writeQAGradientPNG(to: highResolution, width: 512, height: 384)
        try writeQAGradientPNG(to: lowResolution, width: 128, height: 96)
        let historyStore = ReviewedTrashHistoryStore(
            fileURL: root.appendingPathComponent("History/reviewed.json")
        )
        let trashService = try makeQATrashService(
            historyStore: historyStore,
            trashRoot: root.appendingPathComponent("Trash", isDirectory: true)
        )
        let center = SimilarImageCenter(
            rootURL: images,
            scanner: SimilarImageScanner(),
            trashService: trashService,
            historyStore: historyStore
        )

        center.scan(force: true)
        try await waitForQACondition(timeout: 20) { center.hasScanned && !center.isScanning }
        let group = try XCTUnwrap(center.groups.first)
        XCTAssertEqual(group.items.count, 2)
        XCTAssertEqual(group.recommendedKeepID, highResolution.path)
        center.useSuggestions()
        XCTAssertEqual(center.selectedIDs, Set([lowResolution.path]))

        center.removeSelected()
        try await waitForQACondition(timeout: 20) {
            !center.isRemoving && !FileManager.default.fileExists(atPath: lowResolution.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: highResolution.path))
        let record = try XCTUnwrap(center.latestUndoableRecord)

        center.undo(record)
        try await waitForQACondition(timeout: 20) {
            !center.isRemoving && FileManager.default.fileExists(atPath: lowResolution.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: highResolution.path))
        XCTAssertNil(center.errorMessage)
    }
}
