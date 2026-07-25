import AppKit
import Darwin
import Foundation

enum DuplicateFileRemovalStatus: String, Codable, Hashable, Sendable {
    case movedToTrash
    case alreadyMissing
    case rejected
    case trashFailed
    case rolledBackAfterHistoryFailure
    case rollbackFailedAfterHistoryFailure
}

struct DuplicateFileRemovalHistoryItem: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let groupID: String
    let originalPath: String
    var trashPath: String?
    let name: String
    let size: Int64
    let contentHash: String
    let fingerprint: DuplicateFileFingerprint
    var status: DuplicateFileRemovalStatus
    var detail: String?
    var restoredAt: Date?

    init(
        id: UUID = UUID(),
        groupID: String,
        originalPath: String,
        trashPath: String?,
        name: String,
        size: Int64,
        contentHash: String,
        fingerprint: DuplicateFileFingerprint,
        status: DuplicateFileRemovalStatus,
        detail: String? = nil,
        restoredAt: Date? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.name = name
        self.size = size
        self.contentHash = contentHash
        self.fingerprint = fingerprint
        self.status = status
        self.detail = detail
        self.restoredAt = restoredAt
    }
}

struct DuplicateFileRemovalRecord: Codable, Identifiable, Hashable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let removedAt: Date
    var items: [DuplicateFileRemovalHistoryItem]

    init(
        schemaVersion: Int = 1,
        id: UUID = UUID(),
        removedAt: Date = Date(),
        items: [DuplicateFileRemovalHistoryItem]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.removedAt = removedAt
        self.items = items
    }
}

struct DuplicateFileRemovalOutcome: Sendable {
    let items: [DuplicateFileRemovalHistoryItem]
    let record: DuplicateFileRemovalRecord?
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

struct DuplicateFileUndoOutcome: Sendable {
    let record: DuplicateFileRemovalRecord
    let restoredCount: Int
    let failedCount: Int
    let historyPersisted: Bool
    let rollbackFailed: Bool
}

struct DuplicateFileRecycleResult: Sendable {
    let recycled: [URL: URL]
    let errorDescription: String?
}

final class DuplicateFileRemovalHistoryStore: @unchecked Sendable {
    static let shared = DuplicateFileRemovalHistoryStore()

    private static let maximumRecords = 100
    private static let maximumBytes = 1_000_000

    private let fileURL: URL
    private let currentUserID: uid_t
    private let lock = NSLock()
    private var records: [DuplicateFileRemovalRecord]

    init(
        fileURL: URL = DuplicateFileRemovalHistoryStore.defaultFileURL,
        currentUserID: uid_t = getuid()
    ) {
        self.fileURL = fileURL
        self.currentUserID = currentUserID
        self.records = Self.load(from: fileURL, currentUserID: currentUserID)
    }

    func snapshot() -> [DuplicateFileRemovalRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    @discardableResult
    func append(_ record: DuplicateFileRemovalRecord) -> Bool {
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
            guard Self.isSafeContainer(
                directory,
                currentUserID: currentUserID
            ) else {
                return false
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
            guard Self.isSafeContainer(directory, currentUserID: currentUserID),
                  !Self.isSymbolicLink(fileURL) else {
                return false
            }
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: fileURL.path
            )
            return Self.isSafeHistoryFile(fileURL, currentUserID: currentUserID)
        } catch {
            Logger.shared.log(
                "Could not persist duplicate-file history: \(error.localizedDescription)",
                level: .warning
            )
            return false
        }
    }

    private static func load(
        from fileURL: URL,
        currentUserID: uid_t
    ) -> [DuplicateFileRemovalRecord] {
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
            [DuplicateFileRemovalRecord].self,
            from: data
        ),
        decoded.count <= maximumRecords,
        Set(decoded.map(\.id)).count == decoded.count,
        decoded.allSatisfy(isValid) else {
            return []
        }
        return decoded.sorted { $0.removedAt > $1.removedAt }
    }

    private static func isValid(_ record: DuplicateFileRemovalRecord) -> Bool {
        guard record.schemaVersion == 1,
              !record.items.isEmpty,
              record.items.count <= 10_000,
              Set(record.items.map(\.id)).count == record.items.count else {
            return false
        }
        return record.items.allSatisfy { item in
            item.groupID.count <= 256
                && item.originalPath.hasPrefix("/")
                && item.originalPath.count <= 4_096
                && (item.trashPath == nil
                    || (item.trashPath!.hasPrefix("/")
                        && item.trashPath!.count <= 4_096))
                && !item.name.isEmpty
                && item.name.count <= 1_024
                && item.size >= 0
                && item.contentHash.count == 64
                && (item.detail?.count ?? 0) <= 1_024
        }
    }

