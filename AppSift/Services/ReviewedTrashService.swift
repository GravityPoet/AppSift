import AppKit
import Darwin
import Foundation

struct ReviewedTrashFingerprint: Codable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let owner: UInt32
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64

    static func read(at url: URL) -> ReviewedTrashFingerprint? {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT != S_IFLNK else {
            return nil
        }
        return ReviewedTrashFingerprint(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            mode: UInt32(information.st_mode),
            owner: UInt32(information.st_uid),
            modificationSeconds: Int64(information.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec)
        )
    }
}

struct ReviewedTrashCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
    let size: Int64
    let fingerprint: ReviewedTrashFingerprint
    let allowedRoot: URL
    let requiresDirectChild: Bool
}

enum ReviewedTrashItemStatus: String, Codable, Hashable, Sendable {
    case movedToTrash
    case alreadyMissing
    case rejected
    case trashFailed
    case rolledBackAfterHistoryFailure
    case rollbackFailedAfterHistoryFailure
}

struct ReviewedTrashHistoryItem: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let candidateID: String
    let name: String
    let originalPath: String
    var trashPath: String?
    let size: Int64
    let fingerprint: ReviewedTrashFingerprint
    var status: ReviewedTrashItemStatus
    var detail: String?
    var restoredAt: Date?
}

struct ReviewedTrashRecord: Codable, Identifiable, Hashable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let feature: String
    let removedAt: Date
    var items: [ReviewedTrashHistoryItem]

    init(
        schemaVersion: Int = 1,
        id: UUID = UUID(),
        feature: String,
        removedAt: Date = Date(),
        items: [ReviewedTrashHistoryItem]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.feature = feature
        self.removedAt = removedAt
        self.items = items
    }
}

struct ReviewedTrashOutcome: Sendable {
    let record: ReviewedTrashRecord?
    let historyPersisted: Bool

    var movedCount: Int {
        record?.items.count { $0.status == .movedToTrash } ?? 0
    }

    var failedCount: Int {
        record?.items.count {
            $0.status == .rejected
                || $0.status == .trashFailed
                || $0.status == .rollbackFailedAfterHistoryFailure
        } ?? 0
    }
}

struct ReviewedTrashUndoOutcome: Sendable {
    let restoredCount: Int
    let failedCount: Int
    let historyPersisted: Bool
}

final class ReviewedTrashHistoryStore: @unchecked Sendable {
    static let shared = ReviewedTrashHistoryStore()

    private static let maximumRecords = 150
    private static let maximumBytes = 1_500_000

    private let fileURL: URL
    private let lock = NSLock()
    private let currentUserID: uid_t
    private var records: [ReviewedTrashRecord]

    init(
        fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AppSift", isDirectory: true)
            .appendingPathComponent("ReviewedTrashHistory.json"),
        currentUserID: uid_t = getuid()
    ) {
        self.fileURL = fileURL
        self.currentUserID = currentUserID
        self.records = Self.load(from: fileURL, currentUserID: currentUserID)
    }

    func snapshot(feature: String? = nil) -> [ReviewedTrashRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let feature else { return records }
        return records.filter { $0.feature == feature }
    }

