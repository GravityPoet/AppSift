import AppKit
import XCTest
@testable import AppSift

final class TrashAppSnapshotDetectorTests: XCTestCase {
    func testInitialSnapshotIsSilentAndReaddedAppIsDetectedAgain() {
        let first = candidate("First.app")
        let second = candidate("Second.app")
        var detector = TrashAppSnapshotDetector()

        XCTAssertTrue(detector.observe([first]).isEmpty)
        XCTAssertEqual(detector.observe([first, second]), [second])
        XCTAssertTrue(detector.observe([first, second]).isEmpty)
        XCTAssertTrue(detector.observe([first]).isEmpty)
        XCTAssertEqual(detector.observe([first, second]), [second])
    }

    func testSuppressedNewAppStillJoinsSnapshotWithoutLaterDuplicate() {
        let app = candidate("AppSiftRemoved.app")
        var detector = TrashAppSnapshotDetector()

        XCTAssertTrue(detector.observe([]).isEmpty)
        XCTAssertTrue(
            detector.observe([app], suppressedPaths: [app.path]).isEmpty
        )
        XCTAssertTrue(detector.observe([app]).isEmpty)
    }

    private func candidate(_ name: String) -> TrashAppCandidate {
        TrashAppCandidate(
            url: URL(fileURLWithPath: "/tmp/Trash/\(name)", isDirectory: true),
            appName: URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent,
            bundleIdentifier: "com.example.\(name)"
        )
    }
}

final class TrashAppDirectoryScannerTests: XCTestCase {
    @MainActor
    func testDefaultLoaderAcceptsOnlyReadableUnprotectedBundles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let accepted = root.appendingPathComponent("Accepted.app", isDirectory: true)
        let currentApp = root.appendingPathComponent("AppSift.app", isDirectory: true)
        let protectedApp = root.appendingPathComponent("Safari.app", isDirectory: true)
        let invalid = root.appendingPathComponent("Invalid.app", isDirectory: true)
        try makeSyntheticApp(
            at: accepted,
            name: "Accepted",
            bundleIdentifier: "com.example.accepted"
        )
        try makeSyntheticApp(
            at: currentApp,
            name: "AppSift",
            bundleIdentifier: try XCTUnwrap(Bundle.main.bundleIdentifier)
        )
        try makeSyntheticApp(
            at: protectedApp,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)

        let snapshot = try TrashAppDirectoryScanner(rootURL: root).scan().get()

        XCTAssertEqual(snapshot.candidates.map(\.path), [accepted.standardizedFileURL.path])
        XCTAssertEqual(snapshot.candidates.first?.appName, "Accepted")
        XCTAssertEqual(snapshot.candidates.first?.bundleIdentifier, "com.example.accepted")
    }

    func testScannerAcceptsOnlyTopLevelRealAppDirectories() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let topLevelApp = root.appendingPathComponent("Top.app", isDirectory: true)
        let uppercaseApp = root.appendingPathComponent("Upper.APP", isDirectory: true)
        let ordinaryFile = root.appendingPathComponent("Notes.app")
        let nestedFolder = root.appendingPathComponent("Nested", isDirectory: true)
        let nestedApp = nestedFolder.appendingPathComponent("Hidden.app", isDirectory: true)
        let targetApp = root.appendingPathComponent("Target.app", isDirectory: true)
        let symlinkApp = root.appendingPathComponent("Alias.app", isDirectory: true)

        for directory in [topLevelApp, uppercaseApp, nestedApp, targetApp] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try Data("not a bundle".utf8).write(to: ordinaryFile)
        try FileManager.default.createSymbolicLink(
            at: symlinkApp,
            withDestinationURL: targetApp
        )

        let scanner = TrashAppDirectoryScanner(rootURL: root) { url in
            TrashAppCandidate(
                url: url,
                appName: url.deletingPathExtension().lastPathComponent,
                bundleIdentifier: "com.example.\(url.lastPathComponent)"
            )
        }
        let snapshot = try XCTUnwrap(try? scanner.scan().get())

        XCTAssertEqual(
            Set(snapshot.candidates.map(\.path)),
            Set([topLevelApp, uppercaseApp, targetApp].map { $0.standardizedFileURL.path })
        )
    }

    @MainActor
    func testDefaultLoaderRejectsSymlinkedInfoPlist() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("LinkedInfo.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let outsideInfo = root.appendingPathComponent("Outside.plist")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.linked-info",
            "CFBundleName": "Linked Info",
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: outsideInfo)
        try FileManager.default.createSymbolicLink(
            at: contents.appendingPathComponent("Info.plist"),
            withDestinationURL: outsideInfo
        )

        let snapshot = try TrashAppDirectoryScanner(rootURL: root).scan().get()

        XCTAssertTrue(snapshot.candidates.isEmpty)
    }

    func testScannerRejectsSymlinkedTrashRoot() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let realRoot = parent.appendingPathComponent("RealTrash", isDirectory: true)
        let linkedRoot = parent.appendingPathComponent("LinkedTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkedRoot,
            withDestinationURL: realRoot
        )

        let result = TrashAppDirectoryScanner(
            rootURL: linkedRoot,
            candidateLoader: { _ in nil }
        ).scan()

        XCTAssertEqual(result.failure, .unsafeRoot)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftTrashWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSyntheticApp(
        at url: URL,
        name: String,
        bundleIdentifier: String
    ) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let executableDirectory = contents.appendingPathComponent("MacOS", isDirectory: true)
        let executable = executableDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: executableDirectory,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleExecutable": name,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
    }
}

