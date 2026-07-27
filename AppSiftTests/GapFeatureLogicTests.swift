import Darwin
import Foundation
import XCTest
@testable import AppSift

final class SidebarNavigationGroupTests: XCTestCase {
    func testPrimaryDestinationsRemainOutsideCollapsedGroups() {
        let primaryDestinations: [AppSection] = [
            .cleaning(.smartScan),
            .apps,
            .spaceLens,
            .systemHealth,
            .cleaning(.purgeableSpace),
        ]

        for destination in primaryDestinations {
            XCTAssertNil(SidebarNavigationGroup.containing(destination))
        }
    }

    func testSecondaryDestinationsBelongToExactlyOneSemanticGroup() {
        let expectedMappings: [(AppSection, SidebarNavigationGroup)] = [
            (.appUpdates, .applications),
            (.installationFiles, .applications),
            (.startupItems, .applications),
            (.extensions, .applications),
            (.appPermissions, .applications),
            (.browserPrivacy, .applications),
            (.defaultApplications, .applications),
            (.removalHistory, .applications),
            (.orphans, .applications),
            (.duplicateFiles, .storage),
            (.similarImages, .storage),
            (.timeMachine, .storage),
            (.iosBackups, .storage),
            (.downloadsBySource, .storage),
            (.systemMaintenance, .maintenance),
            (.systemResidue, .maintenance),
        ]

        for (destination, expectedGroup) in expectedMappings {
            XCTAssertEqual(
                SidebarNavigationGroup.containing(destination),
                expectedGroup
            )
            XCTAssertEqual(
                SidebarNavigationGroup.allCases.count {
                    $0.contains(destination)
                },
                1
            )
        }
    }

    func testEveryScannableCleaningCategoryBelongsToCleanupGroup() {
        for category in CleaningCategory.scannable {
            let destination = AppSection.cleaning(category)
            XCTAssertEqual(
                SidebarNavigationGroup.containing(destination),
                .cleanup
            )
            XCTAssertEqual(
                SidebarNavigationGroup.allCases.count {
                    $0.contains(destination)
                },
                1
            )
        }
    }

    func testGroupsUseUniqueVersionedCollapsedDefaults() {
        let keys = SidebarNavigationGroup.allCases.map(\.preferenceKey)

        XCTAssertTrue(
            SidebarNavigationGroup.allCases.allSatisfy(\.defaultCollapsed)
        )
        XCTAssertEqual(Set(keys).count, SidebarNavigationGroup.allCases.count)
        XCTAssertTrue(
            keys.allSatisfy {
                $0.hasPrefix("AppSift.Sidebar.CompactV2.Collapsed.")
            }
        )
    }
}

final class MacOSUpdateScannerTests: XCTestCase {
    func testParsesSoftwareUpdateCatalogEntries() throws {
        let output = """
        Software Update Tool

        Finding available software
        Software Update found the following new or updated software:
        * Label: macOS Sequoia 15.6-24G84
            Title: macOS Sequoia 15.6, Version: 15.6, Size: 3.2 GB, Recommended: YES, Action: restart,
        * Label: Safari18.6-18.6
            Title: Safari, Version: 18.6, Size: 245000K, Recommended: YES,
        """

        let updates = try MacOSUpdateScanner.parse(output)

        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates[0].title, "macOS Sequoia 15.6")
        XCTAssertEqual(updates[0].version, "15.6")
        XCTAssertEqual(updates[0].sizeBytes, 3_200_000_000)
        XCTAssertTrue(updates[0].requiresRestart)
        XCTAssertEqual(updates[1].title, "Safari")
        XCTAssertEqual(updates[1].sizeBytes, 245_000_000)
    }

    func testNoUpdatesOutputReturnsEmptyList() throws {
        XCTAssertEqual(
            try MacOSUpdateScanner.parse("No new software available."),
            []
        )
    }

    func testRejectsCatalogEntryWithoutVerifiableTitle() {
        XCTAssertThrowsError(
            try MacOSUpdateScanner.parse(
                "Software Update found the following new or updated software:\n* Label: unlabeled"
            )
        )
    }
}

final class DownloadSourceScannerTests: XCTestCase {
    func testClassifiesSupportedDownloadSourcesFromLocalMetadata() {
        XCTAssertEqual(
            DownloadSourceScanner.classify(
                agentName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                originHost: "example.com"
            ),
            .chrome
        )
        XCTAssertEqual(
            DownloadSourceScanner.classify(
                agentName: "Slack",
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                originHost: nil
            ),
            .slack
        )
        XCTAssertEqual(
            DownloadSourceScanner.classify(
                agentName: nil,
                bundleIdentifier: nil,
                originHost: nil
            ),
            .unknown
        )
    }

