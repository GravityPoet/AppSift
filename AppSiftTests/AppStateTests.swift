import AppKit
import Security
import XCTest
@testable import AppSift

@MainActor
final class AppStateTests: XCTestCase {
    func testScanForAppFilesTracksLocationsWhileResultsArePending() throws {
        var completion: ((Set<URL>) -> Void)?
        let expectedLocations = ["/one", "/two", "/three"]
        let appState = AppState(
            performStartupTasks: false,
            locationsProvider: {
                let locations = Locations()
                locations.appSearch = .init(name: "Apps", paths: expectedLocations)
                return locations
            },
            appFileScanner: { _, searchPaths, pendingCompletion in
                XCTAssertEqual(searchPaths, expectedLocations)
                completion = pendingCompletion
                return nil
            }
        )

        appState.scanForAppFiles(makeApp(name: "AppSift", bundleIdentifier: "com.gravitypoet.appsift"))

        XCTAssertTrue(appState.isScanningAppFiles)
        XCTAssertTrue(appState.discoveredFiles.isEmpty)
        XCTAssertEqual(appState.currentAppFileSearchLocationCount, expectedLocations.count)

        let pendingCompletion = try XCTUnwrap(completion)
        let urls: Set<URL> = [
            URL(fileURLWithPath: "/tmp/B"),
            URL(fileURLWithPath: "/tmp/A")
        ]

        pendingCompletion(urls)

        XCTAssertFalse(appState.isScanningAppFiles)
        XCTAssertEqual(
            appState.discoveredFiles,
            urls.sorted { $0.path < $1.path }
        )
        XCTAssertEqual(appState.selectedFiles, urls)
        XCTAssertEqual(appState.currentAppFileSearchLocationCount, urls.count)
    }

    func testScanForAppFilesExcludesDataOwnedByAnotherApplication() throws {
        var completion: ((Set<URL>) -> Void)?
        let selectedApp = makeApp(
            name: "ChatGPT",
            bundleIdentifier: "com.openai.codex",
            path: "/Applications/ChatGPT.app"
        )
        let appCleaner = makeApp(
            name: "App Cleaner 9",
            bundleIdentifier: "com.nektony.App-Cleaner-SIII",
            path: "/Applications/App Cleaner 9.app"
        )
        let appState = AppState(
            performStartupTasks: false,
            searchSensitivityProvider: { .enhanced },
            appFileScanner: { _, _, pendingCompletion in
                completion = pendingCompletion
                return nil
            }
        )
        appState.installedApps = [selectedApp, appCleaner]

        appState.scanForAppFiles(selectedApp)
        let completeScan = try XCTUnwrap(completion)
        let ownCache = URL(fileURLWithPath: "/Users/test/Library/Caches/com.openai.codex")
        let foreignIndex = URL(
            fileURLWithPath: "/Users/test/Library/Application Support/com.nektony.App-Cleaner-SIII/SubdomainAppsSearcher/com.openai.codex.26.707.41301.plist"
        )
        let secondForeignIndex = URL(
            fileURLWithPath: "/Users/test/Library/Application Support/com.nektony.App-Cleaner-SIII/SubdomainAppsSearcher/com.openai.codex.26.707.41302.plist"
        )
        completeScan([selectedApp.path, ownCache, foreignIndex, secondForeignIndex])

        XCTAssertEqual(Set(appState.discoveredFiles), [selectedApp.path, ownCache])
        XCTAssertEqual(appState.selectedFiles, [selectedApp.path, ownCache])
        XCTAssertFalse(appState.discoveredFiles.contains(foreignIndex))
        XCTAssertEqual(appState.protectedAppFiles.map(\.url), [
            URL(fileURLWithPath: "/Users/test/Library/Application Support/com.nektony.App-Cleaner-SIII")
        ])
        XCTAssertEqual(appState.protectedAppFiles.first?.reason, .foreignPrivateData)
        XCTAssertEqual(appState.protectedAppFiles.first?.matchedItemCount, 2)
        XCTAssertEqual(
            appState.protectedAppFiles.first?.relatedApplications.map(\.name),
            ["App Cleaner 9"]
        )
    }

    func testScanProtectsNameOnlyBackupButKeepsExactBundleEvidence() throws {
        var completion: ((Set<URL>) -> Void)?
        let selectedApp = makeApp(
            name: "OpenFind",
            bundleIdentifier: "com.openfind.app",
            path: "/Applications/OpenFind.app"
        )
        let appState = AppState(
            performStartupTasks: false,
            searchSensitivityProvider: { .enhanced },
            appFileScanner: { _, _, pendingCompletion in
                completion = pendingCompletion
                return nil
            }
        )
        appState.installedApps = [selectedApp]

        appState.scanForAppFiles(selectedApp)
        let completeScan = try XCTUnwrap(completion)
        let weakBackup = URL(
            fileURLWithPath: "/Users/test/Library/Application Support/Codex/Backups/OpenFind"
        )
        let exactBundleBackup = URL(
            fileURLWithPath: "/Users/test/Library/Application Support/Codex/Backups/com.openfind.app.plist"
        )
        completeScan([selectedApp.path, weakBackup, exactBundleBackup])

        XCTAssertEqual(Set(appState.discoveredFiles), [selectedApp.path, exactBundleBackup])
        XCTAssertEqual(appState.selectedFiles, [selectedApp.path, exactBundleBackup])
        XCTAssertEqual(appState.protectedAppFiles.map(\.url), [weakBackup])
        XCTAssertEqual(appState.protectedAppFiles.first?.reason, .ambiguousName)
        XCTAssertEqual(
            appState.appFileMatchEvidenceByPath[exactBundleBackup.path],
            .exactBundleIdentifier
        )
        XCTAssertTrue(appState.canRemoveSelectedAppFiles)
    }

