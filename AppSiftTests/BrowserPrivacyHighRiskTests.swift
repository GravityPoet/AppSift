import Foundation
import SQLite3
import XCTest
@testable import AppSift

final class BrowserPrivacyHighRiskTests: XCTestCase {
    func testDisposableSafariChromeAndFirefoxProfilesIncludeOnlySupportedData() async throws {
        let home = try makeQATemporaryDirectory(prefix: "AppSiftBrowserProfiles")
        defer { try? FileManager.default.removeItem(at: home) }

        let safariRoot = home.appendingPathComponent("Library/Safari", isDirectory: true)
        try FileManager.default.createDirectory(at: safariRoot, withIntermediateDirectories: true)
        let safariHistory = safariRoot.appendingPathComponent("History.db")
        let safariDownloads = safariRoot.appendingPathComponent("Downloads.plist")
        try Data(repeating: 0x11, count: 512).write(to: safariHistory)
        try Data(repeating: 0x12, count: 256).write(to: safariDownloads)

        let chromeProfile = home.appendingPathComponent(
            "Library/Application Support/Google/Chrome/Default",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: chromeProfile, withIntermediateDirectories: true)
        let chromeHistory = chromeProfile.appendingPathComponent("History")
        let chromeCookies = chromeProfile.appendingPathComponent("Network/Cookies")
        let chromePasswords = chromeProfile.appendingPathComponent("Login Data")
        let chromeAutofill = chromeProfile.appendingPathComponent("Web Data")
        try FileManager.default.createDirectory(
            at: chromeCookies.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        for url in [chromeHistory, chromeCookies, chromePasswords, chromeAutofill] {
            try Data(repeating: 0x22, count: 512).write(to: url)
        }

        let firefoxProfile = home.appendingPathComponent(
            "Library/Application Support/Firefox/Profiles/qa.default-release",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: firefoxProfile, withIntermediateDirectories: true)
        let firefoxHistory = firefoxProfile.appendingPathComponent("places.sqlite")
        let firefoxCookies = firefoxProfile.appendingPathComponent("cookies.sqlite")
        let firefoxPasswords = firefoxProfile.appendingPathComponent("logins.json")
        try createFirefoxHistoryDatabase(at: firefoxHistory)
        try Data(repeating: 0x33, count: 512).write(to: firefoxCookies)
        try Data("do not touch".utf8).write(to: firefoxPasswords)

        let result = try await BrowserPrivacyScanner(homeURL: home).scan()
        let targets = result.groups.flatMap(\.targets)
        let targetPaths = Set(targets.map(\.url.path))

        let scannedPaths = targetPaths.sorted().joined(separator: "\n")
        XCTAssertTrue(targetPaths.contains(safariHistory.path), scannedPaths)
        XCTAssertTrue(targetPaths.contains(safariDownloads.path), scannedPaths)
        XCTAssertTrue(targetPaths.contains(chromeHistory.path), scannedPaths)
        XCTAssertTrue(targetPaths.contains(chromeCookies.path), scannedPaths)
        XCTAssertTrue(targetPaths.contains(firefoxHistory.path), scannedPaths)
        XCTAssertTrue(targetPaths.contains(firefoxCookies.path), scannedPaths)
        XCTAssertFalse(targetPaths.contains(chromePasswords.path))
        XCTAssertFalse(targetPaths.contains(chromeAutofill.path))
        XCTAssertFalse(targetPaths.contains(firefoxPasswords.path))
        XCTAssertEqual(
            targets.first(where: { $0.url == firefoxHistory })?.action,
            .firefoxHistoryDatabase
        )
        XCTAssertEqual(result.inaccessibleCount, 0)
        XCTAssertFalse(result.wasTruncated)
    }

    func testFirefoxSQLiteCleanupCreatesBackupAndUndoRestoresExactHistory() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftFirefoxSQLite")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let profile = home.appendingPathComponent(
            "Library/Application Support/Firefox/Profiles/qa.default-release",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let databaseURL = profile.appendingPathComponent("places.sqlite")
        try createFirefoxHistoryDatabase(at: databaseURL)
        let backupRoot = root.appendingPathComponent("Backups", isDirectory: true)
        let backupStore = BrowserPrivacyDatabaseBackupStore(rootURL: backupRoot)
        let trashService = try makeQATrashService(
            historyURL: root.appendingPathComponent("TrashHistory/history.json"),
            trashRoot: root.appendingPathComponent("Trash", isDirectory: true)
        )
        let controller = BrowserPrivacyController(
            trashService: trashService,
            backupStore: backupStore
        )
        let groups = try await BrowserPrivacyScanner(homeURL: home).scan().groups.filter {
            $0.browser == .firefox && $0.kind == .historyAndDownloads
        }
        let scannedDatabaseURL = try XCTUnwrap(groups.first?.targets.first?.url)
        XCTAssertEqual(scannedDatabaseURL.path, databaseURL.path)
        XCTAssertEqual(
            sqliteOpenStatusWithNoFollow(at: scannedDatabaseURL),
            SQLITE_OK,
            scannedDatabaseURL.path
        )

        let outcome = await controller.clean(groups)

        XCTAssertEqual(
            outcome.databaseCleanedCount,
            1,
            outcome.failures.joined(separator: "\n")
        )
        XCTAssertTrue(outcome.failures.isEmpty, outcome.failures.joined(separator: "\n"))
        XCTAssertEqual(try sqliteInteger(at: databaseURL, sql: "SELECT COUNT(*) FROM moz_historyvisits"), 0)
        XCTAssertEqual(try sqliteInteger(at: databaseURL, sql: "SELECT COUNT(*) FROM moz_inputhistory"), 0)
        XCTAssertEqual(
            try sqliteInteger(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM moz_annos WHERE anno_attribute_id = 1"
            ),
            0
        )
        XCTAssertEqual(try sqliteInteger(at: databaseURL, sql: "SELECT frecency FROM moz_places WHERE id = 1"), 100)
        XCTAssertEqual(try sqliteInteger(at: databaseURL, sql: "SELECT frecency FROM moz_places WHERE id = 2"), -1)
        let record = try XCTUnwrap(backupStore.snapshot().first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.backupPath))
        let rollbackBytes = try Data(contentsOf: URL(fileURLWithPath: record.backupPath))
        let wal = URL(fileURLWithPath: databaseURL.path + "-wal")
        let shm = URL(fileURLWithPath: databaseURL.path + "-shm")
        try Data([0]).write(to: wal)
        try Data([0]).write(to: shm)