    @discardableResult
    func append(_ record: ReviewedTrashRecord) -> Bool {
        guard Self.isValid(record) else { return false }
        lock.lock()
        defer { lock.unlock() }
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
    func markRestored(recordID: UUID, itemIDs: Set<UUID>, at date: Date) -> Bool {
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
              data.count <= Self.maximumBytes else { return false }
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
            guard Self.isOwnedDirectory(directory, currentUserID: currentUserID),
                  !Self.isSymbolicLink(fileURL) else { return false }
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: fileURL.path
            )
            return Self.isOwnedRegularFile(fileURL, currentUserID: currentUserID)
        } catch {
            Logger.shared.log(
                "Could not persist reviewed Trash history: \(error.localizedDescription)",
                level: .warning
            )
            return false
        }
    }

    private static func load(from fileURL: URL, currentUserID: uid_t) -> [ReviewedTrashRecord] {
        guard isOwnedDirectory(fileURL.deletingLastPathComponent(), currentUserID: currentUserID),
              isOwnedRegularFile(fileURL, currentUserID: currentUserID),
              let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0,
              size <= maximumBytes,
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              data.count <= maximumBytes,
              let decoded = try? JSONDecoder().decode([ReviewedTrashRecord].self, from: data),
              decoded.count <= maximumRecords,
              decoded.allSatisfy(isValid) else {
            return []
        }
        return decoded.sorted { $0.removedAt > $1.removedAt }
    }

    private static func isValid(_ record: ReviewedTrashRecord) -> Bool {
        record.schemaVersion == 1
            && !record.feature.isEmpty
            && record.feature.count <= 80
            && !record.items.isEmpty
            && record.items.count <= 5_000
            && record.items.allSatisfy {
                $0.originalPath.hasPrefix("/")
                    && !$0.originalPath.contains("\0")
                    && ($0.trashPath == nil || $0.trashPath?.hasPrefix("/") == true)
            }
    }

    private static func isOwnedDirectory(_ url: URL, currentUserID: uid_t) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFDIR
            && information.st_uid == currentUserID
            && information.st_mode & S_IWOTH == 0
    }

    private static func isOwnedRegularFile(_ url: URL, currentUserID: uid_t) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFREG
            && information.st_uid == currentUserID
            && information.st_mode & S_IWOTH == 0
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0
            && information.st_mode & S_IFMT == S_IFLNK
    }
}