    func testRemovalBoundaryRevalidatesBackupEvidenceBeforeTrash() async throws {
        var completion: ((Set<URL>) -> Void)?
        var requestedTrashURLs: [URL]?
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftBackupBoundary-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: historyURL) }
        let selectedApp = makeApp(
            name: "OpenFind",
            bundleIdentifier: "com.openfind.app",
            path: "/Applications/OpenFind.app"
        )
        let weakBackup = URL(
            fileURLWithPath: "/Users/test/Library/Application Support/Codex/Backups/OpenFind"
        )
        let exactBundleBackup = URL(
            fileURLWithPath: "/Users/test/Library/Application Support/Codex/Backups/com.openfind.app.plist"
        )
        let appState = AppState(
            performStartupTasks: false,
            searchSensitivityProvider: { .enhanced },
            appFileScanner: { _, _, pendingCompletion in
                completion = pendingCompletion
                return nil
            },
            appFileTrashHandler: { urls in
                requestedTrashURLs = urls
                return AppFileTrashResult(
                    trashed: [],
                    missing: urls,
                    needsFullDiskAccess: false,
                    failed: []
                )
            },
            removalHistoryStore: AppRemovalHistoryStore(fileURL: historyURL),
            appTerminationHandler: { _, _ in .notRunning }
        )
        appState.installedApps = [selectedApp]

        appState.scanForAppFiles(selectedApp)
        try XCTUnwrap(completion)([selectedApp.path, weakBackup, exactBundleBackup])
        appState.removeSelectedFiles()

        try await waitUntil { requestedTrashURLs != nil }
        XCTAssertEqual(Set(try XCTUnwrap(requestedTrashURLs)), [selectedApp.path, exactBundleBackup])
        XCTAssertFalse(try XCTUnwrap(requestedTrashURLs).contains(weakBackup))
    }

    func testScanProtectsSharedAppGroupInsteadOfSelectingIt() throws {
        var completion: ((Set<URL>) -> Void)?
        let groupIdentifier = "2DC432GLL2.com.openai.codex.notifications"
        let signature = AppSignatureMetadata(
            status: .developerSigned,
            signingIdentifier: "com.openai.codex",
            teamIdentifier: "2DC432GLL2",
            entitlementIdentifiers: [groupIdentifier],
            sharedContainerIdentifiers: [groupIdentifier]
        )
        let selectedApp = makeApp(
            name: "ChatGPT",
            bundleIdentifier: "com.openai.codex",
            path: "/Applications/ChatGPT.app",
            signature: signature
        )
        let appState = AppState(
            performStartupTasks: false,
            appFileScanner: { _, _, pendingCompletion in
                completion = pendingCompletion
                return nil
            }
        )
        appState.installedApps = [selectedApp]

        appState.scanForAppFiles(selectedApp)
        let completeScan = try XCTUnwrap(completion)
        let ownCache = URL(fileURLWithPath: "/Users/test/Library/Caches/com.openai.codex")
        let sharedGroup = URL(
            fileURLWithPath: "/Users/test/Library/Group Containers/\(groupIdentifier)"
        )
        completeScan([selectedApp.path, ownCache, sharedGroup])

        XCTAssertEqual(Set(appState.discoveredFiles), [selectedApp.path, ownCache])
        XCTAssertEqual(appState.selectedFiles, [selectedApp.path, ownCache])
        XCTAssertEqual(appState.protectedAppFiles.count, 1)
        XCTAssertEqual(appState.protectedAppFiles.first?.url, sharedGroup)
        XCTAssertEqual(appState.protectedAppFiles.first?.reason, .sharedContainer)
        XCTAssertTrue(appState.canRemoveSelectedAppFiles)
    }

    func testScanProtectsAnotherApplicationBundleInsteadOfSelectingIt() throws {
        var completion: ((Set<URL>) -> Void)?
        let selectedApp = makeApp(
            name: "ChatGPT",
            bundleIdentifier: "com.openai.codex",
            path: "/Applications/ChatGPT.app"
        )
        let otherApp = URL(fileURLWithPath: "/Applications/ChatGPT Atlas.app")
        let appState = AppState(
            performStartupTasks: false,
            appFileScanner: { _, _, pendingCompletion in
                completion = pendingCompletion
                return nil
            }
        )
        appState.installedApps = [selectedApp]

        appState.scanForAppFiles(selectedApp)
        let completeScan = try XCTUnwrap(completion)
        completeScan([selectedApp.path, otherApp])

        XCTAssertEqual(appState.discoveredFiles, [selectedApp.path])
        XCTAssertEqual(appState.selectedFiles, [selectedApp.path])
        XCTAssertEqual(appState.protectedAppFiles.count, 1)
        XCTAssertEqual(appState.protectedAppFiles.first?.url, otherApp)
        XCTAssertEqual(appState.protectedAppFiles.first?.reason, .foreignApplication)
        XCTAssertEqual(
            appState.protectedAppFiles.first?.relatedApplications.map(\.name),
            ["ChatGPT Atlas"]
        )
        XCTAssertTrue(appState.canRemoveSelectedAppFiles)
    }

    func testRelationshipScanPublishesSignedPeersAndEnrichesProtectedContainer() async throws {
        var completion: ((Set<URL>) -> Void)?
        let groupIdentifier = "TEAM123456.shared"
        let selected = makeApp(
            name: "Word",
            bundleIdentifier: "com.example.word",
            path: "/Applications/Word.app",
            signature: AppSignatureMetadata(
                status: .developerSigned,
                signingIdentifier: "com.example.word",
                teamIdentifier: "TEAM123456",
                entitlementIdentifiers: [groupIdentifier],
                sharedContainerIdentifiers: [groupIdentifier]
            )
        )
        let peer = makeApp(
            name: "Excel",
            bundleIdentifier: "com.example.excel",
            path: "/Applications/Excel.app",
            signature: AppSignatureMetadata(
                status: .developerSigned,
                signingIdentifier: "com.example.excel",
                teamIdentifier: "TEAM123456",
                entitlementIdentifiers: [groupIdentifier],
                sharedContainerIdentifiers: [groupIdentifier]
            )
        )
        let appState = AppState(
            performStartupTasks: false,
            appFileScanner: { _, _, pendingCompletion in
                completion = pendingCompletion
                return nil
            },
            appInstallationInspector: { _, _ in
                AppInstallationInsights(source: .unknown, officialUninstaller: nil)
            },
            appRelationshipsScanner: { applications, selectedID, shouldCancel in
                AppRelationshipScanner.scan(
                    applications: applications,
                    selectedApplicationID: selectedID,
                    shouldCancel: shouldCancel
                )
            }
        )
        appState.installedApps = [selected, peer]
        let protectedContainer = URL(
            fileURLWithPath: "/Users/test/Library/Group Containers/\(groupIdentifier)"
        )

        appState.scanForAppFiles(selected)
        try XCTUnwrap(completion)([selected.path, protectedContainer])
        try await waitUntil {
            appState.selectedAppRelationships != nil
                && appState.protectedAppFiles.first?.relatedApplications.isEmpty == false
        }

        XCTAssertEqual(
            appState.selectedAppRelationships?.relatedApplications(to: selected.id).map(\.name),
            ["Excel"]
        )
        XCTAssertEqual(
            appState.protectedAppFiles.first?.relatedApplications.map(\.name),
            ["Excel"]
        )
    }

    func testSelectedAppChangeRejectsLateRelationshipScan() async throws {
        let firstStarted = expectation(description: "first relationship scan started")
        let releaseFirst = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal() }
        let first = makeApp(
            name: "First",
            bundleIdentifier: "com.example.first",
            path: "/Applications/First.app"
        )
        let second = makeApp(
            name: "Second",
            bundleIdentifier: "com.example.second",
            path: "/Applications/Second.app"
        )
        let appState = AppState(
            performStartupTasks: false,
            appFileScanner: { app, _, completion in
                completion([app.path])
                return nil
            },
            appInstallationInspector: { _, _ in
                AppInstallationInsights(source: .unknown, officialUninstaller: nil)
            },
            appRelationshipsScanner: { _, selectedID, _ in
                if selectedID == first.id {
                    firstStarted.fulfill()
                    releaseFirst.wait()
                }
                return AppRelationshipScanResult(
                    groups: [],
                    selectedApplicationID: selectedID,
                    scannedApplicationCount: 1,
                    ignoredUnsignedApplicationCount: 1,
                    invalidGroupIdentifierCount: 0,
                    wasTruncated: false,
                    wasCancelled: false,
                    scannedAt: Date()
                )
            }
        )

        appState.scanForAppFiles(first)
        await fulfillment(of: [firstStarted], timeout: 1)
        appState.scanForAppFiles(second)
        releaseFirst.signal()

        try await waitUntil {
            appState.selectedAppRelationships?.selectedApplicationID == second.id
        }
        XCTAssertEqual(appState.selectedApp?.id, second.id)
        XCTAssertEqual(
            appState.selectedAppRelationships?.selectedApplicationID,
            second.id
        )
    }

    func testScanForAppFilesIgnoresStaleCompletionAfterAppChanges() throws {
        var firstCompletion: ((Set<URL>) -> Void)?
        var secondCompletion: ((Set<URL>) -> Void)?
        let firstScanWasCancelled = ThreadSafeFlag()
        var scanCount = 0
        let firstApp = makeApp(
            name: "ChordVox",
            bundleIdentifier: "com.gravitypoet.chordvox",
            path: "/Applications/ChordVox.app"
        )
        let secondApp = makeApp(
            name: "Clash Verge",
            bundleIdentifier: "io.github.clash-verge-rev.clash-verge-rev",
            path: "/Applications/Clash Verge.app"
        )
        let appState = AppState(
            performStartupTasks: false,
            appFileScanner: { _, _, pendingCompletion in
                scanCount += 1
                if scanCount == 1 {
                    firstCompletion = pendingCompletion
                    return { firstScanWasCancelled.set() }
                } else {
                    secondCompletion = pendingCompletion
                    return nil
                }
            }
        )

        appState.scanForAppFiles(firstApp)
        appState.scanForAppFiles(secondApp)
        XCTAssertTrue(firstScanWasCancelled.value)

        let completeFirstScan = try XCTUnwrap(firstCompletion)
        completeFirstScan([
            URL(fileURLWithPath: "/Users/test/Library/Application Support/chordvox")
        ])

        XCTAssertTrue(appState.isScanningAppFiles)
        XCTAssertTrue(appState.discoveredFiles.isEmpty)
        XCTAssertTrue(appState.selectedFiles.isEmpty)
        XCTAssertFalse(appState.canRemoveSelectedAppFiles)

        let clashURLs: Set<URL> = [
            URL(fileURLWithPath: "/Users/test/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev")
        ]
        let completeSecondScan = try XCTUnwrap(secondCompletion)
        completeSecondScan(clashURLs)

        XCTAssertFalse(appState.isScanningAppFiles)
        XCTAssertEqual(appState.selectedApp?.id, secondApp.id)
        XCTAssertEqual(appState.discoveredFiles, clashURLs.sorted { $0.path < $1.path })
        XCTAssertEqual(appState.selectedFiles, clashURLs)
        XCTAssertTrue(appState.canRemoveSelectedAppFiles)
    }

    func testRemoveSelectedFilesRefusesURLsOutsideCurrentScanResult() throws {
        var completion: ((Set<URL>) -> Void)?
        let app = makeApp(name: "Example", bundleIdentifier: "com.example.editor")
        let appState = AppState(
            performStartupTasks: false,
            appFileScanner: { _, _, pendingCompletion in
                completion = pendingCompletion
                return nil
            }
        )
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppSiftAppStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let validURL = tempDirectory.appendingPathComponent("valid-leftover")
        let unexpectedURL = tempDirectory.appendingPathComponent("unexpected-leftover")
        try Data("valid".utf8).write(to: validURL)
        try Data("unexpected".utf8).write(to: unexpectedURL)

        appState.scanForAppFiles(app)
        let completeScan = try XCTUnwrap(completion)
        completeScan([validURL])
        appState.selectedFiles.insert(unexpectedURL)

        XCTAssertFalse(appState.canRemoveSelectedAppFiles)

        appState.removeSelectedFiles()

        XCTAssertTrue(FileManager.default.fileExists(atPath: validURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unexpectedURL.path))
        XCTAssertTrue(appState.selectedFiles.isEmpty)
        XCTAssertTrue(appState.removalError?.contains("not in the current scan result") == true)
    }

    func testRemoveSelectedFilesDoesNotTrashRunningAppWhenQuitFails() async throws {
        var completion: ((Set<URL>) -> Void)?
        var terminationRequests: [String] = []
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppSiftAppStateTests-\(UUID().uuidString)", isDirectory: true)
        let appBundle = tempDirectory.appendingPathComponent("ChordVox.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appBundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let app = makeApp(
            name: "ChordVox",
            bundleIdentifier: "com.gravitypoet.chordvox",
            path: appBundle.path
        )
        let appState = AppState(
            performStartupTasks: false,
            appFileScanner: { _, _, pendingCompletion in
                completion = pendingCompletion
                return nil
            },
            appTerminationHandler: { app, _ in
                terminationRequests.append(app.bundleIdentifier)
                return .stillRunning
            }
        )

        appState.scanForAppFiles(app)
        let completeScan = try XCTUnwrap(completion)
        completeScan([appBundle])

        appState.removeSelectedFiles()

        try await waitUntil {
            appState.removalError != nil
        }

        XCTAssertEqual(terminationRequests, ["com.gravitypoet.chordvox"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: appBundle.path))
        XCTAssertTrue(appState.selectedFiles.contains(appBundle))
        XCTAssertFalse(appState.isRemovingAppFiles)
        XCTAssertFalse(appState.removalNeedsFullDiskAccess)
        XCTAssertTrue(appState.removalError?.contains("still running") == true)
    }

    func testRemoveSelectedFilesRecordsRestorableTrashReceipt() async throws {
        var completion: ((Set<URL>) -> Void)?
        let historyURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppSiftRemovalHistory-\(UUID().uuidString).json")
        let historyStore = AppRemovalHistoryStore(fileURL: historyURL)
        defer { try? FileManager.default.removeItem(at: historyURL) }

        let app = makeApp(name: "Example", bundleIdentifier: "com.example.editor")
        let original = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.example.editor", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: original) }
        let trashURL = URL(fileURLWithPath: "/Users/test/.Trash/com.example.editor")
        let appState = AppState(
            performStartupTasks: false,
            searchSensitivityProvider: { .enhanced },
            appFileScanner: { _, _, pendingCompletion in
                completion = pendingCompletion
                return nil
            },
            appFileTrashHandler: { urls in
                XCTAssertEqual(urls, [original])
                return AppFileTrashResult(
                    trashed: [TrashedAppFile(originalURL: original, trashURL: trashURL)],
                    missing: [],
                    needsFullDiskAccess: false,
                    failed: []
                )
            },
            removalHistoryStore: historyStore
        )

        appState.scanForAppFiles(app)
        try XCTUnwrap(completion)([original])
        appState.removeSelectedFiles()

        try await waitUntil {
            appState.removalHistory.count == 1
        }

        let record = try XCTUnwrap(appState.removalHistory.first)
        XCTAssertEqual(record.appName, "Example")
        XCTAssertEqual(record.bundleIdentifier, "com.example.editor")
        XCTAssertEqual(record.items.map(\.originalPath), [original.path])
        XCTAssertEqual(record.items.compactMap(\.trashPath), [trashURL.path])
        XCTAssertEqual(record.items.map(\.outcome), [.movedToTrash])
        XCTAssertEqual(record.items.map(\.evidence), [.exactBundleIdentifier])
        XCTAssertEqual(record.operation, .relatedFiles)
        XCTAssertEqual(record.restorableItemCount, 1)
        XCTAssertTrue(appState.discoveredFiles.isEmpty)
    }

    func testRemovalRecordCapturesEveryOutcomeAndProtectedGroup() async throws {
        var completion: ((Set<URL>) -> Void)?
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftAuditHistory-\(UUID().uuidString).json")
        let historyStore = AppRemovalHistoryStore(fileURL: historyURL)
        defer { try? FileManager.default.removeItem(at: historyURL) }

        let app = makeApp(name: "Example", bundleIdentifier: "com.example.editor")
        let moved = URL(fileURLWithPath: "/Users/test/Library/Caches/com.example.editor")
        let missing = URL(fileURLWithPath: "/Users/test/Library/Logs/com.example.editor.log")
        let failed = URL(fileURLWithPath: "/Users/test/Library/Preferences/com.example.editor.plist")
        let foreignApp = URL(fileURLWithPath: "/Applications/Example Companion.app")
        let trashURL = URL(fileURLWithPath: "/Users/test/.Trash/com.example.editor")
        let appState = AppState(
            performStartupTasks: false,
            searchSensitivityProvider: { .enhanced },
            appFileScanner: { _, _, pendingCompletion in
                completion = pendingCompletion
                return nil
            },
            appFileTrashHandler: { urls in
                XCTAssertEqual(Set(urls), Set([moved, missing, failed]))
                return AppFileTrashResult(
                    trashed: [TrashedAppFile(originalURL: moved, trashURL: trashURL)],
                    missing: [missing],
                    needsFullDiskAccess: false,
                    failed: [failed]
                )
            },
            removalHistoryStore: historyStore
        )

        appState.scanForAppFiles(app)
        try XCTUnwrap(completion)([moved, missing, failed, foreignApp])
        appState.removeSelectedFiles()

        try await waitUntil { appState.removalHistory.count == 1 }
        let record = try XCTUnwrap(appState.removalHistory.first)
        let outcomes = Dictionary(uniqueKeysWithValues: record.items.map { ($0.originalPath, $0.outcome) })

        XCTAssertEqual(outcomes[moved.path], .movedToTrash)
        XCTAssertEqual(outcomes[missing.path], .alreadyMissing)
        XCTAssertEqual(outcomes[failed.path], .failed)
        XCTAssertEqual(record.movedItemCount, 1)
        XCTAssertEqual(record.missingItemCount, 1)
        XCTAssertEqual(record.failedItemCount, 1)
        XCTAssertEqual(record.protectedItems, [
            AppRemovalProtectedItem(
                path: foreignApp.path,
                reason: .foreignApplication,
                matchedItemCount: 1
            ),
        ])
        XCTAssertEqual(record.searchSensitivity, .enhanced)
    }

    func testAppStateRefusesToUninstallItsOwnRunningBundle() throws {
        let currentBundleIdentifier = try XCTUnwrap(Bundle.main.bundleIdentifier)
        var completion: ((Set<URL>) -> Void)?
        let app = makeApp(
            name: "AppSift Tests",
            bundleIdentifier: currentBundleIdentifier
        )
        let appState = AppState(
            performStartupTasks: false,
            appFileScanner: { _, _, pendingCompletion in
                completion = pendingCompletion
                return nil
            }
        )

        appState.scanForAppFiles(app)
        try XCTUnwrap(completion)([app.path])

        XCTAssertFalse(appState.canRemoveSelectedAppFiles)
        appState.removeSelectedFiles()
        XCTAssertTrue(appState.removalError?.contains("cannot uninstall its own") == true)
    }

    func testPartialRemovalKeepsPermissionRetryAvailableAfterAppDisappears() async throws {
        var completion: ((Set<URL>) -> Void)?
        var suppressedTrashApps: [URL] = []
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftPartialRemoval-\(UUID().uuidString).json")
        let historyStore = AppRemovalHistoryStore(fileURL: historyURL)
        defer { try? FileManager.default.removeItem(at: historyURL) }
        let app = makeApp(name: "Example", bundleIdentifier: "com.example.partial")
        let leftover = URL(fileURLWithPath: "/Users/test/Library/Caches/com.example.partial")
        let trashedApp = URL(fileURLWithPath: "/Users/test/.Trash/Example.app")
        let appState = AppState(
            performStartupTasks: false,
            appFileScanner: { _, _, pendingCompletion in
                completion = pendingCompletion
                return nil
            },
            appFileTrashHandler: { _ in
                AppFileTrashResult(
                    trashed: [
                        TrashedAppFile(originalURL: app.path, trashURL: trashedApp),
                    ],
                    missing: [],
                    needsFullDiskAccess: true,
                    failed: [leftover]
                )
            },
            trashAppSuppressor: { suppressedTrashApps = $0 },
            removalHistoryStore: historyStore,
            appTerminationHandler: { _, _ in .terminated }
        )

        appState.scanForAppFiles(app)
        try XCTUnwrap(completion)([app.path, leftover])
        appState.removeSelectedFiles()

        try await waitUntil {
            appState.removalNeedsFullDiskAccess
        }
        XCTAssertEqual(appState.selectedApp?.id, app.id)
        XCTAssertEqual(appState.discoveredFiles, [leftover])
        XCTAssertEqual(appState.selectedFiles, Set([leftover]))
        XCTAssertEqual(appState.removalHistory.count, 1)
        XCTAssertEqual(appState.removalHistory.first?.operation, .uninstall)
        XCTAssertEqual(suppressedTrashApps, [trashedApp])
        XCTAssertTrue(appState.removalError?.contains("Full Disk Access") == true)
    }

    func testFailedRemovalDoesNotClaimItemsMovedWhenReportCannotPersist() async throws {
        var completion: ((Set<URL>) -> Void)?
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftReportFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blockingFile = root.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockingFile)
        let historyStore = AppRemovalHistoryStore(
            fileURL: blockingFile.appendingPathComponent("history.json")
        )
        let app = makeApp(name: "Example", bundleIdentifier: "com.example.editor")
        let failed = URL(fileURLWithPath: "/Users/test/Library/Caches/com.example.editor")
        let appState = AppState(
            performStartupTasks: false,
            appFileScanner: { _, _, pendingCompletion in
                completion = pendingCompletion
                return nil
            },
            appFileTrashHandler: { urls in
                XCTAssertEqual(urls, [failed])
                return AppFileTrashResult(
                    trashed: [],
                    missing: [],
                    needsFullDiskAccess: false,
                    failed: [failed]
                )
            },
            removalHistoryStore: historyStore
        )

        appState.scanForAppFiles(app)
        try XCTUnwrap(completion)([failed])
        appState.removeSelectedFiles()

        try await waitUntil {
            !appState.isRemovingAppFiles && appState.removalError != nil
        }

        XCTAssertTrue(appState.removalHistory.isEmpty)
        let expectedPersistenceError = String(
            localized: "AppSift could not save the local removal report for this attempt."
        )
        let inaccurateMovedMessage = String(
            localized: "Items were moved to Trash, but AppSift could not save the local removal report. Restore them manually from Trash."
        )
        XCTAssertTrue(appState.removalError?.contains(expectedPersistenceError) == true)
        XCTAssertFalse(appState.removalError?.contains(inaccurateMovedMessage) == true)
    }

    func testResetSelectedAppKeepsBundleAndNonResettableComponents() async throws {
        var completion: ((Set<URL>) -> Void)?
        var trashedBatches: [[URL]] = []
        var terminationRequests: [String] = []
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftResetFlow-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let appBundle = root.appendingPathComponent("Applications/Example.app", isDirectory: true)
        let cache = library.appendingPathComponent("Caches/com.example.editor", isDirectory: true)
        let support = library.appendingPathComponent("Application Support/Example", isDirectory: true)
        let groupContainer = library.appendingPathComponent("Group Containers/group.com.example.shared", isDirectory: true)
        let launchAgent = library.appendingPathComponent("LaunchAgents/com.example.editor.plist")
        let historyURL = root.appendingPathComponent("history.json")
        let historyStore = AppRemovalHistoryStore(fileURL: historyURL)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [appBundle, cache, support, groupContainer] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: launchAgent.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("launch".utf8).write(to: launchAgent)

        let app = makeApp(
            name: "Example",
            bundleIdentifier: "com.example.editor",
            path: appBundle.path
        )
        let appState = AppState(
            performStartupTasks: false,
            appFileScanner: { _, _, pendingCompletion in
                completion = pendingCompletion
                return nil
            },
            appFileTrashHandler: { urls in
                trashedBatches.append(urls)
                return AppFileTrashResult(
                    trashed: urls.map {
                        TrashedAppFile(
                            originalURL: $0,
                            trashURL: root.appendingPathComponent("Trash/\($0.lastPathComponent)")
                        )
                    },
                    missing: [],
                    needsFullDiskAccess: false,
                    failed: []
                )
            },
            appResetSafetyPolicy: AppResetSafetyPolicy(homeDirectory: home),
            removalHistoryStore: historyStore,
            appTerminationHandler: { target, _ in
                terminationRequests.append(target.bundleIdentifier)
                return .terminated
            }
        )

        appState.scanForAppFiles(app, initialSelection: .resetEligible)
        try XCTUnwrap(completion)([
            appBundle,
            cache,
            support,
            groupContainer,
            launchAgent,
        ])

        XCTAssertEqual(appState.availableAppResetFiles, Set([cache, support]))
        XCTAssertEqual(appState.selectedAppResetFiles, Set([cache, support]))
        XCTAssertEqual(appState.selectedFiles, Set([cache, support]))
        XCTAssertTrue(appState.canResetSelectedApp)

        appState.resetSelectedApp()

        try await waitUntil { appState.removalHistory.count == 1 }
        XCTAssertEqual(terminationRequests, ["com.example.editor"])
        XCTAssertEqual(trashedBatches.map(Set.init), [Set([cache, support])])
        XCTAssertTrue(appState.discoveredFiles.contains(appBundle))
        XCTAssertTrue(appState.discoveredFiles.contains(launchAgent))
        XCTAssertTrue(appState.protectedAppFiles.contains { $0.url == groupContainer })
        XCTAssertFalse(appState.discoveredFiles.contains(cache))
        XCTAssertFalse(appState.discoveredFiles.contains(support))

        let record = try XCTUnwrap(appState.removalHistory.first)
        XCTAssertEqual(record.schemaVersion, 3)
        XCTAssertEqual(record.operation, .reset)
        XCTAssertEqual(Set(record.items.map(\.originalPath)), Set([cache.path, support.path]))
        XCTAssertFalse(record.items.contains { $0.originalPath == appBundle.path })
    }

    func testResetSelectedAppDoesNotTrashDataWhenQuitFails() async throws {
        var completion: ((Set<URL>) -> Void)?
        var trashCallCount = 0
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftResetQuit-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let appBundle = root.appendingPathComponent("Applications/Example.app", isDirectory: true)
        let cache = home.appendingPathComponent("Library/Caches/com.example.editor", isDirectory: true)
        let historyURL = root.appendingPathComponent("history.json")
        let historyStore = AppRemovalHistoryStore(fileURL: historyURL)
        try FileManager.default.createDirectory(at: appBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(
            name: "Example",
            bundleIdentifier: "com.example.editor",
            path: appBundle.path
        )
        let appState = AppState(
            performStartupTasks: false,
            appFileScanner: { _, _, pendingCompletion in
                completion = pendingCompletion
                return nil
            },
            appFileTrashHandler: { _ in
                trashCallCount += 1
                return AppFileTrashResult(
                    trashed: [],
                    missing: [],
                    needsFullDiskAccess: false,
                    failed: []
                )
            },
            appResetSafetyPolicy: AppResetSafetyPolicy(homeDirectory: home),
            removalHistoryStore: historyStore,
            appTerminationHandler: { _, _ in .stillRunning }
        )

        appState.scanForAppFiles(app)
        try XCTUnwrap(completion)([appBundle, cache])
        appState.resetSelectedApp()

        try await waitUntil { appState.removalError != nil }
        XCTAssertEqual(trashCallCount, 0)
        XCTAssertTrue(appState.removalHistory.isEmpty)
        XCTAssertTrue(appState.discoveredFiles.contains(cache))
        XCTAssertTrue(appState.removalError?.contains("did not reset") == true)
    }

    func testFinderActionsChooseTheExpectedInitialSelection() {
        XCTAssertEqual(ExternalAppAction.uninstall.initialSelection, .all)
        XCTAssertEqual(ExternalAppAction.reset.initialSelection, .resetEligible)
        XCTAssertEqual(ExternalAppAction.reviewTrash.initialSelection, .relatedFiles)
    }

    private func makeApp(
        name: String,
        bundleIdentifier: String,
        path: String = "/Applications/AppSift.app",
        version: String? = nil,
        buildNumber: String? = nil,
        signature: AppSignatureMetadata = .unknown
    ) -> InstalledApp {
        InstalledApp(
            appName: name,
            bundleIdentifier: bundleIdentifier,
            path: URL(fileURLWithPath: path),
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1,
            version: version,
            buildNumber: buildNumber,
            signature: signature
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

final class AppResetSafetyPolicyTests: XCTestCase {
    func testResetPolicyAllowsOnlyReviewedUserLibraryData() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftResetPolicy-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let app = InstalledApp(
            appName: "Example",
            bundleIdentifier: "com.example.editor",
            path: root.appendingPathComponent("Applications/Example.app", isDirectory: true),
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1
        )
        let policy = AppResetSafetyPolicy(homeDirectory: home)

        XCTAssertTrue(policy.isEligible(
            home.appendingPathComponent("Library/Caches/com.example.editor", isDirectory: true),
            for: app
        ))
        XCTAssertTrue(policy.isEligible(
            home.appendingPathComponent("Library/Preferences/com.example.editor.plist"),
            for: app
        ))
        XCTAssertFalse(policy.isEligible(
            home.appendingPathComponent("Library/Caches", isDirectory: true),
            for: app
        ))
        XCTAssertFalse(policy.isEligible(
            home.appendingPathComponent("Library/Application Support", isDirectory: true),
            for: app
        ))
        XCTAssertFalse(policy.isEligible(app.path, for: app))
        XCTAssertFalse(policy.isEligible(
            home.appendingPathComponent("Library/Application Support/Example/Helper.app", isDirectory: true),
            for: app
        ))
        XCTAssertFalse(policy.isEligible(
            home.appendingPathComponent("Library/Group Containers/group.com.example.shared", isDirectory: true),
            for: app
        ))
        XCTAssertFalse(policy.isEligible(
            home.appendingPathComponent("Library/LaunchAgents/com.example.editor.plist"),
            for: app
        ))
        XCTAssertFalse(policy.isEligible(
            root.appendingPathComponent("Library/Application Support/Example", isDirectory: true),
            for: app
        ))
    }

    func testResetPolicyRejectsSymlinkThatEscapesAllowedRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftResetSymlink-\(UUID().uuidString)", isDirectory: true)
        let allowed = root.appendingPathComponent("Allowed", isDirectory: true)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        let link = allowed.appendingPathComponent("com.example.editor", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = InstalledApp(
            appName: "Example",
            bundleIdentifier: "com.example.editor",
            path: root.appendingPathComponent("Example.app", isDirectory: true),
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1
        )
        let policy = AppResetSafetyPolicy(allowedRoots: [allowed])

        XCTAssertFalse(policy.isEligible(link, for: app))
    }

    func testResetPolicyRejectsSymlinkTraversalBelowAllowedRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftResetNestedSymlink-\(UUID().uuidString)", isDirectory: true)
        let allowed = root.appendingPathComponent("Allowed", isDirectory: true)
        let packageContents = allowed
            .appendingPathComponent("Real/Helper.app/Contents", isDirectory: true)
        let data = packageContents.appendingPathComponent("Data", isDirectory: true)
        let link = allowed.appendingPathComponent("Alias", isDirectory: true)
        let candidate = link.appendingPathComponent("Data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: packageContents)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = InstalledApp(
            appName: "Example",
            bundleIdentifier: "com.example.editor",
            path: root.appendingPathComponent("Example.app", isDirectory: true),
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1
        )
        let policy = AppResetSafetyPolicy(allowedRoots: [allowed])

        XCTAssertFalse(policy.isEligible(candidate, for: app))
    }

    func testResetPolicyAllowsRelocatedAllowedRootWithoutNestedTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftResetRelocatedRoot-\(UUID().uuidString)", isDirectory: true)
        let physicalRoot = root.appendingPathComponent("Physical", isDirectory: true)
        let logicalRoot = root.appendingPathComponent("Logical", isDirectory: true)
        let physicalCandidate = physicalRoot
            .appendingPathComponent("com.example.editor", isDirectory: true)
        let logicalCandidate = logicalRoot
            .appendingPathComponent("com.example.editor", isDirectory: true)
        try FileManager.default.createDirectory(
            at: physicalCandidate,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: logicalRoot,
            withDestinationURL: physicalRoot
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let app = InstalledApp(
            appName: "Example",
            bundleIdentifier: "com.example.editor",
            path: root.appendingPathComponent("Example.app", isDirectory: true),
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1
        )
        let policy = AppResetSafetyPolicy(allowedRoots: [logicalRoot])

        XCTAssertTrue(policy.isEligible(logicalCandidate, for: app))
    }
}

final class AppRemovalRecoveryTests: XCTestCase {
    func testLegacyTrashReceiptDecodesWithSafeDefaults() throws {
        let itemID = UUID()
        let json = """
        {
          "id": "\(itemID.uuidString)",
          "originalPath": "/Users/test/Library/Caches/com.example.editor",
          "trashPath": "/Users/test/.Trash/com.example.editor"
        }
        """

        let item = try JSONDecoder().decode(
            AppRemovalHistoryItem.self,
            from: try XCTUnwrap(json.data(using: .utf8))
        )

        XCTAssertEqual(item.id, itemID)
        XCTAssertEqual(item.outcome, .movedToTrash)
        XCTAssertEqual(item.evidence, .legacyUnknown)
    }

    func testLegacyRemovalRecordDecodesWithoutInventingAuditEvidence() throws {
        let recordID = UUID()
        let itemID = UUID()
        let json = """
        {
          "id": "\(recordID.uuidString)",
          "appName": "Example",
          "bundleIdentifier": "com.example.editor",
          "removedAt": 0,
          "items": [{
            "id": "\(itemID.uuidString)",
            "originalPath": "/Users/test/Library/Caches/com.example.editor",
            "trashPath": "/Users/test/.Trash/com.example.editor"
          }]
        }
        """

        let record = try JSONDecoder().decode(
            AppRemovalRecord.self,
            from: try XCTUnwrap(json.data(using: .utf8))
        )

        XCTAssertEqual(record.schemaVersion, 1)
        XCTAssertEqual(record.operation, .legacyRemoval)
        XCTAssertNil(record.searchSensitivity)
        XCTAssertTrue(record.protectedItems.isEmpty)
        XCTAssertEqual(record.items.first?.evidence, .legacyUnknown)
    }

    func testRemovalReportExportContainsAuditDataAndIntegrityHash() throws {
        let record = AppRemovalRecord(
            appName: "Example",
            bundleIdentifier: "com.example.editor",
            searchSensitivity: .enhanced,
            items: [
                AppRemovalHistoryItem(
                    originalPath: "/Users/test/Library/Caches/com.example.editor",
                    trashPath: "/Users/test/.Trash/com.example.editor",
                    outcome: .movedToTrash,
                    evidence: .exactBundleIdentifier
                ),
            ],
            protectedItems: [
                AppRemovalProtectedItem(
                    path: "/Users/test/Library/Group Containers/group.com.example.shared",
                    reason: .sharedContainer,
                    matchedItemCount: 2
                ),
            ]
        )
        let exportedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let data = try AppRemovalReportExporter.data(for: record, exportedAt: exportedAt)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let receipt = try XCTUnwrap(json["receipt"] as? [String: Any])
        let digest = try XCTUnwrap(json["receiptSHA256"] as? String)

        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["integrityAlgorithm"] as? String, "SHA-256")
        XCTAssertEqual(
            json["integrityNote"] as? String,
            "Integrity checksum only; not a digital signature"
        )
        XCTAssertEqual(receipt["bundleIdentifier"] as? String, "com.example.editor")
        XCTAssertEqual(receipt["operation"] as? String, "relatedFiles")
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(digest.allSatisfy { $0.isHexDigit })
    }

    func testRemovalReportExportUsesPrivateFilePermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftPrivateReport-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("report.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let record = AppRemovalRecord(
            appName: "Example",
            bundleIdentifier: "com.example.editor",
            items: [
                AppRemovalHistoryItem(
                    originalPath: "/Users/test/Library/Caches/com.example.editor",
                    trashPath: "/Users/test/.Trash/com.example.editor"
                ),
            ]
        )

        try AppRemovalReportExporter.write(record, to: fileURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testSelfRemovalPolicyMatchesOnlyCurrentBundleIdentifier() {
        XCTAssertTrue(
            AppSelfRemovalPolicy.isCurrentApplication(
                bundleIdentifier: "com.gravitypoet.appsift",
                currentBundleIdentifier: "com.gravitypoet.appsift"
            )
        )
        XCTAssertFalse(
            AppSelfRemovalPolicy.isCurrentApplication(
                bundleIdentifier: "com.example.editor",
                currentBundleIdentifier: "com.gravitypoet.appsift"
            )
        )
        XCTAssertFalse(
            AppSelfRemovalPolicy.isCurrentApplication(
                bundleIdentifier: "com.gravitypoet.appsift",
                currentBundleIdentifier: nil
            )
        )
    }

    func testWorkspaceRecycleClassificationPreservesPartialTrashMapping() {
        let first = URL(fileURLWithPath: "/Applications/First.app")
        let second = URL(fileURLWithPath: "/Applications/Second.app")
        let trashed = URL(fileURLWithPath: "/Users/test/.Trash/First.app")
        let permissionError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError
        )

        let result = AppFileTrashService.classify(
            requested: [first, second],
            recycled: [first: trashed],
            error: permissionError,
            hasFullDiskAccess: false,
            fileExists: { $0 == second.path }
        )

        XCTAssertEqual(result.trashed, [
            TrashedAppFile(originalURL: first, trashURL: trashed)
        ])
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertEqual(result.failed, [second])
        XCTAssertTrue(result.needsFullDiskAccess)
    }

    func testRemovalHistoryStorePersistsReceipt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftHistoryStore-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let item = AppRemovalHistoryItem(
            originalPath: "/Users/test/Library/Caches/com.example.editor",
            trashPath: "/Users/test/.Trash/com.example.editor"
        )
        let record = AppRemovalRecord(
            appName: "Example",
            bundleIdentifier: "com.example.editor",
            items: [item]
        )

        AppRemovalHistoryStore(fileURL: fileURL).append(record)
        let reloaded = AppRemovalHistoryStore(fileURL: fileURL).snapshot()

        XCTAssertEqual(reloaded, [record])
    }

    func testRemovalHistoryStorePersistsRestoredState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftHistoryRestore-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let item = AppRemovalHistoryItem(
            originalPath: "/Users/test/Library/Caches/com.example.editor",
            trashPath: "/Users/test/.Trash/com.example.editor"
        )
        let record = AppRemovalRecord(
            appName: "Example",
            bundleIdentifier: "com.example.editor",
            items: [item]
        )
        let store = AppRemovalHistoryStore(fileURL: fileURL)
        let restoredAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.append(record)
        store.markRestored(recordID: record.id, itemID: item.id, at: restoredAt)

        let reloaded = AppRemovalHistoryStore(fileURL: fileURL).snapshot()
        XCTAssertEqual(reloaded.first?.items.first?.restoredAt, restoredAt)
    }

    func testRemovalHistoryStoreKeepsRestoredStateInMemoryWhenPersistenceFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftHistoryRestoreFailure-\(UUID().uuidString)", isDirectory: true)
        let storeDirectory = root.appendingPathComponent("History", isDirectory: true)
        let fileURL = storeDirectory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let item = AppRemovalHistoryItem(
            originalPath: "/Users/test/Library/Caches/com.example.editor",
            trashPath: "/Users/test/.Trash/com.example.editor"
        )
        let record = AppRemovalRecord(
            appName: "Example",
            bundleIdentifier: "com.example.editor",
            items: [item]
        )
        let store = AppRemovalHistoryStore(fileURL: fileURL)
        let restoredAt = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertTrue(store.append(record))
        try FileManager.default.removeItem(at: storeDirectory)
        try Data("blocked".utf8).write(to: storeDirectory)

        XCTAssertFalse(store.markRestored(
            recordID: record.id,
            itemID: item.id,
            at: restoredAt
        ))
        XCTAssertEqual(store.snapshot().first?.items.first?.restoredAt, restoredAt)
    }

    func testRemovalHistoryStoreCanDeleteOneRecordAndClearLocalFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftHistoryClear-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = AppRemovalRecord(
            appName: "First",
            bundleIdentifier: "com.example.first",
            items: [
                AppRemovalHistoryItem(
                    originalPath: "/Users/test/Library/Caches/com.example.first",
                    trashPath: "/Users/test/.Trash/com.example.first"
                ),
            ]
        )
        let second = AppRemovalRecord(
            appName: "Second",
            bundleIdentifier: "com.example.second",
            items: [
                AppRemovalHistoryItem(
                    originalPath: "/Users/test/Library/Caches/com.example.second",
                    trashPath: "/Users/test/.Trash/com.example.second"
                ),
            ]
        )
        let store = AppRemovalHistoryStore(fileURL: fileURL)

        store.append(first)
        store.append(second)
        store.remove(recordID: first.id)
        XCTAssertEqual(store.snapshot(), [second])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        store.removeAll()
        XCTAssertTrue(store.snapshot().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testRemovalHistoryStoreDoesNotClaimPersistenceWhenWriteFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftHistoryFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blockingFile = root.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockingFile)
        let store = AppRemovalHistoryStore(
            fileURL: blockingFile.appendingPathComponent("history.json")
        )
        let record = AppRemovalRecord(
            appName: "Example",
            bundleIdentifier: "com.example.editor",
            items: [
                AppRemovalHistoryItem(
                    originalPath: "/Users/test/Library/Caches/com.example.editor",
                    trashPath: "/Users/test/.Trash/com.example.editor"
                ),
            ]
        )

        XCTAssertFalse(store.append(record))
        XCTAssertTrue(store.snapshot().isEmpty)
    }

    func testRemovalHistoryStoreRejectsDuplicateItemPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftHistoryDuplicates-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let duplicatePath = "/Users/test/Library/Caches/com.example.editor"
        let record = AppRemovalRecord(
            appName: "Example",
            bundleIdentifier: "com.example.editor",
            items: [
                AppRemovalHistoryItem(
                    originalPath: duplicatePath,
                    trashPath: "/Users/test/.Trash/com.example.editor"
                ),
                AppRemovalHistoryItem(
                    originalPath: duplicatePath,
                    trashPath: "/Users/test/.Trash/com.example.editor-2"
                ),
            ]
        )
        try JSONEncoder().encode([record]).write(to: fileURL, options: .atomic)

        XCTAssertTrue(AppRemovalHistoryStore(fileURL: fileURL).snapshot().isEmpty)
    }

    func testRemovalRestorerMovesTrashItemBackWithoutOverwrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftRestorer-\(UUID().uuidString)", isDirectory: true)
        let trashRoot = root.appendingPathComponent("Trash", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let trashItem = trashRoot.appendingPathComponent("com.example.editor")
        let original = destinationRoot.appendingPathComponent("com.example.editor")
        try Data("restorable".utf8).write(to: trashItem)
        let item = AppRemovalHistoryItem(
            originalPath: original.path,
            trashPath: trashItem.path
        )
        let restorer = AppRemovalRestorer(
            trashRoot: trashRoot,
            allowedDestinationRoots: [destinationRoot]
        )

        XCTAssertEqual(restorer.restore(item), .restored)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashItem.path))
    }

    func testRemovalRestorerRefusesDestinationCollision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftRestorerCollision-\(UUID().uuidString)", isDirectory: true)
        let trashRoot = root.appendingPathComponent("Trash", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let trashItem = trashRoot.appendingPathComponent("com.example.editor")
        let original = destinationRoot.appendingPathComponent("com.example.editor")
        try Data("trash".utf8).write(to: trashItem)
        try Data("current".utf8).write(to: original)
        let item = AppRemovalHistoryItem(
            originalPath: original.path,
            trashPath: trashItem.path
        )
        let restorer = AppRemovalRestorer(
            trashRoot: trashRoot,
            allowedDestinationRoots: [destinationRoot]
        )

        XCTAssertEqual(restorer.restore(item), .destinationExists)
        XCTAssertEqual(try Data(contentsOf: original), Data("current".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashItem.path))
    }

    func testRemovalRestorerRefusesSourceOutsideTrash() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftRestorerOutsideTrash-\(UUID().uuidString)", isDirectory: true)
        let trashRoot = root.appendingPathComponent("Trash", isDirectory: true)
        let outsideRoot = root.appendingPathComponent("Outside", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outsideItem = outsideRoot.appendingPathComponent("payload")
        let original = destinationRoot.appendingPathComponent("payload")
        try Data("outside".utf8).write(to: outsideItem)
        let item = AppRemovalHistoryItem(
            originalPath: original.path,
            trashPath: outsideItem.path
        )
        let restorer = AppRemovalRestorer(
            trashRoot: trashRoot,
            allowedDestinationRoots: [destinationRoot]
        )

        XCTAssertEqual(restorer.restore(item), .blocked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideItem.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    func testRemovalRestorerRefusesDestinationOutsideAppSearchRoots() {
        let trashRoot = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)
        let source = trashRoot.appendingPathComponent("payload")
        let item = AppRemovalHistoryItem(
            originalPath: "/Users/test/Documents/payload",
            trashPath: source.path
        )
        let restorer = AppRemovalRestorer(
            trashRoot: trashRoot,
            fileExists: { $0 == source.path },
            moveOperation: { _, _ in
                XCTFail("Blocked receipt must not reach the move operation")
            }
        )

        XCTAssertEqual(restorer.restore(item), .blocked)
    }

    func testRemovalRestorerRefusesSymlinkedDestinationParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftRestorerDestinationLink-\(UUID().uuidString)", isDirectory: true)
        let trashRoot = root.appendingPathComponent("Trash", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("Caches", isDirectory: true)
        let outsideRoot = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let trashItem = trashRoot.appendingPathComponent("payload")
        let linkedParent = destinationRoot.appendingPathComponent("Linked", isDirectory: true)
        let original = linkedParent.appendingPathComponent("payload")
        try Data("restorable".utf8).write(to: trashItem)
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: outsideRoot
        )
        let item = AppRemovalHistoryItem(
            originalPath: original.path,
            trashPath: trashItem.path
        )
        let restorer = AppRemovalRestorer(
            trashRoot: trashRoot,
            allowedDestinationRoots: [destinationRoot]
        )

        XCTAssertEqual(restorer.restore(item), .blocked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashItem.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideRoot.appendingPathComponent("payload").path))
    }

    func testRemovalRestorerMatchesEveryAppSearchRootExceptProtectedDotPaths() {
        let trashRoot = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)
        let searchRoots = Locations().appSearch.paths.filter { !$0.isEmpty }

        for (index, rootPath) in searchRoots.enumerated() {
            let source = trashRoot.appendingPathComponent("item-\(index)")
            let destinationPath = URL(fileURLWithPath: rootPath, isDirectory: true)
                .appendingPathComponent("appsift-restore-probe-\(index)")
                .standardizedFileURL.path
            let item = AppRemovalHistoryItem(
                originalPath: destinationPath,
                trashPath: source.path
            )
            let restorer = AppRemovalRestorer(
                trashRoot: trashRoot,
                fileExists: { $0 == source.path },
                moveOperation: { _, _ in }
            )

            let isProtectedDotPath = highRiskHomeDotPaths.contains {
                destinationPath == $0 || destinationPath.hasPrefix($0 + "/")
            }
            XCTAssertEqual(
                restorer.restore(item),
                isProtectedDotPath ? .blocked : .restored,
                destinationPath
            )
        }
    }

    func testRemovalRestorerReportsAdministratorRequirement() {
        let trashRoot = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)
        let source = trashRoot.appendingPathComponent("ExampleExtension.kext")
        let item = AppRemovalHistoryItem(
            originalPath: "/Library/Extensions/ExampleExtension.kext",
            trashPath: source.path
        )
        let restorer = AppRemovalRestorer(
            trashRoot: trashRoot,
            fileExists: { $0 == source.path },
            moveOperation: { _, _ in
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileWriteNoPermissionError
                )
            }
        )

        XCTAssertEqual(restorer.restore(item), .requiresAdministratorAccess)
    }
}