@MainActor
final class TrashAppWatcherLifecycleTests: XCTestCase {
    func testWatcherUsesSilentBaselineDeduplicatesAndStopsCallbacks() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("Existing.app", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)

        let watcher = makeWatcher(root: root)
        var detections: [TrashAppCandidate] = []
        watcher.start { detections.append(contentsOf: $0) }

        watcher.scanNowForTesting()
        XCTAssertTrue(detections.isEmpty)

        let added = root.appendingPathComponent("Added.app", isDirectory: true)
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        watcher.scanNowForTesting()
        watcher.scanNowForTesting()
        XCTAssertEqual(detections.map(\.path), [added.standardizedFileURL.path])

        try FileManager.default.removeItem(at: added)
        watcher.scanNowForTesting()
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        watcher.scanNowForTesting()
        XCTAssertEqual(detections.map(\.path), [
            added.standardizedFileURL.path,
            added.standardizedFileURL.path,
        ])

        watcher.stop()
        let afterStop = root.appendingPathComponent("AfterStop.app", isDirectory: true)
        try FileManager.default.createDirectory(at: afterStop, withIntermediateDirectories: true)
        watcher.scanNowForTesting()
        XCTAssertEqual(detections.count, 2)
        XCTAssertEqual(watcher.status, .stopped)
    }

    func testWatcherSuppressesAppSiftTrashDestination() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = makeWatcher(root: root)
        var detections: [TrashAppCandidate] = []
        watcher.start { detections.append(contentsOf: $0) }

        let app = root.appendingPathComponent("RemovedByAppSift.app", isDirectory: true)
        watcher.suppress([app])
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        watcher.scanNowForTesting()
        watcher.scanNowForTesting()

        XCTAssertTrue(detections.isEmpty)
        watcher.stop()
    }

    func testRealDirectoryEventTriggersOneDetectionBatch() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = TrashAppWatcher(
            rootURL: root,
            debounceInterval: 0.05,
            retryInterval: 0.05,
            candidateLoader: candidateLoader
        )
        let detected = expectation(description: "top-level app detected")
        var batches: [[TrashAppCandidate]] = []
        watcher.start { candidates in
            batches.append(candidates)
            if candidates.contains(where: { $0.appName == "Event" }) {
                detected.fulfill()
            }
        }

        let eventApp = root.appendingPathComponent("Event.app", isDirectory: true)
        try FileManager.default.createDirectory(at: eventApp, withIntermediateDirectories: true)
        await fulfillment(of: [detected], timeout: 2)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(
            batches.flatMap { $0 }.filter { $0.appName == "Event" }.count,
            1
        )
        watcher.stop()
    }

    private var candidateLoader: TrashAppDirectoryScanner.CandidateLoader {
        { url in
            TrashAppCandidate(
                url: url,
                appName: url.deletingPathExtension().lastPathComponent,
                bundleIdentifier: "com.example.\(url.lastPathComponent)"
            )
        }
    }

    private func makeWatcher(root: URL) -> TrashAppWatcher {
        TrashAppWatcher(
            rootURL: root,
            debounceInterval: 60,
            retryInterval: 60,
            candidateLoader: candidateLoader
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftTrashWatcherLifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
final class TrashAppReviewStateTests: XCTestCase {
    func testDetectionQueuesInAppReviewWithoutNotificationAuthorization() async throws {
        let appState = AppState(performStartupTasks: false)
        let candidate = TrashAppCandidate(
            url: URL(fileURLWithPath: "/Users/test/.Trash/Queued.app", isDirectory: true),
            appName: "Queued",
            bundleIdentifier: "com.example.queued"
        )

        NotificationCenter.default.post(
            name: .appSiftTrashAppsDetected,
            object: [candidate]
        )
        for _ in 0..<100 where appState.pendingTrashAppReviews.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(appState.pendingTrashAppReviews, [candidate])
        appState.dismissTrashAppReviews()
        XCTAssertTrue(appState.pendingTrashAppReviews.isEmpty)
    }

    func testTrashReviewScanNeverIncludesTheTrashedAppBundle() throws {
        var completion: ((Set<URL>) -> Void)?
        let appURL = URL(fileURLWithPath: "/Users/test/.Trash/Example.app", isDirectory: true)
        let leftover = URL(fileURLWithPath: "/Users/test/Library/Caches/com.example.editor")
        let signature = AppSignatureMetadata(
            status: .developerSigned,
            signingIdentifier: "com.example.editor",
            teamIdentifier: "TEAM123",
            entitlementIdentifiers: []
        )
        let app = InstalledApp(
            appName: "Example",
            bundleIdentifier: "com.example.editor",
            path: appURL,
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 1,
            signature: signature
        )
        let appState = AppState(
            performStartupTasks: false,
            appFileScanner: { _, _, pendingCompletion in
                completion = pendingCompletion
                return nil
            },
            appInstallationInspector: { _, _ in
                AppInstallationInsights(source: .unknown, officialUninstaller: nil)
            }
        )

        appState.scanForAppFiles(app, initialSelection: .relatedFiles)
        try XCTUnwrap(completion)([appURL, leftover])

        XCTAssertEqual(appState.discoveredFiles, [leftover])
        XCTAssertEqual(appState.selectedFiles, [leftover])
        XCTAssertFalse(appState.discoveredFiles.contains(appURL))
        XCTAssertFalse(appState.selectedFiles.contains(appURL))
        XCTAssertTrue(appState.isReviewingTrashedApp)
        XCTAssertFalse(appState.canResetSelectedApp)
        XCTAssertEqual(ExternalAppAction.reviewTrash.initialSelection, .relatedFiles)
    }
}

private extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