        try await controller.undoDatabase(record)

        XCTAssertEqual(try sqliteInteger(at: databaseURL, sql: "SELECT COUNT(*) FROM moz_historyvisits"), 2)
        XCTAssertEqual(try sqliteInteger(at: databaseURL, sql: "SELECT COUNT(*) FROM moz_inputhistory"), 1)
        XCTAssertEqual(
            try sqliteInteger(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM moz_annos WHERE anno_attribute_id = 1"
            ),
            1
        )
        XCTAssertEqual(try sqliteInteger(at: databaseURL, sql: "SELECT visit_count FROM moz_places WHERE id = 2"), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shm.path))
        XCTAssertEqual(try Data(contentsOf: databaseURL), rollbackBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.backupPath))
        XCTAssertNotNil(backupStore.snapshot().first?.restoredAt)
    }

    func testFirefoxUndoRefusesToOverwriteHistoryAddedAfterCleanup() async throws {
        let fixture = try makeFirefoxControllerFixture(prefix: "AppSiftFirefoxChanged")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let groups = try await BrowserPrivacyScanner(homeURL: fixture.home).scan().groups.filter {
            $0.browser == .firefox && $0.kind == .historyAndDownloads
        }
        let outcome = await fixture.controller.clean(groups)
        XCTAssertEqual(
            outcome.databaseCleanedCount,
            1,
            outcome.failures.joined(separator: "\n")
        )
        let record = try XCTUnwrap(fixture.backupStore.snapshot().first)
        try await Task.sleep(nanoseconds: 25_000_000)
        try executeSQLite(
            at: fixture.databaseURL,
            sql: "INSERT INTO moz_historyvisits(id, place_id) VALUES (99, 1)"
        )

        do {
            try await fixture.controller.undoDatabase(record)
            XCTFail("Undo must not overwrite browser history created after cleanup.")
        } catch BrowserPrivacyError.databaseChanged {
            // Expected safety stop.
        }

        XCTAssertEqual(
            try sqliteInteger(at: fixture.databaseURL, sql: "SELECT COUNT(*) FROM moz_historyvisits"),
            1
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.backupPath))
    }

    func testManifestWriteFailureRestoresFirefoxDatabaseImmediately() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftFirefoxManifestFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let profile = home.appendingPathComponent(
            "Library/Application Support/Firefox/Profiles/qa.default-release",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let databaseURL = profile.appendingPathComponent("places.sqlite")
        try createFirefoxHistoryDatabase(at: databaseURL)
        let backupRoot = root.appendingPathComponent("Backups", isDirectory: true)
        let manifestAsDirectory = backupRoot.appendingPathComponent("manifest.json", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestAsDirectory, withIntermediateDirectories: true)
        let backupStore = BrowserPrivacyDatabaseBackupStore(rootURL: backupRoot)
        let controller = BrowserPrivacyController(backupStore: backupStore)
        let groups = try await BrowserPrivacyScanner(homeURL: home).scan().groups.filter {
            $0.browser == .firefox && $0.kind == .historyAndDownloads
        }

        let outcome = await controller.clean(groups)

        XCTAssertEqual(outcome.databaseCleanedCount, 0)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(try sqliteInteger(at: databaseURL, sql: "SELECT COUNT(*) FROM moz_historyvisits"), 2)
        XCTAssertEqual(try sqliteInteger(at: databaseURL, sql: "SELECT visit_count FROM moz_places WHERE id = 2"), 1)
        XCTAssertTrue(backupStore.snapshot().isEmpty)
    }

    private func makeFirefoxControllerFixture(prefix: String) throws -> (
        root: URL,
        home: URL,
        databaseURL: URL,
        backupStore: BrowserPrivacyDatabaseBackupStore,
        controller: BrowserPrivacyController
    ) {
        let root = try makeQATemporaryDirectory(prefix: prefix)
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let profile = home.appendingPathComponent(
            "Library/Application Support/Firefox/Profiles/qa.default-release",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let databaseURL = profile.appendingPathComponent("places.sqlite")
        try createFirefoxHistoryDatabase(at: databaseURL)
        let backupStore = BrowserPrivacyDatabaseBackupStore(
            rootURL: root.appendingPathComponent("Backups", isDirectory: true)
        )
        return (
            root,
            home,
            databaseURL,
            backupStore,
            BrowserPrivacyController(backupStore: backupStore)
        )
    }

    private func createFirefoxHistoryDatabase(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try executeSQLite(
            at: url,
            sql: """
            CREATE TABLE moz_places (
                id INTEGER PRIMARY KEY,
                visit_count INTEGER,
                typed INTEGER,
                last_visit_date INTEGER,
                frecency INTEGER
            );
            CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, place_id INTEGER);
            CREATE TABLE moz_inputhistory (place_id INTEGER, input TEXT, use_count REAL);
            CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, fk INTEGER);
            CREATE TABLE moz_anno_attributes (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE moz_annos (id INTEGER PRIMARY KEY, anno_attribute_id INTEGER);
            INSERT INTO moz_places VALUES (1, 1, 1, 1000, 100);
            INSERT INTO moz_places VALUES (2, 1, 1, 2000, 80);
            INSERT INTO moz_historyvisits VALUES (1, 1);
            INSERT INTO moz_historyvisits VALUES (2, 2);
            INSERT INTO moz_inputhistory VALUES (1, 'exa', 1.0);
            INSERT INTO moz_bookmarks VALUES (1, 1);
            INSERT INTO moz_anno_attributes VALUES (1, 'downloads/destinationFileURI');
            INSERT INTO moz_anno_attributes VALUES (2, 'other/annotation');
            INSERT INTO moz_annos VALUES (1, 1);
            INSERT INTO moz_annos VALUES (2, 2);
            """
        )
    }

    private func executeSQLite(at url: URL, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK,
        let database else {
            if let database { sqlite3_close(database) }
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard status == SQLITE_OK else {
            let detail = errorMessage.map { String(cString: $0) } ?? "SQLite error \(status)"
            throw NSError(domain: "BrowserPrivacyHighRiskTests.SQLite", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: detail,
            ])
        }
    }

    private func sqliteInteger(at url: URL, sql: String) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK,
        let database else {
            if let database { sqlite3_close(database) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func sqliteOpenStatusWithNoFollow(at url: URL) -> Int32 {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
            nil
        )
        if let database { sqlite3_close(database) }
        return status
    }
}