private final class ThreadSafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set() {
        lock.lock()
        storedValue = true
        lock.unlock()
    }
}

final class AppPathFinderSearchPlanTests: XCTestCase {
    func testPathFinderExplainsMatchEvidenceWithoutReadingFileContents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftEvidence-\(UUID().uuidString)", isDirectory: true)
        let appURL = root.appendingPathComponent("Example Editor.app", isDirectory: true)
        let exactBundle = root.appendingPathComponent("com.example.editor", isDirectory: true)
        let structuredBundle = root.appendingPathComponent("com.example.editor.cache", isDirectory: true)
        let exactName = root.appendingPathComponent("Example Editor.log")
        let entitlement = root.appendingPathComponent("group.com.example.editor.state")
        for directory in [appURL, exactBundle, structuredBundle] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data().write(to: exactName)
        try Data().write(to: entitlement)
        defer { try? FileManager.default.removeItem(at: root) }
        let finder = AppPathFinder(
            appInfo: AppPathFinder.AppInfo(
                appName: "Example Editor",
                bundleIdentifier: "com.example.editor",
                path: appURL,
                entitlements: ["group.com.example.editor"]
            ),
            searchPaths: [root.path],
            sensitivity: .deep
        )

        XCTAssertEqual(finder.evidence(for: appURL), .selectedApplication)
        XCTAssertEqual(finder.evidence(for: exactBundle), .exactBundleIdentifier)
        XCTAssertEqual(finder.evidence(for: structuredBundle), .structuredBundleIdentifier)
        XCTAssertEqual(finder.evidence(for: exactName), .exactAppName)
        XCTAssertEqual(finder.evidence(for: entitlement), .verifiedEntitlement)
    }

    func testSearchPlanProtectsDesktopAndDocumentsFromUninstallScanning() {
        let desktop = "\(home)/Desktop"
        let documents = "\(home)/Documents"
        let library = "\(home)/Library"

        let plan = AppPathFinder.makeSearchPlan(paths: [
            desktop,
            "\(desktop)/App Data",
            documents,
            "\(documents)/App Data",
            library,
        ])
        let roots = Set(plan.map(\.path))
        let normalizedDesktop = URL(fileURLWithPath: desktop).resolvingSymlinksInPath().path
        let normalizedDocuments = URL(fileURLWithPath: documents).resolvingSymlinksInPath().path

        XCTAssertFalse(roots.contains {
            $0 == normalizedDesktop || $0.hasPrefix(normalizedDesktop + "/")
        })
        XCTAssertFalse(roots.contains {
            $0 == normalizedDocuments || $0.hasPrefix(normalizedDocuments + "/")
        })
        XCTAssertTrue(roots.contains(
            URL(fileURLWithPath: library).resolvingSymlinksInPath().path
        ))
    }

    @MainActor
    func testAsyncPathFinderMatchesSynchronousResults() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AppSiftAsyncPathFinder-\(UUID().uuidString)", isDirectory: true)
        let selectedApp = root.appendingPathComponent("ExampleEditor.app", isDirectory: true)
        let exactCache = root.appendingPathComponent("com.example.editor", isDirectory: true)
        let collision = root.appendingPathComponent("ExampleEditor Helper.app", isDirectory: true)
        for directory in [selectedApp, exactCache, collision] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: root) }

        let appInfo = AppPathFinder.AppInfo(
            appName: "ExampleEditor",
            bundleIdentifier: "com.example.editor",
            path: selectedApp,
            entitlements: nil
        )
        let expected = AppPathFinder(
            appInfo: appInfo,
            searchPaths: [root.path],
            sensitivity: .enhanced
        ).findPaths()

        let asyncFinder = AppPathFinder(
            appInfo: appInfo,
            searchPaths: [root.path],
            sensitivity: .enhanced
        )
        let actual = await withCheckedContinuation { continuation in
            asyncFinder.findPathsAsync { urls in
                continuation.resume(returning: urls)
            }
        }

        XCTAssertEqual(actual, expected)
        XCTAssertTrue(actual.contains(selectedApp))
        XCTAssertTrue(actual.contains(exactCache))
        XCTAssertFalse(actual.contains(collision))
    }

    func testSearchPlanCompactsOverlappingLibraryAndAppSupportRoots() {
        let library = "\(home)/Library"
        let appSupport = "\(library)/Application Support"
        let deepVendorRoot = "\(appSupport)/Vendor/Nested"

        let plan = AppPathFinder.makeSearchPlan(paths: [
            library,
            "\(library)/Caches",
            appSupport,
            "\(appSupport)/Vendor",
            deepVendorRoot,
            "\(home)/.config",
            appSupport,
        ])
        let roots = Dictionary(uniqueKeysWithValues: plan.map { ($0.path, $0.maxDepth) })
        let normalizedLibrary = URL(fileURLWithPath: library).resolvingSymlinksInPath().path
        let normalizedAppSupport = URL(fileURLWithPath: appSupport).resolvingSymlinksInPath().path
        let normalizedDeepVendor = URL(fileURLWithPath: deepVendorRoot).resolvingSymlinksInPath().path

        XCTAssertEqual(roots.count, 3)
        XCTAssertEqual(roots[normalizedLibrary], 2)
        XCTAssertEqual(roots[normalizedAppSupport], 2)
        XCTAssertEqual(roots[normalizedDeepVendor], 1)
        XCTAssertFalse(roots.keys.contains { $0.hasPrefix("\(home)/.config") })
    }

    func testPathFinderDoesNotFollowDirectorySymlinksOutsideSearchRoot() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("AppSiftPathFinder-\(UUID().uuidString)", isDirectory: true)
        let searchRoot = base.appendingPathComponent("search", isDirectory: true)
        let externalRoot = base.appendingPathComponent("external", isDirectory: true)
        let link = searchRoot.appendingPathComponent("linked-data", isDirectory: true)
        try fileManager.createDirectory(at: searchRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        try Data("outside".utf8).write(
            to: externalRoot.appendingPathComponent("ExampleApp-cache")
        )
        try fileManager.createSymbolicLink(at: link, withDestinationURL: externalRoot)
        defer { try? fileManager.removeItem(at: base) }

        let finder = AppPathFinder(
            appInfo: AppPathFinder.AppInfo(
                appName: "ExampleApp",
                bundleIdentifier: "com.example.app",
                path: URL(fileURLWithPath: "/Applications/ExampleApp.app"),
                entitlements: nil
            ),
            searchPaths: [searchRoot.path],
            sensitivity: .enhanced
        )

        let results = finder.findPaths()

        XCTAssertFalse(results.contains { $0.path.hasPrefix(link.path + "/") })
    }

    func testPathFinderKeepsExactIdentityArtifactsButRejectsOtherAppsAndNameCollisions() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AppSiftIdentityMatch-\(UUID().uuidString)", isDirectory: true)
        let selectedApp = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let exactNameCache = root.appendingPathComponent("ChatGPT", isDirectory: true)
        let exactBundleCache = root.appendingPathComponent("com.openai.codex", isDirectory: true)
        let bundleState = root.appendingPathComponent("com.openai.codex.savedState", isDirectory: true)
        let collisionPaths = [
            root.appendingPathComponent("ChatGPT Atlas.app", isDirectory: true),
            root.appendingPathComponent("ChatGPT Classic.app", isDirectory: true),
            root.appendingPathComponent("ChatGPT Swift.app", isDirectory: true),
            root.appendingPathComponent("ChatGPT Cloak", isDirectory: true),
            root.appendingPathComponent("ChatGPTHelper", isDirectory: true),
            root.appendingPathComponent("notcom.openai.codexbackup", isDirectory: true),
        ]
        let toolCacheRoot = root.appendingPathComponent("claude-cli-nodejs", isDirectory: true)
        let projectCache = toolCacheRoot
            .appendingPathComponent("-Users-test-Tools-chatgpt-web-desktop", isDirectory: true)

        for directory in [
            selectedApp,
            exactNameCache,
            exactBundleCache,
            bundleState,
            toolCacheRoot,
            projectCache,
        ] + collisionPaths {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: root) }

        let finder = AppPathFinder(
            appInfo: AppPathFinder.AppInfo(
                appName: "ChatGPT",
                bundleIdentifier: "com.openai.codex",
                path: selectedApp,
                entitlements: nil
            ),
            searchPaths: [root.path],
            sensitivity: .enhanced
        )

        let results = finder.findPaths()

        XCTAssertTrue(results.contains(selectedApp))
        XCTAssertTrue(results.contains(exactNameCache))
        XCTAssertTrue(results.contains(exactBundleCache))
        XCTAssertTrue(results.contains(bundleState))
        for collision in collisionPaths + [projectCache] {
            XCTAssertFalse(results.contains(collision), "Unexpected cross-app match: \(collision.path)")
        }
    }
}

