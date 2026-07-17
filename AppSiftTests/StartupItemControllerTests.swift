import AppKit
import Darwin
import XCTest
@testable import AppSift

final class StartupItemControllerTests: XCTestCase {
    func testRejectsSystemLaunchAgent() throws {
        let fixture = try makeFixture(scope: .system)
        defer { fixture.cleanup() }

        XCTAssertFalse(fixture.controller.canControl(fixture.item))
        XCTAssertThrowsError(
            try fixture.controller.perform(.disable, on: fixture.item)
        ) { error in
            XCTAssertEqual(error as? StartupItemControlError, .unsupportedItem)
        }
        XCTAssertTrue(fixture.runtime.commands().isEmpty)
    }

    func testRejectsModernBackgroundItem() throws {
        let fixture = try makeFixture(
            kind: .backgroundItem,
            isLegacy: false,
            evidence: [.backgroundTaskManagement]
        )
        defer { fixture.cleanup() }

        XCTAssertFalse(fixture.controller.canControl(fixture.item))
        XCTAssertThrowsError(
            try fixture.controller.perform(.disable, on: fixture.item)
        ) { error in
            XCTAssertEqual(error as? StartupItemControlError, .unsupportedItem)
        }
    }

    func testRejectsPathOutsideAllowedRoot() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let outsideRoot = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("Outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        let outsideURL = outsideRoot.appendingPathComponent("com.example.outside.plist")
        try writePropertyList(label: "com.example.outside", to: outsideURL)
        defer { try? FileManager.default.removeItem(at: outsideRoot) }
        let item = makeItem(
            url: outsideURL,
            label: "com.example.outside"
        )

        XCTAssertFalse(fixture.controller.canControl(item))
        XCTAssertThrowsError(try fixture.controller.perform(.disable, on: item))
    }

