import AppKit
import Darwin
import Foundation

enum SpaceLensRemovalStatus: String, Codable, Hashable, Sendable {
    case movedToTrash
    case alreadyMissing
    case rejected
    case trashFailed
    case rolledBackAfterHistoryFailure
    case rollbackFailedAfterHistoryFailure
}

struct SpaceLensRemovalHistoryItem: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let originalPath: String
    var trashPath: String?
    let name: String
    let kind: SpaceLensNodeKind
    let logicalSize: Int64
    let allocatedSize: Int64
    let fingerprint: SpaceLensFingerprint
    let verificationToken: String
    var status: SpaceLensRemovalStatus
    var detail: String?
    var restoredAt: Date?

    init(
        id: UUID = UUID(),
        originalPath: String,
        trashPath: String? = nil,
        name: String,
        kind: SpaceLensNodeKind,
        logicalSize: Int64,
        allocatedSize: Int64,
        fingerprint: SpaceLensFingerprint,
        verificationToken: String,
        status: SpaceLensRemovalStatus,
        detail: String? = nil,
        restoredAt: Date? = nil
    ) {
        self.id = id
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.name = name
        self.kind = kind
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.fingerprint = fingerprint
        self.verificationToken = verificationToken
        self.status = status
        self.detail = detail
        self.restoredAt = restoredAt
    }
}

struct SpaceLensRemovalRecord: Codable, Identifiable, Hashable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let removedAt: Date
    let scanRootPath: String
    var items: [SpaceLensRemovalHistoryItem]

    init(
        schemaVersion: Int = 1,
        id: UUID = UUID(),
        removedAt: Date = Date(),
        scanRootPath: String,
        items: [SpaceLensRemovalHistoryItem]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.removedAt = removedAt
        self.scanRootPath = scanRootPath
        self.items = items
    }
}

struct SpaceLensRemovalOutcome: Sendable {
    let items: [SpaceLensRemovalHistoryItem]
    let record: SpaceLensRemovalRecord?
    let historyPersisted: Bool

    var movedCount: Int {
        items.count { $0.status == .movedToTrash }
    }

    var failedCount: Int {
        items.count {
            $0.status == .rejected
                || $0.status == .trashFailed
                || $0.status == .rollbackFailedAfterHistoryFailure
        }
    }
}

struct SpaceLensUndoOutcome: Sendable {
    let restoredCount: Int
    let failedCount: Int
    let historyPersisted: Bool
    let rollbackFailed: Bool
}

struct SpaceLensRecycleResult: Sendable {
    let recycled: [URL: URL]
    let errorDescription: String?
}

final class SpaceLensRemovalHistoryStore: @unchecked Sendable {
    static let shared = SpaceLensRemovalHistoryStore()

    private static let maximumRecords = 50
    private static let maximumBytes = 1_000_000

    private let fileURL: URL
    private let currentUserID: uid_t
    private let lock = NSLock()
    private var records: [SpaceLensRemovalRecord]

    init(
        fileURL: URL = SpaceLensRemovalHistoryStore.defaultFileURL,
        currentUserID: uid_t = getuid()
    ) {
        self.fileURL = fileURL
        self.currentUserID = currentUserID
        self.records = Self.load(
            from: fileURL,
            currentUserID: currentUserID
        )
    }

    func snapshot() -> [SpaceLensRemovalRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    @discardableResult
    func append(_ record: SpaceLensRemovalRecord) -> Bool {
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
        guard let recordIndex = records.firstIndex(where: {
            $0.id == recordID
        }) else {
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
            var isDirectory: ObjCBool = false
            let directoryExists = FileManager.default.fileExists(
                atPath: directory.path,
                isDirectory: &isDirectory
            )
            if directoryExists {
                guard isDirectory.boolValue,
                      Self.isSafeContainer(
                        directory,
                        currentUserID: currentUserID
                      ) else {
                    return false
                }
            } else {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [
                        .posixPermissions: NSNumber(value: 0o700),
                    ]
                )
                guard Self.isSafeContainer(
                    directory,
                    currentUserID: currentUserID
                ) else {
                    return false
                }
            }

            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
            if FileManager.default.fileExists(atPath: fileURL.path),
               !Self.isSafeHistoryFile(
                    fileURL,
                    currentUserID: currentUserID
               ) {
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
                "Could not persist Space Lens history: \(error.localizedDescription)",
                level: .warning
            )
            return false
        }
    }

