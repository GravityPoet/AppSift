import AppKit
import Darwin
import Foundation
import XCTest
@testable import AppSift

final class PrivilegedAppRemovalServiceTests: XCTestCase {
    func testRootOwnedBatchUsesOneAuthorizedTransactionAndRecordsLaunchdState() async throws {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        let app = URL(fileURLWithPath: "/Applications/Example.app", isDirectory: true)
        let daemon = URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.helper.plist")
        let state = LockedPathSet([trash.path, app.path, daemon.path])
        let runnerCalls = LockedValue(0)

        let service = PrivilegedAppRemovalService(
            trashRoot: trash,
            allowedSourceRoots: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
            ],
            currentUserID: 501,
            fileExists: { state.contains($0) },
            metadataProvider: { url in
                if url.path == trash.path {
                    return PrivilegedAppRemovalFileMetadata(
                        ownerUserID: 501,
                        deviceID: 7,
                        isDirectory: true,
                        isSymbolicLink: false
                    )
                }
                if url.path == "/Applications" || url.path == "/Library/LaunchDaemons" {
                    return PrivilegedAppRemovalFileMetadata(
                        ownerUserID: 0,
                        deviceID: 7,
                        isDirectory: true,
                        isSymbolicLink: false
                    )
                }
                guard state.contains(url.path) else { return nil }
                return PrivilegedAppRemovalFileMetadata(
                    ownerUserID: 0,
                    deviceID: 7,
                    isDirectory: url.pathExtension == "app",
                    isSymbolicLink: false
                )
            },
            parentIsWritable: { _ in false },
            authorizationRunner: { plan in
                runnerCalls.withValue { $0 += 1 }
                XCTAssertEqual(plan.operation, .trash)
                XCTAssertEqual(plan.items.map(\.originalURL), [app, daemon])
                for item in plan.items {
                    state.remove(item.sourceURL.path)
                    state.insert(item.destinationURL.path)
                }
                guard let daemonIndex = plan.items.firstIndex(where: {
                    $0.originalURL == daemon
                }) else {
                    XCTFail("LaunchDaemon item missing from the authorized plan")
                    return .failed("missing LaunchDaemon fixture")
                }
                return .succeeded(loadedLaunchdItemIndexes: [daemonIndex])
            }
        )

        let result = await service.trash([app, daemon])