final class AppRemovalSafetyPolicyTests: XCTestCase {
    func testForeignAppBundlesAreBlockedAtTheDeletionBoundary() {
        let selected = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        let candidates: Set<URL> = [
            selected,
            selected.appendingPathComponent("Contents/Resources/data.bin"),
            URL(fileURLWithPath: "/Applications/ChatGPT Atlas.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/ChatGPT Classic.app/Contents/Info.plist"),
            URL(fileURLWithPath: "/Users/test/Library/Caches/com.openai.codex"),
        ]

        let foreign = AppRemovalSafetyPolicy.foreignApplicationBundles(
            in: candidates,
            selectedAppURL: selected
        )

        XCTAssertEqual(foreign.map(\.path), [
            "/Applications/ChatGPT Atlas.app",
            "/Applications/ChatGPT Classic.app",
        ])
    }

    func testForeignPrivateDataNamespacesAreBlockedAtTheDeletionBoundary() {
        let selected = makeApp(
            name: "ChatGPT",
            bundleIdentifier: "com.openai.codex",
            path: "/Applications/ChatGPT.app"
        )
        let appCleaner = makeApp(
            name: "App Cleaner 9",
            bundleIdentifier: "com.nektony.App-Cleaner-SIII",
            path: "/Applications/App Cleaner 9.app"
        )
        let slack = makeApp(
            name: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            path: "/Applications/Slack.app"
        )
        let classic = makeApp(
            name: "ChatGPT",
            bundleIdentifier: "com.openai.chat",
            path: "/Applications/ChatGPT Classic.app"
        )
        let candidates: Set<URL> = [
            URL(fileURLWithPath: "/Users/test/Library/Application Support/ChatGPT"),
            URL(fileURLWithPath: "/Users/test/Library/Caches/com.openai.codex"),
            URL(fileURLWithPath: "/Users/test/Library/Application Support/OpenAI/ChatGPT"),
            URL(fileURLWithPath: "/Users/test/Library/Application Support/com.nektony.App-Cleaner-SIII/SubdomainAppsSearcher/com.openai.codex.26.plist"),
            URL(fileURLWithPath: "/Users/test/Library/Application Support/com.nektony.App-Cleaner-SIIICn/SubdomainAppsSearcher/com.openai.codex.25.plist"),
            URL(fileURLWithPath: "/Users/test/Library/Application Support/Slack/com.openai.codex.plist"),
            URL(fileURLWithPath: "/Users/test/Library/Caches/ChatGPT Cloak/com.openai.codex"),
        ]

        let foreignOwners = AppRemovalSafetyPolicy.foreignPrivateDataOwners(
            in: candidates,
            selectedApp: selected,
            installedApps: [selected, appCleaner, slack, classic]
        )

        XCTAssertEqual(Set(foreignOwners.map(\.path)), [
            "/Users/test/Library/Application Support/Slack",
            "/Users/test/Library/Application Support/ChatGPT",
            "/Users/test/Library/Application Support/OpenAI/ChatGPT",
            "/Users/test/Library/Application Support/com.nektony.App-Cleaner-SIII",
            "/Users/test/Library/Application Support/com.nektony.App-Cleaner-SIIICn",
            "/Users/test/Library/Caches/ChatGPT Cloak",
        ])
    }

    func testOwnPrivateDataFileWithExactDisplayNameIsAllowed() {
        let selected = makeApp(
            name: "ChatGPT",
            bundleIdentifier: "com.openai.codex",
            path: "/Applications/ChatGPT.app"
        )
        let log = URL(fileURLWithPath: "/Users/test/Library/Logs/ChatGPT.log")

        XCTAssertNil(
            AppRemovalSafetyPolicy.foreignPrivateDataOwner(
                containing: log,
                selectedApp: selected,
                installedApps: [selected]
            )
        )
    }

    func testNameOnlyMatchInsideToolBackupIsProtected() {
        let selected = makeApp(
            name: "OpenFind",
            bundleIdentifier: "com.openfind.app",
            path: "/Applications/OpenFind.app"
        )
        let backup = URL(
            fileURLWithPath: "/Users/test/Library/Application Support/Codex/Backups/OpenFind"
        )

        let protection = AppRemovalSafetyPolicy.protection(
            containing: backup,
            selectedApp: selected,
            installedApps: [selected]
        )

        XCTAssertEqual(protection?.protectedRoot, backup)
        XCTAssertEqual(protection?.reason, .ambiguousName)
    }

    func testExactBundleIdentifierInsideToolBackupCanBypassNameProtection() {
        let selected = makeApp(
            name: "OpenFind",
            bundleIdentifier: "com.openfind.app",
            path: "/Applications/OpenFind.app"
        )
        let backup = URL(
            fileURLWithPath: "/Users/test/Library/Application Support/Codex/Backups/com.openfind.app.plist"
        )

        XCTAssertNil(
            AppRemovalSafetyPolicy.protection(
                containing: backup,
                selectedApp: selected,
                installedApps: [selected],
                evidence: .exactBundleIdentifier
            )
        )
    }

    func testEveryStrongOwnershipEvidenceCanBypassRecoveryProtection() {
        let entitlement = "group.com.openfind.shared"
        let selected = InstalledApp(
            appName: "OpenFind",
            bundleIdentifier: "com.openfind.app",
            path: URL(fileURLWithPath: "/Applications/OpenFind.app"),
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1,
            signature: AppSignatureMetadata(
                status: .developerSigned,
                signingIdentifier: "com.openfind.app",
                teamIdentifier: "TEAM123456",
                entitlementIdentifiers: [entitlement],
                sharedContainerIdentifiers: []
            )
        )
        let cases: [(AppFileMatchEvidence, String)] = [
            (.appSpecificRule, "OpenFindRuleData"),
            (.exactBundleIdentifier, "com.openfind.app.plist"),
            (.structuredBundleIdentifier, "com.openfind.app.helper.plist"),
            (.verifiedEntitlement, "\(entitlement).plist"),
            (.containerMetadata, "99BD7CC0-239C-49C5-84AF-7F0C8767C1A5"),
        ]

        for (evidence, name) in cases {
            let candidate = URL(
                fileURLWithPath: "/Users/test/Library/Application Support/Codex/Backups/\(name)"
            )
            XCTAssertNil(
                AppRemovalSafetyPolicy.protection(
                    containing: candidate,
                    selectedApp: selected,
                    installedApps: [selected],
                    evidence: evidence
                ),
                evidence.rawValue
            )
        }
    }

    func testRecoveryHostMarkersAreCaseInsensitiveAndComponentBounded() {
        let selected = makeApp(
            name: "OpenFind",
            bundleIdentifier: "com.openfind.app",
            path: "/Applications/OpenFind.app"
        )
        let hostMarkers = [
            "Backup", "BACKUPS", "Archive", "ARCHIVES", "Snapshot",
            "SNAPSHOTS", "Recovery", "RECOVERIES", "Restore", "RESTORES",
        ]

        for marker in hostMarkers {
            let candidate = URL(
                fileURLWithPath: "/Users/test/Library/Application Support/Host/2026/\(marker)/OpenFind"
            )
            let protection = AppRemovalSafetyPolicy.protection(
                containing: candidate,
                selectedApp: selected,
                installedApps: [selected],
                evidence: .exactAppName
            )
            XCTAssertEqual(protection?.protectedRoot, candidate, marker)
            XCTAssertEqual(protection?.reason, .ambiguousName, marker)
        }

        let nestedHosts = URL(
            fileURLWithPath: "/Users/test/Library/Application Support/Host/Archives/2026/BACKUPS/OpenFind"
        )
        XCTAssertEqual(
            AppRemovalSafetyPolicy.protection(
                containing: nestedHosts,
                selectedApp: selected,
                installedApps: [selected],
                evidence: .exactAppName
            )?.protectedRoot,
            nestedHosts
        )

        for allowedPath in [
            "/Users/test/Library/Application Support/OpenFind",
            "/Users/test/Library/Application Support/BackupManager/OpenFind",
            "/Users/test/Documents/Backups/OpenFind",
        ] {
            XCTAssertNil(
                AppRemovalSafetyPolicy.protection(
                    containing: URL(fileURLWithPath: allowedPath),
                    selectedApp: selected,
                    installedApps: [selected],
                    evidence: .exactAppName
                ),
                allowedPath
            )
        }
    }

    func testWeakIdentifierAndNameEvidenceStayProtectedInsideBackupHost() {
        let selected = InstalledApp(
            appName: "OpenFind",
            bundleIdentifier: "com.openfind.app",
            path: URL(fileURLWithPath: "/Applications/OpenFind.app"),
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1,
            signature: AppSignatureMetadata(
                status: .developerSigned,
                signingIdentifier: "com.openfind.app",
                teamIdentifier: "TEAM123456",
                entitlementIdentifiers: [],
                sharedContainerIdentifiers: []
            )
        )
        let candidate = URL(
            fileURLWithPath: "/Users/test/Library/Application Support/Codex/Backups/OpenFind"
        )
        let weakEvidence: [AppFileMatchEvidence] = [
            .exactAppName,
            .exactBundlePathName,
            .bundleIdentifierSuffix,
            .baseBundleIdentifier,
            .versionStrippedName,
            .legacyUnknown,
        ]

        for evidence in weakEvidence {
            XCTAssertEqual(
                AppRemovalSafetyPolicy.protection(
                    containing: candidate,
                    selectedApp: selected,
                    installedApps: [selected],
                    evidence: evidence
                )?.reason,
                .ambiguousName,
                evidence.rawValue
            )
        }
    }

    func testSharedAppGroupIsAlwaysProtected() {
        let groupIdentifier = "2DC432GLL2.com.openai.codex.notifications"
        let selected = InstalledApp(
            appName: "ChatGPT",
            bundleIdentifier: "com.openai.codex",
            path: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1,
            signature: AppSignatureMetadata(
                status: .developerSigned,
                signingIdentifier: "com.openai.codex",
                teamIdentifier: "2DC432GLL2",
                entitlementIdentifiers: [groupIdentifier],
                sharedContainerIdentifiers: [groupIdentifier]
            )
        )
        let groupURL = URL(
            fileURLWithPath: "/Users/test/Library/Group Containers/\(groupIdentifier)"
        )
        let scriptsURL = URL(
            fileURLWithPath: "/Users/test/Library/Application Scripts/\(groupIdentifier)/helper.plist"
        )

        for (candidate, expectedRoot) in [
            (groupURL, groupURL),
            (
                scriptsURL,
                URL(fileURLWithPath: "/Users/test/Library/Application Scripts/\(groupIdentifier)")
            ),
        ] {
            let protection = AppRemovalSafetyPolicy.protection(
                containing: candidate,
                selectedApp: selected,
                installedApps: [selected]
            )

            XCTAssertEqual(protection?.protectedRoot, expectedRoot)
            XCTAssertEqual(protection?.reason, .sharedContainer)
        }
    }

    private func makeApp(name: String, bundleIdentifier: String, path: String) -> InstalledApp {
        InstalledApp(
            appName: name,
            bundleIdentifier: bundleIdentifier,
            path: URL(fileURLWithPath: path),
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1
        )
    }
}

final class OrphanTrashServiceTests: XCTestCase {
    func testTrashUsesInjectedTrashOperationWithoutUnlinkingDirectly() throws {
        let cacheRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
        let candidate = cacheRoot
            .appendingPathComponent("AppSiftOrphanTrashServiceTests-\(UUID().uuidString)")
        try Data("candidate".utf8).write(to: candidate)
        defer { try? FileManager.default.removeItem(at: candidate) }

        var receivedURLs: [URL] = []
        let service = OrphanTrashService(
            trashOperation: { url in receivedURLs.append(url) }
        )

        XCTAssertEqual(service.trash(candidate), .trashed)
        XCTAssertEqual(receivedURLs, [candidate])
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
    }

    func testTrashBlocksCandidateOutsideOrphanSafetyRoots() {
        var operationWasCalled = false
        let service = OrphanTrashService(
            fileExists: { _ in true },
            trashOperation: { _ in operationWasCalled = true }
        )

        let outcome = service.trash(URL(fileURLWithPath: "/tmp/not-an-orphan-candidate"))

        XCTAssertEqual(outcome, .blocked)
        XCTAssertFalse(operationWasCalled)
    }

    func testTrashReportsPermissionDeniedWithoutPermanentFallback() {
        let service = OrphanTrashService(
            fileExists: { _ in true },
            trashOperation: { _ in
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileWriteNoPermissionError
                )
            }
        )
        let candidate = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.example.permission-denied")

        XCTAssertEqual(service.trash(candidate), .permissionDenied)
    }
}

@MainActor
final class AppInstallationInspectorTests: XCTestCase {
    func testMacAppStoreRequiresBothStoreSignatureAndBoundedReceipt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Applications/Pages.app", isDirectory: true)
        try createBundle(at: appURL, bundleIdentifier: "com.apple.iWork.Pages")
        let receipt = appURL.appendingPathComponent("Contents/_MASReceipt/receipt")
        try FileManager.default.createDirectory(
            at: receipt.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("signed-receipt".utf8).write(to: receipt)

        let storeSigned = makeApp(
            at: appURL,
            bundleIdentifier: "com.apple.iWork.Pages",
            signature: developerSignature(teamID: "APPLE123", isMacAppStoreSigned: true)
        )
        let verified = AppInstallationInspector.inspect(
            app: storeSigned,
            homebrewRoots: []
        )
        XCTAssertEqual(verified.source, .macAppStore)

        let copiedReceiptOnly = makeApp(
            at: appURL,
            bundleIdentifier: "com.apple.iWork.Pages",
            signature: developerSignature(teamID: "THIRDPARTY", isMacAppStoreSigned: false)
        )
        XCTAssertEqual(
            AppInstallationInspector.inspect(
                app: copiedReceiptOnly,
                homebrewRoots: []
            ).source,
            .unknown
        )

        try FileManager.default.removeItem(at: receipt)
        XCTAssertEqual(
            AppInstallationInspector.inspect(
                app: storeSigned,
                homebrewRoots: []
            ).source,
            .unknown
        )
    }

