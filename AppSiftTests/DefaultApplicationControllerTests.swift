import Foundation
import XCTest
@testable import AppSift

final class DefaultApplicationControllerTests: XCTestCase {
    func testPerformRevalidatesCandidateChangesDefaultAndPersistsHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let outcome = try await fixture.controller.perform(
            item: fixture.item,
            target: fixture.target
        )

        XCTAssertEqual(fixture.runtime.currentURL(), fixture.target.url)
        XCTAssertEqual(outcome.currentApplication, fixture.target)
        XCTAssertEqual(outcome.record.previousApplicationPath, fixture.current.url.path)
        XCTAssertEqual(outcome.record.newApplicationPath, fixture.target.url.path)
        XCTAssertEqual(fixture.controller.historySnapshot().count, 1)
        let permissions = try FileManager.default.attributesOfItem(
            atPath: fixture.historyURL.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o600)
    }

    func testPerformRejectsCandidateThatDisappearedAfterScan() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.runtime.setCandidates([fixture.current.url])

        do {
            _ = try await fixture.controller.perform(
                item: fixture.item,
                target: fixture.target
            )
            XCTFail("Expected candidate validation to fail")
        } catch {
            XCTAssertEqual(
                error as? DefaultApplicationControlError,
                .candidateUnavailable
            )
        }
        XCTAssertEqual(fixture.runtime.currentURL(), fixture.current.url)
        XCTAssertTrue(fixture.controller.historySnapshot().isEmpty)
    }

    func testPerformRejectsStaleCurrentHandler() async throws {
        let fixture = try makeFixture(includeThirdApplication: true)
        defer { fixture.cleanup() }
        let third = try XCTUnwrap(fixture.third)
        fixture.runtime.setCurrent(third.url)

        do {
            _ = try await fixture.controller.perform(
                item: fixture.item,
                target: fixture.target
            )
            XCTFail("Expected stale scan validation to fail")
        } catch {
            XCTAssertEqual(
                error as? DefaultApplicationControlError,
                .sourceChanged
            )
        }
    }

    func testRejectedSystemConsentKeepsOriginalWithoutHistory() async throws {
        let fixture = try makeFixture(setterBehavior: .keepCurrent)
        defer { fixture.cleanup() }

        do {
            _ = try await fixture.controller.perform(
                item: fixture.item,
                target: fixture.target
            )
            XCTFail("Expected macOS refusal to be reported")
        } catch {
            XCTAssertEqual(
                error as? DefaultApplicationControlError,
                .changeNotApplied
            )
        }
        XCTAssertEqual(fixture.runtime.currentURL(), fixture.current.url)
        XCTAssertTrue(fixture.controller.historySnapshot().isEmpty)
    }

    func testHistoryFailureRollsBackChangedDefault() async throws {
        let fixture = try makeFixture(historyPathBlocked: true)
        defer { fixture.cleanup() }

        do {
            _ = try await fixture.controller.perform(
                item: fixture.item,
                target: fixture.target
            )
            XCTFail("Expected history persistence failure")
        } catch {
            XCTAssertEqual(
                error as? DefaultApplicationControlError,
                .historySaveFailedRolledBack
            )
        }
        XCTAssertEqual(fixture.runtime.currentURL(), fixture.current.url)
        XCTAssertTrue(fixture.controller.historySnapshot().isEmpty)
    }

    func testUndoRestoresPreviousApplicationAndMarksHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let change = try await fixture.controller.perform(
            item: fixture.item,
            target: fixture.target
        )

        let undo = try await fixture.controller.undo(change.record)

        XCTAssertEqual(fixture.runtime.currentURL(), fixture.current.url)
        XCTAssertEqual(undo.currentApplication, fixture.current)
        XCTAssertTrue(undo.historyPersisted)
        XCTAssertNotNil(
            fixture.controller.historySnapshot().first?.restoredAt
        )
    }

    func testUndoRefusesToOverwriteNewerExternalChoice() async throws {
        let fixture = try makeFixture(includeThirdApplication: true)
        defer { fixture.cleanup() }
        let third = try XCTUnwrap(fixture.third)
        let change = try await fixture.controller.perform(
            item: fixture.item,
            target: fixture.target
        )
        fixture.runtime.setCurrent(third.url)

        do {
            _ = try await fixture.controller.undo(change.record)
            XCTFail("Expected stale undo to be rejected")
        } catch {
            XCTAssertEqual(
                error as? DefaultApplicationControlError,
                .currentHandlerChanged
            )
        }
        XCTAssertEqual(fixture.runtime.currentURL(), third.url)
    }

    private enum SetterBehavior {
        case apply
        case keepCurrent
    }

    private struct Fixture {
        let root: URL
        let historyURL: URL
        let current: DefaultApplicationCandidate
        let target: DefaultApplicationCandidate
        let third: DefaultApplicationCandidate?
        let item: DefaultApplicationItem
        let runtime: HandlerRuntime
        let controller: DefaultApplicationController

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private final class HandlerRuntime: @unchecked Sendable {
        private let lock = NSLock()
        private var current: URL
        private var candidates: [URL]
        private let setterBehavior: SetterBehavior

        init(
            current: URL,
            candidates: [URL],
            setterBehavior: SetterBehavior
        ) {
            self.current = current
            self.candidates = candidates
            self.setterBehavior = setterBehavior
        }

        func snapshot(
            _ identifier: String
        ) -> DefaultApplicationHandlerSnapshot? {
            guard identifier == "com.adobe.pdf" else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return DefaultApplicationHandlerSnapshot(
                defaultApplicationURL: current,
                candidateApplicationURLs: candidates
            )
        }

        func set(_ url: URL, identifier: String) -> Error? {
            guard identifier == "com.adobe.pdf" else {
                return DefaultApplicationControlError.unsupportedContentType
            }
            lock.lock()
            defer { lock.unlock() }
            if setterBehavior == .apply {
                current = url
            }
            return nil
        }

        func currentURL() -> URL {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        func setCurrent(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            current = url
        }

        func setCandidates(_ values: [URL]) {
            lock.lock()
            defer { lock.unlock() }
            candidates = values
        }
    }

    private func makeFixture(
        includeThirdApplication: Bool = false,
        setterBehavior: SetterBehavior = .apply,
        historyPathBlocked: Bool = false
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AppSiftDefaultAppControl-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let currentURL = root.appendingPathComponent("Current.app", isDirectory: true)
        let targetURL = root.appendingPathComponent("Target.app", isDirectory: true)
        try makeApplication(
            at: currentURL,
            name: "Current",
            bundleIdentifier: "com.example.current"
        )
        try makeApplication(
            at: targetURL,
            name: "Target",
            bundleIdentifier: "com.example.target"
        )
        let thirdURL = root.appendingPathComponent("Third.app", isDirectory: true)
        if includeThirdApplication {
            try makeApplication(
                at: thirdURL,
                name: "Third",
                bundleIdentifier: "com.example.third"
            )
        }
        let current = try XCTUnwrap(
            DefaultApplicationScanner.candidate(at: currentURL)
        )
        let target = try XCTUnwrap(
            DefaultApplicationScanner.candidate(at: targetURL)
        )
        let third = includeThirdApplication
            ? try XCTUnwrap(DefaultApplicationScanner.candidate(at: thirdURL))
            : nil
        let candidates = [currentURL, targetURL]
            + (includeThirdApplication ? [thirdURL] : [])
        let runtime = HandlerRuntime(
            current: currentURL,
            candidates: candidates,
            setterBehavior: setterBehavior
        )

        let historyURL: URL
        if historyPathBlocked {
            let blocker = root.appendingPathComponent("not-a-directory")
            try Data("block".utf8).write(to: blocker)
            historyURL = blocker.appendingPathComponent("history.json")
        } else {
            historyURL = root
                .appendingPathComponent("History", isDirectory: true)
                .appendingPathComponent("history.json")
        }
        let historyStore = DefaultApplicationControlHistoryStore(
            fileURL: historyURL
        )
        let controller = DefaultApplicationController(
            historyStore: historyStore,
            snapshotProvider: { identifier in
                runtime.snapshot(identifier)
            },
            setter: { url, identifier in
                runtime.set(url, identifier: identifier)
            }
        )
        let item = DefaultApplicationItem(
            contentTypeIdentifier: "com.adobe.pdf",
            displayName: "PDF document",
            filenameExtensions: ["pdf"],
            category: .documents,
            currentApplication: current,
            candidateApplications: [current, target] + (third.map { [$0] } ?? []),
            evidence: [
                .commonTypeCatalog,
                .launchServicesCurrentHandler,
                .launchServicesCandidates,
            ]
        )
        return Fixture(
            root: root,
            historyURL: historyURL,
            current: current,
            target: target,
            third: third,
            item: item,
            runtime: runtime,
            controller: controller
        )
    }

    private func makeApplication(
        at url: URL,
        name: String,
        bundleIdentifier: String
    ) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contents,
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleName": name,
                "CFBundleDisplayName": name,
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1",
            ],
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
