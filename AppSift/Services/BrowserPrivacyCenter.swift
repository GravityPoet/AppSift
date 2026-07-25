import AppKit
import Darwin
import Foundation
import SQLite3

struct BrowserPrivacyDatabaseBackupRecord: Codable, Identifiable, Hashable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let browser: BrowserPrivacyBrowser
    let databasePath: String
    let backupPath: String
    let cleanedAt: Date
    let cleanedFingerprint: ReviewedTrashFingerprint
    var restoredAt: Date?
}

struct BrowserPrivacyCleanOutcome: Sendable {
    let trashOutcome: ReviewedTrashOutcome?
    let databaseCleanedCount: Int
    let failures: [String]
}

final class BrowserPrivacyDatabaseBackupStore: @unchecked Sendable {
    static let shared = BrowserPrivacyDatabaseBackupStore()

    private static let maximumRecords = 30
    private static let maximumManifestBytes = 256_000

    private let rootURL: URL
    private let manifestURL: URL
    private let currentUserID: uid_t
    private let lock = NSLock()
    private var records: [BrowserPrivacyDatabaseBackupRecord]

    init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AppSift/BrowserPrivacyBackups", isDirectory: true),
        currentUserID: uid_t = getuid()
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.manifestURL = self.rootURL.appendingPathComponent("manifest.json")
        self.currentUserID = currentUserID
        self.records = []
        self.records = load()
    }

    func snapshot() -> [BrowserPrivacyDatabaseBackupRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func makeBackupURL(recordID: UUID) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        try ensureRoot()
        let directory = rootURL.appendingPathComponent(recordID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        guard isOwnedDirectory(directory) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return directory.appendingPathComponent("places.sqlite")
    }

    @discardableResult
    func append(_ record: BrowserPrivacyDatabaseBackupRecord) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isValid(record), isSafeBackupFile(URL(fileURLWithPath: record.backupPath)) else {
            return false
        }
        let previous = records
        var prunedRecords: [BrowserPrivacyDatabaseBackupRecord] = []
        records.insert(record, at: 0)
        while records.count > Self.maximumRecords {
            prunedRecords.append(records.removeLast())
        }
        guard persistLocked() else {
            records = previous
            return false
        }
        prunedRecords.forEach(removeBackupDirectory)
        return true
    }

    @discardableResult
    func markRestored(_ record: BrowserPrivacyDatabaseBackupRecord) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return false }
        let previous = records
        records[index].restoredAt = Date()
        guard persistLocked() else {
            records = previous
            return false
        }
        removeBackupDirectory(for: record)
        return true
    }

    func discardBackup(recordID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        let directory = rootURL.appendingPathComponent(recordID.uuidString, isDirectory: true)
        if isDirectChild(directory, of: rootURL) { try? FileManager.default.removeItem(at: directory) }
    }

    private func load() -> [BrowserPrivacyDatabaseBackupRecord] {
        guard isOwnedDirectory(rootURL),
              isOwnedRegularFile(manifestURL),
              let values = try? manifestURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0,
              size <= Self.maximumManifestBytes,
              let data = try? Data(contentsOf: manifestURL, options: .mappedIfSafe),
              let decoded = try? JSONDecoder().decode([BrowserPrivacyDatabaseBackupRecord].self, from: data) else {
            return []
        }
        return decoded
            .filter { isValid($0) && isSafeBackupFile(URL(fileURLWithPath: $0.backupPath)) }
            .sorted { $0.cleanedAt > $1.cleanedAt }
            .prefix(Self.maximumRecords)
            .map { $0 }
    }

    private func persistLocked() -> Bool {
        do {
            try ensureRoot()
            let data = try JSONEncoder().encode(records)
            guard data.count <= Self.maximumManifestBytes else { return false }
            try data.write(to: manifestURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: manifestURL.path
            )
            return isOwnedRegularFile(manifestURL)
        } catch {
            Logger.shared.log(
                "Could not persist browser privacy backup manifest: \(error.localizedDescription)",
                level: .warning
            )
            return false
        }
    }

    private func ensureRoot() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: rootURL.path
        )
        guard isOwnedDirectory(rootURL) else { throw CocoaError(.fileWriteNoPermission) }
    }

    private func isValid(_ record: BrowserPrivacyDatabaseBackupRecord) -> Bool {
        record.schemaVersion == 1
            && record.databasePath.hasPrefix("/")
            && record.backupPath.hasPrefix(rootURL.path + "/")
            && !record.databasePath.contains("\0")
            && !record.backupPath.contains("\0")
    }

    private func isSafeBackupFile(_ url: URL) -> Bool {
        isDirectChild(url.deletingLastPathComponent(), of: rootURL)
            && url.lastPathComponent == "places.sqlite"
            && isOwnedDirectory(url.deletingLastPathComponent())
            && isOwnedRegularFile(url)
    }

    private func removeBackupDirectory(for record: BrowserPrivacyDatabaseBackupRecord) {
        let url = URL(fileURLWithPath: record.backupPath).deletingLastPathComponent()
        guard isDirectChild(url, of: rootURL), isOwnedDirectory(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func isDirectChild(_ child: URL, of root: URL) -> Bool {
        child.standardizedFileURL.deletingLastPathComponent().path == root.standardizedFileURL.path
    }

    private func isOwnedDirectory(_ url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFDIR
            && information.st_uid == currentUserID
            && information.st_mode & S_IWOTH == 0
    }

    private func isOwnedRegularFile(_ url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFREG
            && information.st_uid == currentUserID
            && information.st_mode & S_IWOTH == 0
    }
}

actor BrowserPrivacyController {
    static let featureIdentifier = "browser-privacy"

    private let trashService: ReviewedTrashService
    private let backupStore: BrowserPrivacyDatabaseBackupStore
    private let currentUserID: uid_t

    init(
        trashService: ReviewedTrashService = ReviewedTrashService(),
        backupStore: BrowserPrivacyDatabaseBackupStore = .shared,
        currentUserID: uid_t = getuid()
    ) {
        self.trashService = trashService
        self.backupStore = backupStore
        self.currentUserID = currentUserID
    }

    func trashHistory() async -> [ReviewedTrashRecord] {
        await trashService.history(feature: Self.featureIdentifier)
    }

    func databaseHistory() -> [BrowserPrivacyDatabaseBackupRecord] {
        backupStore.snapshot()
    }

    func clean(_ groups: [BrowserPrivacyGroup]) async -> BrowserPrivacyCleanOutcome {
        var trashCandidates: [ReviewedTrashCandidate] = []
        var databaseCount = 0
        var failures: [String] = []

        for group in groups {
            for target in group.targets {
                switch target.action {
                case .trash:
                    trashCandidates.append(
                        ReviewedTrashCandidate(
                            id: target.id,
                            name: "\(group.browser.displayName) · \(group.kind.title)",
                            url: target.url,
                            size: target.size,
                            fingerprint: target.fingerprint,
                            allowedRoot: target.allowedRoot,
                            requiresDirectChild: false
                        )
                    )
                case .firefoxHistoryDatabase:
                    do {
                        try cleanFirefoxHistory(target)
                        databaseCount += 1
                    } catch {
                        failures.append("\(target.url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        }

        let trashOutcome: ReviewedTrashOutcome?
        if trashCandidates.isEmpty {
            trashOutcome = nil
        } else {
            trashOutcome = await trashService.moveToTrash(
                trashCandidates,
                feature: Self.featureIdentifier
            )
            if let trashOutcome, !trashOutcome.historyPersisted {
                failures.append(String(localized: "File cleanup was rolled back because undo history could not be saved."))
            } else if let trashOutcome, trashOutcome.failedCount > 0 {
                failures.append(
                    String(
                        format: String(localized: "%lld browser data item(s) could not be moved to Trash."),
                        Int64(trashOutcome.failedCount)
                    )
                )
            }
        }
        return BrowserPrivacyCleanOutcome(
            trashOutcome: trashOutcome,
            databaseCleanedCount: databaseCount,
            failures: failures
        )
    }

    func undoTrash(_ record: ReviewedTrashRecord) async -> ReviewedTrashUndoOutcome {
        await trashService.undo(record)
    }

    func undoDatabase(_ record: BrowserPrivacyDatabaseBackupRecord) throws {
        let databaseURL = URL(fileURLWithPath: record.databasePath)
        let backupURL = URL(fileURLWithPath: record.backupPath)
        guard record.restoredAt == nil,
              ReviewedTrashFingerprint.read(at: databaseURL) == record.cleanedFingerprint,
              isOwnedRegularFile(databaseURL),
              isOwnedRegularFile(backupURL) else {
            throw BrowserPrivacyError.databaseChanged
        }

        let temporary = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(".appsift-restore-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: backupURL, to: temporary)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: temporary.path
            )
            _ = try FileManager.default.replaceItemAt(
                databaseURL,
                withItemAt: temporary,
                backupItemName: nil,
                options: []
            )
            removeSQLiteSidecars(databaseURL)
            guard backupStore.markRestored(record) else {
                throw BrowserPrivacyError.historySaveFailed
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func cleanFirefoxHistory(_ target: BrowserPrivacyTarget) throws {
        let databaseURL = target.url.standardizedFileURL
        guard target.action == .firefoxHistoryDatabase,
              isDescendant(databaseURL, of: target.allowedRoot),
              target.fingerprint.owner == UInt32(currentUserID),
              ReviewedTrashFingerprint.read(at: databaseURL) == target.fingerprint,
              isOwnedRegularFile(databaseURL) else {
            throw BrowserPrivacyError.unsafeDatabase
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw BrowserPrivacyError.couldNotOpenDatabase
        }
        var databaseWasClosed = false
        defer {
            if !databaseWasClosed { sqlite3_close(database) }
        }
        sqlite3_busy_timeout(database, 2_000)

        guard tableExists("moz_historyvisits", in: database),
              tableExists("moz_places", in: database) else {
            throw BrowserPrivacyError.unsupportedDatabase
        }

        let recordID = UUID()
        let backupURL = try backupStore.makeBackupURL(recordID: recordID)
        do {
            try backup(database, to: backupURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: backupURL.path
            )
            try execute("BEGIN IMMEDIATE", in: database)
            do {
                try execute("DELETE FROM moz_historyvisits", in: database)
                if tableExists("moz_inputhistory", in: database) {
                    try execute("DELETE FROM moz_inputhistory", in: database)
                }
                if tableExists("moz_annos", in: database),
                   tableExists("moz_anno_attributes", in: database) {
                    try execute(
                        """
                        DELETE FROM moz_annos
                        WHERE anno_attribute_id IN (
                            SELECT id FROM moz_anno_attributes
                            WHERE name LIKE 'downloads/%'
                        )
                        """,
                        in: database
                    )
                }
                if tableExists("moz_bookmarks", in: database) {
                    try execute(
                        """
                        UPDATE moz_places
                        SET visit_count = 0,
                            typed = 0,
                            last_visit_date = NULL,
                            frecency = CASE
                                WHEN id IN (SELECT fk FROM moz_bookmarks WHERE fk IS NOT NULL)
                                THEN frecency ELSE -1 END
                        """,
                        in: database
                    )
                } else {
                    try execute(
                        "UPDATE moz_places SET visit_count = 0, typed = 0, last_visit_date = NULL, frecency = -1",
                        in: database
                    )
                }
                try execute("COMMIT", in: database)
            } catch {
                _ = try? execute("ROLLBACK", in: database)
                throw error
            }
            _ = sqlite3_exec(database, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)

            guard let cleanedFingerprint = ReviewedTrashFingerprint.read(at: databaseURL) else {
                throw BrowserPrivacyError.databaseChanged
            }
            let record = BrowserPrivacyDatabaseBackupRecord(
                schemaVersion: 1,
                id: recordID,
                browser: .firefox,
                databasePath: databaseURL.path,
                backupPath: backupURL.path,
                cleanedAt: Date(),
                cleanedFingerprint: cleanedFingerprint,
                restoredAt: nil
            )
            guard backupStore.append(record) else {
                throw BrowserPrivacyError.historySaveFailed
            }
        } catch {
            sqlite3_close(database)
            databaseWasClosed = true
            self.restoreDatabase(databaseURL, from: backupURL)
            backupStore.discardBackup(recordID: recordID)
            throw error
        }
    }

    private func backup(_ source: OpaquePointer, to url: URL) throws {
        var destination: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
            nil
        ) == SQLITE_OK,
        let destination else {
            if let destination { sqlite3_close(destination) }
            throw BrowserPrivacyError.backupFailed
        }
        defer { sqlite3_close(destination) }
        guard let operation = sqlite3_backup_init(destination, "main", source, "main") else {
            throw BrowserPrivacyError.backupFailed
        }
        defer { sqlite3_backup_finish(operation) }
        guard sqlite3_backup_step(operation, -1) == SQLITE_DONE else {
            throw BrowserPrivacyError.backupFailed
        }
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw BrowserPrivacyError.databaseWriteFailed
        }
    }

    private func tableExists(_ name: String, in database: OpaquePointer) -> Bool {
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func restoreDatabase(_ databaseURL: URL, from backupURL: URL) {
        guard isOwnedRegularFile(backupURL) else { return }
        let temporary = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(".appsift-rollback-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: backupURL, to: temporary)
            _ = try FileManager.default.replaceItemAt(
                databaseURL,
                withItemAt: temporary,
                backupItemName: nil,
                options: []
            )
            removeSQLiteSidecars(databaseURL)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            Logger.shared.log("Firefox history rollback failed: \(error.localizedDescription)", level: .error)
        }
    }

    private func removeSQLiteSidecars(_ databaseURL: URL) {
        for suffix in ["-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            if isOwnedRegularFile(url) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func isOwnedRegularFile(_ url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFREG
            && information.st_uid == currentUserID
            && information.st_mode & S_IWOTH == 0
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path != rootPath && path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}

enum BrowserPrivacyError: LocalizedError {
    case unsafeDatabase
    case couldNotOpenDatabase
    case unsupportedDatabase
    case backupFailed
    case databaseWriteFailed
    case databaseChanged
    case historySaveFailed

    var errorDescription: String? {
        switch self {
        case .unsafeDatabase: return String(localized: "The browser database failed safety validation.")
        case .couldNotOpenDatabase: return String(localized: "The browser database could not be opened.")
        case .unsupportedDatabase: return String(localized: "This browser database schema is not supported safely.")
        case .backupFailed: return String(localized: "AppSift could not create a private rollback backup.")
        case .databaseWriteFailed: return String(localized: "The browser database cleanup failed and was rolled back.")
        case .databaseChanged: return String(localized: "The browser database changed after cleanup, so AppSift refused to overwrite newer data.")
        case .historySaveFailed: return String(localized: "AppSift could not save rollback history, so the database was restored.")
        }
    }
}

@MainActor
final class BrowserPrivacyCenter: ObservableObject {
    @Published private(set) var groups: [BrowserPrivacyGroup] = []
    @Published var selectedIDs: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var inaccessibleCount = 0
    @Published private(set) var wasTruncated = false
    @Published private(set) var trashHistory: [ReviewedTrashRecord] = []
    @Published private(set) var databaseHistory: [BrowserPrivacyDatabaseBackupRecord] = []
    @Published var errorMessage: String?
    @Published var actionMessage: String?

    private let scanner: BrowserPrivacyScanner
    private let controller: BrowserPrivacyController
    private var scanTask: Task<Void, Never>?

    init(
        scanner: BrowserPrivacyScanner = BrowserPrivacyScanner(),
        controller: BrowserPrivacyController = BrowserPrivacyController()
    ) {
        self.scanner = scanner
        self.controller = controller
        Task { await refreshHistory() }
    }

    var selectedGroups: [BrowserPrivacyGroup] {
        groups.filter { selectedIDs.contains($0.id) }
    }

    var selectedSize: Int64 {
        selectedGroups.reduce(0) { $0 + $1.allocatedSize }
    }

    var selectedBrowsers: Set<BrowserPrivacyBrowser> {
        Set(selectedGroups.map(\.browser))
    }

    var runningBrowsers: Set<BrowserPrivacyBrowser> {
        Set(BrowserPrivacyBrowser.allCases.filter { browser in
            !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier).isEmpty
        })
    }

    var latestUndoableTrashRecord: ReviewedTrashRecord? {
        trashHistory.first { $0.items.contains { $0.status == .movedToTrash && $0.restoredAt == nil } }
    }

    var latestUndoableDatabaseRecord: BrowserPrivacyDatabaseBackupRecord? {
        databaseHistory.first { $0.restoredAt == nil }
    }

    func scan() {
        guard !isScanning, !isCleaning else { return }
        scanTask?.cancel()
        isScanning = true
        errorMessage = nil
        actionMessage = nil
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await scanner.scan()
                guard !Task.isCancelled else { return }
                groups = result.groups
                selectedIDs.formIntersection(Set(result.groups.map(\.id)))
                inaccessibleCount = result.inaccessibleCount
                wasTruncated = result.wasTruncated
                hasScanned = true
                lastScanDate = Date()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                hasScanned = true
            }
            isScanning = false
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func cleanSelected() {
        let selected = selectedGroups
        guard !selected.isEmpty, !isCleaning else { return }
        isCleaning = true
        errorMessage = nil
        actionMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let failedToClose = await closeBrowsers(Set(selected.map(\.browser)))
            let cleanable = selected.filter { !failedToClose.contains($0.browser) }
            let outcome = await controller.clean(cleanable)
            await refreshHistory()
            selectedIDs.removeAll()
            isCleaning = false

            var failures = outcome.failures
            if !failedToClose.isEmpty {
                failures.append(
                    String(
                        format: String(localized: "Could not close: %@"),
                        failedToClose.map(\.displayName).sorted().joined(separator: ", ")
                    )
                )
            }
            if failures.isEmpty {
                let moved = outcome.trashOutcome?.movedCount ?? 0
                actionMessage = String(
                    format: String(localized: "Cleaned %lld browser data target(s)."),
                    Int64(moved + outcome.databaseCleanedCount)
                )
            } else {
                errorMessage = failures.joined(separator: "\n")
            }
            scan()
        }
    }

    func undoLatestTrash() {
        guard let record = latestUndoableTrashRecord, !isCleaning else { return }
        isCleaning = true
        Task { [weak self] in
            guard let self else { return }
            let outcome = await controller.undoTrash(record)
            await refreshHistory()
            isCleaning = false
            if outcome.failedCount > 0 || !outcome.historyPersisted {
                errorMessage = String(localized: "Some browser files could not be restored from Trash.")
            } else {
                actionMessage = String(format: String(localized: "%lld browser data item(s) restored."), Int64(outcome.restoredCount))
            }
            scan()
        }
    }

    func undoLatestDatabase() {
        guard let record = latestUndoableDatabaseRecord, !isCleaning else { return }
        isCleaning = true
        Task { [weak self] in
            guard let self else { return }
            let failed = await closeBrowsers([record.browser])
            guard failed.isEmpty else {
                errorMessage = String(format: String(localized: "Could not close: %@"), record.browser.displayName)
                isCleaning = false
                return
            }
            do {
                try await controller.undoDatabase(record)
                actionMessage = String(localized: "Firefox history database restored.")
            } catch {
                errorMessage = error.localizedDescription
            }
            await refreshHistory()
            isCleaning = false
            scan()
        }
    }

    private func refreshHistory() async {
        trashHistory = await controller.trashHistory()
        databaseHistory = await controller.databaseHistory()
    }

    private func closeBrowsers(
        _ browsers: Set<BrowserPrivacyBrowser>
    ) async -> Set<BrowserPrivacyBrowser> {
        for browser in browsers {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier) {
                app.terminate()
            }
        }
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            let running = Set(browsers.filter {
                !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleIdentifier).isEmpty
            })
            if running.isEmpty { return [] }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return Set(browsers.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleIdentifier).isEmpty
        })
    }
}