        XCTAssertEqual(runnerCalls.value, 1)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertEqual(result.trashed.count, 2)
        XCTAssertEqual(
            result.trashed.first { $0.originalURL == daemon }?.launchdWasLoaded,
            true
        )
        XCTAssertEqual(
            result.trashed.first { $0.originalURL == app }?.launchdWasLoaded,
            nil
        )
    }

    func testAuthorizationCancellationLeavesEveryProtectedItemInPlace() async {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        let app = URL(fileURLWithPath: "/Applications/Example.app", isDirectory: true)
        let state = LockedPathSet([trash.path, app.path])
        let service = PrivilegedAppRemovalService(
            trashRoot: trash,
            allowedSourceRoots: [URL(fileURLWithPath: "/Applications", isDirectory: true)],
            currentUserID: 501,
            fileExists: { state.contains($0) },
            metadataProvider: { url in
                PrivilegedAppRemovalFileMetadata(
                    ownerUserID: url.path == trash.path ? 501 : 0,
                    deviceID: 9,
                    isDirectory: true,
                    isSymbolicLink: false
                )
            },
            parentIsWritable: { _ in false },
            authorizationRunner: { _ in .authorizationCancelled }
        )

        let result = await service.trash([app])

        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertEqual(result.failed, [app])
        XCTAssertTrue(state.contains(app.path))
        XCTAssertEqual(
            result.failure(for: app)?.kind,
            .administratorAuthorizationCancelled
        )
    }

    func testPreflightRejectsSymlinkedAndOverlappingSourcesBeforeAuthorization() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftPrivilegedPreflight-\(UUID().uuidString)", isDirectory: true)
        let allowed = root.appendingPathComponent("Allowed", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let real = allowed.appendingPathComponent("Real", isDirectory: true)
        let linked = allowed.appendingPathComponent("Linked", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = LockedValue(0)
        let service = PrivilegedAppRemovalService(
            trashRoot: trash,
            allowedSourceRoots: [allowed],
            authorizationRunner: { _ in
                calls.withValue { $0 += 1 }
                return .failed("must not execute")
            }
        )

        let symlinkResult = await service.trash([linked])
        XCTAssertEqual(symlinkResult.failure(for: linked)?.kind, .unsafePath)
        XCTAssertTrue(service.shouldHandleTrash([linked]))

        let child = real.appendingPathComponent("Child")
        try Data("fixture".utf8).write(to: child)
        let overlapResult = await service.trash([real, child])
        XCTAssertEqual(overlapResult.failed.count, 2)
        XCTAssertTrue(overlapResult.failed.allSatisfy {
            overlapResult.failure(for: $0)?.kind == .unsafePath
        })
        XCTAssertEqual(calls.value, 0)
    }

    func testPreflightCanonicalizesVarAliasBeforeAuthorization() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
        guard temporaryRoot.path.hasPrefix("/var/") else {
            throw XCTSkip("This host does not expose the standard /var to /private/var alias.")
        }
        let root = temporaryRoot
            .appendingPathComponent("AppSiftCanonicalPreflight-\(UUID().uuidString)", isDirectory: true)
        let allowed = root.appendingPathComponent("Allowed", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let source = allowed.appendingPathComponent("item")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data("canonical".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = PrivilegedAppRemovalService(
            trashRoot: trash,
            allowedSourceRoots: [allowed],
            parentIsWritable: { _ in false },
            authorizationRunner: { plan in
                XCTAssertTrue(plan.trashRoot.path.hasPrefix("/private/var/"))
                XCTAssertTrue(plan.items[0].sourceURL.path.hasPrefix("/private/var/"))
                do {
                    try FileManager.default.moveItem(
                        at: plan.items[0].sourceURL,
                        to: plan.items[0].destinationURL
                    )
                    return .succeeded(loadedLaunchdItemIndexes: [])
                } catch {
                    XCTFail(error.localizedDescription)
                    return .failed(error.localizedDescription)
                }
            }
        )

        let result = await service.trash([source])

        XCTAssertTrue(
            result.failed.isEmpty,
            String(describing: result.failure(for: source))
        )
        XCTAssertEqual(
            result.trashed.count,
            1,
            String(describing: result.failure(for: source))
        )
    }

    func testPrivilegedRestoreUsesOneTransactionAndPreservesLaunchdIntent() async throws {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        let source = trash.appendingPathComponent("com.example.helper.plist")
        let destination = URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.helper.plist")
        let state = LockedPathSet([trash.path, source.path])
        let item = AppRemovalHistoryItem(
            originalPath: destination.path,
            trashPath: source.path,
            launchdWasLoaded: true
        )
        let service = PrivilegedAppRemovalService(
            trashRoot: trash,
            allowedSourceRoots: [URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)],
            currentUserID: 501,
            fileExists: { state.contains($0) },
            metadataProvider: { url in
                guard state.contains(url.path) || url.path == destination.deletingLastPathComponent().path else {
                    return nil
                }
                return PrivilegedAppRemovalFileMetadata(
                    ownerUserID: url.path == trash.path ? 501 : 0,
                    deviceID: 12,
                    isDirectory: url.path == trash.path || url.path == destination.deletingLastPathComponent().path,
                    isSymbolicLink: false
                )
            },
            parentIsWritable: { _ in false },
            authorizationRunner: { plan in
                XCTAssertEqual(plan.operation, .restore)
                XCTAssertEqual(plan.items.count, 1)
                XCTAssertTrue(plan.items[0].restartLaunchdAfterRestore)
                state.remove(plan.items[0].sourceURL.path)
                state.insert(plan.items[0].destinationURL.path)
                return .succeeded(loadedLaunchdItemIndexes: [])
            }
        )

        let outcomes = await service.restore([item])

        XCTAssertEqual(outcomes[item.id], .restored)
        XCTAssertTrue(state.contains(destination.path))
        XCTAssertFalse(state.contains(source.path))
    }

    func testGeneratedShellCommandTreatsMetacharactersAsLiteralArguments() throws {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let canonicalTemporaryPath = temporaryPath.hasPrefix("/var/")
            ? "/private\(temporaryPath)"
            : temporaryPath
        let root = URL(fileURLWithPath: canonicalTemporaryPath, isDirectory: true)
            .appendingPathComponent("AppSiftPrivilegedCommand-\(UUID().uuidString)", isDirectory: true)
        let allowed = root.appendingPathComponent("Allowed", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: trash.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let source = allowed.appendingPathComponent("odd '$() `name`\nitem")
        let destination = trash.appendingPathComponent("odd '$() `name`\nitem")
        try Data("literal".utf8).write(to: source)
        let plan = PrivilegedAppRemovalPlan(
            operation: .trash,
            currentUserID: getuid(),
            trashRoot: trash,
            allowedSourceRoots: [allowed],
            items: [
                PrivilegedAppRemovalPlan.Item(
                    originalURL: source,
                    sourceURL: source,
                    destinationURL: destination,
                    restartLaunchdAfterRestore: false
                ),
            ]
        )
        let command = PrivilegedAppRemovalCommandBuilder.command(
            for: plan,
            requireEffectiveRoot: false
        )
        let scriptSource = "do shell script \(PrivilegedAppRemovalAuthorizationRunner.appleScriptLiteral(command))"
        let script = try XCTUnwrap(NSAppleScript(source: scriptSource))
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error).stringValue ?? ""

        XCTAssertNil(error, String(describing: error))
        XCTAssertTrue(output.contains("APPSIFT_OK"), output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("literal".utf8))
    }

    func testGeneratedShellCommandRestoresToAnAllowedRoot() throws {
        let root = canonicalTemporaryRoot(prefix: "AppSiftPrivilegedRestore")
        let allowed = root.appendingPathComponent("Allowed", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: trash.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let source = trash.appendingPathComponent("restorable-item")
        let destination = allowed.appendingPathComponent("restorable-item")
        try Data("restore".utf8).write(to: source)
        let plan = PrivilegedAppRemovalPlan(
            operation: .restore,
            currentUserID: getuid(),
            trashRoot: trash,
            allowedSourceRoots: [allowed],
            items: [
                PrivilegedAppRemovalPlan.Item(
                    originalURL: destination,
                    sourceURL: source,
                    destinationURL: destination,
                    restartLaunchdAfterRestore: false
                ),
            ]
        )

        let result = try executeCommand(
            PrivilegedAppRemovalCommandBuilder.command(
                for: plan,
                requireEffectiveRoot: false
            )
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("APPSIFT_OK"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("restore".utf8))
    }

    func testGeneratedShellCommandRollsBackEarlierMoveWhenLaterMoveFails() throws {
        let root = canonicalTemporaryRoot(prefix: "AppSiftPrivilegedRollback")
        let allowed = root.appendingPathComponent("Allowed", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: trash.path
        )

        let firstSource = allowed.appendingPathComponent("first")
        let secondSource = allowed.appendingPathComponent("second")
        let firstDestination = trash.appendingPathComponent("first")
        let secondDestination = trash.appendingPathComponent("second")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        try FileManager.default.setAttributes(
            [.immutable: true],
            ofItemAtPath: secondSource.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false],
                ofItemAtPath: secondSource.path
            )
            try? FileManager.default.setAttributes(
                [.immutable: false],
                ofItemAtPath: secondDestination.path
            )
            try? FileManager.default.removeItem(at: root)
        }

        let plan = PrivilegedAppRemovalPlan(
            operation: .trash,
            currentUserID: getuid(),
            trashRoot: trash,
            allowedSourceRoots: [allowed],
            items: [
                PrivilegedAppRemovalPlan.Item(
                    originalURL: firstSource,
                    sourceURL: firstSource,
                    destinationURL: firstDestination,
                    restartLaunchdAfterRestore: false
                ),
                PrivilegedAppRemovalPlan.Item(
                    originalURL: secondSource,
                    sourceURL: secondSource,
                    destinationURL: secondDestination,
                    restartLaunchdAfterRestore: false
                ),
            ]
        )

        let result = try executeCommand(
            PrivilegedAppRemovalCommandBuilder.command(
                for: plan,
                requireEffectiveRoot: false
            )
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("APPSIFT_ROLLED_BACK|move"), result.output)
        XCTAssertEqual(try Data(contentsOf: firstSource), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: secondSource), Data("second".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstDestination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondDestination.path))
    }

    func testOversizedBatchIsRejectedBeforeAuthorization() async {
        let calls = LockedValue(0)
        let service = PrivilegedAppRemovalService(authorizationRunner: { _ in
            calls.withValue { $0 += 1 }
            return .failed("must not execute")
        })
        let urls = (0...PrivilegedAppRemovalService.maximumItemCount).map {
            URL(fileURLWithPath: "/Applications/Oversized-\($0).app")
        }

        let result = await service.trash(urls)

        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(result.failed.count, urls.count)
        XCTAssertTrue(result.failed.allSatisfy {
            result.failure(for: $0)?.kind == .batchTooLarge
        })
    }

    private func canonicalTemporaryRoot(prefix: String) -> URL {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let canonicalTemporaryPath = temporaryPath.hasPrefix("/var/")
            ? "/private\(temporaryPath)"
            : temporaryPath
        return URL(fileURLWithPath: canonicalTemporaryPath, isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func executeCommand(_ command: String) throws -> (status: Int32, output: String) {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (process.terminationStatus, output)
    }
}

private final class LockedPathSet: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String>

    init(_ paths: Set<String>) {
        self.paths = paths
    }

    convenience init(_ paths: [String]) {
        self.init(Set(paths))
    }

    func contains(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.contains(path)
    }

    func insert(_ path: String) {
        lock.lock()
        paths.insert(path)
        lock.unlock()
    }

    func remove(_ path: String) {
        lock.lock()
        paths.remove(path)
        lock.unlock()
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}