    func testUnknownApplicationIsNotMisrepresentedAsKnownBrowser() {
        XCTAssertEqual(
            DownloadSourceScanner.classify(
                agentName: "Acme Downloader",
                bundleIdentifier: "com.example.downloader",
                originHost: "downloads.example"
            ),
            .otherApplication
        )
        XCTAssertEqual(
            DownloadSourceScanner.classify(
                agentName: nil,
                bundleIdentifier: nil,
                originHost: "slack.com"
            ),
            .unknown,
            "A website domain is display-only evidence and must not be treated as the source app."
        )
    }
}

final class BrowserPrivacyScannerTests: XCTestCase {
    func testFindsChromeHistoryButNeverIncludesPasswordDatabase() async throws {
        let home = try makeTemporaryDirectory(prefix: "AppSiftBrowserPrivacy")
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent(
            "Library/Application Support/Google/Chrome/Default",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let history = profile.appendingPathComponent("History")
        let passwords = profile.appendingPathComponent("Login Data")
        try Data(repeating: 0x41, count: 4_096).write(to: history)
        try Data(repeating: 0x42, count: 4_096).write(to: passwords)

        let result = try await BrowserPrivacyScanner(homeURL: home).scan()
        let allTargets = result.groups.flatMap(\.targets)

        XCTAssertTrue(allTargets.contains { $0.url == history })
        XCTAssertFalse(allTargets.contains { $0.url == passwords })
        XCTAssertEqual(result.inaccessibleCount, 0)
        XCTAssertFalse(result.wasTruncated)
        XCTAssertEqual(
            result.groups.first(where: {
                $0.browser == .chrome && $0.kind == .historyAndDownloads
            })?.profileCount,
            1
        )
    }
}

final class IOSBackupScannerTests: XCTestCase {
    func testReadsBackupMetadataAndMarksNewestPerDevice() async throws {
        let root = try makeTemporaryDirectory(prefix: "AppSiftIOSBackups")
        defer { try? FileManager.default.removeItem(at: root) }
        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_710_000_000)
        try makeBackup(
            at: root.appendingPathComponent("device-old", isDirectory: true),
            deviceID: "device-1",
            deviceName: "Test iPhone",
            date: olderDate,
            encrypted: true
        )
        try makeBackup(
            at: root.appendingPathComponent("device-new", isDirectory: true),
            deviceID: "device-1",
            deviceName: "Test iPhone",
            date: newerDate,
            encrypted: true
        )

        let result = try await IOSBackupScanner().scan(rootURL: root)

        XCTAssertEqual(result.backups.count, 2)
        XCTAssertEqual(result.backups.count(where: \.isLatestForDevice), 1)
        XCTAssertEqual(result.backups.first?.lastBackupDate, newerDate)
        XCTAssertTrue(result.backups.allSatisfy(\.isEncrypted))
        XCTAssertTrue(result.backups.allSatisfy { $0.completionState == .finished })
        XCTAssertEqual(result.inaccessibleCount, 0)
        XCTAssertFalse(result.wasTruncated)
    }

    private func makeBackup(
        at url: URL,
        deviceID: String,
        deviceName: String,
        date: Date,
        encrypted: Bool
    ) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try writePlist([
            "Target Identifier": deviceID,
            "Device Name": deviceName,
            "Product Type": "iPhone17,1",
            "Product Version": "18.5",
            "Last Backup Date": date,
        ], to: url.appendingPathComponent("Info.plist"))
        try writePlist(
            ["IsEncrypted": encrypted],
            to: url.appendingPathComponent("Manifest.plist")
        )
        try writePlist(
            ["SnapshotState": "finished", "Date": date],
            to: url.appendingPathComponent("Status.plist")
        )
        try Data(repeating: 0x55, count: 8_192).write(
            to: url.appendingPathComponent("payload.bin")
        )
    }

    private func writePlist(_ value: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .binary,
            options: 0
        )
        try data.write(to: url)
    }
}

final class SimilarImageScannerLogicTests: XCTestCase {
    func testHammingDistanceUsesAllBits() {
        XCTAssertEqual(SimilarImageScanner.hammingDistance(0, 0), 0)
        XCTAssertEqual(SimilarImageScanner.hammingDistance(0, UInt64.max), 64)
        XCTAssertEqual(
            SimilarImageScanner.hammingDistance(0b101010, 0b111000),
            2
        )
    }

    func testRejectsProtectedSystemSubdirectory() async {
        do {
            _ = try await SimilarImageScanner().scan(
                rootURL: URL(fileURLWithPath: "/System/Library", isDirectory: true)
            )
            XCTFail("Protected system directories must not be scanned.")
        } catch {
            XCTAssertEqual(error as? SimilarImageScanError, .invalidRoot)
        }
    }