    func testHomebrewCaskRequiresExactReceiptArtifactAndCaskroomLink() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Applications/UTM.app", isDirectory: true)
        let caskroom = root.appendingPathComponent("Caskroom", isDirectory: true)
        try createBundle(at: appURL, bundleIdentifier: "com.utmapp.UTM")
        let cask = caskroom.appendingPathComponent("utm", isDirectory: true)
        let version = cask.appendingPathComponent("4.7.5", isDirectory: true)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: version.appendingPathComponent("UTM.app"),
            withDestinationURL: appURL
        )
        try writeCaskReceipt(
            at: cask,
            appArtifact: "UTM.app",
            version: "4.7.5",
            cleanupPatterns: [
                "~/Library/Containers/com.utmapp*",
                "~/Library/Preferences/com.utmapp.UTM.plist",
            ]
        )
        let app = makeApp(
            at: appURL,
            bundleIdentifier: "com.utmapp.UTM",
            signature: developerSignature(teamID: "WDNLXAD4W8")
        )

        let insights = AppInstallationInspector.inspect(
            app: app,
            homebrewRoots: [caskroom]
        )
        guard case .homebrewCask(let metadata) = insights.source else {
            return XCTFail("Expected verified Homebrew cask provenance")
        }
        XCTAssertEqual(metadata.token, "utm")
        XCTAssertEqual(metadata.version, "4.7.5")
        XCTAssertEqual(metadata.tap, "homebrew/cask")
        XCTAssertEqual(metadata.extraCleanupPatternCount, 2)
        XCTAssertEqual(
            metadata.receiptURL,
            cask.appendingPathComponent(".metadata/INSTALL_RECEIPT.json")
                .standardizedFileURL
        )
    }

    func testHomebrewRejectsTraversalArtifactsAndConflictingCasks() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Applications/UTM.app", isDirectory: true)
        let caskroom = root.appendingPathComponent("Caskroom", isDirectory: true)
        try createBundle(at: appURL, bundleIdentifier: "com.utmapp.UTM")
        let app = makeApp(
            at: appURL,
            bundleIdentifier: "com.utmapp.UTM",
            signature: developerSignature(teamID: "WDNLXAD4W8")
        )

        let traversalCask = caskroom.appendingPathComponent("utm", isDirectory: true)
        let traversalVersion = traversalCask.appendingPathComponent("4.7.5", isDirectory: true)
        try FileManager.default.createDirectory(at: traversalVersion, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: traversalVersion.appendingPathComponent("UTM.app"),
            withDestinationURL: appURL
        )
        try writeCaskReceipt(
            at: traversalCask,
            appArtifact: "../UTM.app",
            version: "4.7.5"
        )
        XCTAssertEqual(
            AppInstallationInspector.inspect(
                app: app,
                homebrewRoots: [caskroom]
            ).source,
            .unknown
        )

        try writeCaskReceipt(
            at: traversalCask,
            appArtifact: "UTM.app",
            version: "4.7.5"
        )
        let duplicateCask = caskroom.appendingPathComponent("utm-nightly", isDirectory: true)
        let duplicateVersion = duplicateCask.appendingPathComponent("nightly", isDirectory: true)
        try FileManager.default.createDirectory(at: duplicateVersion, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: duplicateVersion.appendingPathComponent("UTM.app"),
            withDestinationURL: appURL
        )
        try writeCaskReceipt(
            at: duplicateCask,
            appArtifact: "UTM.app",
            version: "nightly"
        )

        XCTAssertEqual(
            AppInstallationInspector.inspect(
                app: app,
                homebrewRoots: [caskroom]
            ).source,
            .unknown,
            "Conflicting cask ownership must not be resolved by guessing"
        )
    }

    func testHomebrewCopiedArtifactRequiresMatchingDeveloperTeam() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Applications/Example.app", isDirectory: true)
        let caskroom = root.appendingPathComponent("Caskroom", isDirectory: true)
        let cask = caskroom.appendingPathComponent("example", isDirectory: true)
        let stagedApp = cask.appendingPathComponent("1.0/Example.app", isDirectory: true)
        try createBundle(at: appURL, bundleIdentifier: "com.example.editor")
        try createBundle(at: stagedApp, bundleIdentifier: "com.example.editor")
        try writeCaskReceipt(
            at: cask,
            appArtifact: "Example.app",
            version: "1.0"
        )
        let selected = makeApp(
            at: appURL,
            bundleIdentifier: "com.example.editor",
            signature: developerSignature(teamID: "REALTEAM")
        )

        let insights = AppInstallationInspector.inspect(
            app: selected,
            homebrewRoots: [caskroom],
            signatureInspector: { url in
                url.standardizedFileURL == stagedApp.standardizedFileURL
                    ? self.developerSignature(teamID: "OTHERTEAM")
                    : .unknown
            }
        )
        XCTAssertEqual(insights.source, .unknown)
    }

    func testOfficialUninstallerRequiresAppBundleNameAndMatchingTeam() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Applications/Example.app", isDirectory: true)
        let uninstaller = appURL.appendingPathComponent(
            "Contents/SharedSupport/Uninstall Example.app",
            isDirectory: true
        )
        try createBundle(at: appURL, bundleIdentifier: "com.example.editor")
        try createBundle(
            at: uninstaller,
            bundleIdentifier: "com.example.editor.uninstaller",
            displayName: "Example Uninstaller"
        )
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents/Resources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("not an app".utf8).write(
            to: appURL.appendingPathComponent("Contents/Resources/uninstall.txt")
        )
        let app = makeApp(
            at: appURL,
            bundleIdentifier: "com.example.editor",
            signature: developerSignature(teamID: "REALTEAM")
        )

        let verified = AppInstallationInspector.inspect(
            app: app,
            homebrewRoots: [],
            signatureInspector: { url in
                url.standardizedFileURL == uninstaller.standardizedFileURL
                    ? self.developerSignature(teamID: "REALTEAM")
                    : .unknown
            }
        )
        XCTAssertEqual(
            verified.officialUninstaller,
            AppOfficialUninstaller(
                name: "Example Uninstaller",
                url: uninstaller.standardizedFileURL
            )
        )

        let wrongTeam = AppInstallationInspector.inspect(
            app: app,
            homebrewRoots: [],
            signatureInspector: { _ in self.developerSignature(teamID: "OTHERTEAM") }
        )
        XCTAssertNil(wrongTeam.officialUninstaller)
    }

    func testMultipleSameRankOfficialUninstallersAreTreatedAsAmbiguous() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Applications/Example.app", isDirectory: true)
        let first = appURL.appendingPathComponent("Contents/Resources/Uninstall Example.app")
        let second = appURL.appendingPathComponent("Contents/Helpers/Example Uninstaller.app")
        try createBundle(at: appURL, bundleIdentifier: "com.example.editor")
        try createBundle(at: first, bundleIdentifier: "com.example.uninstall.one")
        try createBundle(at: second, bundleIdentifier: "com.example.uninstall.two")
        let app = makeApp(
            at: appURL,
            bundleIdentifier: "com.example.editor",
            signature: developerSignature(teamID: "REALTEAM")
        )

        let insights = AppInstallationInspector.inspect(
            app: app,
            homebrewRoots: [],
            signatureInspector: { _ in self.developerSignature(teamID: "REALTEAM") }
        )
        XCTAssertNil(insights.officialUninstaller)
    }

    func testSelectedAppChangeRejectsLateInstallationInspection() async throws {
        let firstStarted = expectation(description: "first inspection started")
        let releaseFirst = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal() }
        let first = makeApp(
            at: URL(fileURLWithPath: "/Applications/First.app"),
            bundleIdentifier: "com.example.first",
            signature: developerSignature(teamID: "TEAMONE")
        )
        let second = makeApp(
            at: URL(fileURLWithPath: "/Applications/Second.app"),
            bundleIdentifier: "com.example.second",
            signature: developerSignature(teamID: "TEAMTWO")
        )
        let state = AppState(
            performStartupTasks: false,
            appFileScanner: { app, _, completion in
                completion([app.path])
                return nil
            },
            appInstallationInspector: { app, _ in
                if app.id == first.id {
                    firstStarted.fulfill()
                    releaseFirst.wait()
                    return AppInstallationInsights(
                        source: .homebrewCask(
                            HomebrewCaskInstallMetadata(
                                token: "stale",
                                version: nil,
                                tap: nil,
                                receiptURL: URL(fileURLWithPath: "/tmp/stale.json"),
                                extraCleanupPatternCount: 0
                            )
                        ),
                        officialUninstaller: nil
                    )
                }
                return AppInstallationInsights(
                    source: .macAppStore,
                    officialUninstaller: nil
                )
            }
        )

        state.scanForAppFiles(first)
        await fulfillment(of: [firstStarted], timeout: 1)
        state.scanForAppFiles(second)
        releaseFirst.signal()

        try await waitUntil {
            state.selectedAppInstallationInsights?.source == .macAppStore
        }
        XCTAssertEqual(state.selectedApp?.id, second.id)
        XCTAssertEqual(state.selectedAppInstallationInsights?.source, .macAppStore)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftInstallationTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func createBundle(
        at url: URL,
        bundleIdentifier: String,
        displayName: String? = nil
    ) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": displayName ?? url.deletingPathExtension().lastPathComponent,
            "CFBundleDisplayName": displayName ?? url.deletingPathExtension().lastPathComponent,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func writeCaskReceipt(
        at caskDirectory: URL,
        appArtifact: String,
        version: String,
        cleanupPatterns: [String] = []
    ) throws {
        let metadata = caskDirectory.appendingPathComponent(".metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        var artifacts: [[String: Any]] = [["app": [appArtifact]]]
        if !cleanupPatterns.isEmpty {
            artifacts.append(["zap": [["trash": cleanupPatterns]]])
        }
        let document: [String: Any] = [
            "source": ["tap": "homebrew/cask", "version": version],
            "uninstall_artifacts": artifacts,
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try data.write(to: metadata.appendingPathComponent("INSTALL_RECEIPT.json"))
    }

    private func developerSignature(
        teamID: String,
        isMacAppStoreSigned: Bool = false
    ) -> AppSignatureMetadata {
        AppSignatureMetadata(
            status: .developerSigned,
            signingIdentifier: "com.example.signed",
            teamIdentifier: teamID,
            isMacAppStoreSigned: isMacAppStoreSigned,
            entitlementIdentifiers: []
        )
    }

    private func makeApp(
        at url: URL,
        bundleIdentifier: String,
        signature: AppSignatureMetadata
    ) -> InstalledApp {
        InstalledApp(
            appName: url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: bundleIdentifier,
            path: url,
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1,
            signature: signature
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

@MainActor
final class PkgReceiptInspectorTests: XCTestCase {
    func testVerifiedReceiptReportsExternalAndSharedPayloadWithoutSelectingIt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Applications/Editor.app", isDirectory: true)
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let exclusiveURL = root.appendingPathComponent("Library/Exclusive.component")
        let sharedURL = root.appendingPathComponent("Library/Shared.component")
        let unknownURL = root.appendingPathComponent("Library/Unknown.component")
        try createBundle(at: appURL)
        try FileManager.default.createDirectory(
            at: sharedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("exclusive".utf8).write(to: exclusiveURL)
        try Data("shared".utf8).write(to: sharedURL)
        try Data("unknown".utf8).write(to: unknownURL)

        let receiptID = "com.example.pkg.editor"
        let ownerPlist = try plistData([
            "path": infoURL.path,
            "path-info": [["pkgid": receiptID]],
        ])
        let sharedPlist = try plistData([
            "path": sharedURL.path,
            "path-info": [
                ["pkgid": receiptID],
                ["pkgid": "com.example.pkg.shared-runtime"],
            ],
        ])
        let exclusivePlist = try plistData([
            "path": exclusiveURL.path,
            "path-info": [["pkgid": receiptID]],
        ])
        let unknownPlist = try plistData([
            "path": unknownURL.path,
            "path-info": [],
        ])
        let infoPlist = try plistData([
            "pkgid": receiptID,
            "pkg-version": "4.2.0",
            "install-location": root.path,
        ])
        let payload = Data(
            "Applications/Editor.app/Contents/Info.plist\nLibrary/Exclusive.component\nLibrary/Shared.component\nLibrary/Unknown.component\nLibrary/Missing.component\n".utf8
        )
        let responses: [String: PkgCommandResult] = [
            key(["--file-info-plist", appURL.path]): success(ownerPlist),
            key(["--file-info-plist", infoURL.path]): success(ownerPlist),
            key(["--pkg-info-plist", receiptID]): success(infoPlist),
            key(["--files", receiptID]): success(payload),
            key(["--file-info-plist", exclusiveURL.path]): success(exclusivePlist),
            key(["--file-info-plist", sharedURL.path]): success(sharedPlist),
            key(["--file-info-plist", unknownURL.path]): success(unknownPlist),
        ]

        let insights = PkgReceiptInspector.inspect(
            app: makeApp(at: appURL),
            commandProvider: { arguments in
                responses[arguments.joined(separator: "\u{1f}")] ?? PkgCommandResult(
                    exitCode: 1,
                    output: Data(),
                    timedOut: false,
                    truncated: false
                )
            }
        )

        XCTAssertEqual(insights?.receipts, [
            InstallerPackageReceiptMetadata(
                identifier: receiptID,
                version: "4.2.0",
                installLocation: root.path
            ),
        ])
        XCTAssertEqual(insights?.payloadPathCount, 5)
        XCTAssertEqual(insights?.externalPayloadPathCount, 4)
        XCTAssertEqual(insights?.existingExternalPayloadPathCount, 3)
        XCTAssertEqual(insights?.externalComponents, [
            InstallerPackageExternalComponent(
                url: exclusiveURL,
                payloadPathCount: 1,
                ownership: .receiptOnly,
                otherOwnerIdentifiers: [],
                isSystemSensitive: false
            ),
            InstallerPackageExternalComponent(
                url: sharedURL,
                payloadPathCount: 1,
                ownership: .shared,
                otherOwnerIdentifiers: ["com.example.pkg.shared-runtime"],
                isSystemSensitive: false
            ),
            InstallerPackageExternalComponent(
                url: unknownURL,
                payloadPathCount: 1,
                ownership: .unverified,
                otherOwnerIdentifiers: [],
                isSystemSensitive: false
            ),
        ])
        XCTAssertEqual(insights?.sharedExternalComponentCount, 1)
        XCTAssertEqual(insights?.unverifiedExternalComponentCount, 1)
        XCTAssertEqual(insights?.systemSensitiveExternalComponentCount, 0)
        XCTAssertEqual(insights?.isIncomplete, true)
    }

    func testReceiptMustActuallyCoverSelectedApp() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Applications/Editor.app", isDirectory: true)
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        try createBundle(at: appURL)
        let receiptID = "com.example.pkg.unrelated"
        let ownerPlist = try plistData([
            "path": infoURL.path,
            "path-info": [["pkgid": receiptID]],
        ])
        let infoPlist = try plistData([
            "pkgid": receiptID,
            "install-location": root.path,
        ])
        let responses: [String: PkgCommandResult] = [
            key(["--file-info-plist", appURL.path]): success(ownerPlist),
            key(["--file-info-plist", infoURL.path]): success(ownerPlist),
            key(["--pkg-info-plist", receiptID]): success(infoPlist),
            key(["--files", receiptID]): success(
                Data("Library/Unrelated.component\n".utf8)
            ),
        ]

        XCTAssertNil(
            PkgReceiptInspector.inspect(
                app: makeApp(at: appURL),
                commandProvider: { arguments in
                    responses[arguments.joined(separator: "\u{1f}")] ?? PkgCommandResult(
                        exitCode: 1,
                        output: Data(),
                        timedOut: false,
                        truncated: false
                    )
                }
            )
        )
    }

    func testPayloadNormalizationRejectsTraversalOutsideInstallLocation() {
        XCTAssertNil(
            PkgReceiptInspector.normalizedPayloadURL(
                "../Library/Injected.component",
                installLocation: "/Applications"
            )
        )
        XCTAssertEqual(
            PkgReceiptInspector.normalizedPayloadURL(
                "Applications/Editor.app/Contents/Info.plist",
                installLocation: "/"
            )?.path,
            "/Applications/Editor.app/Contents/Info.plist"
        )
        XCTAssertEqual(
            PkgReceiptInspector.normalizedPayloadURL(
                "Applications/Editor.app/Contents/Info.plist",
                installLocation: "Library/Caches/InstallerClone"
            )?.path,
            "/Library/Caches/InstallerClone/Applications/Editor.app/Contents/Info.plist"
        )
        XCTAssertNil(
            PkgReceiptInspector.normalizedPayloadURL(
                "/Library/Injected.component",
                installLocation: "/Applications"
            )
        )
    }

    func testPayloadComponentsCollapseStructuralParentsAndDescendants() {
        let selectedApp = URL(fileURLWithPath: "/Applications/Editor.app")
        let payloadPaths = Set([
            URL(fileURLWithPath: "/Applications"),
            selectedApp,
            selectedApp.appendingPathComponent("Contents/Info.plist"),
            URL(fileURLWithPath: "/Applications/Editor Helper.app"),
            URL(fileURLWithPath: "/Applications/Editor Helper.app/Contents/Info.plist"),
            URL(fileURLWithPath: "/Library"),
            URL(fileURLWithPath: "/Library/Application Support"),
            URL(fileURLWithPath: "/Library/Application Support/com.example.editor"),
            URL(fileURLWithPath: "/Library/Application Support/com.example.editor/helper"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/usr/local/bin/editor-tool"),
        ])

        XCTAssertEqual(
            PkgReceiptInspector.collapsedExternalComponentRoots(
                payloadPaths: payloadPaths,
                appURL: selectedApp
            ),
            [
                URL(fileURLWithPath: "/Applications/Editor Helper.app"),
                URL(fileURLWithPath: "/Library/Application Support/com.example.editor"),
                URL(fileURLWithPath: "/usr/local/bin/editor-tool"),
            ]
        )
    }

    func testSystemSensitiveClassificationDoesNotMislabelUsrLocal() {
        XCTAssertTrue(
            PkgReceiptInspector.isSystemSensitivePath(
                "/Library/LaunchDaemons/com.example.editor.plist"
            )
        )
        XCTAssertTrue(PkgReceiptInspector.isSystemSensitivePath("/usr/bin/editor-tool"))
        XCTAssertFalse(
            PkgReceiptInspector.isSystemSensitivePath("/usr/local/bin/editor-tool")
        )
    }

    func testReceiptIdentifiersRejectOptionAndPathInjection() throws {
        let data = try plistData([
            "path": "/Applications/Editor.app/Contents/Info.plist",
            "path-info": [
                ["pkgid": "com.example.valid-package"],
                ["pkgid": "--forget"],
                ["pkgid": "com.example/escaped"],
                ["pkgid": "com.example package"],
            ],
        ])

        XCTAssertEqual(
            PkgReceiptInspector.parsePackageIdentifiers(from: data),
            ["com.example.valid-package"]
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftPkgReceiptTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func createBundle(at url: URL) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try plistData([
            "CFBundleIdentifier": "com.example.editor",
            "CFBundleName": "Editor",
            "CFBundlePackageType": "APPL",
        ])
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func makeApp(at url: URL) -> InstalledApp {
        InstalledApp(
            appName: "Editor",
            bundleIdentifier: "com.example.editor",
            path: url,
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1,
            signature: AppSignatureMetadata(
                status: .developerSigned,
                signingIdentifier: "com.example.editor",
                teamIdentifier: "TEAM123",
                entitlementIdentifiers: []
            )
        )
    }

    private func plistData(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
    }

    private func key(_ arguments: [String]) -> String {
        arguments.joined(separator: "\u{1f}")
    }

    private func success(_ output: Data) -> PkgCommandResult {
        PkgCommandResult(
            exitCode: 0,
            output: output,
            timedOut: false,
            truncated: false
        )
    }

}

@MainActor
final class AppMetadataTests: XCTestCase {
    func testInstalledAppIdentityIsStableForTheSameCanonicalPath() {
        let path = URL(fileURLWithPath: "/Applications/../Applications/Example.app")
        let first = makeApp(path: path)
        let second = makeApp(path: path.standardizedFileURL)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.id, "/Applications/Example.app")
    }

    func testSignatureInspectorKeepsOnlyIdentifierBearingEntitlements() {
        let entitlements: [String: Any] = [
            "application-identifier": "TEAM123.com.example.editor",
            "com.apple.security.application-groups": [
                "group.com.example.shared",
                "group.com.example.shared",
                "",
            ],
            "keychain-access-groups": [
                "TEAM123.com.example.editor",
                "TEAM123.com.example.keychain-only",
            ],
            "com.apple.developer.icloud-container-identifiers": ["iCloud.com.example.editor"],
            "com.apple.developer.team-identifier": "TEAM123",
            "com.apple.security.app-sandbox": true,
        ]
        let identifiers = AppSignatureInspector.relatedIdentifiers(from: entitlements)

        XCTAssertEqual(identifiers, [
            "TEAM123.com.example.editor",
            "group.com.example.shared",
            "iCloud.com.example.editor",
        ])
        XCTAssertEqual(
            AppSignatureInspector.sharedContainerIdentifiers(from: entitlements),
            ["group.com.example.shared"]
        )
        XCTAssertTrue(AppSignatureInspector.isSandboxed(from: entitlements))
    }

    func testSignatureInspectorDistinguishesAdHocDeveloperAndLocalSignatures() {
        XCTAssertEqual(
            AppSignatureInspector.signatureStatus(
                teamIdentifier: "TEAM123",
                codeDirectoryFlags: 0,
                hasCertificate: true,
                isAppleDeveloperCertificate: true
            ),
            .developerSigned
        )
        XCTAssertEqual(
            AppSignatureInspector.signatureStatus(
                teamIdentifier: "FAKE_TEAM",
                codeDirectoryFlags: 0x2,
                hasCertificate: false,
                isAppleDeveloperCertificate: false
            ),
            .adHoc
        )
        XCTAssertEqual(
            AppSignatureInspector.signatureStatus(
                teamIdentifier: nil,
                codeDirectoryFlags: 0,
                hasCertificate: true,
                isAppleDeveloperCertificate: false
            ),
            .locallySigned
        )
        XCTAssertEqual(
            AppSignatureInspector.signatureStatus(
                teamIdentifier: "SPOOFED_TEAM",
                codeDirectoryFlags: 0,
                hasCertificate: true,
                isAppleDeveloperCertificate: false
            ),
            .locallySigned
        )
        XCTAssertEqual(
            AppSignatureInspector.signatureStatus(
                teamIdentifier: nil,
                codeDirectoryFlags: 0,
                hasCertificate: false,
                isAppleDeveloperCertificate: false
            ),
            .unknown
        )
    }

    func testSignatureInspectorExtractsHumanReadableDeveloperName() {
        XCTAssertEqual(
            AppSignatureInspector.developerName(
                from: "Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2)",
                teamIdentifier: "2DC432GLL2"
            ),
            "OpenAI OpCo, LLC"
        )
        XCTAssertEqual(
            AppSignatureInspector.developerName(
                from: "Apple Distribution: Example Corp (TEAM123)",
                teamIdentifier: "TEAM123"
            ),
            "Example Corp"
        )
        XCTAssertEqual(
            AppSignatureInspector.developerName(
                from: "ChatGPT Rust Local Code Signing",
                teamIdentifier: nil
            ),
            "ChatGPT Rust Local Code Signing"
        )
        XCTAssertNil(
            AppSignatureInspector.developerName(
                from: "Apple Mac OS Application Signing",
                teamIdentifier: "APPLE123"
            )
        )
    }

    func testSignatureInspectorRecognizesOnlyMacAppStoreCertificateNames() {
        XCTAssertTrue(
            AppSignatureInspector.isMacAppStoreCertificate(
                "Apple Mac OS Application Signing"
            )
        )
        XCTAssertTrue(
            AppSignatureInspector.isMacAppStoreCertificate(
                "3rd Party Mac Developer Application: Example Corp (TEAM123)"
            )
        )
        XCTAssertFalse(
            AppSignatureInspector.isMacAppStoreCertificate(
                "Developer ID Application: Example Corp (TEAM123)"
            )
        )
    }

    func testNotarizationRequirementStatusIsConservative() {
        XCTAssertEqual(
            AppSignatureInspector.notarizationStatus(forRequirementStatus: errSecSuccess),
            .notarized
        )
        XCTAssertEqual(
            AppSignatureInspector.notarizationStatus(forRequirementStatus: errSecCSReqFailed),
            .notNotarized
        )
        XCTAssertEqual(
            AppSignatureInspector.notarizationStatus(forRequirementStatus: errSecInternalComponent),
            .unknown
        )
    }

    func testPathFinderUsesOnlyVerifiedDeveloperSignatureIdentifiers() {
        let verified = AppSignatureMetadata(
            status: .developerSigned,
            signingIdentifier: "com.example.editor",
            teamIdentifier: "TEAM123",
            entitlementIdentifiers: ["group.com.example.shared"]
        )
        let verifiedInfo = AppPathFinder.AppInfo(
            installedApp: makeApp(path: URL(fileURLWithPath: "/Applications/Verified.app"), signature: verified)
        )

        XCTAssertEqual(verifiedInfo.entitlements, ["group.com.example.shared"])

        let untrusted = AppSignatureMetadata(
            status: .adHoc,
            signingIdentifier: "com.attacker.claim",
            teamIdentifier: "FAKETEAM",
            entitlementIdentifiers: ["group.com.victim.shared"]
        )
        let untrustedInfo = AppPathFinder.AppInfo(
            installedApp: makeApp(path: URL(fileURLWithPath: "/Applications/Untrusted.app"), signature: untrusted)
        )

        XCTAssertNil(untrustedInfo.entitlements)
    }

    func testStoredSearchSensitivityFallsBackToEnhanced() {
        let suiteName = "AppSift.AppMetadataTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        defaults.set(SearchSensitivity.deep.rawValue, forKey: SearchSensitivity.defaultsKey)
        XCTAssertEqual(SearchSensitivity.stored(in: defaults), .deep)

        defaults.set("unexpected", forKey: SearchSensitivity.defaultsKey)
        XCTAssertEqual(SearchSensitivity.stored(in: defaults), .enhanced)
    }

    func testAppSizeCacheRequiresFreshMatchingBundleFingerprint() throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftAppSizeCache-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("sizes.json")
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let app = makeApp(
            path: URL(fileURLWithPath: "/Applications/Example.app"),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 9_000),
            sizeState: .pending
        )
        let cache = AppSizeCacheStore(cacheURL: cacheURL, maximumAge: 60)
        cache.record(size: 42_000, for: app, now: now)
        cache.persist()

        let reloaded = AppSizeCacheStore(cacheURL: cacheURL, maximumAge: 60)
        XCTAssertEqual(reloaded.cachedSize(for: app, now: now.addingTimeInterval(59)), 42_000)
        XCTAssertNil(reloaded.cachedSize(for: app, now: now.addingTimeInterval(61)))

        let updatedApp = makeApp(
            path: app.path,
            version: "2.0",
            modifiedAt: app.modifiedAt,
            sizeState: .pending
        )
        XCTAssertNil(reloaded.cachedSize(for: updatedApp, now: now.addingTimeInterval(10)))
    }

    func testAppSizeCacheNeverPersistsSignatureMetadata() throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftAppSizeCache-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("sizes.json")
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let signature = AppSignatureMetadata(
            status: .developerSigned,
            signingIdentifier: "com.example.secret",
            teamIdentifier: "SENSITIVE123",
            entitlementIdentifiers: ["group.com.example.secret"]
        )
        let app = makeApp(
            path: URL(fileURLWithPath: "/Applications/Signed.app"),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 20_000),
            sizeState: .pending,
            signature: signature
        )
        let cache = AppSizeCacheStore(cacheURL: cacheURL)
        cache.record(size: 84_000, for: app)
        cache.persist()

        let persisted = try String(contentsOf: cacheURL, encoding: .utf8)
        XCTAssertFalse(persisted.contains("SENSITIVE123"))
        XCTAssertFalse(persisted.contains("group.com.example.secret"))
        XCTAssertFalse(persisted.contains("com.example.secret"))
    }

    func testReplacingAppSizePreservesIdentityAndVerifiedMetadata() {
        let signature = AppSignatureMetadata(
            status: .developerSigned,
            signingIdentifier: "com.example.app",
            teamIdentifier: "TEAM123",
            entitlementIdentifiers: ["group.com.example.shared"]
        )
        let pending = makeApp(
            path: URL(fileURLWithPath: "/Applications/Example.app"),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 30_000),
            sizeState: .pending,
            signature: signature
        )

        let calculated = pending.replacingSize(123_456, state: .calculated)

        XCTAssertEqual(calculated.id, pending.id)
        XCTAssertEqual(calculated.size, 123_456)
        XCTAssertTrue(calculated.hasKnownSize)
        XCTAssertEqual(calculated.signature, signature)
        XCTAssertEqual(calculated.versionSummary, pending.versionSummary)
    }

    func testIndependentSizeAndSignatureEnrichmentsMergeWithoutDataLoss() {
        let base = makeApp(
            path: URL(fileURLWithPath: "/Applications/Example.app"),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 40_000),
            sizeState: .pending,
            signatureInspectionState: .pending
        )
        let signature = AppSignatureMetadata(
            status: .developerSigned,
            signingIdentifier: "com.example.app",
            teamIdentifier: "TEAM123",
            entitlementIdentifiers: ["group.com.example.shared"]
        )
        let signed = base.replacingSignature(signature)
        let sized = base.replacingSize(654_321, state: .calculated)

        let signatureThenSize = signed.mergingEnrichment(from: sized)
        let sizeThenSignature = sized.mergingEnrichment(from: signed)

        for merged in [signatureThenSize, sizeThenSignature] {
            XCTAssertEqual(merged.size, 654_321)
            XCTAssertEqual(merged.sizeState, .calculated)
            XCTAssertEqual(merged.signature, signature)
            XCTAssertEqual(merged.signatureInspectionState, .inspected)
        }
    }

    private func makeApp(
        path: URL,
        version: String? = "1.2.3",
        buildNumber: String? = "45",
        modifiedAt: Date? = nil,
        sizeState: AppSizeState = .calculated,
        signature: AppSignatureMetadata = .unknown,
        signatureInspectionState: AppSignatureInspectionState = .inspected
    ) -> InstalledApp {
        InstalledApp(
            appName: path.deletingPathExtension().lastPathComponent,
            bundleIdentifier: "com.example.app",
            path: path,
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1,
            sizeState: sizeState,
            version: version,
            buildNumber: buildNumber,
            modifiedAt: modifiedAt,
            signature: signature,
            signatureInspectionState: signatureInspectionState
        )
    }
}