    private static func isSafeContainer(
        _ directory: URL,
        currentUserID: uid_t
    ) -> Bool {
        var information = stat()
        guard lstat(directory.path, &information) == 0 else {
            return false
        }
        return information.st_mode & S_IFMT == S_IFDIR
            && information.st_uid == currentUserID
            && information.st_mode & 0o022 == 0
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
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFREG
            && information.st_uid == currentUserID
            && information.st_nlink == 1
            && information.st_mode & 0o077 == 0
    }

    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/AppSift",
                isDirectory: true
            )
            .appendingPathComponent("duplicate-file-removal-history.json")
    }
}

final class DuplicateFileRemovalController: @unchecked Sendable {
    typealias Recycler = @Sendable ([URL]) async -> DuplicateFileRecycleResult
    typealias MoveOperation = @Sendable (URL, URL) throws -> Void
    typealias TrashPathValidator = @Sendable (URL) -> Bool

    private let currentUserID: uid_t
    private let historyStore: DuplicateFileRemovalHistoryStore
    private let recycler: Recycler
    private let moveOperation: MoveOperation
    private let trashPathValidator: TrashPathValidator

    init(
        currentUserID: uid_t = getuid(),
        historyStore: DuplicateFileRemovalHistoryStore = .shared,
        recycler: @escaping Recycler = DuplicateFileRemovalController.defaultRecycler,
        moveOperation: @escaping MoveOperation = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        },
        trashPathValidator: TrashPathValidator? = nil
    ) {
        self.currentUserID = currentUserID
        self.historyStore = historyStore
        self.recycler = recycler
        self.moveOperation = moveOperation
        self.trashPathValidator = trashPathValidator ?? {
            DuplicateFileRemovalController.isRecognizedTrashPath(
                $0,
                currentUserID: currentUserID
            )
        }
    }

    func historySnapshot() -> [DuplicateFileRemovalRecord] {
        historyStore.snapshot()
    }

    func canUndo(_ record: DuplicateFileRemovalRecord) -> Bool {
        guard historyStore.snapshot().contains(where: { $0 == record }) else {
            return false
        }
        return record.items.contains { item in
            guard item.status == .movedToTrash,
                  item.restoredAt == nil,
                  let trashPath = item.trashPath else {
                return false
            }
            let source = URL(fileURLWithPath: trashPath).standardizedFileURL
            return isSafeTrashSource(source, fingerprint: item.fingerprint)
        }
    }

    func remove(
        groups: [DuplicateFileGroup],
        selectedItemIDs: Set<String>,
        removedAt: Date = Date()
    ) async -> DuplicateFileRemovalOutcome {
        var historyItems: [DuplicateFileRemovalHistoryItem] = []
        var validItems: [(item: DuplicateFileItem, group: DuplicateFileGroup)] = []
        var seen = Set<String>()

        for group in groups {
            let selected = group.files.filter { selectedItemIDs.contains($0.id) }
            guard !selected.isEmpty else { continue }

            guard group.files.contains(where: {
                !selectedItemIDs.contains($0.id)
            }) else {
                historyItems.append(contentsOf: selected.map {
                    historyItem(
                        for: $0,
                        group: group,
                        status: .rejected,
                        detail: "No unchanged verified copy would remain."
                    )
                })
                continue
            }

            var verifiedItems: [(item: DuplicateFileItem, group: DuplicateFileGroup)] = []
            for item in selected where seen.insert(item.id).inserted {
                let isVerified = await isCurrentVerifiedCopy(
                    item,
                    expectedHash: group.contentHash
                )
                if !FileManager.default.fileExists(atPath: item.url.path) {
                    historyItems.append(historyItem(
                        for: item,
                        group: group,
                        status: .alreadyMissing,
                        detail: "File was already missing."
                    ))
                } else if !item.isRemovalEligible
                    || !isOwnedSingleLinkFile(item)
                    || !isVerified {
                    historyItems.append(historyItem(
                        for: item,
                        group: group,
                        status: .rejected,
                        detail: "The file changed after scanning or is protected."
                    ))
                } else {
                    verifiedItems.append((item, group))
                }
            }

            if !verifiedItems.isEmpty {
                guard await hasVerifiedKeeper(
                    in: group,
                    selectedItemIDs: selectedItemIDs
                ) else {
                    historyItems.append(contentsOf: verifiedItems.map {
                        historyItem(
                            for: $0.item,
                            group: $0.group,
                            status: .rejected,
                            detail: "No unchanged verified copy would remain."
                        )
                    })
                    continue
                }
            }
            validItems.append(contentsOf: verifiedItems)
        }

        guard !validItems.isEmpty else {
            return DuplicateFileRemovalOutcome(
                items: historyItems,
                record: nil,
                historyPersisted: true
            )
        }

        let recycleResult = await recycler(validItems.map(\.item.url))
        let recycledByPath = Dictionary(
            uniqueKeysWithValues: recycleResult.recycled.map {
                ($0.key.standardizedFileURL.path, $0.value.standardizedFileURL)
            }
        )
        var movedMappings: [UUID: (original: URL, trash: URL)] = [:]
        for pair in validItems {
            let item = pair.item
            let group = pair.group
            if let trash = recycledByPath[item.url.standardizedFileURL.path],
               isSafeTrashSource(trash, fingerprint: item.fingerprint) {
                var result = historyItem(
                    for: item,
                    group: group,
                    status: .movedToTrash,
                    detail: nil
                )
                result.trashPath = trash.path
                movedMappings[result.id] = (item.url, trash)
                historyItems.append(result)
            } else if !FileManager.default.fileExists(atPath: item.url.path) {
                historyItems.append(historyItem(
                    for: item,
                    group: group,
                    status: .trashFailed,
                    detail: "Finder did not return a recoverable Trash location."
                ))
            } else {
                historyItems.append(historyItem(
                    for: item,
                    group: group,
                    status: .trashFailed,
                    detail: recycleResult.errorDescription
                        ?? "Finder could not move this file to Trash."
                ))
            }
        }

        guard !movedMappings.isEmpty else {
            return DuplicateFileRemovalOutcome(
                items: historyItems,
                record: nil,
                historyPersisted: true
            )
        }

        let record = DuplicateFileRemovalRecord(
            removedAt: removedAt,
            items: historyItems
        )
        if historyStore.append(record) {
            return DuplicateFileRemovalOutcome(
                items: historyItems,
                record: record,
                historyPersisted: true
            )
        }

        for index in historyItems.indices {
            guard let mapping = movedMappings[historyItems[index].id] else {
                continue
            }
            do {
                guard !FileManager.default.fileExists(atPath: mapping.original.path),
                      safeDestinationParent(for: mapping.original),
                      isSafeTrashSource(
                        mapping.trash,
                        fingerprint: historyItems[index].fingerprint
                      ) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try moveOperation(mapping.trash, mapping.original)
                historyItems[index].status = .rolledBackAfterHistoryFailure
                historyItems[index].trashPath = nil
                historyItems[index].detail =
                    "Removal was rolled back because history could not be saved."
            } catch {
                historyItems[index].status = .rollbackFailedAfterHistoryFailure
                historyItems[index].detail =
                    "History could not be saved and rollback failed: \(error.localizedDescription)"
            }
        }
        return DuplicateFileRemovalOutcome(
            items: historyItems,
            record: nil,
            historyPersisted: false
        )
    }

    func undo(
        _ record: DuplicateFileRemovalRecord,
        restoredAt: Date = Date()
    ) -> DuplicateFileUndoOutcome {
        guard canUndo(record) else {
            return DuplicateFileUndoOutcome(
                record: record,
                restoredCount: 0,
                failedCount: 1,
                historyPersisted: true,
                rollbackFailed: false
            )
        }

        var restored: [(
            itemID: UUID,
            source: URL,
            destination: URL,
            fingerprint: DuplicateFileFingerprint
        )] = []
        var failedCount = 0
        for item in record.items
        where item.status == .movedToTrash && item.restoredAt == nil {
            guard let trashPath = item.trashPath else {
                failedCount += 1
                continue
            }
            let source = URL(fileURLWithPath: trashPath).standardizedFileURL
            let destination = URL(
                fileURLWithPath: item.originalPath
            ).standardizedFileURL
            guard isSafeTrashSource(source, fingerprint: item.fingerprint),
                  safeDestinationParent(for: destination),
                  !FileManager.default.fileExists(atPath: destination.path) else {
                failedCount += 1
                continue
            }
            do {
                try moveOperation(source, destination)
                restored.append((
                    item.id,
                    source,
                    destination,
                    item.fingerprint
                ))
            } catch {
                failedCount += 1
            }
        }

        let restoredIDs = Set(restored.map(\.itemID))
        guard !restoredIDs.isEmpty else {
            return DuplicateFileUndoOutcome(
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
            return DuplicateFileUndoOutcome(
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
                      trashPathValidator(move.source),
                      DuplicateFileScanner.currentFingerprint(
                        for: move.destination
                      ) == move.fingerprint else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try moveOperation(move.destination, move.source)
            } catch {
                rollbackFailed = true
            }
        }
        return DuplicateFileUndoOutcome(
            record: record,
            restoredCount: rollbackFailed ? restored.count : 0,
            failedCount: failedCount,
            historyPersisted: false,
            rollbackFailed: rollbackFailed
        )
    }

    private func isCurrentVerifiedCopy(
        _ item: DuplicateFileItem,
        expectedHash: String
    ) async -> Bool {
        guard DuplicateFileScanner.currentFingerprint(for: item.url)
            == item.fingerprint else {
            return false
        }
        guard let hash = try? await DuplicateFileScanner.fullHashHex(for: item),
              hash == expectedHash else {
            return false
        }
        return DuplicateFileScanner.currentFingerprint(for: item.url)
            == item.fingerprint
    }

    private func hasVerifiedKeeper(
        in group: DuplicateFileGroup,
        selectedItemIDs: Set<String>
    ) async -> Bool {
        let candidates = group.files
            .filter { !selectedItemIDs.contains($0.id) }
            .sorted {
                if $0.id == group.suggestedKeeperID { return true }
                if $1.id == group.suggestedKeeperID { return false }
                return $0.id < $1.id
            }
        for candidate in candidates {
            if await isCurrentVerifiedCopy(
                candidate,
                expectedHash: group.contentHash
            ) {
                return true
            }
        }
        return false
    }

    private func isOwnedSingleLinkFile(_ item: DuplicateFileItem) -> Bool {
        item.fingerprint.ownerUserID == currentUserID
            && item.fingerprint.hardLinkCount == 1
    }

    private func historyItem(
        for item: DuplicateFileItem,
        group: DuplicateFileGroup,
        status: DuplicateFileRemovalStatus,
        detail: String?
    ) -> DuplicateFileRemovalHistoryItem {
        DuplicateFileRemovalHistoryItem(
            groupID: group.id,
            originalPath: item.url.standardizedFileURL.path,
            trashPath: nil,
            name: item.name,
            size: item.size,
            contentHash: group.contentHash,
            fingerprint: item.fingerprint,
            status: status,
            detail: detail
        )
    }

    private func isSafeTrashSource(
        _ url: URL,
        fingerprint: DuplicateFileFingerprint
    ) -> Bool {
        trashPathValidator(url.standardizedFileURL)
            && DuplicateFileScanner.currentFingerprint(for: url) == fingerprint
            && fingerprint.ownerUserID == currentUserID
            && fingerprint.hardLinkCount == 1
    }

    private func safeDestinationParent(for url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        var information = stat()
        return url.path.hasPrefix("/")
            && lstat(parent.path, &information) == 0
            && information.st_mode & S_IFMT == S_IFDIR
            && FileManager.default.isWritableFile(atPath: parent.path)
    }

    nonisolated static func isRecognizedTrashPath(
        _ url: URL,
        currentUserID: uid_t
    ) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/") else { return false }

        let homeTrash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL.path
        if isDescendant(path, of: homeTrash) {
            return true
        }

        let components = URL(
            fileURLWithPath: path
        ).standardizedFileURL.pathComponents
        let userID = String(currentUserID)
        if components.count >= 4,
           components[1] == ".Trashes",
           components[2] == userID {
            return true
        }
        guard components.count >= 5,
              components[1] == "Volumes" else {
            return false
        }
        if components[3] == ".Trashes",
           components.count >= 6,
           components[4] == userID {
            return true
        }
        return components[3] == ".Trash-\(userID)"
            && components.count >= 5
    }

    private nonisolated static func isDescendant(
        _ path: String,
        of directory: String
    ) -> Bool {
        path != directory && path.hasPrefix(directory + "/")
    }

    private static let defaultRecycler: Recycler = { urls in
        guard !urls.isEmpty else {
            return DuplicateFileRecycleResult(
                recycled: [:],
                errorDescription: nil
            )
        }
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                NSWorkspace.shared.recycle(urls) { recycled, error in
                    continuation.resume(returning: DuplicateFileRecycleResult(
                        recycled: recycled,
                        errorDescription: error?.localizedDescription
                    ))
                }
            }
        }
    }
}