    private static func load(
        from fileURL: URL,
        currentUserID: uid_t
    ) -> [SpaceLensRemovalRecord] {
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
            [SpaceLensRemovalRecord].self,
            from: data
        ),
        decoded.count <= maximumRecords,
        Set(decoded.map(\.id)).count == decoded.count,
        decoded.allSatisfy(isValid) else {
            return []
        }
        return decoded.sorted { $0.removedAt > $1.removedAt }
    }

    private static func isValid(
        _ record: SpaceLensRemovalRecord
    ) -> Bool {
        guard record.schemaVersion == 1,
              record.scanRootPath.hasPrefix("/"),
              record.scanRootPath.count <= 4_096,
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
                && item.logicalSize >= 0
                && item.allocatedSize >= 0
                && item.verificationToken.count == 64
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
              !SpaceLensScanner.pathContainsSymbolicLink(directory) else {
            return false
        }
        return true
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
            .appendingPathComponent(
                "Library/Application Support/AppSift",
                isDirectory: true
            )
            .appendingPathComponent(
                "space-lens-removal-history.json"
            )
    }
}

final class SpaceLensRemovalController: @unchecked Sendable {
    typealias Recycler = @Sendable ([URL]) async -> SpaceLensRecycleResult
    typealias MoveOperation = @Sendable (URL, URL) throws -> Void

    private let currentUserID: uid_t
    private let configuredTrashRoot: URL
    private let historyStore: SpaceLensRemovalHistoryStore
    private let recycler: Recycler
    private let moveOperation: MoveOperation

