import AppKit
import Darwin
import Foundation

enum InstallationFileRemovalStatus: String, Codable, Hashable, Sendable {
    case movedToTrash
    case alreadyMissing
    case rejected
    case trashFailed
    case rolledBackAfterHistoryFailure
    case rollbackFailedAfterHistoryFailure
}

struct InstallationFileRemovalHistoryItem: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let originalPath: String
    var trashPath: String?
    let name: String
    let kind: InstallationFileKind
    let size: Int64
    let fingerprint: InstallationFileFingerprint
    var status: InstallationFileRemovalStatus
    var detail: String?
    var restoredAt: Date?

    init(
        id: UUID = UUID(),
        originalPath: String,
        trashPath: String?,
        name: String,
        kind: InstallationFileKind,
        size: Int64,
        fingerprint: InstallationFileFingerprint,
        status: InstallationFileRemovalStatus,
        detail: String? = nil,
        restoredAt: Date? = nil
    ) {
        self.id = id
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.name = name
        self.kind = kind
        self.size = size
        self.fingerprint = fingerprint
        self.status = status
        self.detail = detail
        self.restoredAt = restoredAt
    }
}

struct InstallationFileRemovalRecord: Codable, Identifiable, Hashable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let removedAt: Date
    var items: [InstallationFileRemovalHistoryItem]

    init(
        schemaVersion: Int = 1,
        id: UUID = UUID(),
        removedAt: Date = Date(),
        items: [InstallationFileRemovalHistoryItem]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.removedAt = removedAt
        self.items = items
    }
}

struct InstallationFileRemovalOutcome: Sendable {
    let items: [InstallationFileRemovalHistoryItem]
    let record: InstallationFileRemovalRecord?
    let historyPersisted: Bool

    var movedCount: Int { items.count { $0.status == .movedToTrash } }
    var missingCount: Int { items.count { $0.status == .alreadyMissing } }
    var failedCount: Int {
        items.count {
            $0.status == .rejected
                || $0.status == .trashFailed
                || $0.status == .rollbackFailedAfterHistoryFailure
        }
    }
    var rolledBackCount: Int {
        items.count { $0.status == .rolledBackAfterHistoryFailure }
    }
}

struct InstallationFileUndoOutcome: Sendable {
    let record: InstallationFileRemovalRecord
    let restoredCount: Int
    let failedCount: Int
    let historyPersisted: Bool
    let rollbackFailed: Bool
}

struct InstallationFileRecycleResult: Sendable {
    let recycled: [URL: URL]
    let errorDescription: String?
}

final class InstallationFileRemovalHistoryStore: @unchecked Sendable {
    static let shared = InstallationFileRemovalHistoryStore()

    private static let maximumRecords = 100
    private static let maximumBytes = 512_000

    private let fileURL: URL
    private let currentUserID: uid_t
    private let lock = NSLock()
    private var records: [InstallationFileRemovalRecord]

    init(
        fileURL: URL = InstallationFileRemovalHistoryStore.defaultFileURL,
        currentUserID: uid_t = getuid()
    ) {
        self.fileURL = fileURL
        self.currentUserID = currentUserID
        self.records = Self.load(
            from: fileURL,
            currentUserID: currentUserID
        )
    }

