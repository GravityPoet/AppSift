import Foundation
import SQLite3
import XCTest
@testable import AppSift

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class AppPermissionScannerTests: XCTestCase {
    func testReadsEvidenceAndMergesInstalledAndStaleClients() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.root.appendingPathComponent("TCC.db")
        try createDatabase(at: databaseURL, currentSchema: true)
        try insert(
            into: databaseURL,
            service: AppPermissionService.camera.rawValue,
            client: "com.example.CameraApp",
            clientType: 0,
            authorizationValue: 0,
            authorizationReason: 4,
            indirectObject: "UNUSED",
            lastModified: 1_750_000_000
        )
        try insert(
            into: databaseURL,
            service: AppPermissionService.screenRecording.rawValue,
            client: "com.example.CameraApp",
            clientType: 0,
            authorizationValue: 2,
            authorizationReason: 2,
            indirectObject: "UNUSED",
            lastModified: 1_750_000_100
        )
        try insert(
            into: databaseURL,
            service: AppPermissionService.appleEvents.rawValue,
            client: "com.example.CameraApp",
            clientType: 0,
            authorizationValue: 2,
            authorizationReason: 2,
            indirectObject: "com.apple.Finder",
            lastModified: 1_750_000_200
        )
        try insert(
            into: databaseURL,
            service: AppPermissionService.microphone.rawValue,
            client: "com.example.Removed",
            clientType: 0,
            authorizationValue: 2,
            authorizationReason: nil,
            indirectObject: nil,
            lastModified: nil
        )

        let appURL = try makeApplication(
            in: fixture.root,
            name: "Camera App",
            bundleIdentifier: "com.example.CameraApp",
            purposeStrings: [
                "NSCameraUsageDescription": "  Take\nphotos for calls.  ",
                "NSMicrophoneUsageDescription": "Record call audio.",
            ]
        )
        let result = AppPermissionScanner.scan(
            applications: [
                AppPermissionApplicationReference(
                    name: "Camera App",
                    bundleIdentifier: "com.example.CameraApp",
                    url: appURL,
                    version: "1.2"
                ),
            ],
            databaseLocations: [
                .init(scope: .system, url: databaseURL),
            ]
        )

        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources[0].status, .available)
        XCTAssertEqual(result.sources[0].rowCount, 4)
        XCTAssertEqual(result.recordCount, 4)
        XCTAssertEqual(result.allowedCount, 3)
        XCTAssertEqual(result.deniedCount, 1)
        XCTAssertEqual(result.staleClientCount, 1)

        let installed = try XCTUnwrap(
            result.clients.first { $0.bundleIdentifier == "com.example.CameraApp" }
        )
        XCTAssertTrue(installed.isInstalled)
        XCTAssertEqual(installed.name, "Camera App")
        XCTAssertEqual(installed.version, "1.2")
        XCTAssertEqual(installed.records.count, 3)
        XCTAssertEqual(installed.highImpactAllowedCount, 2)
        XCTAssertEqual(Set(installed.declarations.map(\.service)), [
            .camera,
            .microphone,
        ])
        XCTAssertEqual(
            installed.declarations.first { $0.service == .camera }?.purpose,
            "Take photos for calls."
        )
        XCTAssertEqual(
            installed.records.first { $0.service == .appleEvents }?
                .indirectObjectIdentifier,
            "com.apple.Finder"
        )

        let stale = try XCTUnwrap(
            result.clients.first { $0.bundleIdentifier == "com.example.Removed" }
        )
        XCTAssertFalse(stale.isInstalled)
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.allowedCount, 1)
    }

    func testDeclarationOnlyApplicationRemainsVisible() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.root.appendingPathComponent("TCC.db")
        try createDatabase(at: databaseURL, currentSchema: true)
        let appURL = try makeApplication(
            in: fixture.root,
            name: "Declared App",
            bundleIdentifier: "com.example.Declared",
            purposeStrings: [
                "NSContactsUsageDescription": "Find people you choose.",
            ]
        )

        let result = AppPermissionScanner.scan(
            applications: [
                .init(
                    name: "Declared App",
                    bundleIdentifier: "com.example.Declared",
                    url: appURL
                ),
            ],
            databaseLocations: [.init(scope: .user, url: databaseURL)]
        )

        XCTAssertEqual(result.clients.count, 1)
        XCTAssertTrue(result.clients[0].isInstalled)
        XCTAssertFalse(result.clients[0].hasObservedDecision)
        XCTAssertEqual(result.clients[0].declarations.map(\.service), [.addressBook])
    }

    func testOptionalLegacyColumnsAreNotRequired() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.root.appendingPathComponent("TCC.db")
        try createDatabase(at: databaseURL, currentSchema: false)
        try insertLegacy(
            into: databaseURL,
            service: AppPermissionService.calendar.rawValue,
            client: "com.example.Calendar",
            authorizationValue: 3
        )

        let result = AppPermissionScanner.scan(
            applications: [],
            databaseLocations: [.init(scope: .user, url: databaseURL)]
        )

        XCTAssertEqual(result.sources[0].status, .available)
        XCTAssertEqual(result.clients[0].records[0].decision, .limited)
        XCTAssertNil(result.clients[0].records[0].authorizationReason)
        XCTAssertNil(result.clients[0].records[0].lastModified)
    }

    func testUnsupportedSchemaIsExplicitInsteadOfLookingEmpty() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.root.appendingPathComponent("TCC.db")
        try execute(
            "CREATE TABLE access (service TEXT, client TEXT);",
            at: databaseURL
        )

        let result = AppPermissionScanner.scan(
            applications: [],
            databaseLocations: [.init(scope: .system, url: databaseURL)]
        )

        XCTAssertEqual(result.sources[0].status, .unsupportedSchema)
        XCTAssertFalse(result.hasReadableDatabase)
        XCTAssertTrue(result.clients.isEmpty)
    }

    func testRowLimitIsEnforced() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.root.appendingPathComponent("TCC.db")
        try createDatabase(at: databaseURL, currentSchema: true)
        for index in 0..<5 {
            try insert(
                into: databaseURL,
                service: AppPermissionService.camera.rawValue,
                client: "com.example.App\(index)",
                clientType: 0,
                authorizationValue: 2,
                authorizationReason: nil,
                indirectObject: nil,
                lastModified: Int64(1_750_000_000 + index)
            )
        }

        let result = AppPermissionScanner.scan(
            applications: [],
            databaseLocations: [.init(scope: .system, url: databaseURL)],
            maximumRowsPerDatabase: 3
        )

        XCTAssertTrue(result.wasTruncated)
        XCTAssertEqual(result.recordCount, 3)
        XCTAssertEqual(result.sources[0].rowCount, 3)
    }

    func testSymlinkDatabaseIsNeverFollowed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let databaseURL = fixture.root.appendingPathComponent("TCC.db")
        let symlinkURL = fixture.root.appendingPathComponent("Linked.db")
        try createDatabase(at: databaseURL, currentSchema: true)
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: databaseURL
        )

        let result = AppPermissionScanner.scan(
            applications: [],
            databaseLocations: [.init(scope: .system, url: symlinkURL)]
        )

        XCTAssertEqual(result.sources[0].status, .readFailed)
        XCTAssertFalse(result.hasReadableDatabase)
    }

    func testUnknownServiceRemainsVisibleButCannotBecomeResetArgument() {
        let service = AppPermissionService(rawValue: "kTCCServiceFuturePrivateData")

        XCTAssertEqual(service.category, .other)
        XCTAssertEqual(service.displayNameKey, "FuturePrivateData")
        XCTAssertNil(service.resetServiceName)
        XCTAssertNil(service.systemSettingsAnchor)
    }

    private func makeFixture() throws -> (root: URL, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSift-AppPermissionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return (root, { try? FileManager.default.removeItem(at: root) })
    }

    private func makeApplication(
        in root: URL,
        name: String,
        bundleIdentifier: String,
        purposeStrings: [String: String]
    ) throws -> URL {
        let appURL = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        var propertyList: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": name,
        ]
        propertyList.merge(purposeStrings) { _, new in new }
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return appURL
    }

    private func createDatabase(at url: URL, currentSchema: Bool) throws {
        let sql: String
        if currentSchema {
            sql = """
            CREATE TABLE access (
                service TEXT NOT NULL,
                client TEXT NOT NULL,
                client_type INTEGER NOT NULL,
                auth_value INTEGER NOT NULL,
                auth_reason INTEGER,
                indirect_object_identifier TEXT,
                last_modified INTEGER
            );
            """
        } else {
            sql = """
            CREATE TABLE access (
                service TEXT NOT NULL,
                client TEXT NOT NULL,
                client_type INTEGER NOT NULL,
                auth_value INTEGER NOT NULL
            );
            """
        }
        try execute(sql, at: url)
    }

    private func insert(
        into url: URL,
        service: String,
        client: String,
        clientType: Int32,
        authorizationValue: Int64,
        authorizationReason: Int64?,
        indirectObject: String?,
        lastModified: Int64?
    ) throws {
        try withDatabase(at: url) { database in
            var statement: OpaquePointer?
            let sql = """
            INSERT INTO access (
                service, client, client_type, auth_value, auth_reason,
                indirect_object_identifier, last_modified
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """
            XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
            guard let statement else { throw CocoaError(.fileWriteUnknown) }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, service, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, client, -1, sqliteTransient)
            sqlite3_bind_int(statement, 3, clientType)
            sqlite3_bind_int64(statement, 4, authorizationValue)
            if let authorizationReason {
                sqlite3_bind_int64(statement, 5, authorizationReason)
            } else {
                sqlite3_bind_null(statement, 5)
            }
            if let indirectObject {
                sqlite3_bind_text(statement, 6, indirectObject, -1, sqliteTransient)
            } else {
                sqlite3_bind_null(statement, 6)
            }
            if let lastModified {
                sqlite3_bind_int64(statement, 7, lastModified)
            } else {
                sqlite3_bind_null(statement, 7)
            }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
    }

    private func insertLegacy(
        into url: URL,
        service: String,
        client: String,
        authorizationValue: Int64
    ) throws {
        try withDatabase(at: url) { database in
            var statement: OpaquePointer?
            let sql = "INSERT INTO access (service, client, client_type, auth_value) VALUES (?, ?, 0, ?)"
            XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
            guard let statement else { throw CocoaError(.fileWriteUnknown) }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, service, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, client, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 3, authorizationValue)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
    }

    private func execute(_ sql: String, at url: URL) throws {
        try withDatabase(at: url) { database in
            var error: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(database, sql, nil, nil, &error)
            let detail = error.map { String(cString: $0) }
            if let error { sqlite3_free(error) }
            if result != SQLITE_OK {
                throw NSError(
                    domain: "AppPermissionScannerTests",
                    code: Int(result),
                    userInfo: [NSLocalizedDescriptionKey: detail ?? "SQLite error"]
                )
            }
        }
    }

    private func withDatabase(
        at url: URL,
        operation: (OpaquePointer) throws -> Void
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        try operation(database)
    }
}