final class FileTreeStatsCalculatorTests: XCTestCase {
    func testCountsFilesFoldersHiddenItemsAndSymlinksWithoutFollowingThem() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AppSiftFileTreeStats-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let hidden = root.appendingPathComponent(".hidden", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: hidden, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let rootFile = root.appendingPathComponent("root.txt")
        let nestedFile = nested.appendingPathComponent("nested.txt")
        let hiddenFile = hidden.appendingPathComponent("secret.txt")
        try Data(repeating: 1, count: 32).write(to: rootFile)
        try Data(repeating: 2, count: 64).write(to: nestedFile)
        try Data(repeating: 3, count: 96).write(to: hiddenFile)
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("root-link"),
            withDestinationURL: rootFile
        )

        let stats = try XCTUnwrap(FileTreeStatsCalculator.calculate(at: root))

        XCTAssertEqual(stats.fileCount, 4)
        XCTAssertEqual(stats.directoryCount, 3)
        XCTAssertEqual(stats.itemCount, 7)
        XCTAssertGreaterThan(stats.allocatedSize, 0)
    }

    func testRegularFileCountsAsOneItem() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftFileTreeStats-\(UUID().uuidString)")
        try Data(repeating: 1, count: 32).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let stats = try XCTUnwrap(FileTreeStatsCalculator.calculate(at: file))

        XCTAssertEqual(stats.fileCount, 1)
        XCTAssertEqual(stats.directoryCount, 0)
        XCTAssertEqual(stats.itemCount, 1)
        XCTAssertGreaterThan(stats.allocatedSize, 0)
    }

    func testCancellationDiscardsPartialStatistics() {
        let result = FileTreeStatsCalculator.calculate(
            at: FileManager.default.temporaryDirectory,
            shouldCancel: { true }
        )

        XCTAssertNil(result)
    }
}