    func snapshot() -> [InstallationFileRemovalRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    @discardableResult
    func append(_ record: InstallationFileRemovalRecord) -> Bool {
        guard Self.isValid(record) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard !records.contains(where: { $0.id == record.id }) else {
            return false
        }
        let previous = records
        records.insert(record, at: 0)
        if records.count > Self.maximumRecords {
            records.removeLast(records.count - Self.maximumRecords)
        }
        while records.count > 1,
              let data = try? JSONEncoder().encode(records),
              data.count > Self.maximumBytes {
            records.removeLast()
        }
        guard persistLocked() else {
            records = previous
            return false
        }
        return true
    }

    @discardableResult
    func markRestored(
        recordID: UUID,
        itemIDs: Set<UUID>,
        at date: Date
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let recordIndex = records.firstIndex(where: { $0.id == recordID }) else {
            return false
        }
        let previous = records
        var changed = false
        for itemIndex in records[recordIndex].items.indices
        where itemIDs.contains(records[recordIndex].items[itemIndex].id) {
            records[recordIndex].items[itemIndex].restoredAt = date
            changed = true
        }
        guard changed, persistLocked() else {
            records = previous
            return false
        }
        return true
    }

    private func persistLocked() -> Bool {
        guard let data = try? JSONEncoder().encode(records),
              data.count <= Self.maximumBytes else {
            return false
        }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
            guard Self.isSafeContainer(
                directory,
                currentUserID: currentUserID
            ),
            !Self.isSymbolicLink(fileURL) else {
                return false
            }
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: fileURL.path
            )
            return Self.isSafeHistoryFile(
                fileURL,
                currentUserID: currentUserID
            )
        } catch {
            Logger.shared.log(
                "Could not persist installation-file history: \(error.localizedDescription)",
                level: .warning
            )
            return false
        }
    }

    private static func load(
        from fileURL: URL,
        currentUserID: uid_t
    ) -> [InstallationFileRemovalRecord] {
        guard isSafeContainer(
            fileURL.deletingLastPathComponent(),
            currentUserID: currentUserID
        ),
        isSafeHistoryFile(fileURL, currentUserID: currentUserID),
        let values = try? fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
        ]),
        values.isRegularFile == true,
        let size = values.fileSize,
        size > 0,
        size <= maximumBytes,
        let data = try? Data(contentsOf: fileURL),
        data.count <= maximumBytes,
        let decoded = try? JSONDecoder().decode(
            [InstallationFileRemovalRecord].self,
            from: data
        ),
        decoded.count <= maximumRecords,
        Set(decoded.map(\.id)).count == decoded.count,
        decoded.allSatisfy(isValid) else {
            return []
        }
        return decoded.sorted { $0.removedAt > $1.removedAt }
    }

    private static func isValid(_ record: InstallationFileRemovalRecord) -> Bool {
        guard record.schemaVersion == 1,
              !record.items.isEmpty,
              record.items.count <= 5_000,
              Set(record.items.map(\.id)).count == record.items.count else {
            return false
        }
        return record.items.allSatisfy { item in
            item.originalPath.hasPrefix("/")
                && item.originalPath.count <= 4_096
                && (item.trashPath == nil
                    || (item.trashPath!.hasPrefix("/")
                        && item.trashPath!.count <= 4_096))
                && !item.name.isEmpty
                && item.name.count <= 1_024
                && item.size >= 0
                && (item.detail?.count ?? 0) <= 1_024
        }
    }

    private static func isSafeContainer(
        _ directory: URL,
        currentUserID: uid_t
    ) -> Bool {
        var information = stat()
        guard lstat(directory.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == currentUserID,
              !InstallationFileScanner.pathContainsSymbolicLink(directory) else {
            return false
        }
        return true
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFLNK
    }

    private static func isSafeHistoryFile(
        _ url: URL,
        currentUserID: uid_t
    ) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == currentUserID,
              information.st_nlink == 1,
              information.st_mode & 0o077 == 0 else {
            return false
        }
        return true
    }

    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AppSift", isDirectory: true)
            .appendingPathComponent("installation-file-removal-history.json")
    }
}

final class InstallationFileController: @unchecked Sendable {
    typealias Recycler = @Sendable ([URL]) async -> InstallationFileRecycleResult
    typealias MoveOperation = @Sendable (URL, URL) throws -> Void

