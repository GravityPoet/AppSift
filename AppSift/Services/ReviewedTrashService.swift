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
    var failure: AppFileRemovalFailure? = nil
    var usedAdministrator: Bool? = nil
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
    typealias Recycler = @Sendable ([URL]) async -> [URL: URL]

    private let historyStore: ReviewedTrashHistoryStore
    private let currentUserID: uid_t
    private let recycler: @Sendable ([URL]) async -> AppFileTrashResult
    private let additionalTrashRoots: [URL]
    private let privilegedService: PrivilegedAppRemovalService?

    init(
        historyStore: ReviewedTrashHistoryStore = .shared,
        currentUserID: uid_t = getuid(),
        additionalTrashRoots: [URL] = [],
        privilegedService: PrivilegedAppRemovalService? = nil,
        recycler: Recycler? = nil
    ) {
        self.historyStore = historyStore
        self.currentUserID = currentUserID
        self.additionalTrashRoots = additionalTrashRoots.map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
        self.privilegedService = privilegedService
        self.recycler = { urls in
            if let recycler {
                let mapping = await recycler(urls)
                return AppFileTrashResult(
                    trashed: mapping.map { TrashedAppFile(originalURL: $0.key, trashURL: $0.value) },
                    missing: [], needsFullDiskAccess: false,
                    failed: urls.filter { mapping[$0] == nil }
                )
            }
            return await Self.defaultRecycle(urls)
        }
    }

    func history(feature: String) -> [ReviewedTrashRecord] {
        historyStore.snapshot(feature: feature)
    }

    func moveToTrash(
        _ candidates: [ReviewedTrashCandidate],
        feature: String,
        usingAdministrator: Bool = false,
        progressHandler: @Sendable (Double) -> Void = { _ in }
    ) async -> ReviewedTrashOutcome {
        guard !candidates.isEmpty,
              candidates.count <= 5_000,
              !feature.isEmpty else {
            return ReviewedTrashOutcome(record: nil, historyPersisted: true)
        }

        var historyItems: [ReviewedTrashHistoryItem] = []
        var accepted: [(ReviewedTrashCandidate, URL)] = []
        for candidate in candidates {
            guard let standardized = validate(candidate, usingAdministrator: usingAdministrator) else {
                historyItems.append(historyItem(for: candidate, status: .rejected,
                                                failure: AppFileRemovalFailure(kind: .unsafePath)))
                continue
            }
            accepted.append((candidate, standardized))
        }

        if !accepted.isEmpty {
            let recycleResult: AppFileTrashResult
            if usingAdministrator, let privilegedService {
                recycleResult = await privilegedService.trash(accepted.map(\.1))
            } else {
                var trashed: [TrashedAppFile] = []
                var failures: [String: AppFileRemovalFailure] = [:]
                for (index, entry) in accepted.enumerated() {
                    // Earlier Finder operations can suspend this actor. Recheck
                    // each reviewed object immediately before its own move.
                    if validate(entry.0, usingAdministrator: false) != nil {
                        let result = await recycler([entry.1])
                        trashed.append(contentsOf: result.trashed)
                        if result.trashed.isEmpty {
                            failures[entry.1.path] = result.failure(for: entry.1)
                                ?? AppFileRemovalFailure(kind: .finderRejected)
                        }
                    } else {
                        failures[entry.1.path] = AppFileRemovalFailure(kind: .unsafePath)
                    }
                    progressHandler(Double(index + 1) / Double(accepted.count))
                }
                recycleResult = AppFileTrashResult(
                    trashed: trashed, missing: [], needsFullDiskAccess: false,
                    failed: accepted.map(\.1).filter { failures[$0.path] != nil }, failureDetails: failures
                )
            }
            for (candidate, url) in accepted {
                let trashURL = recycleResult.trashed.first { $0.originalURL == url }?.trashURL
                if !FileManager.default.fileExists(atPath: url.path),
                   let trashURL, isRecognizedTrashPath(trashURL),
                   ReviewedTrashFingerprint.read(at: trashURL) == candidate.fingerprint {
                    historyItems.append(
                        historyItem(
                            for: candidate,
                            status: .movedToTrash,
                            trashURL: trashURL,
                            usedAdministrator: usingAdministrator
                        )
                    )
                } else {
                    historyItems.append(
                        historyItem(
                            for: candidate,
                            status: .trashFailed,
                            trashURL: trashURL,
                            failure: recycleResult.failure(for: url)
                                ?? AppFileRemovalFailure(kind: .verificationFailed)
                        )
                    )
                }
            }
        }

        let record = ReviewedTrashRecord(feature: feature, items: historyItems)
        guard historyStore.append(record) else {
            let rolledBack = await rollback(record)
            return ReviewedTrashOutcome(record: rolledBack, historyPersisted: false)
        }
        return ReviewedTrashOutcome(record: record, historyPersisted: true)
    }

    func undo(_ record: ReviewedTrashRecord) async -> ReviewedTrashUndoOutcome {
        let items = record.items.filter { $0.status == .movedToTrash && $0.restoredAt == nil }
        let restoredIDs = await restore(items)

        let persisted = restoredIDs.isEmpty
            || historyStore.markRestored(recordID: record.id, itemIDs: restoredIDs, at: Date())
        return ReviewedTrashUndoOutcome(
            restoredCount: restoredIDs.count,
            failedCount: items.count - restoredIDs.count,
            historyPersisted: persisted
        )
    }

    private func validate(_ candidate: ReviewedTrashCandidate, usingAdministrator: Bool) -> URL? {
        let root = candidate.allowedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidateURL = candidate.url.standardizedFileURL
        guard candidateURL.path.hasPrefix("/"),
              !candidateURL.path.contains("\0"),
              !isProtectedRoot(candidateURL),
              let current = ReviewedTrashFingerprint.read(at: candidateURL),
              current == candidate.fingerprint,
              (!usingAdministrator || privilegedService != nil),
              current.owner == UInt32(currentUserID)
                || (usingAdministrator && current.owner == 0) else { return nil }
        let resolved = candidateURL.resolvingSymlinksInPath()
        guard resolved.path == candidateURL.path || resolved.standardizedFileURL.path == candidateURL.path,
              isDescendant(resolved, of: root) else { return nil }
        if candidate.requiresDirectChild,
           resolved.deletingLastPathComponent().path != root.path {
            return nil
        }
        return resolved
    }

    private func rollback(_ record: ReviewedTrashRecord) async -> ReviewedTrashRecord {
        var updated = record
        let restored = await restore(record.items.filter { $0.status == .movedToTrash })
        for index in updated.items.indices where updated.items[index].status == .movedToTrash {
            if restored.contains(updated.items[index].id) {
                updated.items[index].status = .rolledBackAfterHistoryFailure
                updated.items[index].trashPath = nil
                updated.items[index].detail = AppFileRemovalFailure(kind: .transactionRolledBack).localizedDescription
            } else {
                updated.items[index].status = .rollbackFailedAfterHistoryFailure
                updated.items[index].detail = String(localized: "Undo history could not be saved and at least one file could not be restored automatically. Open Trash before doing anything else.")
            }
        }
        return updated
    }

    private func restore(_ items: [ReviewedTrashHistoryItem]) async -> Set<UUID> {
        var restored: Set<UUID> = []
        var administratorItems: [AppRemovalHistoryItem] = []
        for item in items {
            guard let trashPath = item.trashPath else { continue }
            let source = URL(fileURLWithPath: trashPath)
            let destination = URL(fileURLWithPath: item.originalPath)
            let usesAdministrator = item.usedAdministrator == true && privilegedService != nil
            guard isRecognizedTrashPath(source),
                  ReviewedTrashFingerprint.read(at: source) == item.fingerprint,
                  !FileManager.default.fileExists(atPath: destination.path),
                  isSafeRestoreDestination(destination, usingAdministrator: usesAdministrator) else { continue }
            if usesAdministrator {
                administratorItems.append(AppRemovalHistoryItem(
                    id: item.id, originalPath: item.originalPath, trashPath: trashPath
                ))
            } else {
                do {
                    try FileManager.default.moveItem(at: source, to: destination)
                    restored.insert(item.id)
                } catch {
                    Logger.shared.log("Restore failed at \(item.originalPath): \(error)", level: .warning)
                }
            }
        }
        if !administratorItems.isEmpty, let privilegedService {
            let outcomes = await privilegedService.restore(administratorItems)
            for (id, outcome) in outcomes where outcome == .restored { restored.insert(id) }
        }
        return restored
    }

    private func historyItem(
        for candidate: ReviewedTrashCandidate,
        status: ReviewedTrashItemStatus,
        trashURL: URL? = nil,
        failure: AppFileRemovalFailure? = nil,
        usedAdministrator: Bool = false
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
            detail: failure?.detail ?? failure?.localizedDescription,
            restoredAt: nil,
            failure: failure,
            usedAdministrator: usedAdministrator ? true : nil
        )
    }

    private static func defaultRecycle(_ urls: [URL]) async -> AppFileTrashResult {
        var trashed: [TrashedAppFile] = []
        var failures: [String: AppFileRemovalFailure] = [:]
        // Keep Finder's path-specific error instead of losing it in a bulk mapping.
        for url in urls {
            let result: (URL?, AppFileRemovalFailure?) = await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    NSWorkspace.shared.recycle([url]) { mapping, error in
                        let failure = error.map { error -> AppFileRemovalFailure in
                            let nsError = error as NSError
                            let denied = (nsError.domain == NSCocoaErrorDomain
                                && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(nsError.code))
                                || (nsError.domain == NSPOSIXErrorDomain
                                    && [Int(EACCES), Int(EPERM)].contains(nsError.code))
                            return AppFileRemovalFailure(
                                kind: denied ? .administratorAccessRequired : .finderRejected,
                                detail: "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
                            )
                        }
                        continuation.resume(returning: (mapping[url], failure))
                    }
                }
            }
            if let destination = result.0 {
                trashed.append(TrashedAppFile(originalURL: url, trashURL: destination))
            } else {
                failures[url.path] = result.1 ?? AppFileRemovalFailure(kind: .finderRejected)
            }
        }
        return AppFileTrashResult(trashed: trashed, missing: [], needsFullDiskAccess: false,
                                  failed: urls.filter { failures[$0.path] != nil }, failureDetails: failures)
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

    private func isSafeRestoreDestination(_ destination: URL, usingAdministrator: Bool) -> Bool {
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        guard !isProtectedRoot(destination),
              FileManager.default.fileExists(atPath: parent.path),
              parent.resolvingSymlinksInPath().path == parent.path,
              usingAdministrator || FileManager.default.isWritableFile(atPath: parent.path) else { return false }
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
        if additionalTrashRoots.contains(where: {
            isDescendant(standardized, of: $0)
        }) {
            return true
        }

        let components = standardized.pathComponents
        let uid = String(currentUserID)
        for index in components.indices where components[index] == ".Trashes" {
            guard components.indices.contains(index + 1) else { continue }
            if components[index + 1] == uid { return true }
        }
        return components.contains(".Trash-\(uid)")
    }
}