final class StartupItemScannerTests: XCTestCase {
    func testBackgroundRegistryUsesParentOwnershipAndStateEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftStartupBTM-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Example.app", isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/helper")
        let plist = app.appendingPathComponent(
            "Contents/Library/LaunchAgents/com.example.helper.plist"
        )
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: plist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: executable.path, contents: Data())
        FileManager.default.createFile(atPath: plist.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: root) }

        let output = """
         #1:
          Name: Example
          Developer Name: Example Corp
          Team Identifier: TEAM123
          Type: developer
          Disposition: [enabled, allowed, visible, notified]
          Identifier: 1.com.example.app
          URL: \(app.absoluteString)
          Bundle Identifier: [com.example.app]
         #2:
          Name: com.example.helper
          Type: legacy agent
          Disposition: [enabled, allowed, visible, notified]
          Identifier: 2.com.example.helper
          URL: Contents/Library/LaunchAgents/com.example.helper.plist
          Executable Path: \(executable.path)
          Parent Identifier: 1.com.example.app
          Assoc. Bundle IDs: [com.example.app]
        """

        let items = StartupItemScanner.parseBackgroundTaskOutput(output)

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1, "Developer ownership records must not become startup rows")
        XCTAssertEqual(item.name, "Example")
        XCTAssertEqual(item.developerName, "Example Corp")
        XCTAssertEqual(item.teamIdentifier, "TEAM123")
        XCTAssertEqual(item.kind, .launchAgent)
        XCTAssertEqual(item.state, .enabled)
        XCTAssertEqual(item.itemURL?.standardizedFileURL.path, plist.standardizedFileURL.path)
        XCTAssertEqual(item.executableURL?.standardizedFileURL.path, executable.standardizedFileURL.path)
        XCTAssertEqual(item.associatedBundleIdentifiers, ["com.example.app"])
        XCTAssertEqual(item.evidence, [.backgroundTaskManagement])
        XCTAssertTrue(item.isLegacy)
        XCTAssertFalse(item.isMissing)
    }

    func testBackgroundRegistryTreatsDisallowedAsRequiringApproval() throws {
        let output = """
         #1:
          Name: Approval Helper
          Type: login item
          Disposition: [disabled, disallowed, visible, notified]
          Identifier: 1.com.example.approval
          URL: file:///Applications/Approval.app
        """

        let item = try XCTUnwrap(
            StartupItemScanner.parseBackgroundTaskOutput(output).first
        )

        XCTAssertEqual(item.kind, .loginItem)
        XCTAssertEqual(item.state, .requiresApproval)
    }

    func testBackgroundRegistryDecodesRelativePercentEscapesInsideParentBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSift Startup URL \(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Example App.app", isDirectory: true)
        let helper = app.appendingPathComponent(
            "Contents/Library/LoginItems/Example Helper.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let output = """
         #1:
          Name: Example App
          Type: developer
          Identifier: 1.com.example.app
          URL: \(app.absoluteString)
         #2:
          Name: Example Helper
          Type: login item
          Disposition: [enabled, allowed, visible, notified]
          Identifier: 2.com.example.helper
          URL: Contents/Library/LoginItems/Example%20Helper.app
          Parent Identifier: 1.com.example.app
        """

        let item = try XCTUnwrap(
            StartupItemScanner.parseBackgroundTaskOutput(output).first
        )

        XCTAssertEqual(item.itemURL?.path, helper.path)
        XCTAssertFalse(item.isMissing)
    }

    func testBackgroundRegistryRejectsRelativeTraversalOutsideParentBundle() throws {
        let output = """
         #1:
          Name: Example App
          Type: developer
          Identifier: 1.com.example.app
          URL: file:///Applications/Example.app/
         #2:
          Name: Escaping Helper
          Type: login item
          Identifier: 2.com.example.escape
          URL: %2E%2E/%2E%2E/Library/LaunchAgents/escape.plist
          Parent Identifier: 1.com.example.app
        """

        let item = try XCTUnwrap(
            StartupItemScanner.parseBackgroundTaskOutput(output).first
        )

        XCTAssertNil(item.itemURL)
    }

    func testLaunchdFallbackJoinsExactAppleAttributionWithoutInventingDeveloper() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AppSiftStartupLaunchd-\(UUID().uuidString)", isDirectory: true)
        let launchAgents = root.appendingPathComponent("LaunchAgents", isDirectory: true)
        let executable = root.appendingPathComponent("bin/helper")
        let plistURL = launchAgents.appendingPathComponent("com.example.helper.plist")
        let attributionURL = root.appendingPathComponent("attributions.plist")
        try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        fileManager.createFile(atPath: executable.path, contents: Data())
        defer { try? fileManager.removeItem(at: root) }

        let launchdDocument: [String: Any] = [
            "Label": "com.example.helper",
            "ProgramArguments": [executable.path, "--background"],
        ]
        let launchdData = try PropertyListSerialization.data(
            fromPropertyList: launchdDocument,
            format: .binary,
            options: 0
        )
        try launchdData.write(to: plistURL)

        let attributionDocument: [String: Any] = [
            "com.example.helper": [
                "Attribution": "Example App",
                "TeamIdentifier": "TEAM123",
                "AssociatedBundleIdentifiers": ["com.example.app"],
                "Program": executable.path,
            ],
        ]
        let attributionData = try PropertyListSerialization.data(
            fromPropertyList: attributionDocument,
            format: .binary,
            options: 0
        )
        try attributionData.write(to: attributionURL)

        let result = StartupItemScanner.scan(
            fileManager: fileManager,
            backgroundTaskOutputProvider: { .init(output: nil) },
            launchdRoots: [
                .init(url: launchAgents, kind: .launchAgent, scope: .user),
            ],
            attributionURL: attributionURL,
            legacyStatusProvider: { _ in .disabled }
        )

        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.name, "Example App")
        XCTAssertNil(item.developerName)
        XCTAssertEqual(item.teamIdentifier, "TEAM123")
        XCTAssertEqual(item.associatedBundleIdentifiers, ["com.example.app"])
        XCTAssertEqual(item.state, .disabled)
        XCTAssertEqual(item.scope, .user)
        XCTAssertEqual(item.evidence, [.appleAttribution, .launchdPropertyList])
        XCTAssertFalse(item.isMissing)
        XCTAssertFalse(result.backgroundTaskDataAvailable)
    }

    func testLaunchdScannerIgnoresSymlinkedPropertyLists() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AppSiftStartupSymlink-\(UUID().uuidString)", isDirectory: true)
        let launchAgents = root.appendingPathComponent("LaunchAgents", isDirectory: true)
        let outside = root.appendingPathComponent("outside.plist")
        let symlink = launchAgents.appendingPathComponent("com.example.link.plist")
        try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.example.link"],
            format: .xml,
            options: 0
        )
        try data.write(to: outside)
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: outside)
        defer { try? fileManager.removeItem(at: root) }

        let result = StartupItemScanner.scan(
            fileManager: fileManager,
            backgroundTaskOutputProvider: { .init(output: nil) },
            launchdRoots: [
                .init(url: launchAgents, kind: .launchAgent, scope: .user),
            ],
            attributionURL: root.appendingPathComponent("missing-attributions.plist"),
            legacyStatusProvider: { _ in .enabled }
        )

        XCTAssertTrue(result.items.isEmpty)
    }
}

final class AppUpdateScannerTests: XCTestCase {
    func testAppUpdatesCLICommandIsRecognized() {
        XCTAssertTrue(CLI.isKnownCommand("app-updates"))
    }

    func testAppStoreLookupParsesOnlyBoundedIdentityRecords() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "resultCount": 2,
            "results": [
                [
                    "trackId": 42,
                    "bundleId": "com.example.editor",
                    "version": "2.0",
                    "trackViewUrl": "https://apps.apple.com/app/id42",
                ],
                [
                    "trackId": 43,
                    "bundleId": "com.example.invalid",
                    "version": "3.0",
                    "trackViewUrl": "https://attacker.example/app/id43",
                ],
            ],
        ])

        let records = try XCTUnwrap(AppUpdateScanner.parseAppStoreLookup(data))

        XCTAssertEqual(records[42]?.bundleIdentifier, "com.example.editor")
        XCTAssertEqual(records[42]?.version, "2.0")
        XCTAssertEqual(records[42]?.productURL?.host, "apps.apple.com")
        XCTAssertNil(records[43]?.productURL)
    }

    func testHomebrewOutdatedParserIgnoresUnrequestedCasks() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "formulae": [],
            "casks": [
                ["name": "example", "current_version": "2.0"],
                ["name": "foreign", "current_version": "9.0"],
            ],
        ])

        let outdated = try XCTUnwrap(
            AppUpdateScanner.parseHomebrewOutdated(
                data,
                requestedTokens: ["example"]
            )
        )

        XCTAssertEqual(outdated, ["example": "2.0"])
    }

    func testHomebrewBatchFailureIsolatesCasks() async throws {
        let broken = makeApp(
            name: "Broken Tap",
            bundleIdentifier: "com.example.broken-tap",
            path: URL(fileURLWithPath: "/Applications/Broken Tap.app"),
            version: "1.0",
            buildNumber: "100"
        )
        let healthy = makeApp(
            name: "Healthy Cask",
            bundleIdentifier: "com.example.healthy-cask",
            path: URL(fileURLWithPath: "/Applications/Healthy Cask.app"),
            version: "1.0",
            buildNumber: "100"
        )
        let executable = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let healthyOutput = try JSONSerialization.data(withJSONObject: [
            "formulae": [],
            "casks": [],
        ])
        let metadata: [InstalledApp.ID: HomebrewCaskInstallMetadata] = [
            broken.id: HomebrewCaskInstallMetadata(
                token: "broken-tap",
                version: "1.0",
                tap: "example/untrusted",
                receiptURL: URL(fileURLWithPath: "/tmp/broken.json"),
                extraCleanupPatternCount: 0
            ),
            healthy.id: HomebrewCaskInstallMetadata(
                token: "healthy-cask",
                version: "1.0",
                tap: "homebrew/cask",
                receiptURL: URL(fileURLWithPath: "/tmp/healthy.json"),
                extraCleanupPatternCount: 0
            ),
        ]
        let signature = AppSignatureMetadata(
            status: .developerSigned,
            signingIdentifier: nil,
            teamIdentifier: "TEAM123",
            entitlementIdentifiers: []
        )

        let result = await AppUpdateScanner.scan(
            apps: [broken, healthy],
            signatureInspector: { _ in signature },
            homebrewMetadataProvider: { _ in metadata },
            brewExecutableProvider: { _ in executable },
            appStoreIdentifierProvider: { _ in nil },
            appStoreLookupProvider: { _ in Data() },
            brewOutdatedProvider: { _, tokens in
                if tokens == ["healthy-cask"] {
                    return BrewCommandResult(
                        exitCode: 0,
                        output: healthyOutput,
                        timedOut: false,
                        truncated: false
                    )
                }
                return BrewCommandResult(
                    exitCode: 1,
                    output: Data(),
                    timedOut: false,
                    truncated: false
                )
            },
            sparkleFeedProvider: { _ in Data() },
            electronUpdateDataProvider: { _ in Data() }
        )

        let brokenItem = try XCTUnwrap(
            result.items.first { $0.id == broken.id }
        )
        let healthyItem = try XCTUnwrap(
            result.items.first { $0.id == healthy.id }
        )
        XCTAssertEqual(brokenItem.status, .couldNotCheck)
        XCTAssertEqual(brokenItem.failureReason, .commandFailed)
        XCTAssertEqual(healthyItem.status, .upToDate)
        XCTAssertNil(healthyItem.failureReason)
        XCTAssertTrue(healthyItem.evidence.contains(.homebrewOutdatedCommand))
    }

    func testSparkleParserReadsStableVersionAndCompatibilityEvidence() throws {
        let data = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <item>
                  <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
                  <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
                  <sparkle:releaseNotesLink>https://updates.example.com/notes</sparkle:releaseNotesLink>
                  <enclosure url="https://updates.example.com/app.zip"
                    sparkle:version="200"
                    sparkle:shortVersionString="2.0"
                    length="10" />
                </item>
              </channel>
            </rss>
            """.utf8
        )

        let item = try XCTUnwrap(
            AppUpdateScanner.parseSparkleAppcast(data)?.first
        )

        XCTAssertEqual(item.version, "200")
        XCTAssertEqual(item.displayVersion, "2.0")
        XCTAssertEqual(item.minimumSystemVersion, "13.0")
        XCTAssertEqual(item.hardwareRequirements, ["arm64"])
        XCTAssertEqual(item.releaseNotesURL?.host, "updates.example.com")
        XCTAssertNil(item.channel)
    }

    func testSparkleParserKeepsChildVersionWhenEnclosureOmitsVersionAttributes() throws {
        let data = Data(
            """
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel><item>
                <sparkle:version>205</sparkle:version>
                <sparkle:shortVersionString>2.0.5</sparkle:shortVersionString>
                <enclosure url="https://updates.example.com/app.zip" length="10" />
              </item></channel>
            </rss>
            """.utf8
        )

        let item = try XCTUnwrap(
            AppUpdateScanner.parseSparkleAppcast(data)?.first
        )

        XCTAssertEqual(item.version, "205")
        XCTAssertEqual(item.displayVersion, "2.0.5")
    }

    func testPublicHTTPSPolicyRejectsLocalAndCredentialedTargets() {
        XCTAssertTrue(
            AppUpdateScanner.isAllowedPublicHTTPSURL(
                URL(string: "https://updates.example.com/appcast.xml")!
            )
        )
        XCTAssertFalse(
            AppUpdateScanner.isAllowedPublicHTTPSURL(
                URL(string: "http://updates.example.com/appcast.xml")!
            )
        )
        XCTAssertFalse(
            AppUpdateScanner.isAllowedPublicHTTPSURL(
                URL(string: "https://localhost/appcast.xml")!
            )
        )
        XCTAssertFalse(
            AppUpdateScanner.isAllowedPublicHTTPSURL(
                URL(string: "https://127.0.0.1/appcast.xml")!
            )
        )
        XCTAssertFalse(
            AppUpdateScanner.isAllowedPublicHTTPSURL(
                URL(string: "https://[::1]/appcast.xml")!
            )
        )
        XCTAssertFalse(
            AppUpdateScanner.isAllowedPublicHTTPSURL(
                URL(string: "https://[::ffff:127.0.0.1]/appcast.xml")!
            )
        )
        let credentialedURL = URL(string: [
            "https://",
            "test-user",
            ":",
            "test-credential",
            "@updates.example.com/appcast.xml",
        ].joined())!
        XCTAssertFalse(
            AppUpdateScanner.isAllowedPublicHTTPSURL(credentialedURL)
        )
    }

    func testAppStoreScanRequiresReceiptProductIDAndBundleMatch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftUpdateMAS-\(UUID().uuidString)", isDirectory: true)
        let appURL = root.appendingPathComponent("Editor.app", isDirectory: true)
        let receipt = appURL.appendingPathComponent("Contents/_MASReceipt/receipt")
        try FileManager.default.createDirectory(
            at: receipt.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1, 2, 3]).write(to: receipt)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = makeApp(
            name: "Editor",
            bundleIdentifier: "com.example.editor",
            path: appURL,
            version: "1.0",
            buildNumber: "100"
        )
        let signature = AppSignatureMetadata(
            status: .developerSigned,
            signingIdentifier: "com.example.editor",
            teamIdentifier: "TEAM123",
            isMacAppStoreSigned: true,
            entitlementIdentifiers: []
        )
        let lookup = try JSONSerialization.data(withJSONObject: [
            "resultCount": 1,
            "results": [[
                "trackId": 42,
                "bundleId": "com.example.editor",
                "version": "2.0",
                "trackViewUrl": "https://apps.apple.com/app/id42",
            ]],
        ])

        let result = await AppUpdateScanner.scan(
            apps: [app],
            signatureInspector: { _ in signature },
            homebrewMetadataProvider: { _ in [:] },
            appStoreIdentifierProvider: { _ in 42 },
            appStoreLookupProvider: { _ in lookup },
            brewOutdatedProvider: { _, _ in
                BrewCommandResult(exitCode: 0, output: Data(), timedOut: false, truncated: false)
            },
            sparkleFeedProvider: { _ in Data() }
        )

        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.status, .updateAvailable)
        XCTAssertEqual(item.availableVersion, "2.0")
        XCTAssertEqual(
            item.evidence,
            [
                .developerSignature,
                .macAppStoreReceipt,
                .spotlightProductIdentifier,
                .appStoreLookupBundleMatch,
            ]
        )
        XCTAssertEqual(result.unsupportedAppCount, 0)
    }

    func testSparkleScanUsesSignedHTTPSFeedAndBuildVersion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftUpdateSparkle-\(UUID().uuidString)", isDirectory: true)
        let appURL = root.appendingPathComponent("Sparkle App.app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.sparkle",
            "CFBundleName": "Sparkle App",
            "CFBundleVersion": "100",
            "CFBundleShortVersionString": "1.0",
            "SUFeedURL": "https://updates.example.com/appcast.xml",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))
        defer { try? FileManager.default.removeItem(at: root) }

        let app = makeApp(
            name: "Sparkle App",
            bundleIdentifier: "com.example.sparkle",
            path: appURL,
            version: "1.0",
            buildNumber: "100"
        )
        let signature = AppSignatureMetadata(
            status: .developerSigned,
            signingIdentifier: "com.example.sparkle",
            teamIdentifier: "TEAM123",
            entitlementIdentifiers: []
        )
        let appcast = Data(
            """
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel><item>
                <enclosure url="https://updates.example.com/app.zip"
                  sparkle:version="200" sparkle:shortVersionString="2.0" length="10" />
              </item></channel>
            </rss>
            """.utf8
        )

        let result = await AppUpdateScanner.scan(
            apps: [app],
            signatureInspector: { _ in signature },
            homebrewMetadataProvider: { _ in [:] },
            appStoreIdentifierProvider: { _ in nil },
            appStoreLookupProvider: { _ in Data() },
            brewOutdatedProvider: { _, _ in
                BrewCommandResult(exitCode: 0, output: Data(), timedOut: false, truncated: false)
            },
            sparkleFeedProvider: { url in
                XCTAssertEqual(url.host, "updates.example.com")
                return appcast
            }
        )

        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.status, .updateAvailable)
        XCTAssertEqual(item.availableVersion, "2.0")
        XCTAssertEqual(item.evidence, [.developerSignature, .sparkleHTTPSFeed, .sparkleAppcast])
    }

    func testElectronUpdaterGenericScanUsesSignedBundleConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftUpdateElectronGeneric-\(UUID().uuidString)", isDirectory: true)
        let appURL = root.appendingPathComponent("Electron App.app", isDirectory: true)
        let resources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let squirrel = appURL.appendingPathComponent(
            "Contents/Frameworks/Squirrel.framework",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: squirrel, withIntermediateDirectories: true)
        try Data(
            """
            provider: generic
            url: https://updates.example.com/desktop
            channel: stable
            updaterCacheDirName: example-updater
            """.utf8
        ).write(to: resources.appendingPathComponent("app-update.yml"))
        defer { try? FileManager.default.removeItem(at: root) }

        let app = makeApp(
            name: "Electron App",
            bundleIdentifier: "com.example.electron",
            path: appURL,
            version: "1.0.0",
            buildNumber: "100"
        )
        let signature = AppSignatureMetadata(
            status: .developerSigned,
            signingIdentifier: "com.example.electron",
            teamIdentifier: "TEAM123",
            entitlementIdentifiers: []
        )
        let metadata = Data(
            """
            version: 2.0.0
            files:
              - url: Electron-App-2.0.0-universal-mac.zip
                sha512: Lc3BAJTnnWB9RKW4iA9sCSKFt+huQkBaveRvOECfhaG92DYy2K+iri6mt9RVxjbQNDBV1LY2IKWg283EcP6ZBA==
                size: 254067532
            releaseDate: '2026-07-15T00:00:00.000Z'
            """.utf8
        )

        let result = await AppUpdateScanner.scan(
            apps: [app],
            signatureInspector: { _ in signature },
            homebrewMetadataProvider: { _ in [:] },
            appStoreIdentifierProvider: { _ in nil },
            appStoreLookupProvider: { _ in Data() },
            brewOutdatedProvider: { _, _ in
                BrewCommandResult(exitCode: 0, output: Data(), timedOut: false, truncated: false)
            },
            sparkleFeedProvider: { _ in Data() },
            electronUpdateDataProvider: { url in
                XCTAssertEqual(
                    url.absoluteString,
                    "https://updates.example.com/desktop/stable-mac.yml"
                )
                return metadata
            }
        )

        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.status, .updateAvailable)
        XCTAssertEqual(item.availableVersion, "2.0.0")
        XCTAssertEqual(
            item.source,
            .electronUpdater(
                provider: .generic(baseURL: URL(string: "https://updates.example.com/desktop")!),
                channel: "stable"
            )
        )
        XCTAssertEqual(
            item.evidence,
            [
                .developerSignature,
                .electronUpdaterConfiguration,
                .squirrelFramework,
                .electronUpdateMetadata,
            ]
        )
        XCTAssertEqual(result.unsupportedAppCount, 0)

        switch await AppUpdateScanner.verifyActionAtClick(
            item: item,
            app: app,
            signatureInspector: { _ in signature },
            electronUpdateDataProvider: { _ in metadata }
        ) {
        case .success(.electronUpdater(let verifiedAppURL, let releasePageURL)):
            XCTAssertEqual(verifiedAppURL, appURL)
            XCTAssertNil(releasePageURL)
        default:
            XCTFail("Expected generic metadata to pass click-time verification")
        }

        let changedMetadata = Data(
            String(decoding: metadata, as: UTF8.self)
                .replacingOccurrences(of: "Lc3BAJ", with: "Mc3BAJ")
                .utf8
        )
        switch await AppUpdateScanner.verifyActionAtClick(
            item: item,
            app: app,
            signatureInspector: { _ in signature },
            electronUpdateDataProvider: { _ in changedMetadata }
        ) {
        case .failure(.sourceChanged):
            break
        default:
            XCTFail("Changed generic metadata should fail click-time verification")
        }

    }

    func testElectronUpdaterGitHubScanValidatesPublicReleaseIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftUpdateElectronGitHub-\(UUID().uuidString)", isDirectory: true)
        let appURL = root.appendingPathComponent("GitHub Electron App.app", isDirectory: true)
        let resources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let squirrel = appURL.appendingPathComponent(
            "Contents/Frameworks/Squirrel.framework",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: squirrel, withIntermediateDirectories: true)
        try Data(
            """
            owner: example-owner
            repo: example-app
            provider: github
            channel: latest
            updaterCacheDirName: example-updater
            """.utf8
        ).write(to: resources.appendingPathComponent("app-update.yml"))
        defer { try? FileManager.default.removeItem(at: root) }

        let app = makeApp(
            name: "GitHub Electron App",
            bundleIdentifier: "com.example.electron.github",
            path: appURL,
            version: "1.0.0",
            buildNumber: "100"
        )
        let signature = AppSignatureMetadata(
            status: .developerSigned,
            signingIdentifier: "com.example.electron.github",
            teamIdentifier: "TEAM123",
            entitlementIdentifiers: []
        )
        let release = Data(
            """
            {
              "tag_name": "v2.0.0",
              "html_url": "https://github.com/example-owner/example-app/releases/tag/v2.0.0",
              "draft": false,
              "prerelease": false,
              "assets": [
                {
                  "name": "latest-mac.yml",
                  "browser_download_url": "https://github.com/example-owner/example-app/releases/download/v2.0.0/latest-mac.yml"
                }
              ]
            }
            """.utf8
        )
        let metadata = Data(
            """
            version: 2.0.0
            files:
              - url: GitHub-Electron-App-2.0.0-arm64-mac.zip
                sha512: Lc3BAJTnnWB9RKW4iA9sCSKFt+huQkBaveRvOECfhaG92DYy2K+iri6mt9RVxjbQNDBV1LY2IKWg283EcP6ZBA==
                size: 123456
            """.utf8
        )

        let result = await AppUpdateScanner.scan(
            apps: [app],
            signatureInspector: { _ in signature },
            homebrewMetadataProvider: { _ in [:] },
            appStoreIdentifierProvider: { _ in nil },
            appStoreLookupProvider: { _ in Data() },
            brewOutdatedProvider: { _, _ in
                BrewCommandResult(exitCode: 0, output: Data(), timedOut: false, truncated: false)
            },
            sparkleFeedProvider: { _ in Data() },
            electronUpdateDataProvider: { url in
                switch url.absoluteString {
                case "https://api.github.com/repos/example-owner/example-app/releases/latest":
                    return release
                case "https://github.com/example-owner/example-app/releases/download/v2.0.0/latest-mac.yml":
                    return metadata
                default:
                    XCTFail("Unexpected Electron update URL: \(url.absoluteString)")
                    return Data()
                }
            }
        )

        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.status, .updateAvailable)
        XCTAssertEqual(item.availableVersion, "2.0.0")
        XCTAssertEqual(
            item.source,
            .electronUpdater(
                provider: .github(owner: "example-owner", repo: "example-app"),
                channel: "latest"
            )
        )
        XCTAssertEqual(
            item.releaseNotesURL?.absoluteString,
            "https://github.com/example-owner/example-app/releases/tag/v2.0.0"
        )
        XCTAssertEqual(
            item.evidence,
            [
                .developerSignature,
                .electronUpdaterConfiguration,
                .squirrelFramework,
                .electronUpdateMetadata,
                .githubReleaseIdentity,
            ]
        )
        XCTAssertEqual(result.unsupportedAppCount, 0)

        switch AppUpdateScanner.verifyAction(
            item: item,
            app: app,
            signatureInspector: { _ in signature }
        ) {
        case .success(.electronUpdater(let verifiedAppURL, let releasePageURL)):
            XCTAssertEqual(verifiedAppURL, appURL)
            XCTAssertEqual(
                releasePageURL?.absoluteString,
                "https://github.com/example-owner/example-app/releases/tag/v2.0.0"
            )
        default:
            XCTFail("Expected a verified GitHub release action")
        }

        switch await AppUpdateScanner.verifyActionAtClick(
            item: item,
            app: app,
            signatureInspector: { _ in signature },
            electronUpdateDataProvider: { url in
                switch url.absoluteString {
                case "https://api.github.com/repos/example-owner/example-app/releases/latest":
                    return release
                case "https://github.com/example-owner/example-app/releases/download/v2.0.0/latest-mac.yml":
                    return metadata
                default:
                    XCTFail("Unexpected click-time update URL: \(url.absoluteString)")
                    return Data()
                }
            }
        ) {
        case .success(.electronUpdater(let verifiedAppURL, let releasePageURL)):
            XCTAssertEqual(verifiedAppURL, appURL)
            XCTAssertEqual(releasePageURL, item.releaseNotesURL)
        default:
            XCTFail("Expected remote identity to pass click-time verification")
        }

        let changedMetadata = Data(
            String(decoding: metadata, as: UTF8.self)
                .replacingOccurrences(of: "Lc3BAJ", with: "Mc3BAJ")
                .utf8
        )
        switch await AppUpdateScanner.verifyActionAtClick(
            item: item,
            app: app,
            signatureInspector: { _ in signature },
            electronUpdateDataProvider: { url in
                if url.host == "api.github.com" { return release }
                return changedMetadata
            }
        ) {
        case .failure(.sourceChanged):
            break
        default:
            XCTFail("Changed remote metadata should fail click-time verification")
        }

        try Data(
            """
            owner: other-owner
            repo: example-app
            provider: github
            """.utf8
        ).write(to: resources.appendingPathComponent("app-update.yml"), options: .atomic)
        switch AppUpdateScanner.verifyAction(
            item: item,
            app: app,
            signatureInspector: { _ in signature }
        ) {
        case .failure(.sourceChanged):
            break
        default:
            XCTFail("Changed GitHub source should fail click-time verification")
        }
    }

    func testElectronUpdaterDoesNotClaimStagedReleaseForEveryUser() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftUpdateElectronStaged-\(UUID().uuidString)", isDirectory: true)
        let appURL = root.appendingPathComponent("Staged Electron App.app", isDirectory: true)
        let resources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(
            """
            provider: generic
            url: https://updates.example.com/desktop
            """.utf8
        ).write(to: resources.appendingPathComponent("app-update.yml"))
        defer { try? FileManager.default.removeItem(at: root) }

        let app = makeApp(
            name: "Staged Electron App",
            bundleIdentifier: "com.example.electron.staged",
            path: appURL,
            version: "1.0.0",
            buildNumber: "100"
        )
        let signature = AppSignatureMetadata(
            status: .developerSigned,
            signingIdentifier: "com.example.electron.staged",
            teamIdentifier: "TEAM123",
            entitlementIdentifiers: []
        )
        let metadata = Data(
            """
            version: 2.0.0
            stagingPercentage: 25
            files:
              - url: Staged-Electron-App-2.0.0-universal-mac.zip
                sha512: Lc3BAJTnnWB9RKW4iA9sCSKFt+huQkBaveRvOECfhaG92DYy2K+iri6mt9RVxjbQNDBV1LY2IKWg283EcP6ZBA==
            """.utf8
        )

        let result = await AppUpdateScanner.scan(
            apps: [app],
            signatureInspector: { _ in signature },
            homebrewMetadataProvider: { _ in [:] },
            appStoreIdentifierProvider: { _ in nil },
            appStoreLookupProvider: { _ in Data() },
            brewOutdatedProvider: { _, _ in
                BrewCommandResult(exitCode: 0, output: Data(), timedOut: false, truncated: false)
            },
            sparkleFeedProvider: { _ in Data() },
            electronUpdateDataProvider: { _ in metadata },
            electronKernelVersionProvider: { "25.0.0" }
        )

        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.status, .couldNotCheck)
        XCTAssertEqual(item.failureReason, .stagedRollout)
        XCTAssertNil(item.availableVersion)
    }

    func testElectronUpdaterRejectsFutureDarwinMinimumSystemVersion() throws {
        let metadata = try XCTUnwrap(
            AppUpdateScanner.parseElectronUpdateMetadata(
                Data(
                    """
                    version: 2.0.0
                    minimumSystemVersion: 99.0.0
                    path: ../../2.0.0/Example-2.0.0-mac.zip
                    sha512: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
                    """.utf8
                )
            )
        )

        XCTAssertEqual(
            AppUpdateScanner.electronCompatibilityFailure(
                metadata,
                currentKernelVersion: "25.0.0"
            ),
            .incompatibleSystem
        )
    }

    func testElectronMetadataRejectsInvalidStagingPercentage() {
        for value in ["-1", "101", "not-a-number"] {
            let data = Data(
                """
                version: 2.0.0
                stagingPercentage: \(value)
                path: Example-2.0.0-mac.zip
                sha512: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
                """.utf8
            )

            XCTAssertNil(
                AppUpdateScanner.parseElectronUpdateMetadata(data),
                "Invalid staging percentage should fail closed: \(value)"
            )
        }
    }

    func testElectronMetadataRejectsAmbiguousDuplicateTopLevelKeys() {
        let data = Data(
            """
            version: 2.0.0
            version: 9.0.0
            path: Example-2.0.0-mac.zip
            sha512: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
            """.utf8
        )

        XCTAssertNil(AppUpdateScanner.parseElectronUpdateMetadata(data))
    }

    func testElectronMetadataRequiresAnActualZipAsset() {
        for path in ["Example.zip.exe", "Example.zip.sig", "Example.dmg"] {
            let data = Data(
                """
                version: 2.0.0
                path: \(path)
                sha512: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
                """.utf8
            )

            XCTAssertNil(
                AppUpdateScanner.parseElectronUpdateMetadata(data),
                "Non-ZIP asset should fail closed: \(path)"
            )
        }
    }

    func testElectronMetadataRejectsInvalidMinimumSystemVersion() {
        let data = Data(
            """
            version: 2.0.0
            minimumSystemVersion: not-a-version
            path: Example-2.0.0-mac.zip
            sha512: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
            """.utf8
        )

        XCTAssertNil(AppUpdateScanner.parseElectronUpdateMetadata(data))
    }

    func testElectronUpdaterRejectsUntrustedLocalConfigurationsWithoutNetworking() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AppSiftUpdateElectronUntrusted-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let invalidConfigurations: [(String, String)] = [
            (
                "Token",
                """
                provider: generic
                url: https://updates.example.com/desktop
                token: placeholder-credential
                """
            ),
            (
                "Local",
                """
                provider: generic
                url: https://127.0.0.1/desktop
                """
            ),
            (
                "Query",
                """
                provider: generic
                url: https://updates.example.com/desktop?token=placeholder
                """
            ),
            (
                "PrivateGitHub",
                """
                provider: github
                owner: example-owner
                repo: example-app
                private: true
                """
            ),
        ]
        var apps: [InstalledApp] = []
        for (name, configuration) in invalidConfigurations {
            let appURL = root.appendingPathComponent("\(name).app", isDirectory: true)
            let resources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
            try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
            try Data(configuration.utf8).write(to: resources.appendingPathComponent("app-update.yml"))
            apps.append(
                makeApp(
                    name: name,
                    bundleIdentifier: "com.example.\(name.lowercased())",
                    path: appURL,
                    version: "1.0.0",
                    buildNumber: "100"
                )
            )
        }

        let symlinkAppURL = root.appendingPathComponent("Symlink.app", isDirectory: true)
        let symlinkResources = symlinkAppURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fileManager.createDirectory(at: symlinkResources, withIntermediateDirectories: true)
        let outsideConfig = root.appendingPathComponent("outside-app-update.yml")
        try Data(
            """
            provider: generic
            url: https://updates.example.com/desktop
            """.utf8
        ).write(to: outsideConfig)
        try fileManager.createSymbolicLink(
            at: symlinkResources.appendingPathComponent("app-update.yml"),
            withDestinationURL: outsideConfig
        )
        apps.append(
            makeApp(
                name: "Symlink",
                bundleIdentifier: "com.example.symlink",
                path: symlinkAppURL,
                version: "1.0.0",
                buildNumber: "100"
            )
        )

        let parentSymlinkAppURL = root.appendingPathComponent(
            "ParentSymlink.app",
            isDirectory: true
        )
        let parentSymlinkContents = parentSymlinkAppURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        let outsideResources = root.appendingPathComponent(
            "outside-resources",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: parentSymlinkContents,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: outsideResources,
            withIntermediateDirectories: true
        )
        try Data(
            """
            provider: generic
            url: https://updates.example.com/desktop
            """.utf8
        ).write(to: outsideResources.appendingPathComponent("app-update.yml"))
        try fileManager.createSymbolicLink(
            at: parentSymlinkContents.appendingPathComponent("Resources"),
            withDestinationURL: outsideResources
        )
        apps.append(
            makeApp(
                name: "ParentSymlink",
                bundleIdentifier: "com.example.parent-symlink",
                path: parentSymlinkAppURL,
                version: "1.0.0",
                buildNumber: "100"
            )
        )

        let squirrelAppURL = root.appendingPathComponent("SquirrelOnly.app", isDirectory: true)
        try fileManager.createDirectory(
            at: squirrelAppURL.appendingPathComponent(
                "Contents/Frameworks/Squirrel.framework",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        apps.append(
            makeApp(
                name: "SquirrelOnly",
                bundleIdentifier: "com.example.squirrel-only",
                path: squirrelAppURL,
                version: "1.0.0",
                buildNumber: "100"
            )
        )

        let oversizedAppURL = root.appendingPathComponent("Oversized.app", isDirectory: true)
        let oversizedResources = oversizedAppURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fileManager.createDirectory(at: oversizedResources, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 64_001).write(
            to: oversizedResources.appendingPathComponent("app-update.yml")
        )
        apps.append(
            makeApp(
                name: "Oversized",
                bundleIdentifier: "com.example.oversized",
                path: oversizedAppURL,
                version: "1.0.0",
                buildNumber: "100"
            )
        )

        let signature = AppSignatureMetadata(
            status: .developerSigned,
            signingIdentifier: nil,
            teamIdentifier: "TEAM123",
            entitlementIdentifiers: []
        )
        let result = await AppUpdateScanner.scan(
            apps: apps,
            signatureInspector: { _ in signature },
            homebrewMetadataProvider: { _ in [:] },
            appStoreIdentifierProvider: { _ in nil },
            appStoreLookupProvider: { _ in Data() },
            brewOutdatedProvider: { _, _ in
                BrewCommandResult(exitCode: 0, output: Data(), timedOut: false, truncated: false)
            },
            sparkleFeedProvider: { _ in Data() },
            electronUpdateDataProvider: { url in
                XCTFail("Untrusted Electron configuration contacted \(url.absoluteString)")
                return Data()
            }
        )

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.unsupportedAppCount, apps.count)
    }

    func testElectronGitHubReleaseParserRejectsCrossRepositoryAndAmbiguousAssets() throws {
        let validPage = "https://github.com/example-owner/example-app/releases/tag/v2.0.0"
        let validAsset = "https://github.com/example-owner/example-app/releases/download/v2.0.0/latest-mac.yml"

        func releaseData(
            page: String = validPage,
            asset: String = validAsset,
            draft: Bool = false,
            prerelease: Bool = false,
            duplicateAsset: Bool = false
        ) throws -> Data {
            var assets: [[String: Any]] = [[
                "name": "latest-mac.yml",
                "browser_download_url": asset,
            ]]
            if duplicateAsset {
                assets.append(assets[0])
            }
            return try JSONSerialization.data(withJSONObject: [
                "tag_name": "v2.0.0",
                "html_url": page,
                "draft": draft,
                "prerelease": prerelease,
                "assets": assets,
            ])
        }

        let invalidReleases = try [
            releaseData(
                page: "https://github.com/other-owner/example-app/releases/tag/v2.0.0"
            ),
            releaseData(
                asset: "https://github.com/example-owner/other-app/releases/download/v2.0.0/latest-mac.yml"
            ),
            releaseData(asset: "https://example.com/latest-mac.yml"),
            releaseData(draft: true),
            releaseData(prerelease: true),
            releaseData(duplicateAsset: true),
        ]

        for release in invalidReleases {
            XCTAssertNil(
                AppUpdateScanner.parseElectronGitHubRelease(
                    release,
                    owner: "example-owner",
                    repo: "example-app",
                    channel: "latest"
                )
            )
        }
    }

    func testElectronMetadataSupportsLegacyAndArchitectureSpecificZipFormats() throws {
        let checksum = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        for asset in [
            "Example-2.0.0-arm64-mac.zip",
            "Example-2.0.0-x64-mac.zip",
            "Example-2.0.0-universal-mac.zip",
        ] {
            let metadata = try XCTUnwrap(
                AppUpdateScanner.parseElectronUpdateMetadata(
                    Data(
                        """
                        version: 2.0.0
                        files:
                          - url: \(asset)
                            sha512: \(checksum)
                        """.utf8
                    )
                )
            )
            XCTAssertEqual(metadata.version, "2.0.0")
        }

        let legacy = try XCTUnwrap(
            AppUpdateScanner.parseElectronUpdateMetadata(
                Data(
                    """
                    version: 3.3.0
                    path: ../../3.3.0/Example-3.3.0-mac.zip
                    sha512: \(checksum)
                    """.utf8
                )
            )
        )
        XCTAssertEqual(legacy.version, "3.3.0")
    }

    private func makeApp(
        name: String,
        bundleIdentifier: String,
        path: URL,
        version: String?,
        buildNumber: String?
    ) -> InstalledApp {
        InstalledApp(
            appName: name,
            bundleIdentifier: bundleIdentifier,
            path: path,
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1,
            version: version,
            buildNumber: buildNumber,
            signature: .unknown
        )
    }
}