    func testRejectsSymlinkedPropertyList() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let symlinkURL = fixture.root.appendingPathComponent("com.example.link.plist")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: fixture.propertyListURL
        )
        let item = makeItem(url: symlinkURL, label: "com.example.link")

        XCTAssertThrowsError(
            try fixture.controller.perform(.disable, on: item)
        ) { error in
            XCTAssertEqual(error as? StartupItemControlError, .unsafePropertyList)
        }
        XCTAssertTrue(fixture.runtime.commands().isEmpty)
    }

    func testRejectsSymlinkedAllowedRoot() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftStartupRootLink-\(UUID().uuidString)", isDirectory: true)
        let realRoot = container.appendingPathComponent("Real", isDirectory: true)
        let linkedRoot = container.appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkedRoot,
            withDestinationURL: realRoot
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let propertyListURL = linkedRoot.appendingPathComponent("com.example.helper.plist")
        try writePropertyList(label: "com.example.helper", to: propertyListURL)
        let historyStore = StartupItemControlHistoryStore(
            fileURL: container.appendingPathComponent("history.json"),
            allowedLaunchAgentsRoot: linkedRoot
        )
        let runtime = RuntimeHarness(
            state: StartupItemRuntimeState(isDisabled: false, isLoaded: true)
        )
        let controller = makeController(
            root: linkedRoot,
            historyStore: historyStore,
            runtime: runtime
        )

        XCTAssertThrowsError(
            try controller.perform(
                .disable,
                on: makeItem(url: propertyListURL, label: "com.example.helper")
            )
        ) { error in
            XCTAssertEqual(error as? StartupItemControlError, .unsafePropertyList)
        }
        XCTAssertTrue(runtime.commands().isEmpty)
    }

    func testRejectsGroupWritablePropertyList() throws {
        let fixture = try makeFixture(permissions: 0o660)
        defer { fixture.cleanup() }

        XCTAssertThrowsError(
            try fixture.controller.perform(.disable, on: fixture.item)
        ) { error in
            XCTAssertEqual(error as? StartupItemControlError, .unsafePropertyList)
        }
        XCTAssertTrue(fixture.runtime.commands().isEmpty)
    }

    func testRejectsLabelMismatch() throws {
        let fixture = try makeFixture(
            label: "com.example.actual",
            itemLabel: "com.example.scanned"
        )
        defer { fixture.cleanup() }

        XCTAssertThrowsError(
            try fixture.controller.perform(.disable, on: fixture.item)
        ) { error in
            XCTAssertEqual(error as? StartupItemControlError, .identityChanged)
        }
        XCTAssertTrue(fixture.runtime.commands().isEmpty)
    }

    func testRejectsIdentifierInjection() throws {
        let fixture = try makeFixture(label: "com.example/escape")
        defer { fixture.cleanup() }

        XCTAssertFalse(fixture.controller.canControl(fixture.item))
        XCTAssertThrowsError(
            try fixture.controller.perform(.disable, on: fixture.item)
        ) { error in
            XCTAssertEqual(error as? StartupItemControlError, .unsupportedItem)
        }
        XCTAssertTrue(fixture.runtime.commands().isEmpty)
    }

    func testDisableUsesDisableThenBootoutAndPersistsPrivateHistory() throws {
        let fixture = try makeFixture(
            initialState: StartupItemRuntimeState(isDisabled: false, isLoaded: true)
        )
        defer { fixture.cleanup() }

        let outcome = try fixture.controller.perform(.disable, on: fixture.item)

        XCTAssertEqual(
            fixture.runtime.commands(),
            [
                .disable(target: "gui/\(getuid())/com.example.helper"),
                .bootout(target: "gui/\(getuid())/com.example.helper"),
            ]
        )
        XCTAssertEqual(
            fixture.runtime.currentState(),
            StartupItemRuntimeState(isDisabled: true, isLoaded: false)
        )
        XCTAssertEqual(outcome.record.originalDisabled, false)
        XCTAssertEqual(outcome.record.originalLoaded, true)
        XCTAssertEqual(fixture.controller.historySnapshot().map(\.id), [outcome.record.id])
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.historyURL.path
        )
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testEnableUsesEnableThenBootstrap() throws {
        let fixture = try makeFixture(
            state: .disabled,
            initialState: StartupItemRuntimeState(isDisabled: true, isLoaded: false)
        )
        defer { fixture.cleanup() }

        _ = try fixture.controller.perform(.enable, on: fixture.item)

        XCTAssertEqual(
            fixture.runtime.commands(),
            [
                .enable(target: "gui/\(getuid())/com.example.helper"),
                .bootstrap(
                    domain: "gui/\(getuid())",
                    propertyListPath: fixture.propertyListURL.path
                ),
            ]
        )
        XCTAssertEqual(
            fixture.runtime.currentState(),
            StartupItemRuntimeState(isDisabled: false, isLoaded: true)
        )
    }

    func testSafeIdentifierAllowsSpacesWithoutChangingArgumentBoundaries() throws {
        let fixture = try makeFixture(label: "Clash Verge")
        defer { fixture.cleanup() }

        _ = try fixture.controller.perform(.disable, on: fixture.item)

        XCTAssertEqual(
            fixture.runtime.commands(),
            [
                .disable(target: "gui/\(getuid())/Clash Verge"),
                .bootout(target: "gui/\(getuid())/Clash Verge"),
            ]
        )
    }

    func testUndoRestoresOriginalDisabledAndLoadedState() throws {
        let fixture = try makeFixture(
            initialState: StartupItemRuntimeState(isDisabled: false, isLoaded: true)
        )
        defer { fixture.cleanup() }
        let record = try fixture.controller.perform(.disable, on: fixture.item).record
        fixture.runtime.clearCommands()

        let outcome = try fixture.controller.undo(record)

        XCTAssertEqual(
            fixture.runtime.commands(),
            [
                .enable(target: "gui/\(getuid())/com.example.helper"),
                .bootstrap(
                    domain: "gui/\(getuid())",
                    propertyListPath: fixture.propertyListURL.path
                ),
            ]
        )
        XCTAssertEqual(
            fixture.runtime.currentState(),
            StartupItemRuntimeState(isDisabled: false, isLoaded: true)
        )
        XCTAssertTrue(outcome.historyPersisted)
        XCTAssertNotNil(fixture.controller.historySnapshot().first?.restoredAt)
    }

    func testUndoRejectsChangedPropertyListDigest() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let record = try fixture.controller.perform(.disable, on: fixture.item).record
        try writePropertyList(
            label: "com.example.helper",
            to: fixture.propertyListURL,
            extra: ["RunAtLoad": true]
        )
        fixture.runtime.clearCommands()

        XCTAssertThrowsError(try fixture.controller.undo(record)) { error in
            XCTAssertEqual(error as? StartupItemControlError, .propertyListChanged)
        }
        XCTAssertTrue(fixture.runtime.commands().isEmpty)
        XCTAssertEqual(
            fixture.runtime.currentState(),
            StartupItemRuntimeState(isDisabled: true, isLoaded: false)
        )
    }

    func testHistoryFailureRollsBackStateAutomatically() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftStartupHistoryFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let propertyListURL = root.appendingPathComponent("com.example.helper.plist")
        try writePropertyList(label: "com.example.helper", to: propertyListURL)
        let blockingParent = root.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockingParent)
        let historyURL = blockingParent.appendingPathComponent("history.json")
        let historyStore = StartupItemControlHistoryStore(
            fileURL: historyURL,
            allowedLaunchAgentsRoot: root
        )
        let runtime = RuntimeHarness(
            state: StartupItemRuntimeState(isDisabled: false, isLoaded: true)
        )
        let controller = makeController(
            root: root,
            historyStore: historyStore,
            runtime: runtime
        )
        let item = makeItem(url: propertyListURL, label: "com.example.helper")

        XCTAssertThrowsError(try controller.perform(.disable, on: item)) { error in
            XCTAssertEqual(
                error as? StartupItemControlError,
                .historySaveFailedRolledBack
            )
        }
        XCTAssertEqual(
            runtime.commands(),
            [
                .disable(target: "gui/\(getuid())/com.example.helper"),
                .bootout(target: "gui/\(getuid())/com.example.helper"),
                .enable(target: "gui/\(getuid())/com.example.helper"),
                .bootstrap(
                    domain: "gui/\(getuid())",
                    propertyListPath: propertyListURL.path
                ),
            ]
        )
        XCTAssertEqual(
            runtime.currentState(),
            StartupItemRuntimeState(isDisabled: false, isLoaded: true)
        )
        XCTAssertTrue(controller.historySnapshot().isEmpty)
    }

    func testOnlyNewestActiveHistoryEntryCanBeUndone() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let first = try fixture.controller.perform(.disable, on: fixture.item).record
        let secondItem = fixture.item.replacingState(.disabled)
        let second = try fixture.controller.perform(.enable, on: secondItem).record

        XCTAssertFalse(fixture.controller.canUndo(first))
        XCTAssertTrue(fixture.controller.canUndo(second))
        XCTAssertThrowsError(try fixture.controller.undo(first)) { error in
            XCTAssertEqual(error as? StartupItemControlError, .staleHistory)
        }
    }

    func testHistoryRejectsOversizedCountAndInvalidSchema() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftStartupHistoryTamper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let itemPath = root.appendingPathComponent("com.example.helper.plist").path
        let historyURL = root.appendingPathComponent("history.json")
        let invalidSchema = StartupItemControlRecord(
            schemaVersion: 99,
            itemName: "Example",
            serviceIdentifier: "com.example.helper",
            itemPath: itemPath,
            action: .disable,
            originalDisabled: false,
            originalLoaded: true,
            plistSHA256: String(repeating: "a", count: 64)
        )
        try JSONEncoder().encode([invalidSchema]).write(to: historyURL, options: .atomic)
        XCTAssertTrue(
            StartupItemControlHistoryStore(
                fileURL: historyURL,
                allowedLaunchAgentsRoot: root
            ).snapshot().isEmpty
        )

        let oversized = (0...100).map { index in
            StartupItemControlRecord(
                itemName: "Example \(index)",
                serviceIdentifier: "com.example.helper\(index)",
                itemPath: root.appendingPathComponent("item\(index).plist").path,
                action: .disable,
                originalDisabled: false,
                originalLoaded: true,
                plistSHA256: String(repeating: "b", count: 64)
            )
        }
        try JSONEncoder().encode(oversized).write(to: historyURL, options: .atomic)
        XCTAssertTrue(
            StartupItemControlHistoryStore(
                fileURL: historyURL,
                allowedLaunchAgentsRoot: root
            ).snapshot().isEmpty
        )
    }

    func testDisabledStateParserMatchesExactIdentifier() {
        let output = """
            disabled services = {
                "com.example.helper" => disabled
                "com.example.helper.extra" => enabled
                "com.example.other" => true
            }
        """

        XCTAssertTrue(
            StartupItemController.disabledState(
                for: "com.example.helper",
                in: output
            )
        )
        XCTAssertFalse(
            StartupItemController.disabledState(
                for: "com.example.helper.extra",
                in: output
            )
        )
        XCTAssertTrue(
            StartupItemController.disabledState(
                for: "com.example.other",
                in: output
            )
        )
    }

    private func makeFixture(
        label: String = "com.example.helper",
        itemLabel: String? = nil,
        permissions: NSNumber = 0o600,
        kind: StartupItemKind = .launchAgent,
        state: StartupItemState = .enabled,
        scope: StartupItemScope = .user,
        isLegacy: Bool = true,
        evidence: Set<StartupItemEvidence> = [.launchdPropertyList],
        initialState: StartupItemRuntimeState = StartupItemRuntimeState(
            isDisabled: false,
            isLoaded: true
        )
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftStartupControl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let propertyListURL = root.appendingPathComponent("helper.plist")
        try writePropertyList(label: label, to: propertyListURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: propertyListURL.path
        )
        let historyURL = root.appendingPathComponent("history.json")
        let historyStore = StartupItemControlHistoryStore(
            fileURL: historyURL,
            allowedLaunchAgentsRoot: root
        )
        let runtime = RuntimeHarness(state: initialState)
        let controller = makeController(
            root: root,
            historyStore: historyStore,
            runtime: runtime
        )
        return Fixture(
            root: root,
            propertyListURL: propertyListURL,
            historyURL: historyURL,
            item: makeItem(
                url: propertyListURL,
                label: itemLabel ?? label,
                kind: kind,
                state: state,
                scope: scope,
                isLegacy: isLegacy,
                evidence: evidence
            ),
            controller: controller,
            runtime: runtime
        )
    }

    private func makeController(
        root: URL,
        historyStore: StartupItemControlHistoryStore,
        runtime: RuntimeHarness
    ) -> StartupItemController {
        StartupItemController(
            allowedLaunchAgentsRoot: root,
            uid: getuid(),
            historyStore: historyStore,
            commandRunner: { command in
                runtime.run(command)
            },
            stateProvider: { _ in
                runtime.currentState()
            }
        )
    }

    private func makeItem(
        url: URL,
        label: String,
        kind: StartupItemKind = .launchAgent,
        state: StartupItemState = .enabled,
        scope: StartupItemScope = .user,
        isLegacy: Bool = true,
        evidence: Set<StartupItemEvidence> = [.launchdPropertyList]
    ) -> StartupItem {
        StartupItem(
            id: "launchd|\(url.path)",
            name: "Example Helper",
            developerName: nil,
            teamIdentifier: nil,
            serviceIdentifier: label,
            kind: kind,
            state: state,
            scope: scope,
            itemURL: url,
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            associatedBundleIdentifiers: ["com.example.app"],
            evidence: evidence,
            isLegacy: isLegacy,
            isMissing: false
        )
    }

    private func writePropertyList(
        label: String,
        to url: URL,
        extra: [String: Any] = [:]
    ) throws {
        var propertyList: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/sleep", "300"],
        ]
        propertyList.merge(extra) { _, new in new }
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }
}