    private let homeURL: URL
    private let homeDeviceID: UInt64?
    private let trashURL: URL
    private let currentUserID: uid_t
    private let historyStore: InstallationFileRemovalHistoryStore
    private let recycler: Recycler
    private let moveOperation: MoveOperation

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        trashURL: URL? = nil,
        currentUserID: uid_t = getuid(),
        historyStore: InstallationFileRemovalHistoryStore = .shared,
        recycler: @escaping Recycler = InstallationFileController.defaultRecycler,
        moveOperation: @escaping MoveOperation = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    ) {
        let normalizedHomeURL = homeURL.standardizedFileURL
        self.homeURL = normalizedHomeURL
        self.homeDeviceID = InstallationFileScanner.deviceID(
            forExistingPath: normalizedHomeURL
        )
        self.trashURL = (trashURL
            ?? homeURL.appendingPathComponent(".Trash", isDirectory: true))
            .standardizedFileURL
        self.currentUserID = currentUserID
        self.historyStore = historyStore
        self.recycler = recycler
        self.moveOperation = moveOperation
    }

    func historySnapshot() -> [InstallationFileRemovalRecord] {
        historyStore.snapshot()
    }

    func canUndo(_ record: InstallationFileRemovalRecord) -> Bool {
        guard historyStore.snapshot().contains(where: { $0 == record }) else {
            return false
        }
        return record.items.contains { item in
            guard item.status == .movedToTrash,
                  item.restoredAt == nil,
                  let trashPath = item.trashPath else { return false }
            let source = URL(fileURLWithPath: trashPath).standardizedFileURL
            return isSafeTrashSource(source)
                && InstallationFileScanner.currentFingerprint(for: source)
                    == item.fingerprint
        }
    }

    func remove(
        _ items: [InstallationFileItem],
        explicitlyApprovedItemIDs: Set<String> = [],
        removedAt: Date = Date()
    ) async -> InstallationFileRemovalOutcome {
        var results: [InstallationFileRemovalHistoryItem] = []
        var validItems: [InstallationFileItem] = []
        var seen = Set<String>()

        for item in items {
            guard seen.insert(item.id).inserted else { continue }
            if !FileManager.default.fileExists(atPath: item.url.path) {
                results.append(historyItem(
                    for: item,
                    status: .alreadyMissing,
                    detail: "File was already missing."
                ))
            } else if let rejection = validationFailure(
                for: item,
                explicitlyApprovedItemIDs: explicitlyApprovedItemIDs
            ) {
                results.append(historyItem(
                    for: item,
                    status: .rejected,
                    detail: rejection
                ))
            } else {
                validItems.append(item)
            }
        }

        guard !validItems.isEmpty else {
            return InstallationFileRemovalOutcome(
                items: results,
                record: nil,
                historyPersisted: true
            )
        }

        let recycleResult = await recycler(validItems.map(\.url))
        let recycledByPath = Dictionary(
            uniqueKeysWithValues: recycleResult.recycled.map {
                ($0.key.standardizedFileURL.path, $0.value.standardizedFileURL)
            }
        )
        var movedMappings: [UUID: (original: URL, trash: URL)] = [:]
        for item in validItems {
            if let trash = recycledByPath[item.url.standardizedFileURL.path],
               isSafeTrashSource(trash),
               InstallationFileScanner.currentFingerprint(for: trash)
                    == item.fingerprint {
                var historyItem = historyItem(
                    for: item,
                    status: .movedToTrash,
                    detail: nil
                )
                historyItem.trashPath = trash.path
                movedMappings[historyItem.id] = (item.url, trash)
                results.append(historyItem)
            } else if !FileManager.default.fileExists(atPath: item.url.path) {
                results.append(historyItem(
                    for: item,
                    status: .trashFailed,
                    detail: "Finder did not return a recoverable Trash location."
                ))
            } else {
                results.append(historyItem(
                    for: item,
                    status: .trashFailed,
                    detail: recycleResult.errorDescription ?? "Finder could not move this file to Trash."
                ))
            }
        }

        guard !movedMappings.isEmpty else {
            return InstallationFileRemovalOutcome(
                items: results,
                record: nil,
                historyPersisted: true
            )
        }

        let record = InstallationFileRemovalRecord(
            removedAt: removedAt,
            items: results
        )
        if historyStore.append(record) {
            return InstallationFileRemovalOutcome(
                items: results,
                record: record,
                historyPersisted: true
            )
        }

        for index in results.indices {
            guard let mapping = movedMappings[results[index].id] else { continue }
            do {
                guard !FileManager.default.fileExists(atPath: mapping.original.path),
                      isSafeTrashSource(mapping.trash),
                      InstallationFileScanner.currentFingerprint(
                        for: mapping.trash
                      ) == results[index].fingerprint,
                      safeDestinationParent(for: mapping.original) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try moveOperation(mapping.trash, mapping.original)
                results[index].status = .rolledBackAfterHistoryFailure
                results[index].trashPath = nil
                results[index].detail = "Removal was rolled back because history could not be saved."
            } catch {
                results[index].status = .rollbackFailedAfterHistoryFailure
                results[index].detail = "History could not be saved and rollback failed: \(error.localizedDescription)"
            }
        }
        return InstallationFileRemovalOutcome(
            items: results,
            record: nil,
            historyPersisted: false
        )
    }

    func undo(
        _ record: InstallationFileRemovalRecord,
        restoredAt: Date = Date()
    ) -> InstallationFileUndoOutcome {
        guard canUndo(record) else {
            return InstallationFileUndoOutcome(
                record: record,
                restoredCount: 0,
                failedCount: 1,
                historyPersisted: true,
                rollbackFailed: false
            )
        }

        var restored: [(itemID: UUID, source: URL, destination: URL)] = []
        var failedCount = 0
        for item in record.items where item.status == .movedToTrash
            && item.restoredAt == nil {
            guard let trashPath = item.trashPath else {
                failedCount += 1
                continue
            }
            let source = URL(fileURLWithPath: trashPath).standardizedFileURL
            let destination = URL(fileURLWithPath: item.originalPath).standardizedFileURL
            guard isSafeTrashSource(source),
                  InstallationFileScanner.currentFingerprint(for: source) == item.fingerprint,
                  isPath(destination.path, inside: homeURL.path),
                  safeDestinationParent(for: destination),
                  !FileManager.default.fileExists(atPath: destination.path) else {
                failedCount += 1
                continue
            }
            do {
                try moveOperation(source, destination)
                restored.append((item.id, source, destination))
            } catch {
                failedCount += 1
            }
        }

        let restoredIDs = Set(restored.map(\.itemID))
        guard !restoredIDs.isEmpty else {
            return InstallationFileUndoOutcome(
                record: record,
                restoredCount: 0,
                failedCount: max(1, failedCount),
                historyPersisted: true,
                rollbackFailed: false
            )
        }
        if historyStore.markRestored(
            recordID: record.id,
            itemIDs: restoredIDs,
            at: restoredAt
        ) {
            let updated = historyStore.snapshot().first { $0.id == record.id }
                ?? record
            return InstallationFileUndoOutcome(
                record: updated,
                restoredCount: restored.count,
                failedCount: failedCount,
                historyPersisted: true,
                rollbackFailed: false
            )
        }

        var rollbackFailed = false
        for move in restored.reversed() {
            do {
                guard !FileManager.default.fileExists(atPath: move.source.path),
                      isSafeTrashDestination(move.source),
                      InstallationFileScanner.currentFingerprint(for: move.destination) != nil else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try moveOperation(move.destination, move.source)
            } catch {
                rollbackFailed = true
            }
        }
        return InstallationFileUndoOutcome(
            record: record,
            restoredCount: rollbackFailed ? restored.count : 0,
            failedCount: failedCount,
            historyPersisted: false,
            rollbackFailed: rollbackFailed
        )
    }

    private func validationFailure(
        for item: InstallationFileItem,
        explicitlyApprovedItemIDs: Set<String>
    ) -> String? {
        let url = item.url.standardizedFileURL
        guard isPath(url.path, inside: homeURL.path),
              !InstallationFileScanner.isIgnoredPath(url, homeURL: homeURL),
              !InstallationFileScanner.pathContainsSymbolicLink(url),
              InstallationFileScanner.kind(for: url) == item.kind,
              let fingerprint = InstallationFileScanner.currentFingerprint(for: url),
              fingerprint == item.fingerprint,
              fingerprint.ownerUserID == currentUserID,
              fingerprint.hardLinkCount == 1,
              safeDestinationParent(for: url) else {
            return "The file changed after the scan or no longer satisfies the removal boundary."
        }
        let currentEligibility = InstallationFileScanner.removalEligibility(
            for: url,
            fingerprint: fingerprint,
            homeURL: homeURL,
            homeDeviceID: homeDeviceID,
            currentUserID: currentUserID
        )
        guard currentEligibility == item.removalEligibility else {
            return "The file's removal boundary changed after the scan."
        }
        switch currentEligibility {
        case .eligible:
            return nil
        case .protected(.applicationManagedCache)
            where explicitlyApprovedItemIDs.contains(item.id):
            return nil
        case .protected:
            return "This scan marked the file as protected."
        }
    }

    private func historyItem(
        for item: InstallationFileItem,
        status: InstallationFileRemovalStatus,
        detail: String?
    ) -> InstallationFileRemovalHistoryItem {
        InstallationFileRemovalHistoryItem(
            originalPath: item.url.standardizedFileURL.path,
            trashPath: nil,
            name: item.name,
            kind: item.kind,
            size: item.size,
            fingerprint: item.fingerprint,
            status: status,
            detail: detail
        )
    }

    private func isSafeTrashSource(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard isPath(standardized.path, inside: trashURL.path),
              !InstallationFileScanner.pathContainsSymbolicLink(trashURL),
              !InstallationFileScanner.pathContainsSymbolicLink(
                standardized,
                stoppingAt: trashURL
              ),
              let fingerprint = InstallationFileScanner.currentFingerprint(
                for: standardized
              ),
              fingerprint.ownerUserID == currentUserID,
              fingerprint.hardLinkCount == 1 else {
            return false
        }
        return true
    }

    private func isSafeTrashDestination(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        return isPath(url.standardizedFileURL.path, inside: trashURL.path)
            && parent.path == trashURL.path
            && !InstallationFileScanner.pathContainsSymbolicLink(trashURL)
    }

    private func safeDestinationParent(for url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        var information = stat()
        return isPath(url.standardizedFileURL.path, inside: homeURL.path)
            && lstat(parent.path, &information) == 0
            && information.st_mode & S_IFMT == S_IFDIR
            && information.st_uid == currentUserID
            && !InstallationFileScanner.pathContainsSymbolicLink(parent)
    }

    private func isPath(_ path: String, inside root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private static let defaultRecycler: Recycler = { urls in
        guard !urls.isEmpty else {
            return InstallationFileRecycleResult(
                recycled: [:],
                errorDescription: nil
            )
        }
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                NSWorkspace.shared.recycle(urls) { recycled, error in
                    continuation.resume(returning: InstallationFileRecycleResult(
                        recycled: recycled,
                        errorDescription: error?.localizedDescription
                    ))
                }
            }
        }
    }
}