    func testProtectsManagedPhotoLibrariesAtAnyDepth() {
        XCTAssertTrue(
            SimilarImageScanner.isProtectedPhotoLibraryPath(
                URL(fileURLWithPath: "/Users/test/Pictures/Photos Library.photoslibrary/originals/a.jpg")
            )
        )
        XCTAssertTrue(
            SimilarImageScanner.isProtectedPhotoLibraryPath(
                URL(fileURLWithPath: "/Volumes/Archive/iPhoto Library.photolibrary")
            )
        )
        XCTAssertFalse(
            SimilarImageScanner.isProtectedPhotoLibraryPath(
                URL(fileURLWithPath: "/Users/test/Pictures/Trip/a.jpg")
            )
        )
    }

    func testRejectsManagedPhotoLibraryAsScanRoot() async {
        do {
            _ = try await SimilarImageScanner().scan(
                rootURL: URL(
                    fileURLWithPath: "/Users/test/Pictures/Photos Library.photoslibrary",
                    isDirectory: true
                )
            )
            XCTFail("Managed Photos libraries must not be scanned directly.")
        } catch {
            XCTAssertEqual(error as? SimilarImageScanError, .managedPhotoLibrary)
        }
    }
}

final class SystemAlertCenterTests: XCTestCase {
    func testEvaluatesDiskMemoryAndStaleTrashFromExplicitThresholds() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let conditions = SystemAlertCenter.evaluate(
            volumes: [
                SystemVolumeSnapshot(
                    path: "/",
                    name: "Macintosh HD",
                    totalBytes: 100_000_000_000,
                    availableBytes: 900_000_000,
                    isInternal: true,
                    isRemovable: false,
                    isReadOnly: false
                ),
            ],
            battery: nil,
            deviceBatteries: [],
            memory: SystemMemorySnapshot(
                usedBytes: 15_500_000_000,
                totalBytes: 16_000_000_000,
                swapUsedBytes: 2_000_000_000
            ),
            trash: SystemTrashSnapshot(
                itemCount: 12,
                oldItemCount: 10,
                oldestModificationDate: now.addingTimeInterval(-100 * 24 * 60 * 60)
            ),
            now: now
        )

        XCTAssertEqual(
            Set(conditions.map(\.kind)),
            [.lowInternalDisk, .memoryPressure, .staleTrash]
        )
        XCTAssertEqual(
            conditions.first(where: { $0.kind == .lowInternalDisk })?.severity,
            .critical
        )
    }

    func testHealthyTelemetryProducesNoAlert() {
        let conditions = SystemAlertCenter.evaluate(
            volumes: [
                SystemVolumeSnapshot(
                    path: "/",
                    name: "Macintosh HD",
                    totalBytes: 500_000_000_000,
                    availableBytes: 200_000_000_000,
                    isInternal: true,
                    isRemovable: false,
                    isReadOnly: false
                ),
            ],
            battery: SystemBatterySnapshot(
                percentage: 80,
                isCharging: false,
                isConnectedToPower: false,
                healthPercentage: 95,
                cycleCount: 100,
                condition: "Normal"
            ),
            deviceBatteries: [],
            memory: SystemMemorySnapshot(
                usedBytes: 8_000_000_000,
                totalBytes: 16_000_000_000,
                swapUsedBytes: 0
            ),
            trash: SystemTrashSnapshot(itemCount: 2, oldItemCount: 0, oldestModificationDate: Date()),
            now: Date()
        )

        XCTAssertTrue(conditions.isEmpty)
    }
}

final class SystemHealthRecommendationEngineTests: XCTestCase {
    func testRecommendationsAreRuleBasedAndActionable() {
        let recommendations = SystemHealthRecommendationEngine.recommendations(
            from: SystemHealthRuleSnapshot(
                activeAlerts: [],
                appUpdateCount: 2,
                macOSUpdateCount: 1,
                brokenStartupItemCount: 1,
                oldBackupCount: 2,
                oldBackupSize: 5_000_000_000,
                corruptPreferenceCount: 1,
                legacyUserResidueCount: 1,
                hasFullDiskAccess: true,
                systemAlertsEnabled: true
            )
        )

        XCTAssertEqual(
            Set(recommendations.map(\.id)),
            [
                "available-updates",
                "broken-startup-items",
                "old-ios-backups",
                "corrupt-preferences",
                "legacy-user-data",
            ]
        )
        XCTAssertTrue(recommendations.allSatisfy { !$0.evidence.isEmpty })
        XCTAssertTrue(recommendations.allSatisfy { !$0.title.localizedCaseInsensitiveContains("score") })
    }
}

private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