@MainActor
final class StartupItemAppStateTests: XCTestCase {
    func testForcedRefreshIgnoresOlderScanCompletion() async throws {
        let firstStarted = expectation(description: "first startup scan started")
        let releaseFirst = DispatchSemaphore(value: 0)
        let calls = LockedCounter()
        let firstItem = makeItem(label: "com.example.first")
        let secondItem = makeItem(label: "com.example.second")
        let appState = AppState(
            performStartupTasks: false,
            startupItemsScanner: {
                let call = calls.increment()
                if call == 1 {
                    firstStarted.fulfill()
                    _ = releaseFirst.wait(timeout: .now() + 3)
                    return StartupItemScanResult(
                        items: [firstItem],
                        backgroundTaskDataAvailable: true,
                        backgroundTaskDataTruncated: false
                    )
                }
                return StartupItemScanResult(
                    items: [secondItem],
                    backgroundTaskDataAvailable: true,
                    backgroundTaskDataTruncated: false
                )
            }
        )

        appState.scanStartupItems()
        await fulfillment(of: [firstStarted], timeout: 1)
        appState.scanStartupItems(force: true)
        for _ in 0..<100 where appState.startupItems != [secondItem] {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(appState.startupItems, [secondItem])

        releaseFirst.signal()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(appState.startupItems, [secondItem])
    }

    private func makeItem(label: String) -> StartupItem {
        let url = URL(fileURLWithPath: "/tmp/\(label).plist")
        return StartupItem(
            id: "launchd|\(url.path)",
            name: label,
            developerName: nil,
            teamIdentifier: nil,
            serviceIdentifier: label,
            kind: .launchAgent,
            state: .enabled,
            scope: .user,
            itemURL: url,
            executableURL: nil,
            associatedBundleIdentifiers: [],
            evidence: [.launchdPropertyList],
            isLegacy: true,
            isMissing: false
        )
    }
}

private struct Fixture {
    let root: URL
    let propertyListURL: URL
    let historyURL: URL
    let item: StartupItem
    let controller: StartupItemController
    let runtime: RuntimeHarness

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RuntimeHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var state: StartupItemRuntimeState
    private var recordedCommands: [StartupItemLaunchctlCommand] = []

    init(state: StartupItemRuntimeState) {
        self.state = state
    }

    func run(_ command: StartupItemLaunchctlCommand) -> StartupItemCommandResult {
        lock.lock()
        defer { lock.unlock() }
        recordedCommands.append(command)
        switch command {
        case .disable:
            state = StartupItemRuntimeState(
                isDisabled: true,
                isLoaded: state.isLoaded
            )
        case .enable:
            state = StartupItemRuntimeState(
                isDisabled: false,
                isLoaded: state.isLoaded
            )
        case .bootout:
            state = StartupItemRuntimeState(
                isDisabled: state.isDisabled,
                isLoaded: false
            )
        case .bootstrap:
            state = StartupItemRuntimeState(
                isDisabled: state.isDisabled,
                isLoaded: true
            )
        case .printDisabled, .printService:
            break
        }
        return StartupItemCommandResult(
            exitCode: 0,
            output: Data(),
            timedOut: false,
            truncated: false
        )
    }

    func currentState() -> StartupItemRuntimeState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func commands() -> [StartupItemLaunchctlCommand] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommands
    }

    func clearCommands() {
        lock.lock()
        defer { lock.unlock() }
        recordedCommands.removeAll()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