actor ReviewedTrashService {
    private let historyStore: ReviewedTrashHistoryStore
    private let currentUserID: uid_t

    init(
        historyStore: ReviewedTrashHistoryStore = .shared,
        currentUserID: uid_t = getuid()
    ) {
        self.historyStore = historyStore
        self.currentUserID = currentUserID
    }

    func history(feature: String) -> [ReviewedTrashRecord] {
        historyStore.snapshot(feature: feature)
    }

    func moveToTrash(
        _ candidates: [ReviewedTrashCandidate],
        feature: String
    ) async -> ReviewedTrashOutcome {
        guard !candidates.isEmpty,
              candidates.count <= 5_000,
              !feature.isEmpty else {
            return ReviewedTrashOutcome(record: nil, historyPersisted: true)
        }

        var historyItems: [ReviewedTrashHistoryItem] = []
        var accepted: [(ReviewedTrashCandidate, URL)] = []
        for candidate in candidates {
            guard let standardized = validate(candidate) else {
                historyItems.append(historyItem(for: candidate, status: .rejected))
                continue
            }
            accepted.append((candidate, standardized))
        }

        if !accepted.isEmpty {
            let recycleResult = await recycle(accepted.map(\.1))
            for (candidate, url) in accepted {
                if !FileManager.default.fileExists(atPath: url.path) {
                    let trashURL = recycleResult[url]
                    historyItems.append(
                        historyItem(
                            for: candidate,
                            status: trashURL == nil ? .trashFailed : .movedToTrash,
                            trashURL: trashURL,
                            detail: trashURL == nil ? "Finder did not return a recoverable Trash path." : nil
                        )
                    )
                } else {
                    historyItems.append(
                        historyItem(
                            for: candidate,
                            status: .trashFailed,
                            detail: "The item remained at its original path."
                        )
                    )
                }
            }
        }

        let record = ReviewedTrashRecord(feature: feature, items: historyItems)
        guard historyStore.append(record) else {
            let rolledBack = rollback(record)
            return ReviewedTrashOutcome(record: rolledBack, historyPersisted: false)
        }
        return ReviewedTrashOutcome(record: record, historyPersisted: true)
    }

    func undo(_ record: ReviewedTrashRecord) -> ReviewedTrashUndoOutcome {
        var restoredIDs: Set<UUID> = []
        var failures = 0

        for item in record.items where item.status == .movedToTrash && item.restoredAt == nil {
            guard let trashPath = item.trashPath else {
                failures += 1
                continue
            }
            let trashURL = URL(fileURLWithPath: trashPath)
            let destination = URL(fileURLWithPath: item.originalPath)
            guard isRecognizedTrashPath(trashURL),
                  FileManager.default.fileExists(atPath: trashURL.path),
                  ReviewedTrashFingerprint.read(at: trashURL) == item.fingerprint,
                  !FileManager.default.fileExists(atPath: destination.path),
                  isSafeRestoreDestination(destination) else {
                failures += 1
                continue
            }
            do {
                try FileManager.default.moveItem(at: trashURL, to: destination)
                restoredIDs.insert(item.id)
            } catch {
                failures += 1
            }
        }

        let persisted = restoredIDs.isEmpty
            || historyStore.markRestored(recordID: record.id, itemIDs: restoredIDs, at: Date())
        return ReviewedTrashUndoOutcome(
            restoredCount: restoredIDs.count,
            failedCount: failures,
            historyPersisted: persisted
        )
    }

    private func validate(_ candidate: ReviewedTrashCandidate) -> URL? {
        let root = candidate.allowedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidateURL = candidate.url.standardizedFileURL
        guard candidateURL.path.hasPrefix("/"),
              !candidateURL.path.contains("\0"),
              !isProtectedRoot(candidateURL),
              let current = ReviewedTrashFingerprint.read(at: candidateURL),
              current == candidate.fingerprint,
              current.owner == UInt32(currentUserID) else { return nil }
        let resolved = candidateURL.resolvingSymlinksInPath()
        guard resolved.path == candidateURL.path || resolved.standardizedFileURL.path == candidateURL.path,
              isDescendant(resolved, of: root) else { return nil }
        if candidate.requiresDirectChild,
           resolved.deletingLastPathComponent().path != root.path {
            return nil
        }
        return resolved
    }

    private func rollback(_ record: ReviewedTrashRecord) -> ReviewedTrashRecord {
        var updated = record
        for index in updated.items.indices where updated.items[index].status == .movedToTrash {
            guard let trashPath = updated.items[index].trashPath else {
                updated.items[index].status = .rollbackFailedAfterHistoryFailure
                continue
            }
            let trashURL = URL(fileURLWithPath: trashPath)
            let destination = URL(fileURLWithPath: updated.items[index].originalPath)
            guard isRecognizedTrashPath(trashURL),
                  ReviewedTrashFingerprint.read(at: trashURL) == updated.items[index].fingerprint,
                  !FileManager.default.fileExists(atPath: destination.path),
                  isSafeRestoreDestination(destination) else {
                updated.items[index].status = .rollbackFailedAfterHistoryFailure
                continue
            }
            do {
                try FileManager.default.moveItem(at: trashURL, to: destination)
                updated.items[index].status = .rolledBackAfterHistoryFailure
                updated.items[index].trashPath = nil
            } catch {
                updated.items[index].status = .rollbackFailedAfterHistoryFailure
            }
        }
        return updated
    }

    private func historyItem(
        for candidate: ReviewedTrashCandidate,
        status: ReviewedTrashItemStatus,
        trashURL: URL? = nil,
        detail: String? = nil
    ) -> ReviewedTrashHistoryItem {
        ReviewedTrashHistoryItem(
            id: UUID(),
            candidateID: candidate.id,
            name: candidate.name,
            originalPath: candidate.url.path,
            trashPath: trashURL?.path,
            size: candidate.size,
            fingerprint: candidate.fingerprint,
            status: status,
            detail: detail,
            restoredAt: nil
        )
    }

    private func recycle(_ urls: [URL]) async -> [URL: URL] {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                NSWorkspace.shared.recycle(urls) { mapping, _ in
                    continuation.resume(returning: mapping)
                }
            }
        }
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path != rootPath && path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private func isProtectedRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == "/"
            || path == "/System"
            || path.hasPrefix("/System/")
            || path == "/usr"
            || path.hasPrefix("/usr/")
            || path == "/bin"
            || path.hasPrefix("/bin/")
            || path == "/sbin"
            || path.hasPrefix("/sbin/")
            || path == "/private"
            || path == FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func isSafeRestoreDestination(_ destination: URL) -> Bool {
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        guard !isProtectedRoot(destination),
              FileManager.default.fileExists(atPath: parent.path),
              FileManager.default.isWritableFile(atPath: parent.path) else { return false }
        var information = stat()
        return lstat(parent.path, &information) == 0
            && information.st_mode & S_IFMT == S_IFDIR
            && information.st_mode & S_IWOTH == 0
    }

    private func isRecognizedTrashPath(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        let homeTrash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        if isDescendant(standardized, of: homeTrash) { return true }

        let components = standardized.pathComponents
        let uid = String(currentUserID)
        for index in components.indices where components[index] == ".Trashes" {
            guard components.indices.contains(index + 1) else { continue }
            if components[index + 1] == uid { return true }
        }
        return components.contains(".Trash-\(uid)")
    }
}