@MainActor
final class AppUpdateStateTests: XCTestCase {
    func testAppStatePublishesInjectedUpdateScanResult() async throws {
        let app = InstalledApp(
            appName: "Example",
            bundleIdentifier: "com.example.app",
            path: URL(fileURLWithPath: "/Applications/Example.app"),
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1,
            version: "1.0",
            buildNumber: "100"
        )
        let item = AppUpdateItem(
            id: app.id,
            appName: app.appName,
            bundleIdentifier: app.bundleIdentifier,
            appURL: app.path,
            currentVersion: "1.0",
            currentBuild: "100",
            availableVersion: "2.0",
            source: .macAppStore(productIdentifier: 42),
            status: .updateAvailable,
            evidence: [.macAppStoreReceipt],
            releaseNotesURL: nil,
            checkedAt: Date(),
            failureReason: nil,
            expectedTeamIdentifier: "TEAM123",
            remoteEvidenceSHA256: nil
        )
        let appState = AppState(
            performStartupTasks: false,
            appUpdatesScanner: { _ in
                AppUpdateScanResult(
                    items: [item],
                    unsupportedAppCount: 3,
                    checkedAt: item.checkedAt
                )
            }
        )
        appState.installedApps = [app]

        appState.scanAppUpdates()
        for _ in 0..<100 where !appState.hasScannedAppUpdates {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(appState.hasScannedAppUpdates)
        XCTAssertFalse(appState.isScanningAppUpdates)
        XCTAssertEqual(appState.appUpdates, [item])
        XCTAssertEqual(appState.availableAppUpdateCount, 1)
        XCTAssertEqual(appState.appUpdateUnsupportedAppCount, 3)
    }
}

@MainActor
final class InstallationFileStateTests: XCTestCase {
    func testScanPublishesResultsWithoutSelectingAnythingAutomatically() async throws {
        let fingerprint = InstallationFileFingerprint(
            deviceID: 1,
            inode: 2,
            fileSize: 1_024,
            modificationSeconds: 3,
            modificationNanoseconds: 4,
            ownerUserID: 501,
            hardLinkCount: 1
        )
        let removable = InstallationFileItem(
            url: URL(fileURLWithPath: "/Users/test/Downloads/Example.dmg"),
            name: "Example.dmg",
            kind: .diskImage,
            size: 1_024,
            createdAt: nil,
            modifiedAt: nil,
            quarantineOriginURL: nil,
            quarantineAgentName: nil,
            signature: .unknown,
            relatedApplication: nil,
            evidence: [.filenameExtension, .regularFile],
            removalEligibility: .eligible,
            fingerprint: fingerprint
        )
        let protected = InstallationFileItem(
            url: URL(fileURLWithPath: "/Users/test/Library/Caches/Update.pkg"),
            name: "Update.pkg",
            kind: .installerPackage,
            size: 2_048,
            createdAt: nil,
            modifiedAt: nil,
            quarantineOriginURL: nil,
            quarantineAgentName: nil,
            signature: .unknown,
            relatedApplication: nil,
            evidence: [.filenameExtension, .regularFile],
            removalEligibility: .protected(.applicationManagedCache),
            fingerprint: fingerprint
        )
        let result = InstallationFileScanResult(
            items: [removable, protected],
            ignoredPathCount: 3,
            inaccessibleCandidateCount: 1,
            wasTruncated: false,
            wasCancelled: false,
            scannedAt: Date()
        )
        let appState = AppState(
            performStartupTasks: false,
            installationFilesScanner: { _, _ in result }
        )

        appState.scanInstallationFiles()
        for _ in 0..<100 where !appState.hasScannedInstallationFiles {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(appState.installationFiles, [removable, protected])
        XCTAssertTrue(appState.selectedInstallationFileIDs.isEmpty)
        XCTAssertEqual(appState.removableInstallationFileSize, 1_024)
        XCTAssertEqual(appState.installationFileIgnoredCount, 3)
        XCTAssertEqual(appState.installationFileInaccessibleCount, 1)

        appState.selectAllRemovableInstallationFiles()
        XCTAssertEqual(appState.selectedInstallationFileIDs, [removable.id])
        appState.toggleInstallationFileSelection(protected)
        XCTAssertEqual(appState.selectedInstallationFileIDs, [removable.id])
        appState.approveManagedInstallationFileSelection(protected)
        XCTAssertEqual(
            appState.selectedInstallationFileIDs,
            [removable.id, protected.id]
        )
        XCTAssertEqual(appState.selectedInstallationFileSize, 3_072)
        appState.selectAllRemovableInstallationFiles()
        XCTAssertEqual(appState.selectedInstallationFileIDs, [removable.id])
        XCTAssertTrue(appState.explicitlyApprovedInstallationFileIDs.isEmpty)
        appState.approveManagedInstallationFileSelection(protected)
        appState.toggleInstallationFileSelection(protected)
        XCTAssertEqual(appState.selectedInstallationFileIDs, [removable.id])
        XCTAssertFalse(
            appState.explicitlyApprovedInstallationFileIDs.contains(protected.id)
        )
    }
}

private actor AppPermissionCommandCapture {
    private(set) var calls: [(URL, [String])] = []

    func append(_ executableURL: URL, _ arguments: [String]) {
        calls.append((executableURL, arguments))
    }

    func snapshot() -> [(URL, [String])] {
        calls
    }
}

@MainActor
final class AppPermissionStateTests: XCTestCase {
    func testScanPublishesEvidenceAndSummaryCounts() async throws {
        let client = makePermissionClient()
        let scannedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let result = AppPermissionScanResult(
            clients: [client],
            sources: [
                AppPermissionDatabaseSource(
                    scope: .system,
                    path: "/Library/Application Support/com.apple.TCC/TCC.db",
                    status: .available,
                    rowCount: 1,
                    sqliteResultCode: nil
                ),
            ],
            scannedAt: scannedAt,
            wasTruncated: false,
            wasCancelled: false
        )
        let appState = AppState(
            performStartupTasks: false,
            appPermissionsScanner: { applications in
                XCTAssertEqual(applications.map(\.bundleIdentifier), ["com.example.Camera"])
                return result
            }
        )
        appState.installedApps = [makeInstalledApp()]

        appState.scanAppPermissions()
        for _ in 0..<100 where !appState.hasScannedAppPermissions {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(appState.hasScannedAppPermissions)
        XCTAssertFalse(appState.isScanningAppPermissions)
        XCTAssertEqual(appState.appPermissionClients, [client])
        XCTAssertEqual(appState.appPermissionSources, result.sources)
        XCTAssertEqual(appState.lastAppPermissionScanDate, scannedAt)
        XCTAssertEqual(appState.highImpactAllowedAppPermissionCount, 1)
        XCTAssertTrue(
            appState.canResetAppPermission(client: client, service: .camera)
        )
    }

    func testResetUsesRevalidatedClientAndTriggersRefresh() async throws {
        let client = makePermissionClient()
        let capture = AppPermissionCommandCapture()
        let controller = AppPermissionController { executableURL, arguments in
            await capture.append(executableURL, arguments)
            return AppPermissionCommandResult(terminationStatus: 0, output: "")
        }
        let appState = AppState(
            performStartupTasks: false,
            appPermissionsScanner: { _ in
                AppPermissionScanResult(
                    clients: [client],
                    sources: [],
                    scannedAt: Date(),
                    wasTruncated: false,
                    wasCancelled: false
                )
            },
            appPermissionController: controller
        )

        appState.scanAppPermissions()
        for _ in 0..<100 where !appState.hasScannedAppPermissions {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        appState.resetAppPermission(client: client, service: .camera)
        for _ in 0..<100 where appState.activeAppPermissionActionID != nil
            || appState.isScanningAppPermissions {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let calls = await capture.snapshot()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0.path, "/usr/bin/tccutil")
        XCTAssertEqual(calls[0].1, ["reset", "Camera", "com.example.Camera"])
        XCTAssertNil(appState.appPermissionActionError)
        XCTAssertNotNil(appState.appPermissionActionMessage)
        XCTAssertTrue(appState.hasScannedAppPermissions)
    }

    private func makePermissionClient() -> AppPermissionClient {
        let record = AppPermissionRecord(
            scope: .system,
            service: .camera,
            clientIdentifier: "com.example.Camera",
            clientType: 0,
            decision: .allowed,
            authorizationValue: 2,
            authorizationReason: 2,
            indirectObjectIdentifier: nil,
            lastModified: nil
        )
        return AppPermissionClient(
            id: "0|com.example.Camera",
            name: "Camera",
            clientIdentifier: "com.example.Camera",
            clientType: 0,
            bundleIdentifier: "com.example.Camera",
            applicationURL: URL(fileURLWithPath: "/Applications/Camera.app"),
            version: "1.0",
            isInstalled: true,
            records: [record],
            declarations: []
        )
    }

    private func makeInstalledApp() -> InstalledApp {
        InstalledApp(
            appName: "Camera",
            bundleIdentifier: "com.example.Camera",
            path: URL(fileURLWithPath: "/Applications/Camera.app"),
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1,
            version: "1.0"
        )
    }
}