    init(
        currentUserID: uid_t = getuid(),
        trashRoot: URL? = nil,
        historyStore: SpaceLensRemovalHistoryStore = .shared,
        recycler: @escaping Recycler =
            SpaceLensRemovalController.defaultRecycler,
        moveOperation: @escaping MoveOperation = { source, destination in
            try FileManager.default.moveItem(
                at: source,
                to: destination
            )
        }
    ) {
        self.currentUserID = currentUserID
        self.configuredTrashRoot = (
            trashRoot
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".Trash", isDirectory: true)
        ).standardizedFileURL
        self.historyStore = historyStore
        self.recycler = recycler
        self.moveOperation = moveOperation
    }

    func historySnapshot() -> [SpaceLensRemovalRecord] {
        historyStore.snapshot()
    }

    func canUndo(_ record: SpaceLensRemovalRecord) -> Bool {
        guard historyStore.snapshot().contains(where: { $0 == record }) else {
            return false
        }
        return record.items.contains { item in
            guard item.status == .movedToTrash,
                  item.restoredAt == nil,
                  let trashPath = item.trashPath else {
                return false
            }
            let source = URL(fileURLWithPath: trashPath)
                .standardizedFileURL
            return isSafeTrashItem(source, expected: item)
        }
    }

    func remove(
        nodes requestedNodes: [SpaceLensNode],
        scanRoot requestedRoot: URL,
        removedAt: Date = Date()
    ) async -> SpaceLensRemovalOutcome {
        guard let scanRoot = SpaceLensScanner.canonicalExistingURL(
            requestedRoot
        ) else {
            return SpaceLensRemovalOutcome(
                items: requestedNodes.map {
                    historyItem(
                        for: $0,
                        status: .rejected,
                        detail: "The scan root is no longer available."
                    )
                },
                record: nil,
                historyPersisted: true
            )
        }

        let nodes = collapsedNodes(requestedNodes)
        var results: [SpaceLensRemovalHistoryItem] = []
        var validNodes: [SpaceLensNode] = []
        for node in nodes {
            if !FileManager.default.fileExists(atPath: node.url.path) {
                results.append(historyItem(
                    for: node,
                    status: .alreadyMissing,
                    detail: "The item was already missing."
                ))
            } else if let rejection = validationFailure(
                for: node,
                scanRoot: scanRoot
            ) {
                results.append(historyItem(
                    for: node,
                    status: .rejected,
                    detail: rejection
                ))
            } else {
                validNodes.append(node)
            }
        }

        guard !validNodes.isEmpty else {
            return SpaceLensRemovalOutcome(
                items: results,
                record: nil,
                historyPersisted: true
            )
        }

        let recycleResult = await recycler(validNodes.map(\.url))
        let recycledByPath = Dictionary(
            uniqueKeysWithValues: recycleResult.recycled.map {
                (
                    $0.key.standardizedFileURL.path,
                    $0.value.standardizedFileURL
                )
            }
        )
        var movedMappings: [
            UUID: (original: URL, trash: URL, expected: SpaceLensRemovalHistoryItem)
        ] = [:]

        for node in validNodes {
            var item = historyItem(
                for: node,
                status: .trashFailed,
                detail: recycleResult.errorDescription
            )
            if let trash = recycledByPath[node.id],
               isSafeTrashItem(trash, expected: item) {
                item.status = .movedToTrash
                item.trashPath = trash.path
                item.detail = nil
                movedMappings[item.id] = (node.url, trash, item)
            } else if item.detail == nil {
                item.detail = FileManager.default.fileExists(
                    atPath: node.url.path
                )
                    ? "Finder could not move this item to Trash."
                    : "Finder did not return a recoverable Trash location."
            }
            results.append(item)
        }

        guard !movedMappings.isEmpty else {
            return SpaceLensRemovalOutcome(
                items: results,
                record: nil,
                historyPersisted: true
            )
        }

        let record = SpaceLensRemovalRecord(
            removedAt: removedAt,
            scanRootPath: scanRoot.path,
            items: results
        )
        if historyStore.append(record) {
            return SpaceLensRemovalOutcome(
                items: results,
                record: record,
                historyPersisted: true
            )
        }

        for index in results.indices {
            guard let mapping = movedMappings[results[index].id] else {
                continue
            }
            do {
                guard !FileManager.default.fileExists(
                    atPath: mapping.original.path
                ),
                isSafeTrashItem(
                    mapping.trash,
                    expected: mapping.expected
                ),
                safeOriginalDestination(
                    mapping.original,
                    scanRoot: scanRoot
                ) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try moveOperation(mapping.trash, mapping.original)
                results[index].status = .rolledBackAfterHistoryFailure
                results[index].trashPath = nil
                results[index].detail =
                    "Removal was rolled back because undo history could not be saved."
            } catch {
                results[index].status = .rollbackFailedAfterHistoryFailure
                results[index].detail =
                    "Undo history could not be saved and rollback failed: \(error.localizedDescription)"
            }
        }
        return SpaceLensRemovalOutcome(
            items: results,
            record: nil,
            historyPersisted: false
        )
    }

    func undo(
        _ record: SpaceLensRemovalRecord,
        restoredAt: Date = Date()
    ) -> SpaceLensUndoOutcome {
        guard canUndo(record),
              let scanRoot = SpaceLensScanner.canonicalExistingURL(
                URL(fileURLWithPath: record.scanRootPath)
              ) else {
            return SpaceLensUndoOutcome(
                restoredCount: 0,
                failedCount: 1,
                historyPersisted: true,
                rollbackFailed: false
            )
        }

        var restored: [
            (
                itemID: UUID,
                source: URL,
                destination: URL,
                expected: SpaceLensRemovalHistoryItem
            )
        ] = []
        var failedCount = 0

        for item in record.items
        where item.status == .movedToTrash && item.restoredAt == nil {
            guard let trashPath = item.trashPath else {
                failedCount += 1
                continue
            }
            let source = URL(fileURLWithPath: trashPath)
                .standardizedFileURL
            let destination = URL(fileURLWithPath: item.originalPath)
                .standardizedFileURL
            guard isSafeTrashItem(source, expected: item),
                  !FileManager.default.fileExists(
                    atPath: destination.path
                  ),
                  safeOriginalDestination(
                    destination,
                    scanRoot: scanRoot
                  ) else {
                failedCount += 1
                continue
            }
            do {
                try moveOperation(source, destination)
                restored.append((
                    item.id,
                    source,
                    destination,
                    item
                ))
            } catch {
                failedCount += 1
            }
        }

        let restoredIDs = Set(restored.map(\.itemID))
        guard !restoredIDs.isEmpty else {
            return SpaceLensUndoOutcome(
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
            return SpaceLensUndoOutcome(
                restoredCount: restored.count,
                failedCount: failedCount,
                historyPersisted: true,
                rollbackFailed: false
            )
        }

        var rollbackFailed = false
        for move in restored.reversed() {
            do {
                guard !FileManager.default.fileExists(
                    atPath: move.source.path
                ),
                isSafeTrashDestination(move.source),
                SpaceLensScanner.currentFingerprint(
                    for: move.destination
                ) == move.expected.fingerprint,
                SpaceLensScanner.verificationToken(
                    for: move.destination
                ) == move.expected.verificationToken else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try moveOperation(move.destination, move.source)
            } catch {
                rollbackFailed = true
            }
        }
        return SpaceLensUndoOutcome(
            restoredCount: restored.count,
            failedCount: failedCount,
            historyPersisted: false,
            rollbackFailed: rollbackFailed
        )
    }

    private func collapsedNodes(
        _ nodes: [SpaceLensNode]
    ) -> [SpaceLensNode] {
        let unique = Dictionary(
            nodes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted {
            $0.url.pathComponents.count < $1.url.pathComponents.count
        }
        var accepted: [SpaceLensNode] = []
        for node in unique where !accepted.contains(where: {
            isPath(node.id, inside: $0.id)
        }) {
            accepted.append(node)
        }
        return accepted
    }

    private func validationFailure(
        for node: SpaceLensNode,
        scanRoot: URL
    ) -> String? {
        guard node.id != scanRoot.path,
              isPath(node.id, inside: scanRoot.path) else {
            return "The scan root itself cannot be removed."
        }
        guard node.isRemovalEligible else {
            return node.protectedDescendantCount > 0
                ? "This folder contains protected items. Open it and review eligible children instead."
                : "This item is protected by the Space Lens safety boundary."
        }
        guard let canonical = SpaceLensScanner.canonicalExistingURL(node.url),
              canonical.path == node.id,
              !SpaceLensScanner.pathContainsSymbolicLink(
                canonical,
                stoppingAt: scanRoot
              ) else {
            return "The item's path changed or now contains a symbolic link."
        }
        guard SpaceLensScanner.currentFingerprint(for: canonical)
                == node.fingerprint,
              SpaceLensScanner.verificationToken(for: canonical)
                == node.verificationToken else {
            return "The item changed after the scan. Refresh before removing it."
        }
        guard safeOriginalDestination(canonical, scanRoot: scanRoot) else {
            return "The item's parent folder is no longer a safe writable destination."
        }
        return nil
    }

    private func historyItem(
        for node: SpaceLensNode,
        status: SpaceLensRemovalStatus,
        detail: String?
    ) -> SpaceLensRemovalHistoryItem {
        SpaceLensRemovalHistoryItem(
            originalPath: node.id,
            name: node.name,
            kind: node.kind,
            logicalSize: node.logicalSize,
            allocatedSize: node.allocatedSize,
            fingerprint: node.fingerprint,
            verificationToken: node.verificationToken,
            status: status,
            detail: detail
        )
    }

    private func isSafeTrashItem(
        _ url: URL,
        expected: SpaceLensRemovalHistoryItem
    ) -> Bool {
        let standardized = url.standardizedFileURL
        return isRecognizedTrashPath(standardized)
            && SpaceLensScanner.currentFingerprint(for: standardized)
                == expected.fingerprint
            && SpaceLensScanner.verificationToken(for: standardized)
                == expected.verificationToken
    }

    private func isSafeTrashDestination(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        return isRecognizedTrashContainer(parent)
            && !SpaceLensScanner.pathContainsSymbolicLink(parent)
    }

    private func isRecognizedTrashPath(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        return isRecognizedTrashContainer(parent)
            && !SpaceLensScanner.pathContainsSymbolicLink(
                url,
                stoppingAt: parent
            )
    }

    private func isRecognizedTrashContainer(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let components = standardized.pathComponents
        let userID = String(currentUserID)
        let hasRecognizedLayout =
            standardized.path == configuredTrashRoot.path
            || (
                components.count == 3
                    && components[0] == "/"
                    && components[1] == ".Trashes"
                    && components[2] == userID
            )
            || (
                components.count == 5
                    && components[0] == "/"
                    && components[1] == "Volumes"
                    && components[3] == ".Trashes"
                    && components[4] == userID
            )
            || (
                components.count == 4
                    && components[0] == "/"
                    && components[1] == "Volumes"
                    && components[3] == ".Trash-\(userID)"
            )
        guard hasRecognizedLayout else { return false }

        var information = stat()
        return lstat(standardized.path, &information) == 0
            && information.st_mode & S_IFMT == S_IFDIR
            && information.st_uid == currentUserID
            && !SpaceLensScanner.pathContainsSymbolicLink(standardized)
    }

    private func safeOriginalDestination(
        _ url: URL,
        scanRoot: URL
    ) -> Bool {
        let standardized = url.standardizedFileURL
        let parent = standardized.deletingLastPathComponent()
            .standardizedFileURL
        var information = stat()
        return standardized.path != scanRoot.path
            && isPath(standardized.path, inside: scanRoot.path)
            && lstat(parent.path, &information) == 0
            && information.st_mode & S_IFMT == S_IFDIR
            && access(parent.path, W_OK | X_OK) == 0
            && !SpaceLensScanner.pathContainsSymbolicLink(
                parent,
                stoppingAt: scanRoot
            )
    }

    private func isPath(_ path: String, inside root: String) -> Bool {
        if root == "/" {
            return path.hasPrefix("/")
        }
        return path == root || path.hasPrefix(root + "/")
    }

    private static let defaultRecycler: Recycler = { urls in
        guard !urls.isEmpty else {
            return SpaceLensRecycleResult(
                recycled: [:],
                errorDescription: nil
            )
        }
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                NSWorkspace.shared.recycle(urls) { recycled, error in
                    continuation.resume(returning: SpaceLensRecycleResult(
                        recycled: recycled,
                        errorDescription: error?.localizedDescription
                    ))
                }
            }
        }
    }
}
