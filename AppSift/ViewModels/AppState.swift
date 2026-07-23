import SwiftUI
import Combine
import UserNotifications
import AppKit
import CryptoKit
import ServiceManagement

// InstalledApp is defined in AppInfoFetcher.swift

enum AppSection: Hashable {
    case apps
    case appUpdates
    case installationFiles
    case startupItems
    case extensions
    case appPermissions
    case defaultApplications
    case removalHistory
    case orphans
    case timeMachine
    case cleaning(CleaningCategory)
}

extension Notification.Name {
    /// Posted by the Finder Services handlers with a path and explicit action
    /// for the right-clicked .app bundle.
    static let appSiftExternalAppAction = Notification.Name("AppSift.ExternalAppAction")
}

enum AppFileInitialSelection: Equatable, Sendable {
    case all
    case resetEligible
    case relatedFiles
}

enum ExternalAppAction: String, Hashable, Sendable {
    case uninstall
    case reset
    case reviewTrash

    var initialSelection: AppFileInitialSelection {
        switch self {
        case .uninstall: return .all
        case .reset: return .resetEligible
        case .reviewTrash: return .relatedFiles
        }
    }
}

struct ExternalAppRequest: Hashable, Sendable {
    let path: String
    let action: ExternalAppAction
}

/// Cold-launch buffer for Finder Services. A request can arrive before the
/// SwiftUI scene (and thus AppState) exists; NotificationCenter has no replay,
/// so AppDelegate stores the complete action until AppState drains it.
@MainActor
enum ExternalAppRequestBuffer {
    static var pending: ExternalAppRequest?
}

enum AppFileProtectionReason: String, Codable, Hashable, Sendable {
    case foreignApplication
    case sharedContainer
    case sharedIdentity
    case foreignPrivateData
    case ambiguousName

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .ambiguousName
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct AppFileProtection: Hashable {
    let candidateURL: URL
    let protectedRoot: URL
    let reason: AppFileProtectionReason
}

struct ProtectedAppFile: Identifiable, Hashable {
    struct ID: Hashable {
        let path: String
        let reason: AppFileProtectionReason
    }

    let url: URL
    let reason: AppFileProtectionReason
    let matchedItemCount: Int
    let relatedApplications: [AppRelationshipApplication]

    var id: ID {
        ID(path: url.standardizedFileURL.path, reason: reason)
    }
}

struct TrashedAppFile: Hashable, Sendable {
    let originalURL: URL
    let trashURL: URL
    let launchdWasLoaded: Bool?

    init(
        originalURL: URL,
        trashURL: URL,
        launchdWasLoaded: Bool? = nil
    ) {
        self.originalURL = originalURL
        self.trashURL = trashURL
        self.launchdWasLoaded = launchdWasLoaded
    }
}

struct AppFileTrashResult: Sendable {
    let trashed: [TrashedAppFile]
    let missing: [URL]
    let needsFullDiskAccess: Bool
    let failed: [URL]
    let failureDetails: [String: AppFileRemovalFailure]

    init(
        trashed: [TrashedAppFile],
        missing: [URL],
        needsFullDiskAccess: Bool,
        failed: [URL],
        failureDetails: [String: AppFileRemovalFailure] = [:]
    ) {
        self.trashed = trashed
        self.missing = missing
        self.needsFullDiskAccess = needsFullDiskAccess
        self.failed = failed
        self.failureDetails = failureDetails
    }

    func failure(for url: URL) -> AppFileRemovalFailure? {
        failureDetails[url.standardizedFileURL.path]
    }
}

/// Finder-semantic Trash boundary for app removal. Unlike the general junk
/// cleaner, this service never falls back to `removeItem` or `/bin/rm`.
@MainActor
enum AppFileTrashService {
    static func trash(_ urls: [URL]) async -> AppFileTrashResult {
        guard !urls.isEmpty else {
            return AppFileTrashResult(
                trashed: [],
                missing: [],
                needsFullDiskAccess: false,
                failed: []
            )
        }

        let privilegedService = PrivilegedAppRemovalService()
        if privilegedService.shouldHandleTrash(urls) {
            return await privilegedService.trash(urls)
        }

        let hasFullDiskAccess = FullDiskAccessManager.shared.hasFullDiskAccess
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { recycled, error in
                let finderResult = classify(
                    requested: urls,
                    recycled: recycled,
                    error: error as NSError?,
                    hasFullDiskAccess: hasFullDiskAccess
                )
                guard hasFullDiskAccess,
                      !finderResult.failed.isEmpty,
                      containsPermissionDenied(error as NSError?) else {
                    continuation.resume(returning: finderResult)
                    return
                }

                Task { @MainActor in
                    let adminResult = await privilegedService.trash(finderResult.failed)
                    var failureDetails = finderResult.failureDetails
                    for item in adminResult.trashed + finderResult.trashed {
                        failureDetails.removeValue(
                            forKey: item.originalURL.standardizedFileURL.path
                        )
                    }
                    failureDetails.merge(adminResult.failureDetails) { _, latest in latest }
                    continuation.resume(returning: AppFileTrashResult(
                        trashed: finderResult.trashed + adminResult.trashed,
                        missing: finderResult.missing + adminResult.missing,
                        needsFullDiskAccess: false,
                        failed: adminResult.failed,
                        failureDetails: failureDetails
                    ))
                }
            }
        }
    }

    nonisolated static func classify(
        requested: [URL],
        recycled: [URL: URL],
        error: NSError?,
        hasFullDiskAccess: Bool,
        fileExists: @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        }
    ) -> AppFileTrashResult {
        var recycledByPath: [String: URL] = [:]
        for (original, trashURL) in recycled {
            recycledByPath[original.standardizedFileURL.path] = trashURL
        }

        var trashed: [TrashedAppFile] = []
        var missing: [URL] = []
        var failed: [URL] = []
        for original in requested {
            if let trashURL = recycledByPath[original.standardizedFileURL.path] {
                trashed.append(
                    TrashedAppFile(originalURL: original, trashURL: trashURL)
                )
            } else if !fileExists(original.path) {
                missing.append(original)
            } else {
                failed.append(original)
            }
        }

        if let error {
            Logger.shared.log(
                "Finder-style Trash operation was partial: \(error.localizedDescription)",
                level: failed.isEmpty ? .info : .warning
            )
        }

        let permissionDenied = containsPermissionDenied(error)
        let failure = AppFileRemovalFailure(
            kind: permissionDenied
                ? (hasFullDiskAccess ? .administratorAccessRequired : .fullDiskAccessRequired)
                : .finderRejected,
            detail: error?.localizedDescription
        )
        return AppFileTrashResult(
            trashed: trashed,
            missing: missing,
            needsFullDiskAccess: !hasFullDiskAccess
                && !failed.isEmpty
                && permissionDenied,
            failed: failed,
            failureDetails: Dictionary(
                uniqueKeysWithValues: failed.map {
                    ($0.standardizedFileURL.path, failure)
                }
            )
        )
    }

    private nonisolated static func containsPermissionDenied(_ error: NSError?) -> Bool {
        guard let error else { return false }
        if (error.domain == NSCocoaErrorDomain && [
            NSFileReadNoPermissionError,
            NSFileWriteNoPermissionError,
        ].contains(error.code)) ||
            (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code)) {
            return true
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           containsPermissionDenied(underlying) {
            return true
        }
        if let detailed = error.userInfo[NSDetailedErrorsKey] as? [NSError] {
            return detailed.contains(where: containsPermissionDenied)
        }
        return false
    }
}

enum AppRemovalItemOutcome: String, Codable, Hashable, Sendable {
    case movedToTrash
    case alreadyMissing
    case failed

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .failed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Records why app-related files entered the Trash flow. Schema v1/v2
/// receipts did not carry this field, so they decode as `legacyRemoval`
/// instead of guessing whether the app bundle itself was included.
enum AppRemovalOperation: String, Codable, Hashable, Sendable {
    case uninstall
    case reset
    case relatedFiles
    case legacyRemoval

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .legacyRemoval
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var requiresTargetAppTermination: Bool {
        self == .uninstall || self == .reset
    }
}

struct AppRemovalHistoryItem: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let originalPath: String
    let trashPath: String?
    let outcome: AppRemovalItemOutcome
    let evidence: AppFileMatchEvidence
    let failure: AppFileRemovalFailure?
    let launchdWasLoaded: Bool?
    var restoredAt: Date?

    init(
        id: UUID = UUID(),
        originalPath: String,
        trashPath: String? = nil,
        outcome: AppRemovalItemOutcome = .movedToTrash,
        evidence: AppFileMatchEvidence = .legacyUnknown,
        failure: AppFileRemovalFailure? = nil,
        launchdWasLoaded: Bool? = nil,
        restoredAt: Date? = nil
    ) {
        self.id = id
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.outcome = outcome
        self.evidence = evidence
        self.failure = failure
        self.launchdWasLoaded = launchdWasLoaded
        self.restoredAt = restoredAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case originalPath
        case trashPath
        case outcome
        case evidence
        case failure
        case launchdWasLoaded
        case restoredAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        originalPath = try container.decode(String.self, forKey: .originalPath)
        trashPath = try container.decodeIfPresent(String.self, forKey: .trashPath)
        outcome = try container.decodeIfPresent(
            AppRemovalItemOutcome.self,
            forKey: .outcome
        ) ?? (trashPath == nil ? .failed : .movedToTrash)
        evidence = try container.decodeIfPresent(
            AppFileMatchEvidence.self,
            forKey: .evidence
        ) ?? .legacyUnknown
        failure = try container.decodeIfPresent(
            AppFileRemovalFailure.self,
            forKey: .failure
        )
        launchdWasLoaded = try container.decodeIfPresent(
            Bool.self,
            forKey: .launchdWasLoaded
        )
        restoredAt = try container.decodeIfPresent(Date.self, forKey: .restoredAt)
    }
}

struct AppRemovalProtectedItem: Codable, Hashable, Sendable {
    let path: String
    let reason: AppFileProtectionReason
    let matchedItemCount: Int
}

struct AppRemovalRecord: Codable, Identifiable, Hashable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let appName: String
    let bundleIdentifier: String
    let removedAt: Date
    let operation: AppRemovalOperation
    let searchSensitivity: SearchSensitivity?
    var items: [AppRemovalHistoryItem]
    let protectedItems: [AppRemovalProtectedItem]

    init(
        schemaVersion: Int = 4,
        id: UUID = UUID(),
        appName: String,
        bundleIdentifier: String,
        removedAt: Date = Date(),
        operation: AppRemovalOperation = .relatedFiles,
        searchSensitivity: SearchSensitivity? = nil,
        items: [AppRemovalHistoryItem],
        protectedItems: [AppRemovalProtectedItem] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.removedAt = removedAt
        self.operation = operation
        self.searchSensitivity = searchSensitivity
        self.items = items
        self.protectedItems = protectedItems
    }

    var restorableItemCount: Int {
        items.reduce(into: 0) { count, item in
            if item.outcome == .movedToTrash,
               item.restoredAt == nil,
               item.trashPath != nil {
                count += 1
            }
        }
    }

    var movedItemCount: Int {
        items.count { $0.outcome == .movedToTrash }
    }

    var missingItemCount: Int {
        items.count { $0.outcome == .alreadyMissing }
    }

    var failedItemCount: Int {
        items.count { $0.outcome == .failed }
    }

    var restoredItemCount: Int {
        items.count { $0.restoredAt != nil }
    }

    var protectedMatchCount: Int {
        protectedItems.reduce(0) { $0 + $1.matchedItemCount }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case appName
        case bundleIdentifier
        case removedAt
        case operation
        case searchSensitivity
        case items
        case protectedItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try container.decode(UUID.self, forKey: .id)
        appName = try container.decode(String.self, forKey: .appName)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        removedAt = try container.decode(Date.self, forKey: .removedAt)
        operation = try container.decodeIfPresent(
            AppRemovalOperation.self,
            forKey: .operation
        ) ?? .legacyRemoval
        searchSensitivity = try container.decodeIfPresent(
            SearchSensitivity.self,
            forKey: .searchSensitivity
        )
        items = try container.decode([AppRemovalHistoryItem].self, forKey: .items)
        protectedItems = try container.decodeIfPresent(
            [AppRemovalProtectedItem].self,
            forKey: .protectedItems
        ) ?? []
    }
}

enum AppRemovalReportExporter {
    private struct ReportEnvelope: Codable {
        let schemaVersion: Int
        let exportedAt: Date
        let integrityAlgorithm: String
        let integrityScope: String
        let integrityNote: String
        let receiptSHA256: String
        let receipt: AppRemovalRecord
    }

    static func data(
        for record: AppRemovalRecord,
        exportedAt: Date = Date()
    ) throws -> Data {
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.dateEncodingStrategy = .iso8601
        canonicalEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let receiptData = try canonicalEncoder.encode(record)
        let digest = SHA256.hash(data: receiptData)
            .map { String(format: "%02x", $0) }
            .joined()

        let report = ReportEnvelope(
            schemaVersion: 1,
            exportedAt: exportedAt,
            integrityAlgorithm: "SHA-256",
            integrityScope: "Canonical receipt JSON with ISO-8601 dates, sorted keys, and unescaped slashes",
            integrityNote: "Integrity checksum only; not a digital signature",
            receiptSHA256: digest,
            receipt: record
        )
        let reportEncoder = JSONEncoder()
        reportEncoder.dateEncodingStrategy = .iso8601
        reportEncoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        return try reportEncoder.encode(report)
    }

    static func write(_ record: AppRemovalRecord, to url: URL) throws {
        try data(for: record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }
}

/// Small local receipt store. Its contents are never trusted as authorization
/// to restore; `AppRemovalRestorer` independently validates source and target.
final class AppRemovalHistoryStore: @unchecked Sendable {
    static let shared = AppRemovalHistoryStore()

    private static let maximumRecords = 50
    private static let maximumBytes = 2_000_000
    private let fileURL: URL
    private let lock = NSLock()
    private var records: [AppRemovalRecord]

    init(fileURL: URL = AppRemovalHistoryStore.defaultFileURL) {
        self.fileURL = fileURL
        self.records = Self.load(from: fileURL)
    }

    func snapshot() -> [AppRemovalRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    @discardableResult
    func append(_ record: AppRemovalRecord) -> Bool {
        guard !record.items.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        let previous = records
        records.insert(record, at: 0)
        if records.count > Self.maximumRecords {
            records.removeLast(records.count - Self.maximumRecords)
        }
        guard persistLocked() else {
            records = previous
            return false
        }
        return true
    }

    @discardableResult
    func replace(_ record: AppRemovalRecord) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.id == record.id }) else {
            return false
        }
        let previous = records[index]
        records[index] = record
        guard persistLocked() else {
            records[index] = previous
            return false
        }
        return true
    }

    @discardableResult
    func remove(recordID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let previous = records
        records.removeAll { $0.id == recordID }
        guard records != previous else { return true }
        let succeeded: Bool
        if records.isEmpty {
            succeeded = removeStoreFileLocked()
        } else {
            succeeded = persistLocked()
        }
        guard succeeded else {
            records = previous
            return false
        }
        return true
    }

    @discardableResult
    func removeAll() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !records.isEmpty || FileManager.default.fileExists(atPath: fileURL.path) else {
            return true
        }
        guard removeStoreFileLocked() else { return false }
        records.removeAll()
        return true
    }

    @discardableResult
    func markRestored(
        recordID: UUID,
        itemID: UUID,
        at date: Date = Date()
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let recordIndex = records.firstIndex(where: { $0.id == recordID }),
              let itemIndex = records[recordIndex].items.firstIndex(where: { $0.id == itemID }) else {
            return false
        }
        // The filesystem restore has already succeeded before this method is
        // called. Keep the current session truthful even if the local receipt
        // cannot be persisted; the caller surfaces that persistence failure.
        records[recordIndex].items[itemIndex].restoredAt = date
        return persistLocked()
    }

    private func persistLocked() -> Bool {
        guard let data = try? JSONEncoder().encode(records) else {
            Logger.shared.log("Could not encode removal history", level: .warning)
            return false
        }
        guard data.count <= Self.maximumBytes else {
            Logger.shared.log("Removal history exceeded its 2 MB safety limit", level: .warning)
            return false
        }
        do {
            let directory = fileURL.deletingLastPathComponent()
            let directoryAlreadyExisted = FileManager.default.fileExists(atPath: directory.path)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            // Do not chmod a caller-provided existing directory (tests and
            // sandbox-managed temporary folders may reject that operation).
            // Newly created history directories are private from the start.
            if !directoryAlreadyExisted {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o700)],
                    ofItemAtPath: directory.path
                )
            }
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            Logger.shared.log(
                "Could not persist removal history: \(error.localizedDescription)",
                level: .warning
            )
            return false
        }
    }

    private func removeStoreFileLocked() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            Logger.shared.log(
                "Could not clear removal history: \(error.localizedDescription)",
                level: .warning
            )
            return false
        }
    }

    private static func load(from fileURL: URL) -> [AppRemovalRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              data.count <= maximumBytes,
              let decoded = try? JSONDecoder().decode([AppRemovalRecord].self, from: data) else {
            return []
        }
        return decoded
            .filter { record in
                !record.appName.isEmpty
                    && !record.bundleIdentifier.isEmpty
                    && record.appName.count <= 512
                    && record.bundleIdentifier.count <= 1_024
                    && (1...4).contains(record.schemaVersion)
                    && !record.items.isEmpty
                    && record.items.allSatisfy {
                        !$0.originalPath.isEmpty
                            && $0.originalPath.count <= 4_096
                            && ($0.trashPath?.count ?? 0) <= 4_096
                            && ($0.failure?.detail?.count ?? 0) <= 2_048
                            && ($0.outcome != .movedToTrash
                                || $0.trashPath?.isEmpty == false)
                    }
                    && Set(record.items.map(\.id)).count == record.items.count
                    && Set(record.items.map(\.originalPath)).count == record.items.count
                    && record.protectedItems.allSatisfy {
                        !$0.path.isEmpty
                            && $0.path.count <= 4_096
                            && $0.matchedItemCount > 0
                            && $0.matchedItemCount <= 1_000_000
                    }
            }
            .prefix(maximumRecords)
            .map { $0 }
    }

    private static var defaultFileURL: URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return root
            .appendingPathComponent(
                Bundle.main.bundleIdentifier ?? ProductIdentity.bundleIdentifier,
                isDirectory: true
            )
            .appendingPathComponent("app-removal-history.json")
    }
}

struct AppRemovalRestorer: Sendable {
    enum Outcome: Equatable, Sendable {
        case restored
        case sourceMissing
        case destinationExists
        case requiresAdministratorAccess
        case authorizationCancelled
        case blocked
        case failed(String)
    }

    typealias FileExists = @Sendable (String) -> Bool
    typealias MoveOperation = @Sendable (URL, URL) throws -> Void

    private let trashRoot: URL
    private let allowedDestinationRoots: [URL]
    private let fileExists: FileExists
    private let moveOperation: MoveOperation

    init(
        trashRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true),
        allowedDestinationRoots: [URL] = AppRemovalRestorer.defaultAllowedDestinationRoots,
        fileExists: @escaping FileExists = { FileManager.default.fileExists(atPath: $0) },
        moveOperation: @escaping MoveOperation = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    ) {
        self.trashRoot = trashRoot
        self.allowedDestinationRoots = allowedDestinationRoots
        self.fileExists = fileExists
        self.moveOperation = moveOperation
    }

    func restore(_ item: AppRemovalHistoryItem) -> Outcome {
        guard item.outcome == .movedToTrash,
              let trashPath = item.trashPath,
              !trashPath.isEmpty else {
            return .blocked
        }
        let source = URL(fileURLWithPath: trashPath)
        let destination = URL(fileURLWithPath: item.originalPath)
        guard isSafeSource(source), isSafeDestination(destination) else {
            return .blocked
        }
        guard fileExists(source.path) else { return .sourceMissing }
        guard !fileExists(destination.path) else { return .destinationExists }

        do {
            try moveOperation(source, destination)
            return .restored
        } catch {
            if Self.isPermissionDenied(error as NSError) {
                return .requiresAdministratorAccess
            }
            return .failed(error.localizedDescription)
        }
    }

    private func isSafeSource(_ source: URL) -> Bool {
        if (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return false
        }
        let rootPath = trashRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
        return sourcePath.hasPrefix(rootPath + "/")
    }

    private func isSafeDestination(_ destination: URL) -> Bool {
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        let resolvedParent = parent.resolvingSymlinksInPath()
        guard parent.path == resolvedParent.path else { return false }

        let path = resolvedParent.appendingPathComponent(destination.lastPathComponent).path
        for blocked in highRiskHomeDotPaths {
            if path == blocked || path.hasPrefix(blocked + "/") { return false }
        }

        return allowedDestinationRoots.contains { root in
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }

    private static func isPermissionDenied(_ error: NSError) -> Bool {
        if (error.domain == NSCocoaErrorDomain && [
            NSFileReadNoPermissionError,
            NSFileWriteNoPermissionError,
        ].contains(error.code)) ||
            (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code)) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionDenied(underlying)
        }
        return false
    }

    private static let defaultAllowedDestinationRoots: [URL] = {
        let paths = Locations().appSearch.paths.filter { !$0.isEmpty }
        return Array(Set(paths)).map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
    }()
}

/// A deliberately narrower boundary than uninstall. Reset keeps every app or
/// executable bundle installed and accepts only reviewed data below the
/// current user's Library. System-wide components, shared group containers,
/// launch items, command-line tools, and arbitrary dot-directories remain in
/// the normal evidence-only/removal flow instead of being reset implicitly.
struct AppResetSafetyPolicy: Sendable {
    private struct AllowedRoot: Sendable {
        let logicalPath: String
        let resolvedPath: String
    }

    private static let executablePackageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "kext", "plugin",
        "prefpane", "saver", "systemextension", "xpc",
    ]

    private let allowedRoots: [AllowedRoot]

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let library = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        self.init(allowedRoots: [
            library.appendingPathComponent("Application Scripts", isDirectory: true),
            library.appendingPathComponent("Application Support", isDirectory: true),
            library.appendingPathComponent("Caches", isDirectory: true),
            library.appendingPathComponent("Containers", isDirectory: true),
            library.appendingPathComponent("HTTPStorages", isDirectory: true),
            library.appendingPathComponent("Logs", isDirectory: true),
            library.appendingPathComponent("Preferences", isDirectory: true),
            library.appendingPathComponent("Saved Application State", isDirectory: true),
            library.appendingPathComponent("WebKit", isDirectory: true),
        ])
    }

    init(allowedRoots: [URL]) {
        self.allowedRoots = allowedRoots.map {
            let logicalRoot = $0.standardizedFileURL
            return AllowedRoot(
                logicalPath: logicalRoot.path,
                resolvedPath: logicalRoot.resolvingSymlinksInPath().path
            )
        }
    }

    func isEligible(_ candidate: URL, for app: InstalledApp) -> Bool {
        let standardizedCandidate = candidate.standardizedFileURL
        let resolvedCandidate = standardizedCandidate.resolvingSymlinksInPath()
        let candidatePath = resolvedCandidate.path
        let appPath = app.path.standardizedFileURL.resolvingSymlinksInPath().path

        guard candidatePath != appPath,
              !candidatePath.hasPrefix(appPath + "/") else {
            return false
        }

        let packagePathComponents = standardizedCandidate.pathComponents
            + resolvedCandidate.pathComponents
        guard !packagePathComponents.contains(where: { component in
            Self.executablePackageExtensions.contains(
                URL(fileURLWithPath: component).pathExtension.lowercased()
            )
        }) else {
            return false
        }

        return allowedRoots.contains { root in
            guard standardizedCandidate.path.hasPrefix(root.logicalPath + "/"),
                  candidatePath.hasPrefix(root.resolvedPath + "/") else {
                return false
            }

            // Permit an allowed root itself to be relocated through a symlink,
            // but reject any symlink traversal below that root. Otherwise a
            // reviewed path could resolve into a different app's data or an
            // executable package between the visible Library root and item.
            let logicalSuffix = standardizedCandidate.path.dropFirst(root.logicalPath.count)
            let resolvedSuffix = candidatePath.dropFirst(root.resolvedPath.count)
            return logicalSuffix.elementsEqual(resolvedSuffix)
        }
    }
}

/// Final deletion-boundary guard. Scanner quality must never be the only thing
/// preventing one app uninstall from moving a different `.app` bundle (or a
/// path inside it) to the Trash.
enum AppRemovalSafetyPolicy {
    private static let privateLibraryDirectories: Set<String> = [
        "Application Scripts",
        "Application Support",
        "Caches",
        "Containers",
        "Group Containers",
        "HTTPStorages",
        "Logs",
        "Saved Application State",
        "WebKit",
    ]

    private static let identifierSeparators: Set<Character> = [".", "-", "_", " ", "\t"]
    private static let identityFileExtensions: Set<String> = [
        "crash", "db", "ips", "json", "log", "plist", "sqlite", "sqlite3",
    ]
    private static let recoveryHostDirectoryNames: Set<String> = [
        "archive", "archives", "backup", "backups", "recoveries", "recovery",
        "restore", "restores", "snapshot", "snapshots",
    ]

    static func protection(
        containing candidate: URL,
        selectedApp: InstalledApp,
        installedApps: [InstalledApp],
        evidence: AppFileMatchEvidence = .legacyUnknown
    ) -> AppFileProtection? {
        if let foreignBundle = foreignApplicationBundle(
            containing: candidate,
            selectedAppURL: selectedApp.path
        ) {
            return AppFileProtection(
                candidateURL: candidate,
                protectedRoot: foreignBundle,
                reason: .foreignApplication
            )
        }

        if let sharedContainer = sharedContainerRoot(
            containing: candidate,
            selectedApp: selectedApp
        ) {
            return AppFileProtection(
                candidateURL: candidate,
                protectedRoot: sharedContainer,
                reason: .sharedContainer
            )
        }

        let foreignApps = installedApps.filter { $0.id != selectedApp.id }
        guard let namespaces = privateDataNamespaces(containing: candidate) else {
            return nil
        }

        if let recoveryDataRoot = recoveryDataRoot(containing: candidate),
           !isStrongOwnershipEvidence(evidence) {
            return AppFileProtection(
                candidateURL: candidate,
                protectedRoot: recoveryDataRoot,
                reason: .ambiguousName
            )
        }

        for namespace in namespaces {
            let component = namespace.lastPathComponent
            let matchesSelectedApp = componentMatchesAppIdentity(component, app: selectedApp)
            if foreignApps.contains(where: { componentMatchesAppIdentity(component, app: $0) }) {
                return AppFileProtection(
                    candidateURL: candidate,
                    protectedRoot: namespace,
                    reason: matchesSelectedApp ? .sharedIdentity : .foreignPrivateData
                )
            }

            if matchesSelectedApp {
                continue
            }

            if looksLikeNamespacedIdentifier(component) {
                return AppFileProtection(
                    candidateURL: candidate,
                    protectedRoot: namespace,
                    reason: .foreignPrivateData
                )
            }

            if looksLikeSiblingDisplayNamespace(component, of: selectedApp) {
                return AppFileProtection(
                    candidateURL: candidate,
                    protectedRoot: namespace,
                    reason: .ambiguousName
                )
            }
        }

        return nil
    }

    private static func isStrongOwnershipEvidence(
        _ evidence: AppFileMatchEvidence
    ) -> Bool {
        // A Team ID proves only the publisher and is deliberately absent:
        // one developer can ship several apps that must not own each other's
        // backup data.
        switch evidence {
        case .selectedApplication,
             .appSpecificRule,
             .exactBundleIdentifier,
             .structuredBundleIdentifier,
             .verifiedEntitlement,
             .containerMetadata:
            return true
        case .exactAppName,
             .exactBundlePathName,
             .bundleIdentifierSuffix,
             .baseBundleIdentifier,
             .versionStrippedName,
             .legacyUnknown:
            return false
        }
    }

    static func foreignApplicationBundle(
        containing candidate: URL,
        selectedAppURL: URL
    ) -> URL? {
        guard let enclosingBundle = enclosingApplicationBundle(for: candidate) else {
            return nil
        }

        let selectedPath = selectedAppURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let enclosingPath = enclosingBundle.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return enclosingPath == selectedPath ? nil : enclosingBundle
    }

    static func foreignApplicationBundles(
        in candidates: Set<URL>,
        selectedAppURL: URL
    ) -> [URL] {
        Set(candidates.compactMap {
            foreignApplicationBundle(containing: $0, selectedAppURL: selectedAppURL)
        })
        .sorted { $0.path < $1.path }
    }

    /// Finds app-private Library namespaces that are demonstrably owned by a
    /// different installed application, or whose reverse-DNS namespace is
    /// unrelated to the selected app. A matching filename inside another
    /// app's data directory is not ownership evidence (for example App
    /// Cleaner indexing `com.openai.codex.*.plist`).
    static func foreignPrivateDataOwner(
        containing candidate: URL,
        selectedApp: InstalledApp,
        installedApps: [InstalledApp]
    ) -> URL? {
        guard let protection = protection(
            containing: candidate,
            selectedApp: selectedApp,
            installedApps: installedApps
        ), protection.reason != .foreignApplication else { return nil }
        return protection.protectedRoot
    }

    static func foreignPrivateDataOwners(
        in candidates: Set<URL>,
        selectedApp: InstalledApp,
        installedApps: [InstalledApp]
    ) -> [URL] {
        Set(candidates.compactMap {
            foreignPrivateDataOwner(
                containing: $0,
                selectedApp: selectedApp,
                installedApps: installedApps
            )
        })
        .sorted { $0.path < $1.path }
    }

    /// Names installed apps only when the protected root itself supplies
    /// direct ownership evidence. This never upgrades a relationship into
    /// removal authorization; it only explains why the root stays excluded.
    static func relatedApplications(
        for protection: AppFileProtection,
        selectedApp: InstalledApp,
        installedApps: [InstalledApp]
    ) -> [AppRelationshipApplication] {
        let foreignApps = installedApps.filter { $0.id != selectedApp.id }
        let matches: [InstalledApp]

        switch protection.reason {
        case .foreignApplication:
            let protectedPath = protection.protectedRoot.standardizedFileURL
                .resolvingSymlinksInPath().path
            matches = foreignApps.filter {
                $0.path.standardizedFileURL.resolvingSymlinksInPath().path == protectedPath
            }

        case .sharedContainer:
            guard selectedApp.signature.status == .developerSigned,
                  let selectedTeam = selectedApp.signature.teamIdentifier else {
                return []
            }
            let identifier = protection.protectedRoot.lastPathComponent
            matches = foreignApps.filter { app in
                app.signature.status == .developerSigned
                    && app.signature.teamIdentifier == selectedTeam
                    && app.signature.sharedContainerIdentifiers.contains(identifier)
            }

        case .sharedIdentity, .foreignPrivateData:
            let component = protection.protectedRoot.lastPathComponent
            matches = foreignApps.filter {
                componentMatchesAppIdentity(component, app: $0)
            }

        case .ambiguousName:
            matches = []
        }

        var applications = matches.map(relationshipApplication)
        if protection.reason == .foreignApplication, applications.isEmpty {
            let root = protection.protectedRoot.standardizedFileURL
            applications = [
                AppRelationshipApplication(
                    id: root.resolvingSymlinksInPath().path,
                    name: root.deletingPathExtension().lastPathComponent,
                    bundleIdentifier: "",
                    url: root,
                    teamIdentifier: "",
                    groupIdentifiers: []
                )
            ]
        }
        return applications.sorted(by: AppRelationshipScanner.applicationSort)
    }

    private static func enclosingApplicationBundle(for url: URL) -> URL? {
        let components = url.standardizedFileURL.pathComponents
        guard components.first == "/" else { return nil }

        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst() {
            current.appendPathComponent(component)
            if current.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                return current
            }
        }
        return nil
    }

    private static func relationshipApplication(
        _ app: InstalledApp
    ) -> AppRelationshipApplication {
        AppRelationshipApplication(
            id: app.id,
            name: app.appName,
            bundleIdentifier: app.bundleIdentifier,
            url: app.path.standardizedFileURL,
            teamIdentifier: app.signature.teamIdentifier ?? "",
            groupIdentifiers: app.signature.sharedContainerIdentifiers
        )
    }

    private static func sharedContainerRoot(
        containing candidate: URL,
        selectedApp: InstalledApp
    ) -> URL? {
        guard selectedApp.signature.status == .developerSigned else { return nil }
        let sharedIdentifiers = Set(
            selectedApp.signature.sharedContainerIdentifiers.map(canonical)
        )
        guard !sharedIdentifiers.isEmpty else { return nil }

        let components = candidate.standardizedFileURL.pathComponents
        guard components.first == "/" else { return nil }

        for libraryIndex in components.indices where components[libraryIndex] == "Library" {
            let categoryIndex = components.index(after: libraryIndex)
            guard categoryIndex < components.endIndex,
                  components[categoryIndex] == "Group Containers"
                    || components[categoryIndex] == "Application Scripts" else {
                continue
            }

            let identifierIndex = components.index(after: categoryIndex)
            guard identifierIndex < components.endIndex,
                  sharedIdentifiers.contains(canonical(components[identifierIndex])) else {
                continue
            }

            let rootPath = "/" + components[...identifierIndex]
                .dropFirst()
                .joined(separator: "/")
            return URL(fileURLWithPath: rootPath)
        }

        return nil
    }

    /// Returns every path component below a recognized app-private Library
    /// root, paired with its full URL. Inspecting all components catches both
    /// `Application Support/Slack/...` and vendor-nested shared names such as
    /// `Application Support/OpenAI/ChatGPT`.
    private static func privateDataNamespaces(containing url: URL) -> [URL]? {
        let components = url.standardizedFileURL.pathComponents
        guard components.first == "/" else { return nil }

        var privateRootIndex: Int?
        for index in components.indices where components[index] == "Library" {
            let categoryIndex = components.index(after: index)
            guard categoryIndex < components.endIndex,
                  privateLibraryDirectories.contains(components[categoryIndex]) else {
                continue
            }
            privateRootIndex = categoryIndex
            break
        }

        guard let privateRootIndex else { return nil }
        let firstNamespaceIndex = components.index(after: privateRootIndex)
        guard firstNamespaceIndex < components.endIndex else { return nil }

        var namespaces: [URL] = []
        var namespaceURL = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, component) in components.dropFirst().enumerated() {
            namespaceURL.appendPathComponent(component)
            let componentIndex = components.index(components.startIndex, offsetBy: index + 1)
            if componentIndex >= firstNamespaceIndex {
                namespaces.append(namespaceURL)
            }
        }
        return namespaces
    }

    /// A weak name or partial-identifier match below another tool's generic
    /// backup/archive host is not ownership evidence. Protect only the first
    /// subtree below the nearest host so unrelated backups stay independent.
    private static func recoveryDataRoot(containing url: URL) -> URL? {
        let components = url.standardizedFileURL.pathComponents
        guard components.first == "/" else { return nil }

        for libraryIndex in components.indices where components[libraryIndex] == "Library" {
            let categoryIndex = components.index(after: libraryIndex)
            guard categoryIndex < components.endIndex,
                  privateLibraryDirectories.contains(components[categoryIndex]) else {
                continue
            }

            var nearestDataIndex: Int?
            var hostIndex = components.index(after: categoryIndex)
            while hostIndex < components.endIndex {
                if recoveryHostDirectoryNames.contains(canonical(components[hostIndex])) {
                    let dataIndex = components.index(after: hostIndex)
                    if dataIndex < components.endIndex {
                        nearestDataIndex = dataIndex
                    }
                }
                hostIndex = components.index(after: hostIndex)
            }

            if let nearestDataIndex {
                let rootPath = "/" + components[...nearestDataIndex]
                    .dropFirst()
                    .joined(separator: "/")
                return URL(fileURLWithPath: rootPath)
            }
        }

        return nil
    }

    private static func componentMatchesAppIdentity(_ component: String, app: InstalledApp) -> Bool {
        let candidate = canonical(component)
        let pathExtension = (component as NSString).pathExtension.lowercased()
        let candidateWithoutExtension = identityFileExtensions.contains(pathExtension)
            ? canonical((component as NSString).deletingPathExtension)
            : candidate
        let exactNames = [
            app.appName,
            app.path.deletingPathExtension().lastPathComponent,
            app.appName.strippingTrailingVersion(),
        ]
        .map(canonical)
        .filter { !$0.isEmpty }
        if exactNames.contains(candidate) || exactNames.contains(candidateWithoutExtension) {
            return true
        }

        var structuredIdentifiers = [app.bundleIdentifier]
        if app.signature.status == .developerSigned {
            structuredIdentifiers.append(contentsOf: app.signature.entitlementIdentifiers)
        }
        return structuredIdentifiers
            .map(canonical)
            .filter { !$0.isEmpty }
            .contains { structuredIdentity(candidate, matches: $0) }
    }

    private static func structuredIdentity(_ candidate: String, matches identifier: String) -> Bool {
        if candidate == identifier { return true }
        guard candidate.hasPrefix(identifier), candidate.count > identifier.count else {
            return false
        }
        let boundary = candidate.index(candidate.startIndex, offsetBy: identifier.count)
        return identifierSeparators.contains(candidate[boundary])
    }

    private static func looksLikeNamespacedIdentifier(_ component: String) -> Bool {
        let segments = canonical(component).split(separator: ".", omittingEmptySubsequences: true)
        return segments.count >= 3
    }

    private static func looksLikeSiblingDisplayNamespace(
        _ component: String,
        of app: InstalledApp
    ) -> Bool {
        let candidate = canonical(component)
        let selectedNames = [
            app.appName,
            app.path.deletingPathExtension().lastPathComponent,
            app.appName.strippingTrailingVersion(),
        ]
        .map(canonical)
        .filter { $0.count >= 5 }

        return selectedNames.contains { selectedName in
            guard candidate.hasPrefix(selectedName), candidate.count > selectedName.count else {
                return false
            }
            let boundary = candidate.index(candidate.startIndex, offsetBy: selectedName.count)
            return identifierSeparators.contains(candidate[boundary])
        }
    }

    private static func canonical(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Standalone observable for the live scan-path ticker. The scan engine reports
/// the filesystem path it is touching ~10×/sec. Routing that through AppState's
/// own `@Published` storage republished the *entire* view tree at that rate,
/// which surfaced as window-drag / button-hover lag and a Smart Scan that
/// looked frozen until you switched sidebar sections and forced a fresh render
/// (issues #119, #120). Isolating the high-frequency value here means only the
/// small ticker label observes it, so the rest of the UI stays still.
@MainActor
final class ScanProgressTicker: ObservableObject {
    @Published var path: String = ""
}

@MainActor
final class AppState: ObservableObject {
    typealias AppFileScanCancellation = @Sendable () -> Void
    typealias AppFileScanner = @MainActor @Sendable (
        _ app: InstalledApp,
        _ searchPaths: [String],
        _ completion: @escaping @MainActor @Sendable (Set<URL>) -> Void
    ) -> AppFileScanCancellation?
    typealias AppFileTrashHandler = @MainActor @Sendable (
        _ urls: [URL]
    ) async -> AppFileTrashResult
    typealias TrashAppSuppressor = @MainActor @Sendable (
        _ trashURLs: [URL]
    ) -> Void
    typealias AppTerminationHandler = @MainActor (
        _ app: InstalledApp,
        _ timeout: TimeInterval
    ) async -> AppTerminationResult
    typealias AppInstallationInspectorHandler = @Sendable (
        _ app: InstalledApp,
        _ shouldCancel: @Sendable () -> Bool
    ) -> AppInstallationInsights
    typealias AppRelationshipsScanner = @Sendable (
        [AppRelationshipApplicationReference],
        String,
        @Sendable () -> Bool
    ) -> AppRelationshipScanResult
    typealias StartupItemsScanner = @Sendable () -> StartupItemScanResult
    typealias ManagedExtensionsScanner = @Sendable (
        [ExtensionOwnerApp]
    ) -> ManagedExtensionScanResult
    typealias AppPermissionsScanner = @Sendable (
        [AppPermissionApplicationReference]
    ) -> AppPermissionScanResult
    typealias DefaultApplicationsScanner = @Sendable (
        [URL]
    ) -> DefaultApplicationScanResult
    typealias AppUpdatesScanner = @Sendable ([InstalledApp]) async -> AppUpdateScanResult
    typealias InstallationFilesScanner = @Sendable (
        [InstallationFileApplicationReference],
        [URL]
    ) async -> InstallationFileScanResult

    enum AppTerminationResult {
        case notRunning
        case terminated
        case stillRunning
    }

    private enum InstallationAction {
        case revealHomebrewReceipt(HomebrewCaskInstallMetadata)
        case openOfficialUninstaller(AppOfficialUninstaller)
    }

    // MARK: - Scan / Clean State

    @Published var selectedCategory: CleaningCategory = .smartScan
    @Published var scanState: ScanState = .idle
    @Published var categoryResults: [CleaningCategory: CategoryResult] = [:]
    @Published var diskInfo = DiskInfo()
    @Published var totalJunkSize: Int64 = 0
    @Published var totalFreedSpace: Int64 = 0
    @Published var scanProgress: Double = 0
    @Published var cleanProgress: Double = 0
    @Published var currentScanCategory: String = ""
    /// Live filesystem path the scan engine is touching, feeding the dashboard's
    /// ticker. Deliberately NOT a `@Published` on AppState — it updates ~10×/sec
    /// and would otherwise invalidate the whole view tree (issues #119, #120).
    /// Only the ticker label observes this object directly.
    let scanTicker = ScanProgressTicker()
    @Published var showCleanConfirmation = false
    @Published var lastCleanedDate: Date?
    @Published var selectedCleanupItems: Set<UUID> = []
    @Published var deselectedItems: Set<UUID> = []
    @Published var hasFullDiskAccess: Bool = true
    @Published var fdaBannerDismissed: Bool = false
    @Published var cleanError: String?
    /// True when the most recent clean error is rooted in a TCC/FDA refusal
    /// (i.e. items survived even the admin pass). MainWindow uses this to
    /// route the user into the PermissionSheet instead of the generic alert.
    @Published var cleanErrorIsFDAFixable: Bool = false
    /// Items that survived the most recent clean attempt — used to re-run the
    /// operation after the user grants Full Disk Access without forcing them
    /// to re-select anything.
    @Published var pendingPermissionRetryItems: [CleanableItem] = []

    // MARK: - Time Machine Snapshot State

    @Published var localTimeMachineSnapshots: [TimeMachineSnapshot] = []
    @Published var selectedTimeMachineSnapshotIDs: Set<String> = []
    @Published var isScanningTimeMachineSnapshots = false
    @Published var isDeletingTimeMachineSnapshots = false
    @Published var hasScannedTimeMachineSnapshots = false
    @Published var isTimeMachineBackupRunning = false
    @Published var timeMachineSnapshotError: String?
    @Published var lastTimeMachineFreedSpace: Int64 = 0
    @Published var lastTimeMachineDeletedCount: Int = 0
    @Published var lastTimeMachineSnapshotScanDate: Date?

    // MARK: - App Uninstaller State

    @Published var installedApps: [InstalledApp] = []
    @Published var selectedApp: InstalledApp?
    @Published var discoveredFiles: [URL] = []
    @Published var protectedAppFiles: [ProtectedAppFile] = []
    @Published private(set) var appFileMatchEvidenceByPath: [String: AppFileMatchEvidence] = [:]
    @Published private(set) var currentAppSearchSensitivity: SearchSensitivity = .enhanced
    @Published var selectedFiles: Set<URL> = [] {
        didSet {
            selectedFilesOwnerAppID = selectedFiles.isEmpty ? nil : selectedApp?.id
        }
    }
    @Published var orphanedFiles: [URL] = []
    @Published var isSearchingOrphans: Bool = false
    @Published var isLoadingApps: Bool = false
    @Published var isCalculatingAppSizes: Bool = false
    @Published var appSizeCalculationProgress: Double = 0
    @Published var isScanningAppFiles: Bool = false
    @Published var isRemovingAppFiles: Bool = false
    @Published var removalError: String?
    @Published var removalNeedsFullDiskAccess = false
    @Published var removalHistory: [AppRemovalRecord] = []
    @Published var removalHistoryError: String?
    @Published var restoringRemovalItemIDs: Set<UUID> = []
    @Published var appFileScanLocationCount: Int = 0
    @Published private(set) var selectedAppInstallationInsights: AppInstallationInsights?
    @Published private(set) var isInspectingAppInstallation = false
    @Published private(set) var selectedAppRelationships: AppRelationshipScanResult?
    @Published private(set) var isScanningAppRelationships = false
    @Published private(set) var isVerifyingInstallationAction = false
    @Published var appInstallationActionError: String?
    @Published private(set) var startupItems: [StartupItem] = []
    @Published private(set) var isScanningStartupItems = false
    @Published private(set) var hasScannedStartupItems = false
    @Published private(set) var startupBackgroundTaskDataAvailable = true
    @Published private(set) var startupBackgroundTaskDataTruncated = false
    @Published private(set) var startupItemControlHistory: [StartupItemControlRecord] = []
    @Published private(set) var activeStartupItemActionID: String?
    @Published var startupItemActionError: String?
    @Published var startupItemActionMessage: String?
    @Published private(set) var managedExtensions: [ManagedExtension] = []
    @Published private(set) var incompleteExtensionSources: Set<ManagedExtensionScanSource> = []
    @Published private(set) var isScanningExtensions = false
    @Published private(set) var hasScannedExtensions = false
    @Published var extensionActionError: String?
    @Published private(set) var appPermissionClients: [AppPermissionClient] = []
    @Published private(set) var appPermissionSources: [AppPermissionDatabaseSource] = []
    @Published private(set) var isScanningAppPermissions = false
    @Published private(set) var hasScannedAppPermissions = false
    @Published private(set) var lastAppPermissionScanDate: Date?
    @Published private(set) var appPermissionScanWasTruncated = false
    @Published private(set) var activeAppPermissionActionID: String?
    @Published var appPermissionActionError: String?
    @Published var appPermissionActionMessage: String?
    @Published private(set) var defaultApplications: [DefaultApplicationItem] = []
    @Published private(set) var unreadableDefaultApplicationDeclarationCount = 0
    @Published private(set) var defaultApplicationScanWasTruncated = false
    @Published private(set) var isScanningDefaultApplications = false
    @Published private(set) var hasScannedDefaultApplications = false
    @Published private(set) var defaultApplicationControlHistory: [DefaultApplicationControlRecord] = []
    @Published private(set) var activeDefaultApplicationActionID: String?
    @Published var defaultApplicationActionError: String?
    @Published var defaultApplicationActionMessage: String?
    @Published private(set) var appUpdates: [AppUpdateItem] = []
    @Published private(set) var appUpdateUnsupportedAppCount = 0
    @Published private(set) var isScanningAppUpdates = false
    @Published private(set) var hasScannedAppUpdates = false
    @Published private(set) var lastAppUpdateScanDate: Date?
    @Published private(set) var activeAppUpdateActionID: String?
    @Published var appUpdateScanError: String?
    @Published var appUpdateActionError: String?
    @Published var appUpdateActionMessage: String?
    @Published private(set) var installationFiles: [InstallationFileItem] = []
    @Published var selectedInstallationFileIDs: Set<String> = []
    @Published private(set) var explicitlyApprovedInstallationFileIDs: Set<String> = []
    @Published private(set) var installationFileIgnoredCount = 0
    @Published private(set) var installationFileInaccessibleCount = 0
    @Published private(set) var installationFileScanWasTruncated = false
    @Published private(set) var isScanningInstallationFiles = false
    @Published private(set) var isRemovingInstallationFiles = false
    @Published private(set) var hasScannedInstallationFiles = false
    @Published private(set) var lastInstallationFileScanDate: Date?
    @Published private(set) var installationFileRemovalHistory: [InstallationFileRemovalRecord] = []
    @Published var installationFileActionError: String?
    @Published var installationFileActionMessage: String?
    /// Set when a right-clicked app arrives via the Finder Services handler.
    /// MainWindow consumes it on both onChange AND onAppear so a request that
    /// lands before MainWindow mounts (cold launch, or while onboarding is
    /// still showing) is still surfaced — a one-shot token would be missed.
    @Published var pendingExternalApp: InstalledApp?
    /// Newly detected Trash apps waiting for an explicit review. They are
    /// never scanned or removed merely because the directory watcher saw them.
    @Published private(set) var pendingTrashAppReviews: [TrashAppCandidate] = []
    /// True only for a review launched from the Trash watcher. The app bundle
    /// is excluded from this scan and app-reset controls are not applicable.
    @Published private(set) var isReviewingTrashedApp = false

    private var externalAppActionObserver: AnyCancellable?
    private var trashAppsDetectedObserver: AnyCancellable?
    private var trashAppsReviewObserver: AnyCancellable?
    private var installedAppsLoadTask: Task<Void, Never>?
    private var activeInstalledAppsLoadID = UUID()
    private var activeAppFileScanCancellation: AppFileScanCancellation?
    private var activeAppFileScanID = UUID()
    private var appInstallationInspectionTask: Task<AppInstallationInsights, Never>?
    private var activeAppInstallationInspectionID = UUID()
    private var appRelationshipScanTask: Task<AppRelationshipScanResult, Never>?
    private var activeAppRelationshipScanID = UUID()
    private var startupItemsScanTask: Task<StartupItemScanResult, Never>?
    private var activeStartupItemsScanID = UUID()
    private var activeStartupItemControlOperationID = UUID()
    private var extensionsScanTask: Task<ManagedExtensionScanResult, Never>?
    private var activeExtensionsScanID = UUID()
    private var appPermissionsScanTask: Task<AppPermissionScanResult, Never>?
    private var activeAppPermissionsScanID = UUID()
    private var activeAppPermissionControlOperationID = UUID()
    private var defaultApplicationsScanTask: Task<DefaultApplicationScanResult, Never>?
    private var activeDefaultApplicationsScanID = UUID()
    private var activeDefaultApplicationControlOperationID = UUID()
    private var appUpdatesScanTask: Task<AppUpdateScanResult, Never>?
    private var activeAppUpdatesScanID = UUID()
    private var installationFilesScanTask: Task<InstallationFileScanResult, Never>?
    private var activeInstallationFilesScanID = UUID()
    private var discoveredFilesAppID: InstalledApp.ID?
    private var selectedFilesOwnerAppID: InstalledApp.ID?
    private var pendingAppRemovalRetry: (
        app: InstalledApp,
        urls: [URL],
        historyRecordID: UUID,
        operation: AppRemovalOperation
    )?

    // MARK: - Services

    var scheduler = SchedulerService()
    private let scanEngine = ScanEngine()
    private let cleaningEngine = CleaningEngine()
    private let timeMachineSnapshotService = TimeMachineSnapshotService()
    private let locationsProvider: () -> Locations
    private let searchSensitivityProvider: () -> SearchSensitivity
    private let appFileScanner: AppFileScanner
    private let appFileTrashHandler: AppFileTrashHandler
    private let trashAppSuppressor: TrashAppSuppressor
    private let appResetSafetyPolicy: AppResetSafetyPolicy
    private let appTerminationHandler: AppTerminationHandler
    private let appInstallationInspector: AppInstallationInspectorHandler
    private let appRelationshipsScanner: AppRelationshipsScanner
    private let startupItemsScanner: StartupItemsScanner
    private let startupItemController: StartupItemController
    private let managedExtensionsScanner: ManagedExtensionsScanner
    private let appPermissionsScanner: AppPermissionsScanner
    private let appPermissionController: AppPermissionController
    private let defaultApplicationsScanner: DefaultApplicationsScanner
    private let defaultApplicationController: DefaultApplicationController
    private let appUpdatesScanner: AppUpdatesScanner
    private let installationFilesScanner: InstallationFilesScanner
    private let installationFileController: InstallationFileController
    private let externalSparkleUpdateCoordinator = ExternalSparkleUpdateCoordinator()
    private let removalHistoryStore: AppRemovalHistoryStore
    private let appRemovalRestorer: AppRemovalRestorer
    private static let appTerminationTimeout: TimeInterval = 5

    // MARK: - Computed

    var totalItemCount: Int {
        categoryResults.values.reduce(0) { $0 + $1.itemCount }
    }

    var currentCategoryResult: CategoryResult? {
        categoryResults[selectedCategory]
    }

    var allResults: [CategoryResult] {
        CleaningCategory.scannable.compactMap { categoryResults[$0] }.filter { $0.totalSize > 0 }
    }

    var totalSelectedSize: Int64 {
        allResults.flatMap { $0.items }.filter { isItemSelected($0) }.reduce(0) { $0 + $1.size }
    }

    var currentAppFileSearchLocationCount: Int {
        if isScanningAppFiles && appFileScanLocationCount > 0 {
            return appFileScanLocationCount
        }
        return discoveredFiles.count
    }

    var canRemoveSelectedAppFiles: Bool {
        guard !selectedFiles.isEmpty,
              !isScanningAppFiles,
              !isRemovingAppFiles,
              let app = selectedApp,
              !AppSelfRemovalPolicy.isCurrentApplication(
                bundleIdentifier: app.bundleIdentifier
              ),
              discoveredFilesAppID == app.id,
              selectedFilesOwnerAppID == app.id
        else {
            return false
        }

        guard selectedFiles.isSubset(of: Set(discoveredFiles)) else { return false }
        let evidenceFinder = appFileEvidenceFinder(for: app)
        return !selectedFiles.contains {
            AppRemovalSafetyPolicy.protection(
                containing: $0,
                selectedApp: app,
                installedApps: installedApps,
                evidence: evidenceFinder.evidence(for: $0)
            ) != nil
        }
    }

    var selectedFilesRequireAdministratorAccess: Bool {
        guard !selectedFiles.isEmpty else { return false }
        return PrivilegedAppRemovalService().requiresAdministratorAccess(
            for: Array(selectedFiles)
        )
    }

    var availableAppResetFiles: Set<URL> {
        guard let app = selectedApp,
              discoveredFilesAppID == app.id else {
            return []
        }
        return Set(discoveredFiles.filter {
            appResetSafetyPolicy.isEligible($0, for: app)
        })
    }

    var selectedAppResetFiles: Set<URL> {
        selectedFiles.intersection(availableAppResetFiles)
    }

    var canResetSelectedApp: Bool {
        guard !isReviewingTrashedApp,
              !selectedAppResetFiles.isEmpty,
              !isScanningAppFiles,
              !isRemovingAppFiles,
              let app = selectedApp,
              !AppSelfRemovalPolicy.isCurrentApplication(
                bundleIdentifier: app.bundleIdentifier
              ),
              discoveredFilesAppID == app.id,
              selectedFilesOwnerAppID == app.id,
              selectedFiles.isSubset(of: Set(discoveredFiles)) else {
            return false
        }

        let evidenceFinder = appFileEvidenceFinder(for: app)
        return !selectedAppResetFiles.contains {
            AppRemovalSafetyPolicy.protection(
                containing: $0,
                selectedApp: app,
                installedApps: installedApps,
                evidence: evidenceFinder.evidence(for: $0)
            ) != nil
        }
    }

    var availableRestorableItemCount: Int {
        removalHistory.reduce(into: 0) { count, record in
            count += record.items.count { item in
                guard item.outcome == .movedToTrash,
                      item.restoredAt == nil,
                      let trashPath = item.trashPath else { return false }
                return FileManager.default.fileExists(atPath: trashPath)
            }
        }
    }

    var availableAppUpdateCount: Int {
        appUpdates.count { $0.status == .updateAvailable }
    }

    var highImpactAllowedAppPermissionCount: Int {
        appPermissionClients.reduce(0) { $0 + $1.highImpactAllowedCount }
    }

    var removableInstallationFileSize: Int64 {
        installationFiles.lazy
            .filter(\.isRemovable)
            .reduce(0) { $0 + $1.size }
    }

    var selectedInstallationFileSize: Int64 {
        installationFiles.lazy
            .filter { self.selectedInstallationFileIDs.contains($0.id) }
            .reduce(0) { $0 + $1.size }
    }

    var latestUndoableInstallationFileRecord: InstallationFileRemovalRecord? {
        installationFileRemovalHistory.first {
            installationFileController.canUndo($0)
        }
    }

    // MARK: - Init

    init(
        performStartupTasks: Bool = true,
        locationsProvider: @escaping () -> Locations = Locations.init,
        searchSensitivityProvider: @escaping () -> SearchSensitivity = {
            SearchSensitivity.stored()
        },
        appFileScanner: @escaping AppFileScanner = AppState.defaultAppFileScanner,
        appFileTrashHandler: @escaping AppFileTrashHandler = AppState.defaultAppFileTrashHandler,
        trashAppSuppressor: @escaping TrashAppSuppressor = { trashURLs in
            TrashAppWatcher.shared.suppress(trashURLs)
        },
        appResetSafetyPolicy: AppResetSafetyPolicy = AppResetSafetyPolicy(),
        removalHistoryStore: AppRemovalHistoryStore = .shared,
        appRemovalRestorer: AppRemovalRestorer = AppRemovalRestorer(),
        appTerminationHandler: @escaping AppTerminationHandler = AppState.defaultAppTerminationHandler,
        appInstallationInspector: @escaping AppInstallationInspectorHandler = { app, shouldCancel in
            AppInstallationInspector.inspect(
                app: app,
                shouldCancel: shouldCancel
            )
        },
        appRelationshipsScanner: @escaping AppRelationshipsScanner = { applications, selectedID, shouldCancel in
            AppRelationshipScanner.scan(
                applications: applications,
                selectedApplicationID: selectedID,
                shouldCancel: shouldCancel
            )
        },
        startupItemsScanner: @escaping StartupItemsScanner = {
            StartupItemScanner.scan()
        },
        startupItemController: StartupItemController = StartupItemController(),
        managedExtensionsScanner: @escaping ManagedExtensionsScanner = { owners in
            ManagedExtensionScanner.scan(ownerApps: owners)
        },
        appPermissionsScanner: @escaping AppPermissionsScanner = { applications in
            AppPermissionScanner.scan(applications: applications)
        },
        appPermissionController: AppPermissionController = AppPermissionController(),
        defaultApplicationsScanner: @escaping DefaultApplicationsScanner = { applicationURLs in
            DefaultApplicationScanner.scan(applicationURLs: applicationURLs)
        },
        defaultApplicationController: DefaultApplicationController = DefaultApplicationController(),
        appUpdatesScanner: @escaping AppUpdatesScanner = { apps in
            await AppUpdateScanner.scan(apps: apps)
        },
        installationFilesScanner: @escaping InstallationFilesScanner = { apps, additionalURLs in
            await InstallationFileScanner.discover(
                installedApps: apps,
                additionalCandidateURLs: additionalURLs
            )
        },
        installationFileController: InstallationFileController = InstallationFileController()
    ) {
        self.locationsProvider = locationsProvider
        self.searchSensitivityProvider = searchSensitivityProvider
        self.appFileScanner = appFileScanner
        self.appFileTrashHandler = appFileTrashHandler
        self.trashAppSuppressor = trashAppSuppressor
        self.appResetSafetyPolicy = appResetSafetyPolicy
        self.removalHistoryStore = removalHistoryStore
        self.appRemovalRestorer = appRemovalRestorer
        self.appTerminationHandler = appTerminationHandler
        self.appInstallationInspector = appInstallationInspector
        self.appRelationshipsScanner = appRelationshipsScanner
        self.startupItemsScanner = startupItemsScanner
        self.startupItemController = startupItemController
        self.managedExtensionsScanner = managedExtensionsScanner
        self.appPermissionsScanner = appPermissionsScanner
        self.appPermissionController = appPermissionController
        self.defaultApplicationsScanner = defaultApplicationsScanner
        self.defaultApplicationController = defaultApplicationController
        self.appUpdatesScanner = appUpdatesScanner
        self.installationFilesScanner = installationFilesScanner
        self.installationFileController = installationFileController
        self.removalHistory = removalHistoryStore.snapshot()
        self.startupItemControlHistory = startupItemController.historySnapshot()
        self.defaultApplicationControlHistory = defaultApplicationController
            .historySnapshot()
        self.installationFileRemovalHistory = installationFileController
            .historySnapshot()

        // Listen for right-click uninstall/reset hand-offs from Finder.
        externalAppActionObserver = NotificationCenter.default
            .publisher(for: .appSiftExternalAppAction)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                let request: ExternalAppRequest? = {
                    guard let path = note.userInfo?["path"] as? String else {
                        return ExternalAppRequestBuffer.pending
                    }
                    let rawAction = note.userInfo?["action"] as? String
                    return ExternalAppRequest(
                        path: path,
                        action: rawAction.flatMap(ExternalAppAction.init(rawValue:)) ?? .uninstall
                    )
                }()
                ExternalAppRequestBuffer.pending = nil
                guard let request else { return }
                Task { @MainActor in self?.presentExternalApp(request) }
            }
        // Drain a request that arrived before this AppState existed (cold launch
        // via Finder Services — the notification fired with no subscriber).
        if let buffered = ExternalAppRequestBuffer.pending {
            ExternalAppRequestBuffer.pending = nil
            presentExternalApp(buffered)
        }

        trashAppsDetectedObserver = NotificationCenter.default
            .publisher(for: .appSiftTrashAppsDetected)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                let candidates = (note.object as? [TrashAppCandidate])
                    ?? TrashAppRequestBuffer.detectedCandidates
                TrashAppRequestBuffer.detectedCandidates = []
                self?.enqueueTrashAppReviews(candidates)
            }
        trashAppsReviewObserver = NotificationCenter.default
            .publisher(for: .appSiftReviewTrashApps)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                let paths = (note.object as? [String])
                    ?? TrashAppRequestBuffer.reviewPaths
                TrashAppRequestBuffer.reviewPaths = []
                self?.reviewTrashApp(paths: paths)
            }
        if !TrashAppRequestBuffer.detectedCandidates.isEmpty {
            let candidates = TrashAppRequestBuffer.detectedCandidates
            TrashAppRequestBuffer.detectedCandidates = []
            enqueueTrashAppReviews(candidates)
        }
        if !TrashAppRequestBuffer.reviewPaths.isEmpty {
            let paths = TrashAppRequestBuffer.reviewPaths
            TrashAppRequestBuffer.reviewPaths = []
            reviewTrashApp(paths: paths)
        }

        if performStartupTasks {
            loadDiskInfo()
            checkFullDiskAccess()
            loadInstalledApps()
            scheduler.setTrigger { [weak self] in
                await self?.runScheduledScan()
            }
            // Only arm the scheduler once onboarding has completed. Before
            // the first launch the defaults plist may have been
            // attacker-planted with autoClean=true; wait for human consent
            // via onboarding.
            if UserDefaults.standard.bool(forKey: "AppSift.OnboardingComplete") {
                scheduler.start()
            }
        }
    }

    // MARK: - App Loading

    func loadInstalledApps(forceSizeRefresh: Bool = false) {
        installedAppsLoadTask?.cancel()

        let loadID = UUID()
        activeInstalledAppsLoadID = loadID
        isLoadingApps = installedApps.isEmpty
        isCalculatingAppSizes = false
        appSizeCalculationProgress = 0

        installedAppsLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let loadingStartedAt = Date()
            let fetcher = AppInfoFetcher.shared
            let apps = fetcher.discoverInstalledApps(
                useSizeCache: !forceSizeRefresh,
                shouldCancel: { Task.isCancelled }
            )
            guard !Task.isCancelled else { return }
            let discoveryLog = String(
                format: "Discovered %lld apps in %.2f seconds",
                Int64(apps.count),
                Date().timeIntervalSince(loadingStartedAt)
            )

            let pendingCount = apps.filter(\.needsSizeCalculation).count
            let knownCount = apps.count - pendingCount

            let accepted = await MainActor.run { [weak self] in
                guard let self, self.activeInstalledAppsLoadID == loadID else { return false }
                Logger.shared.log(discoveryLog, level: .info)
                self.installedApps = apps
                self.refreshSelectedAppMetadata(from: apps)
                self.isLoadingApps = false
                self.isCalculatingAppSizes = pendingCount > 0
                self.appSizeCalculationProgress = apps.isEmpty
                    ? 1
                    : Double(knownCount) / Double(apps.count)
                return true
            }
            guard accepted else { return }

            // Signature validation and recursive sizing are independent work
            // queues. Running them concurrently prevents one very large app
            // bundle from delaying identity checks for every later row.
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for app in apps {
                        guard !Task.isCancelled else { break }
                        guard app.needsSignatureInspection,
                              let inspected = fetcher.inspectSignature(
                                for: app,
                                shouldCancel: { Task.isCancelled }
                              ) else { continue }

                        await MainActor.run { [weak self] in
                            guard let self, self.activeInstalledAppsLoadID == loadID else { return }
                            self.mergeInstalledApp(inspected)
                        }
                    }
                }

                group.addTask {
                    var sizedApps = apps
                    var completedCount = knownCount

                    for index in sizedApps.indices where sizedApps[index].needsSizeCalculation {
                        guard !Task.isCancelled else { break }
                        let result: InstalledApp
                        if let calculated = fetcher.calculateSize(
                            for: sizedApps[index],
                            shouldCancel: { Task.isCancelled }
                        ) {
                            result = calculated
                        } else {
                            if Task.isCancelled { break }
                            result = sizedApps[index].replacingSize(0, state: .unavailable)
                        }

                        sizedApps[index] = result
                        completedCount += 1
                        let progress = sizedApps.isEmpty
                            ? 1
                            : Double(completedCount) / Double(sizedApps.count)

                        await MainActor.run { [weak self] in
                            guard let self, self.activeInstalledAppsLoadID == loadID else { return }
                            self.mergeInstalledApp(result)
                            self.appSizeCalculationProgress = progress
                        }

                        // Preserve useful work if the app quits or a refresh
                        // replaces this task halfway through a large set.
                        if completedCount.isMultiple(of: 8) {
                            fetcher.persistSizeCache(keeping: sizedApps)
                        }
                    }

                    fetcher.persistSizeCache(keeping: sizedApps)
                    await MainActor.run { [weak self] in
                        guard let self, self.activeInstalledAppsLoadID == loadID else { return }
                        self.isCalculatingAppSizes = false
                        self.appSizeCalculationProgress = 1
                    }
                }

                await group.waitForAll()
            }

            let enrichmentLog = String(
                format: "Finished installed-app enrichment in %.2f seconds",
                Date().timeIntervalSince(loadingStartedAt)
            )
            await MainActor.run { [weak self] in
                guard let self, self.activeInstalledAppsLoadID == loadID else { return }
                Logger.shared.log(enrichmentLog, level: .info)
                self.isLoadingApps = false
                self.isCalculatingAppSizes = false
                self.appSizeCalculationProgress = 1
                self.installedAppsLoadTask = nil
            }
        }
    }

    private func mergeInstalledApp(_ app: InstalledApp) {
        if let index = installedApps.firstIndex(where: { $0.id == app.id }) {
            let merged = installedApps[index].mergingEnrichment(from: app)
            installedApps[index] = merged
            if selectedApp?.id == app.id {
                selectedApp = merged
            }
        } else if let selected = selectedApp, selected.id == app.id {
            // Finder Services may hand off an app outside standard search
            // roots, so it has no list row but still needs fresh metadata in
            // the detail pane.
            selectedApp = selected.mergingEnrichment(from: app)
        }
    }

    private func refreshSelectedAppMetadata(from apps: [InstalledApp]) {
        guard let selectedID = selectedApp?.id,
              let refreshed = apps.first(where: { $0.id == selectedID }) else { return }
        selectedApp = refreshed
    }

    /// Compatibility entry point for the original Finder uninstall service.
    func presentExternalUninstall(appPath: String) {
        presentExternalApp(
            ExternalAppRequest(path: appPath, action: .uninstall)
        )
    }

    /// Resolve a Finder request into the app-files surface. Reset requests use
    /// the same evidence scan but preselect only the narrower reset allow-list.
    func presentExternalApp(_ request: ExternalAppRequest) {
        let url = URL(fileURLWithPath: request.path)
        if let cached = installedApps.first(where: { $0.path.standardizedFileURL == url.standardizedFileURL }) {
            applyExternalApp(cached, action: request.action)
            return
        }
        // Not in the cached list (non-standard location, or a cold start before
        // loadInstalledApps finished). Resolve basic identity off the main
        // thread without walking or validating a multi-gigabyte bundle.
        Task.detached(priority: .userInitiated) {
            let app = AppInfoFetcher.shared.discoverApp(at: url)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let app else {
                    Logger.shared.log(
                        "External \(request.action.rawValue) request rejected (non-app or protected): \(request.path)",
                        level: .warning
                    )
                    return
                }
                self.applyExternalApp(app, action: request.action)
            }
        }
    }

    func dismissTrashAppReviews() {
        pendingTrashAppReviews.removeAll()
    }

    func reviewNextTrashApp() {
        guard let candidate = pendingTrashAppReviews.first else { return }
        reviewTrashApp(paths: [candidate.path])
    }

    private func enqueueTrashAppReviews(_ candidates: [TrashAppCandidate]) {
        guard !candidates.isEmpty else { return }
        var byPath = Dictionary(
            pendingTrashAppReviews.map { ($0.path, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        for candidate in candidates {
            byPath[candidate.path] = candidate
        }
        pendingTrashAppReviews = byPath.values.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    private func reviewTrashApp(paths: [String]) {
        let standardizedPaths = paths.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
        }
        let liveCandidates: [String: TrashAppCandidate]
        switch TrashAppDirectoryScanner(rootURL: TrashAppWatcher.defaultRootURL).scan() {
        case .success(let snapshot):
            liveCandidates = Dictionary(
                snapshot.candidates.map { ($0.path, $0) },
                uniquingKeysWith: { existing, _ in existing }
            )
        case .failure:
            liveCandidates = [:]
        }
        let requestedCandidates = standardizedPaths.compactMap { liveCandidates[$0] }
        enqueueTrashAppReviews(requestedCandidates)
        guard let path = requestedCandidates.first?.path else {
            pendingTrashAppReviews.removeAll {
                standardizedPaths.contains($0.path)
            }
            return
        }

        pendingTrashAppReviews.removeAll { $0.path == path }
        presentExternalApp(
            ExternalAppRequest(path: path, action: .reviewTrash)
        )
    }

    private func applyExternalApp(_ app: InstalledApp, action: ExternalAppAction) {
        selectedApp = app
        pendingExternalApp = app
        scanForAppFiles(app, initialSelection: action.initialSelection)
    }

    func scanForAppFiles(
        _ app: InstalledApp,
        initialSelection: AppFileInitialSelection = .all
    ) {
        activeAppFileScanCancellation?()
        activeAppFileScanCancellation = nil
        resetAppInstallationInspection()
        resetAppRelationshipScan()
        let scanID = UUID()
        activeAppFileScanID = scanID
        if selectedApp?.id != app.id {
            selectedApp = app
        }
        isReviewingTrashedApp = initialSelection == .relatedFiles
        discoveredFilesAppID = nil
        selectedFilesOwnerAppID = nil
        discoveredFiles = []
        protectedAppFiles = []
        appFileMatchEvidenceByPath = [:]
        selectedFiles = []
        isScanningAppFiles = true
        currentAppSearchSensitivity = searchSensitivityProvider()
        let searchPaths = locationsProvider().appSearch.paths
        appFileScanLocationCount = AppPathFinder.searchLocationCount(for: searchPaths)

        guard app.needsSignatureInspection else {
            beginAppInstallationInspection(app)
            beginAppRelationshipScan(app)
            beginAppFileScan(
                app,
                searchPaths: searchPaths,
                scanID: scanID,
                initialSelection: initialSelection
            )
            return
        }

        // Deep association identifiers are security-sensitive. A fast list
        // row may still have a pending signature, so validate this selected
        // app before constructing AppPathFinder rather than silently falling
        // back to a less complete scan.
        Task.detached(priority: .userInitiated) {
            let inspected = AppInfoFetcher.shared.inspectSignature(for: app)
            await MainActor.run { [weak self] in
                guard let self,
                      self.activeAppFileScanID == scanID,
                      self.selectedApp?.id == app.id else { return }
                let prepared = inspected ?? app.replacingSignature(.unknown)
                self.mergeInstalledApp(prepared)
                self.beginAppInstallationInspection(prepared)
                self.beginAppRelationshipScan(prepared)
                self.beginAppFileScan(
                    prepared,
                    searchPaths: searchPaths,
                    scanID: scanID,
                    initialSelection: initialSelection
                )
            }
        }
    }

    private func beginAppInstallationInspection(_ app: InstalledApp) {
        appInstallationInspectionTask?.cancel()
        let inspectionID = UUID()
        activeAppInstallationInspectionID = inspectionID
        selectedAppInstallationInsights = nil
        isInspectingAppInstallation = true

        let inspector = appInstallationInspector
        let task = Task.detached(priority: .utility) {
            inspector(app, { Task.isCancelled })
        }
        appInstallationInspectionTask = task

        Task { @MainActor [weak self] in
            let insights = await task.value
            guard let self,
                  !task.isCancelled,
                  self.activeAppInstallationInspectionID == inspectionID,
                  self.selectedApp?.id == app.id else { return }
            self.selectedAppInstallationInsights = insights
            self.isInspectingAppInstallation = false
            self.appInstallationInspectionTask = nil
        }
    }

    private func resetAppInstallationInspection() {
        appInstallationInspectionTask?.cancel()
        appInstallationInspectionTask = nil
        activeAppInstallationInspectionID = UUID()
        selectedAppInstallationInsights = nil
        isInspectingAppInstallation = false
        appInstallationActionError = nil
    }

    private func beginAppRelationshipScan(_ app: InstalledApp) {
        appRelationshipScanTask?.cancel()
        let scanID = UUID()
        activeAppRelationshipScanID = scanID
        selectedAppRelationships = nil
        isScanningAppRelationships = true

        var currentApps = installedApps
        if let index = currentApps.firstIndex(where: { $0.id == app.id }) {
            currentApps[index] = app
        } else {
            currentApps.append(app)
        }
        let applications = currentApps.map(AppRelationshipApplicationReference.init(app:))
        let scanner = appRelationshipsScanner
        let task = Task.detached(priority: .utility) {
            scanner(applications, app.id, { Task.isCancelled })
        }
        appRelationshipScanTask = task

        Task { @MainActor [weak self] in
            let result = await task.value
            guard let self,
                  !task.isCancelled,
                  self.activeAppRelationshipScanID == scanID,
                  self.selectedApp?.id == app.id else { return }
            self.selectedAppRelationships = result
            self.isScanningAppRelationships = false
            self.appRelationshipScanTask = nil
            self.refreshProtectedAppFileRelationships(
                selectedApp: app,
                result: result
            )
        }
    }

    private func resetAppRelationshipScan() {
        appRelationshipScanTask?.cancel()
        appRelationshipScanTask = nil
        activeAppRelationshipScanID = UUID()
        selectedAppRelationships = nil
        isScanningAppRelationships = false
    }

    // MARK: - Startup Items

    /// Runs only after the user opens the Startup Items surface or explicitly
    /// refreshes it. `sfltool dumpbtm` can take several seconds, so it never
    /// delays launch or the installed-app list.
    func scanStartupItems(force: Bool = false) {
        if isScanningStartupItems {
            guard force else { return }
            startupItemsScanTask?.cancel()
        }
        guard force || !hasScannedStartupItems else { return }

        startupItemsScanTask?.cancel()
        let scanID = UUID()
        activeStartupItemsScanID = scanID
        isScanningStartupItems = true

        let scanner = startupItemsScanner
        let task = Task.detached(priority: .userInitiated) {
            scanner()
        }
        startupItemsScanTask = task

        Task { @MainActor [weak self] in
            let result = await task.value
            guard let self,
                  !task.isCancelled,
                  self.activeStartupItemsScanID == scanID else { return }
            self.startupItems = result.items
            self.startupBackgroundTaskDataAvailable = result.backgroundTaskDataAvailable
            self.startupBackgroundTaskDataTruncated = result.backgroundTaskDataTruncated
            self.hasScannedStartupItems = true
            self.isScanningStartupItems = false
            self.startupItemsScanTask = nil
        }
    }

    func isStartupItemControllable(_ item: StartupItem) -> Bool {
        startupItemController.canControl(item)
    }

    func canControlStartupItem(_ item: StartupItem) -> Bool {
        activeStartupItemActionID == nil
            && !isScanningStartupItems
            && isStartupItemControllable(item)
    }

    func isStartupItemControlUndoable(_ record: StartupItemControlRecord) -> Bool {
        startupItemController.canUndo(record)
    }

    func canUndoStartupItemControl(_ record: StartupItemControlRecord) -> Bool {
        activeStartupItemActionID == nil
            && !isScanningStartupItems
            && isStartupItemControlUndoable(record)
    }

    func controlStartupItem(
        _ item: StartupItem,
        action: StartupItemControlAction
    ) {
        guard canControlStartupItem(item) else {
            startupItemActionError = String(
                localized: "Only current-user legacy LaunchAgents can be controlled safely."
            )
            return
        }

        let operationID = UUID()
        activeStartupItemControlOperationID = operationID
        activeStartupItemActionID = item.id
        startupItemActionError = nil
        startupItemActionMessage = nil
        let controller = startupItemController

        let task = Task.detached(priority: .userInitiated) {
            Result {
                try controller.perform(action, on: item)
            }
        }
        Task { @MainActor [weak self] in
            let result = await task.value
            guard let self,
                  self.activeStartupItemControlOperationID == operationID else { return }
            self.activeStartupItemActionID = nil

            switch result {
            case let .success(outcome):
                self.startupItemControlHistory = controller.historySnapshot()
                let refreshedState: StartupItemState = outcome.resultingState.isDisabled
                    ? .disabled
                    : .enabled
                self.startupItems = self.startupItems.map {
                    $0.id == item.id ? $0.replacingState(refreshedState) : $0
                }
                let format = action == .disable
                    ? String(localized: "%@ was safely disabled. You can undo this change from history.")
                    : String(localized: "%@ was enabled. You can undo this change from history.")
                self.startupItemActionMessage = String(format: format, item.name)
            case let .failure(error):
                self.startupItemActionError = error.localizedDescription
            }
            self.scanStartupItems(force: true)
        }
    }

    func undoStartupItemControl(_ record: StartupItemControlRecord) {
        guard canUndoStartupItemControl(record) else {
            startupItemActionError = String(
                localized: "Undo newer changes for this LaunchAgent first."
            )
            return
        }

        let operationID = UUID()
        activeStartupItemControlOperationID = operationID
        activeStartupItemActionID = record.id.uuidString
        startupItemActionError = nil
        startupItemActionMessage = nil
        let controller = startupItemController

        let task = Task.detached(priority: .userInitiated) {
            Result {
                try controller.undo(record)
            }
        }
        Task { @MainActor [weak self] in
            let result = await task.value
            guard let self,
                  self.activeStartupItemControlOperationID == operationID else { return }
            self.activeStartupItemActionID = nil

            switch result {
            case let .success(outcome):
                self.startupItemControlHistory = controller.historySnapshot()
                let refreshedState: StartupItemState = outcome.resultingState.isDisabled
                    ? .disabled
                    : .enabled
                self.startupItems = self.startupItems.map { item in
                    guard item.itemURL?.standardizedFileURL.path == record.itemPath else {
                        return item
                    }
                    return item.replacingState(refreshedState)
                }
                let format = outcome.resultingState.isDisabled
                    ? String(localized: "%@ was restored to its previous disabled state.")
                    : String(localized: "%@ was restored to its previous enabled state.")
                self.startupItemActionMessage = String(format: format, record.itemName)
                if !outcome.historyPersisted {
                    self.startupItemActionError = String(
                        localized: "The LaunchAgent state was restored, but the history file could not be updated."
                    )
                }
            case let .failure(error):
                self.startupItemActionError = error.localizedDescription
            }
            self.scanStartupItems(force: true)
        }
    }

    func clearStartupItemControlHistory() {
        guard activeStartupItemActionID == nil else { return }
        startupItemActionError = nil
        if startupItemController.clearHistory() {
            startupItemControlHistory = []
            startupItemActionMessage = String(
                localized: "Startup item history was cleared. LaunchAgent states were not changed."
            )
        } else {
            startupItemActionError = String(
                localized: "AppSift could not clear the startup item history file."
            )
        }
    }

    func revealStartupItem(_ item: StartupItem) {
        guard let url = item.revealURL,
              url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            startupItemActionError = String(
                localized: "This startup item no longer exists at the recorded path."
            )
            return
        }
        startupItemActionError = nil
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openLoginItemsSettings() {
        startupItemActionError = nil
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    // MARK: - Extensions

    func scanExtensions(force: Bool = false) {
        if isScanningExtensions {
            guard force else { return }
            extensionsScanTask?.cancel()
        }
        guard force || !hasScannedExtensions else { return }

        extensionsScanTask?.cancel()
        let scanID = UUID()
        activeExtensionsScanID = scanID
        isScanningExtensions = true
        extensionActionError = nil

        let owners = installedApps.map(ExtensionOwnerApp.init(app:))
        let scanner = managedExtensionsScanner
        let task = Task.detached(priority: .userInitiated) {
            scanner(owners)
        }
        extensionsScanTask = task

        Task { @MainActor [weak self] in
            let result = await task.value
            guard let self,
                  !task.isCancelled,
                  self.activeExtensionsScanID == scanID else { return }
            self.managedExtensions = result.items
            self.incompleteExtensionSources = result.incompleteSources
            self.hasScannedExtensions = true
            self.isScanningExtensions = false
            self.extensionsScanTask = nil
        }
    }

    func revealExtension(_ item: ManagedExtension) {
        guard let url = item.url,
              url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            extensionActionError = String(
                localized: "This extension no longer exists at the recorded path."
            )
            return
        }
        extensionActionError = nil
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func manageExtension(_ item: ManagedExtension) {
        extensionActionError = nil
        switch item.management {
        case .systemSettings:
            if #available(macOS 13.0, *) {
                SMAppService.openSystemSettingsLoginItems()
            } else {
                extensionActionError = String(
                    localized: "This macOS version does not provide the Extensions settings page."
                )
            }

        case let .browser(bundleIdentifier, applicationURL, page):
            guard Self.isAllowedBrowserManagementPage(
                page,
                for: bundleIdentifier
            ) else {
                extensionActionError = String(
                    localized: "AppSift rejected an unverified browser management page."
                )
                return
            }
            let candidateURLs = [
                NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: bundleIdentifier
                ),
                applicationURL,
            ].compactMap { $0 }
            guard let resolvedURL = candidateURLs.first(where: {
                Self.browserApplicationMatches(
                    $0,
                    bundleIdentifier: bundleIdentifier
                )
            }) else {
                extensionActionError = String(
                    localized: "The browser that owns this extension is not installed."
                )
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.arguments = [page]
            NSWorkspace.shared.openApplication(
                at: resolvedURL,
                configuration: configuration
            ) { [weak self] _, error in
                guard let error else { return }
                Task { @MainActor in
                    self?.extensionActionError = String(
                        format: String(localized: "Could not open %@'s extension manager."),
                        item.owner?.name ?? item.name
                    ) + " \(error.localizedDescription)"
                }
            }

        case .reveal:
            revealExtension(item)
        }
    }

    func openExtensionsSettings() {
        extensionActionError = nil
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        } else {
            extensionActionError = String(
                localized: "This macOS version does not provide the Extensions settings page."
            )
        }
    }

    private static func isAllowedBrowserManagementPage(
        _ page: String,
        for bundleIdentifier: String
    ) -> Bool {
        let allowed: [String: String] = [
            "com.google.Chrome": "chrome://extensions/",
            "com.brave.Browser": "brave://extensions/",
            "com.microsoft.edgemac": "edge://extensions/",
            "company.thebrowser.Browser": "arc://extensions/",
            "org.chromium.Chromium": "chrome://extensions/",
            "com.vivaldi.Vivaldi": "vivaldi://extensions/",
            "com.operasoftware.Opera": "opera://extensions/",
            "org.mozilla.firefox": "about:addons",
        ]
        return allowed[bundleIdentifier] == page
    }

    static func browserApplicationMatches(
        _ url: URL,
        bundleIdentifier: String,
        fileManager: FileManager = .default
    ) -> Bool {
        url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            && fileManager.fileExists(atPath: url.path)
            && Bundle(url: url)?.bundleIdentifier == bundleIdentifier
    }

    // MARK: - Privacy Permissions

    func scanAppPermissions(force: Bool = false) {
        if isScanningAppPermissions {
            guard force else { return }
            appPermissionsScanTask?.cancel()
        }
        guard force || !hasScannedAppPermissions else { return }

        appPermissionsScanTask?.cancel()
        let scanID = UUID()
        activeAppPermissionsScanID = scanID
        isScanningAppPermissions = true
        appPermissionActionError = nil

        let applications = installedApps.map(AppPermissionApplicationReference.init(app:))
        let scanner = appPermissionsScanner
        let task = Task.detached(priority: .userInitiated) {
            scanner(applications)
        }
        appPermissionsScanTask = task

        Task { @MainActor [weak self] in
            let result = await task.value
            guard let self,
                  !task.isCancelled,
                  self.activeAppPermissionsScanID == scanID else { return }
            self.appPermissionClients = result.clients
            self.appPermissionSources = result.sources
            self.lastAppPermissionScanDate = result.scannedAt
            self.appPermissionScanWasTruncated = result.wasTruncated
            self.hasScannedAppPermissions = true
            self.isScanningAppPermissions = false
            self.appPermissionsScanTask = nil
        }
    }

    func canResetAppPermission(
        client: AppPermissionClient,
        service: AppPermissionService
    ) -> Bool {
        guard activeAppPermissionActionID == nil,
              let current = appPermissionClients.first(where: { $0.id == client.id }),
              current == client,
              current.records.contains(where: { $0.service == service }) else {
            return false
        }
        return appPermissionController.canReset(client: current, service: service)
    }

    func resetAppPermission(
        client: AppPermissionClient,
        service: AppPermissionService
    ) {
        guard canResetAppPermission(client: client, service: service) else {
            scanAppPermissions(force: true)
            appPermissionActionError = String(
                localized: "This permission record changed. Refresh and try again."
            )
            return
        }
        guard let current = appPermissionClients.first(where: { $0.id == client.id }) else {
            return
        }

        let operationID = UUID()
        activeAppPermissionControlOperationID = operationID
        activeAppPermissionActionID = "\(client.id)|\(service.rawValue)"
        appPermissionActionError = nil
        appPermissionActionMessage = nil
        let controller = appPermissionController

        Task { @MainActor [weak self] in
            do {
                _ = try await controller.reset(client: current, service: service)
                guard let self,
                      self.activeAppPermissionControlOperationID == operationID else {
                    return
                }
                self.activeAppPermissionActionID = nil
                self.appPermissionActionMessage = String(
                    format: String(
                        localized: "%@'s %@ decision was reset. macOS will ask again the next time it is needed."
                    ),
                    current.name,
                    String(localized: String.LocalizationValue(service.displayNameKey))
                )
                self.scanAppPermissions(force: true)
            } catch {
                guard let self,
                      self.activeAppPermissionControlOperationID == operationID else {
                    return
                }
                self.activeAppPermissionActionID = nil
                self.appPermissionActionError = error.localizedDescription
                self.scanAppPermissions(force: true)
            }
        }
    }

    func openAppPermissionSettings(for service: AppPermissionService) {
        appPermissionActionError = nil
        guard appPermissionController.openSystemSettings(for: service) else {
            appPermissionActionError = String(
                localized: "Could not open Privacy & Security settings."
            )
            return
        }
    }

    // MARK: - Default Applications

    var latestUndoableDefaultApplicationRecord: DefaultApplicationControlRecord? {
        defaultApplicationControlHistory.first {
            defaultApplicationController.canUndo($0)
        }
    }

    func scanDefaultApplications(force: Bool = false) {
        if isScanningDefaultApplications {
            guard force else { return }
            defaultApplicationsScanTask?.cancel()
        }
        guard force || !hasScannedDefaultApplications else { return }

        defaultApplicationsScanTask?.cancel()
        let scanID = UUID()
        activeDefaultApplicationsScanID = scanID
        isScanningDefaultApplications = true
        defaultApplicationActionError = nil

        let applicationURLs = installedApps.map(\.path)
        let scanner = defaultApplicationsScanner
        let task = Task.detached(priority: .userInitiated) {
            scanner(applicationURLs)
        }
        defaultApplicationsScanTask = task

        Task { @MainActor [weak self] in
            let result = await task.value
            guard let self,
                  !task.isCancelled,
                  self.activeDefaultApplicationsScanID == scanID else {
                return
            }
            self.defaultApplications = result.items
            self.unreadableDefaultApplicationDeclarationCount =
                result.unreadableApplicationDeclarationCount
            self.defaultApplicationScanWasTruncated = result.wasTruncated
            self.hasScannedDefaultApplications = true
            self.isScanningDefaultApplications = false
            self.defaultApplicationsScanTask = nil
        }
    }

    func changeDefaultApplication(
        _ item: DefaultApplicationItem,
        to target: DefaultApplicationCandidate
    ) {
        guard activeDefaultApplicationActionID == nil else { return }
        let operationID = UUID()
        activeDefaultApplicationControlOperationID = operationID
        activeDefaultApplicationActionID = item.id
        defaultApplicationActionError = nil
        defaultApplicationActionMessage = nil
        let controller = defaultApplicationController

        Task { @MainActor [weak self] in
            do {
                let outcome = try await controller.perform(
                    item: item,
                    target: target
                )
                guard let self,
                      self.activeDefaultApplicationControlOperationID
                        == operationID else {
                    return
                }
                if let index = self.defaultApplications.firstIndex(
                    where: { $0.id == item.id }
                ) {
                    self.defaultApplications[index] = self.defaultApplications[index]
                        .replacingCurrentApplication(
                            outcome.currentApplication
                        )
                }
                self.defaultApplicationControlHistory = controller
                    .historySnapshot()
                self.defaultApplicationActionMessage = String(
                    format: String(
                        localized: "%@ is now the default for %@."
                    ),
                    outcome.currentApplication.name,
                    item.displayName
                )
                self.activeDefaultApplicationActionID = nil
            } catch {
                guard let self,
                      self.activeDefaultApplicationControlOperationID
                        == operationID else {
                    return
                }
                self.defaultApplicationActionError = error.localizedDescription
                self.defaultApplicationControlHistory = controller
                    .historySnapshot()
                self.activeDefaultApplicationActionID = nil
                if let error = error as? DefaultApplicationControlError,
                   error == .sourceChanged
                    || error == .candidateUnavailable {
                    self.scanDefaultApplications(force: true)
                }
            }
        }
    }

    func undoDefaultApplicationChange(
        _ record: DefaultApplicationControlRecord
    ) {
        guard activeDefaultApplicationActionID == nil,
              defaultApplicationController.canUndo(record) else {
            return
        }
        let operationID = UUID()
        activeDefaultApplicationControlOperationID = operationID
        activeDefaultApplicationActionID = record.contentTypeIdentifier
        defaultApplicationActionError = nil
        defaultApplicationActionMessage = nil
        let controller = defaultApplicationController

        Task { @MainActor [weak self] in
            do {
                let outcome = try await controller.undo(record)
                guard let self,
                      self.activeDefaultApplicationControlOperationID
                        == operationID else {
                    return
                }
                if let index = self.defaultApplications.firstIndex(
                    where: {
                        $0.contentTypeIdentifier
                            == record.contentTypeIdentifier
                    }
                ) {
                    self.defaultApplications[index] = self.defaultApplications[index]
                        .replacingCurrentApplication(
                            outcome.currentApplication
                        )
                }
                self.defaultApplicationControlHistory = controller
                    .historySnapshot()
                if outcome.historyPersisted {
                    self.defaultApplicationActionMessage = String(
                        format: String(
                            localized: "Restored %@ as the default for %@."
                        ),
                        outcome.currentApplication.name,
                        record.displayName
                    )
                } else {
                    self.defaultApplicationActionMessage = String(
                        format: String(
                            localized: "Restored %@ as the default for %@, but the undo history could not be updated."
                        ),
                        outcome.currentApplication.name,
                        record.displayName
                    )
                }
                self.activeDefaultApplicationActionID = nil
            } catch {
                guard let self,
                      self.activeDefaultApplicationControlOperationID
                        == operationID else {
                    return
                }
                self.defaultApplicationActionError = error.localizedDescription
                self.defaultApplicationControlHistory = controller
                    .historySnapshot()
                self.activeDefaultApplicationActionID = nil
                self.scanDefaultApplications(force: true)
            }
        }
    }

    // MARK: - Installation Files

    func scanInstallationFiles(
        force: Bool = false,
        additionalCandidateURLs: [URL] = []
    ) {
        if isScanningInstallationFiles {
            guard force else { return }
            installationFilesScanTask?.cancel()
        }
        guard force || !hasScannedInstallationFiles else { return }

        installationFilesScanTask?.cancel()
        let scanID = UUID()
        activeInstallationFilesScanID = scanID
        isScanningInstallationFiles = true
        installationFileActionError = nil
        installationFileActionMessage = nil
        selectedInstallationFileIDs.removeAll()
        explicitlyApprovedInstallationFileIDs.removeAll()

        let apps = installedApps.map(InstallationFileApplicationReference.init(app:))
        let scanner = installationFilesScanner
        let task = Task.detached(priority: .userInitiated) {
            await scanner(apps, additionalCandidateURLs)
        }
        installationFilesScanTask = task

        Task { @MainActor [weak self] in
            let result = await task.value
            guard let self,
                  !task.isCancelled,
                  self.activeInstallationFilesScanID == scanID else {
                return
            }
            self.installationFiles = result.items
            self.installationFileIgnoredCount = result.ignoredPathCount
            self.installationFileInaccessibleCount = result.inaccessibleCandidateCount
            self.installationFileScanWasTruncated = result.wasTruncated
            self.lastInstallationFileScanDate = result.scannedAt
            self.hasScannedInstallationFiles = true
            self.isScanningInstallationFiles = false
            self.installationFilesScanTask = nil
            if result.wasCancelled {
                self.installationFileActionError = String(
                    localized: "The installation file scan was cancelled."
                )
            }
        }
    }

    func toggleInstallationFileSelection(_ item: InstallationFileItem) {
        guard !isScanningInstallationFiles,
              !isRemovingInstallationFiles,
              installationFiles.contains(where: {
                  $0.id == item.id && $0.fingerprint == item.fingerprint
              }) else {
            return
        }
        if selectedInstallationFileIDs.contains(item.id) {
            selectedInstallationFileIDs.remove(item.id)
            explicitlyApprovedInstallationFileIDs.remove(item.id)
        } else {
            guard item.isRemovable else { return }
            selectedInstallationFileIDs.insert(item.id)
        }
    }

    func approveManagedInstallationFileSelection(
        _ item: InstallationFileItem
    ) {
        guard !isScanningInstallationFiles,
              !isRemovingInstallationFiles,
              item.allowsExplicitSelection,
              installationFiles.contains(where: {
                  $0.id == item.id
                      && $0.fingerprint == item.fingerprint
                      && $0.removalEligibility == item.removalEligibility
              }) else {
            return
        }
        explicitlyApprovedInstallationFileIDs.insert(item.id)
        selectedInstallationFileIDs.insert(item.id)
    }

    func selectAllRemovableInstallationFiles() {
        guard !isScanningInstallationFiles,
              !isRemovingInstallationFiles else { return }
        explicitlyApprovedInstallationFileIDs.removeAll()
        selectedInstallationFileIDs = Set(
            installationFiles.lazy.filter(\.isRemovable).map(\.id)
        )
    }

    func clearInstallationFileSelection() {
        selectedInstallationFileIDs.removeAll()
        explicitlyApprovedInstallationFileIDs.removeAll()
    }

    func removeSelectedInstallationFiles() {
        guard !isScanningInstallationFiles,
              !isRemovingInstallationFiles,
              !selectedInstallationFileIDs.isEmpty else { return }
        let selectedItems = installationFiles.filter {
            selectedInstallationFileIDs.contains($0.id)
                && ($0.isRemovable
                    || explicitlyApprovedInstallationFileIDs.contains($0.id))
        }
        guard selectedItems.count == selectedInstallationFileIDs.count else {
            selectedInstallationFileIDs.removeAll()
            explicitlyApprovedInstallationFileIDs.removeAll()
            installationFileActionError = String(
                localized: "The installation file selection changed. Review the current scan and try again."
            )
            return
        }

        isRemovingInstallationFiles = true
        installationFileActionError = nil
        installationFileActionMessage = nil
        let controller = installationFileController
        let explicitlyApprovedItemIDs = explicitlyApprovedInstallationFileIDs
        Task { @MainActor [weak self] in
            let outcome = await controller.remove(
                selectedItems,
                explicitlyApprovedItemIDs: explicitlyApprovedItemIDs
            )
            guard let self else { return }
            let noLongerPresent = Set(outcome.items.compactMap { item -> String? in
                switch item.status {
                case .movedToTrash, .alreadyMissing,
                     .rollbackFailedAfterHistoryFailure:
                    return URL(fileURLWithPath: item.originalPath)
                        .standardizedFileURL.path
                case .rejected, .trashFailed,
                     .rolledBackAfterHistoryFailure:
                    return nil
                }
            })
            self.installationFiles.removeAll {
                noLongerPresent.contains($0.id)
            }
            self.selectedInstallationFileIDs.removeAll()
            self.explicitlyApprovedInstallationFileIDs.removeAll()
            self.installationFileRemovalHistory = controller.historySnapshot()
            self.isRemovingInstallationFiles = false

            if outcome.movedCount > 0 {
                self.installationFileActionMessage = String(
                    format: String(
                        localized: "Moved %lld installation files to Trash."
                    ),
                    Int64(outcome.movedCount)
                )
            }
            if !outcome.historyPersisted {
                if outcome.failedCount > 0 {
                    self.installationFileActionError = String(
                        localized: "Undo history could not be saved and at least one file could not be restored automatically. Open Trash before doing anything else."
                    )
                } else {
                    self.installationFileActionError = String(
                        localized: "Undo history could not be saved, so AppSift restored every moved file to its original location."
                    )
                }
            } else if outcome.failedCount > 0 {
                self.installationFileActionError = String(
                    format: String(
                        localized: "%lld installation files could not be moved. Refresh before trying again."
                    ),
                    Int64(outcome.failedCount)
                )
            }
        }
    }

    func undoLatestInstallationFileRemoval() {
        guard !isScanningInstallationFiles,
              !isRemovingInstallationFiles,
              let record = latestUndoableInstallationFileRecord else {
            return
        }
        isRemovingInstallationFiles = true
        installationFileActionError = nil
        installationFileActionMessage = nil
        let controller = installationFileController
        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                controller.undo(record)
            }.value
            guard let self else { return }
            self.installationFileRemovalHistory = controller.historySnapshot()
            self.isRemovingInstallationFiles = false
            if outcome.historyPersisted, outcome.restoredCount > 0 {
                let restoredURLs: [URL] = outcome.record.items.compactMap {
                    item -> URL? in
                    guard item.restoredAt != nil else { return nil }
                    return URL(fileURLWithPath: item.originalPath)
                }
                self.scanInstallationFiles(
                    force: true,
                    additionalCandidateURLs: restoredURLs
                )
                self.installationFileActionMessage = String(
                    format: String(
                        localized: "Restored %lld installation files from Trash."
                    ),
                    Int64(outcome.restoredCount)
                )
            }
            if !outcome.historyPersisted {
                self.installationFileActionError = outcome.rollbackFailed
                    ? String(
                        localized: "The files were restored, but history could not be updated and the rollback to Trash was incomplete. Review both locations in Finder."
                    )
                    : String(
                        localized: "History could not be updated, so AppSift returned the restored files to Trash."
                    )
            } else if outcome.failedCount > 0 {
                self.installationFileActionError = String(
                    format: String(
                        localized: "%lld installation files could not be restored because the source or destination changed."
                    ),
                    Int64(outcome.failedCount)
                )
            }
        }
    }

    func revealInstallationFile(_ item: InstallationFileItem) {
        guard installationFiles.contains(where: {
            $0.id == item.id && $0.fingerprint == item.fingerprint
        }),
        FileManager.default.fileExists(atPath: item.url.path) else {
            installationFileActionError = String(
                localized: "This installation file is no longer available. Refresh and try again."
            )
            return
        }
        installationFileActionError = nil
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: - App Updates

    func scanAppUpdates(force: Bool = false) {
        guard !isScanningAppUpdates else { return }
        guard force || !hasScannedAppUpdates else { return }
        guard !installedApps.isEmpty else {
            appUpdateScanError = String(
                localized: "No installed applications are available to check yet."
            )
            return
        }

        appUpdatesScanTask?.cancel()
        let scanID = UUID()
        activeAppUpdatesScanID = scanID
        isScanningAppUpdates = true
        appUpdateScanError = nil
        appUpdateActionError = nil
        appUpdateActionMessage = nil
        let apps = installedApps
        let scanner = appUpdatesScanner
        let task = Task.detached(priority: .userInitiated) {
            await scanner(apps)
        }
        appUpdatesScanTask = task

        Task { @MainActor [weak self] in
            let result = await task.value
            guard let self,
                  !task.isCancelled,
                  self.activeAppUpdatesScanID == scanID else { return }
            self.appUpdates = result.items
            self.appUpdateUnsupportedAppCount = result.unsupportedAppCount
            self.lastAppUpdateScanDate = result.checkedAt
            self.hasScannedAppUpdates = true
            self.isScanningAppUpdates = false
            self.appUpdatesScanTask = nil
        }
    }

    /// Verifies the app's current signature and installation source again
    /// before crossing from a read-only result into an external updater.
    func performAppUpdate(_ item: AppUpdateItem) {
        guard item.status == .updateAvailable,
              activeAppUpdateActionID == nil,
              let app = installedApps.first(where: { $0.id == item.id }) else { return }

        activeAppUpdateActionID = item.id
        appUpdateActionError = nil
        appUpdateActionMessage = nil
        let verificationTask = Task.detached(priority: .userInitiated) {
            await AppUpdateScanner.verifyActionAtClick(item: item, app: app)
        }

        Task { @MainActor [weak self] in
            let verification = await verificationTask.value
            guard let self, self.activeAppUpdateActionID == item.id else { return }
            switch verification {
            case .failure:
                self.activeAppUpdateActionID = nil
                self.appUpdateActionError = String(
                    localized: "The app or its update source changed. AppSift did not start the update."
                )

            case .success(.macAppStore(let productIdentifier)):
                let url = URL(
                    string: "macappstore://itunes.apple.com/app/id\(productIdentifier)"
                )
                self.activeAppUpdateActionID = nil
                guard let url, NSWorkspace.shared.open(url) else {
                    self.appUpdateActionError = String(
                        localized: "macOS could not open this app in the App Store."
                    )
                    return
                }

            case .success(.homebrewCask(let executable, let token)):
                let updateTask = Task.detached(priority: .userInitiated) {
                    AppUpdateScanner.runHomebrewUpgrade(
                        executable: executable,
                        token: token
                    )
                }
                let result = await updateTask.value
                guard self.activeAppUpdateActionID == item.id else { return }
                self.activeAppUpdateActionID = nil
                guard result.succeeded else {
                    self.appUpdateActionError = String(
                        localized: "Homebrew could not update this app. No success was recorded."
                    )
                    return
                }
                if let index = self.appUpdates.firstIndex(where: { $0.id == item.id }) {
                    self.appUpdates[index] = item.replacing(
                        status: .upToDate,
                        availableVersion: item.availableVersion
                    )
                }
                self.appUpdateActionMessage = String(
                    format: String(localized: "%@ was updated by Homebrew."),
                    item.appName
                )
                self.loadInstalledApps()

            case .success(.sparkle(let appURL, let feedURL)):
                do {
                    try self.externalSparkleUpdateCoordinator.presentUpdate(
                        appID: item.id,
                        appURL: appURL,
                        feedURL: feedURL
                    ) { [weak self] error in
                        guard let self else { return }
                        if self.activeAppUpdateActionID == item.id {
                            self.activeAppUpdateActionID = nil
                        }
                        if error != nil {
                            self.appUpdateActionError = String(
                                localized: "Sparkle could not complete the update check."
                            )
                        }
                    }
                } catch {
                    self.activeAppUpdateActionID = nil
                    self.appUpdateActionError = String(
                        localized: "Sparkle could not start the app's verified updater."
                    )
                }

            case .success(.electronUpdater(let appURL, let releasePageURL)):
                self.activeAppUpdateActionID = nil
                let destination = releasePageURL ?? appURL
                guard NSWorkspace.shared.open(destination) else {
                    self.appUpdateActionError = String(
                        localized: "macOS could not open the verified update destination."
                    )
                    return
                }
            }
        }
    }

    func openAppUpdateReleaseNotes(_ item: AppUpdateItem) {
        guard let url = item.releaseNotesURL,
              AppUpdateScanner.isAllowedPublicHTTPSURL(url),
              NSWorkspace.shared.open(url) else {
            appUpdateActionError = String(
                localized: "macOS could not open the release notes."
            )
            return
        }
        appUpdateActionError = nil
    }

    func revealHomebrewReceipt(
        _ metadata: HomebrewCaskInstallMetadata,
        for app: InstalledApp
    ) {
        verifyInstallationAction(
            .revealHomebrewReceipt(metadata),
            for: app
        )
    }

    func openOfficialUninstaller(
        _ uninstaller: AppOfficialUninstaller,
        for app: InstalledApp
    ) {
        verifyInstallationAction(
            .openOfficialUninstaller(uninstaller),
            for: app
        )
    }

    private func verifyInstallationAction(
        _ action: InstallationAction,
        for app: InstalledApp
    ) {
        guard selectedApp?.id == app.id,
              !isVerifyingInstallationAction else { return }
        isVerifyingInstallationAction = true
        appInstallationActionError = nil

        let inspector = appInstallationInspector
        let task = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else {
                return AppInstallationInsights(source: .unknown, officialUninstaller: nil)
            }
            let refreshedSignature = AppSignatureInspector.inspect(at: app.path)
            guard !Task.isCancelled else {
                return AppInstallationInsights(source: .unknown, officialUninstaller: nil)
            }
            let refreshedApp = app.replacingSignature(refreshedSignature)
            return inspector(refreshedApp, { Task.isCancelled })
        }

        Task { @MainActor [weak self] in
            let refreshedInsights = await task.value
            guard let self else { return }
            defer { self.isVerifyingInstallationAction = false }
            guard self.selectedApp?.id == app.id else { return }

            switch action {
            case .revealHomebrewReceipt(let expected):
                guard case .homebrewCask(let current) = refreshedInsights.source,
                      current.token == expected.token,
                      current.receiptURL.standardizedFileURL.path
                        == expected.receiptURL.standardizedFileURL.path else {
                    self.appInstallationActionError = String(
                        localized: "AppSift could not verify the Homebrew receipt because it changed or moved."
                    )
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([current.receiptURL])

            case .openOfficialUninstaller(let expected):
                guard let current = refreshedInsights.officialUninstaller,
                      current.url.standardizedFileURL.path
                        == expected.url.standardizedFileURL.path else {
                    self.appInstallationActionError = String(
                        localized: "AppSift could not verify the official uninstaller because it changed or moved."
                    )
                    return
                }
                guard NSWorkspace.shared.open(current.url) else {
                    self.appInstallationActionError = String(
                        localized: "macOS could not open the official uninstaller."
                    )
                    return
                }
            }
        }
    }

    private func beginAppFileScan(
        _ app: InstalledApp,
        searchPaths: [String],
        scanID: UUID,
        initialSelection: AppFileInitialSelection
    ) {
        let evidenceFinder = AppPathFinder(
            appInfo: AppPathFinder.AppInfo(installedApp: app),
            searchPaths: searchPaths,
            sensitivity: currentAppSearchSensitivity.pathFinderSensitivity
        )
        activeAppFileScanCancellation = appFileScanner(app, searchPaths) { [weak self] urls in
            guard let self else { return }
            guard self.activeAppFileScanID == scanID,
                  self.selectedApp?.id == app.id else {
                Logger.shared.log("Ignored stale app-file scan result for \(app.appName)", level: .info)
                return
            }
            var safeURLs: Set<URL> = []
            var safeEvidence: [String: AppFileMatchEvidence] = [:]
            var protections: [AppFileProtection] = []
            for url in urls {
                if initialSelection == .relatedFiles,
                   url.standardizedFileURL.path == app.path.standardizedFileURL.path {
                    continue
                }
                let evidence = evidenceFinder.evidence(for: url)
                if let protection = AppRemovalSafetyPolicy.protection(
                    containing: url,
                    selectedApp: app,
                    installedApps: self.installedApps,
                    evidence: evidence
                ) {
                    protections.append(protection)
                } else {
                    safeURLs.insert(url)
                    safeEvidence[url.standardizedFileURL.path] = evidence
                }
            }

            let protectedFiles = Self.groupedProtectedAppFiles(
                protections,
                selectedApp: app,
                installedApps: self.installedApps,
                relationships: self.selectedAppRelationships
            )
            if !protectedFiles.isEmpty {
                Logger.shared.log(
                    "Excluded \(protections.count) candidate(s) across \(protectedFiles.count) protected root(s) from \(app.appName): "
                        + protectedFiles.map { "\($0.reason.rawValue)=\($0.url.path)" }.joined(separator: ", "),
                    level: .warning
                )
            }
            let sorted = safeURLs.sorted { $0.path < $1.path }
            self.discoveredFilesAppID = app.id
            self.discoveredFiles = sorted
            self.protectedAppFiles = protectedFiles
            self.appFileMatchEvidenceByPath = safeEvidence
            self.selectedFilesOwnerAppID = app.id
            switch initialSelection {
            case .all:
                self.selectedFiles = safeURLs
            case .resetEligible:
                self.selectedFiles = Set(safeURLs.filter {
                    self.appResetSafetyPolicy.isEligible($0, for: app)
                })
            case .relatedFiles:
                self.selectedFiles = safeURLs
            }
            self.isScanningAppFiles = false
            self.appFileScanLocationCount = 0
            self.activeAppFileScanCancellation = nil
        }
    }

    func removeSelectedFiles() {
        guard !selectedFiles.isEmpty else { return }
        // Re-entrance guard: if a previous removal is still resolving and
        // the FDA sheet/retry hasn't finished, a second call would race-
        // overwrite the frozen retry context. We can't gate on
        // `removalNeedsFullDiskAccess` alone because AppFilesView hands that
        // state to the permission coordinator as soon as the sheet opens.
        // PermissionCoordinator.isRequesting covers the full sheet-open and
        // retry-pending span.
        guard !isRemovingAppFiles,
              !removalNeedsFullDiskAccess,
              !PermissionCoordinator.shared.isRequesting else {
            Logger.shared.log("Refused duplicate removeSelectedFiles while a removal flow is active", level: .info)
            return
        }
        if let reason = appFileRemovalRefusalReason() {
            refuseAppFileRemoval(reason)
            return
        }
        // Safety guard: never allow a high-risk home dotpath (listed in
        // Conditions.swift) to be trashed no matter how it ended up in the
        // selection. Catches selection-time additions that slipped past the
        // scanner-side filters.
        let allURLs = Array(selectedFiles)
        let (urls, blocked): ([URL], [URL]) = allURLs.reduce(into: ([], [])) { acc, url in
            let resolved = url.resolvingSymlinksInPath().path
            let isBlocked = highRiskHomeDotPaths.contains { root in
                resolved == root || resolved.hasPrefix(root + "/")
            }
            if isBlocked {
                acc.1.append(url)
            } else {
                acc.0.append(url)
            }
        }
        removalError = nil
        removalNeedsFullDiskAccess = false
        if !blocked.isEmpty {
            let blockedList = blocked.map(\.path).joined(separator: ", ")
            Logger.shared.log("Refused to delete \(blocked.count) high-risk home dotpath(s): \(blockedList)", level: .warning)
            selectedFiles.subtract(blocked)
        }
        guard !urls.isEmpty else {
            if !blocked.isEmpty {
                removalError = "Refused to delete \(blocked.count) protected item(s) (home credential directory or similar)."
            }
            return
        }
        guard let app = selectedApp else {
            refuseAppFileRemoval("Refused to remove app files because no app is currently selected.")
            return
        }

        let operation: AppRemovalOperation = selectedAppBundleIncluded(in: urls, app: app)
            ? .uninstall
            : .relatedFiles
        beginAppFileTrash(urls, app: app, operation: operation)
    }

    /// Keeps the selected application installed and moves only the reviewed,
    /// reset-eligible user data to Trash. The app bundle, executable packages,
    /// shared containers, and system-wide components never enter this batch.
    func resetSelectedApp() {
        guard !isRemovingAppFiles,
              !removalNeedsFullDiskAccess,
              !PermissionCoordinator.shared.isRequesting else {
            Logger.shared.log("Refused duplicate resetSelectedApp while an app file action is active", level: .info)
            return
        }

        removalError = nil
        removalNeedsFullDiskAccess = false
        guard let app = selectedApp else {
            refuseAppFileRemoval("Refused to reset app data because no app is currently selected.")
            return
        }
        guard !AppSelfRemovalPolicy.isCurrentApplication(
            bundleIdentifier: app.bundleIdentifier
        ) else {
            failRemovalBeforeTrash(String(localized: "AppSift cannot reset its own running application."))
            return
        }
        guard canResetSelectedApp else {
            failRemovalBeforeTrash(String(localized: "No reviewed user data is selected for reset."))
            return
        }

        let urls = selectedAppResetFiles.sorted { $0.path < $1.path }
        beginAppFileTrash(urls, app: app, operation: .reset)
    }

    private func beginAppFileTrash(
        _ urls: [URL],
        app: InstalledApp,
        operation: AppRemovalOperation
    ) {
        guard !urls.isEmpty else { return }

        isRemovingAppFiles = true
        Task { @MainActor in
            if let reason = await appRuntimeRemovalRefusalReason(
                for: urls,
                app: app,
                operation: operation
            ) {
                failRemovalBeforeTrash(reason)
                return
            }
            guard selectedApp?.id == app.id else {
                failRemovalBeforeTrash(
                    "The selected app changed before removal began, so AppSift left every file untouched."
                )
                return
            }
            if let reason = appFileOperationRefusalReason(
                for: urls,
                app: app,
                operation: operation
            ) {
                failRemovalBeforeTrash(reason)
                return
            }
            trashPreparedAppFiles(urls, app: app, operation: operation)
        }
    }

    private func appRuntimeRemovalRefusalReason(
        for urls: [URL],
        app: InstalledApp,
        operation: AppRemovalOperation
    ) async -> String? {
        guard operation.requiresTargetAppTermination
                || selectedAppBundleIncluded(in: urls, app: app) else {
            return nil
        }

        switch await appTerminationHandler(app, Self.appTerminationTimeout) {
        case .notRunning, .terminated:
            return nil
        case .stillRunning:
            if operation == .reset {
                return "\(app.appName) is still running, so AppSift did not reset it. Quit \(app.appName) from the menu bar or Force Quit it, then try again."
            }
            return "\(app.appName) is still running, so AppSift did not uninstall it. Quit \(app.appName) from the menu bar or Force Quit it, then try again."
        }
    }

    private func appFileOperationRefusalReason(
        for urls: [URL],
        app: InstalledApp,
        operation: AppRemovalOperation,
        requireCurrentScan: Bool = true
    ) -> String? {
        if requireCurrentScan {
            guard discoveredFilesAppID == app.id,
                  Set(urls).isSubset(of: Set(discoveredFiles)) else {
                return "The app file scan changed before the action began, so AppSift left every file untouched."
            }
        }

        let evidenceFinder = appFileEvidenceFinder(for: app)
        let protections = urls.compactMap {
            AppRemovalSafetyPolicy.protection(
                containing: $0,
                selectedApp: app,
                installedApps: installedApps,
                evidence: evidenceFinder.evidence(for: $0)
            )
        }
        guard protections.isEmpty else {
            return "The files changed before the action began, so AppSift left every protected item untouched."
        }

        let containsHighRiskPath = urls.contains { url in
            let resolved = url.resolvingSymlinksInPath().path
            return highRiskHomeDotPaths.contains {
                resolved == $0 || resolved.hasPrefix($0 + "/")
            }
        }
        guard !containsHighRiskPath else {
            return "The files changed before the action began, so AppSift left every protected item untouched."
        }

        if operation == .reset {
            guard !selectedAppBundleIncluded(in: urls, app: app),
                  urls.allSatisfy({ appResetSafetyPolicy.isEligible($0, for: app) }) else {
                return "The reset scope changed before the action began, so AppSift left every file untouched."
            }
        }

        return nil
    }

    private func selectedAppBundleIncluded(in urls: [URL], app: InstalledApp) -> Bool {
        let appPath = app.path.standardizedFileURL.path
        return urls.contains { $0.standardizedFileURL.path == appPath }
    }

    private func failRemovalBeforeTrash(_ reason: String) {
        Logger.shared.log(reason, level: .warning)
        removalError = reason
        removalNeedsFullDiskAccess = false
        pendingAppRemovalRetry = nil
        isRemovingAppFiles = false
    }

    private func trashPreparedAppFiles(
        _ urls: [URL],
        app: InstalledApp,
        operation: AppRemovalOperation,
        historyRecordID: UUID? = nil
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRemovingAppFiles = false }

            let result = await self.appFileTrashHandler(urls)
            if operation == .uninstall {
                let appPath = app.path.standardizedFileURL.path
                let trashAppDestinations = result.trashed.compactMap { item -> URL? in
                    guard item.originalURL.standardizedFileURL.path == appPath,
                          item.originalURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                        return nil
                    }
                    return item.trashURL
                }
                self.trashAppSuppressor(trashAppDestinations)
            }
            let removed = result.trashed.map(\.originalURL) + result.missing
            let recordID = self.recordRemovalHistory(
                result,
                requested: urls,
                app: app,
                operation: operation,
                existingRecordID: historyRecordID
            )
            self.applyRemovedAppFiles(removed, appID: app.id)
            self.finishRemoval(
                removedAny: !removed.isEmpty,
                needsFullDiskAccess: result.needsFullDiskAccess,
                failed: result.failed,
                failureDetails: result.failureDetails,
                app: app,
                historyRecordID: recordID,
                operation: operation
            )
            self.refreshStartupItemsAfterSuccessfulUninstall(
                removed,
                app: app,
                operation: operation
            )
        }
    }

    private func refreshStartupItemsAfterSuccessfulUninstall(
        _ removedURLs: [URL],
        app: InstalledApp,
        operation: AppRemovalOperation
    ) {
        guard operation == .uninstall else { return }
        let appPath = app.path.standardizedFileURL.path
        guard removedURLs.contains(where: {
            $0.standardizedFileURL.path == appPath
        }) else { return }

        // A startup scan is relatively expensive because macOS owns the BTM
        // registry. Refresh only an already-visible or in-flight inventory;
        // otherwise the Startup Items screen will perform its normal first
        // scan when opened.
        guard hasScannedStartupItems || isScanningStartupItems else { return }
        scanStartupItems(force: true)
    }

    private static func defaultAppTerminationHandler(
        app: InstalledApp,
        timeout: TimeInterval
    ) async -> AppTerminationResult {
        func runningTargetApps() -> [NSRunningApplication] {
            NSRunningApplication
                .runningApplications(withBundleIdentifier: app.bundleIdentifier)
                .filter { !$0.isTerminated }
        }

        let running = runningTargetApps()
        guard !running.isEmpty else { return .notRunning }

        for runningApp in running {
            if !runningApp.terminate() {
                Logger.shared.log("Termination request was not accepted by \(app.appName) (\(app.bundleIdentifier))", level: .warning)
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if runningTargetApps().isEmpty {
                return .terminated
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return .stillRunning
    }

    private func appFileRemovalRefusalReason() -> String? {
        if isScanningAppFiles {
            return "Refused to remove app files while a related-file scan is still running."
        }

        guard let app = selectedApp else {
            return "Refused to remove app files because no app is currently selected."
        }

        guard !AppSelfRemovalPolicy.isCurrentApplication(
            bundleIdentifier: app.bundleIdentifier
        ) else {
            return "AppSift cannot uninstall its own running application."
        }

        guard discoveredFilesAppID == app.id else {
            return "Refused to remove app files because the displayed scan results do not belong to the currently selected app."
        }

        guard selectedFilesOwnerAppID == app.id else {
            return "Refused to remove app files because the file selection does not belong to the currently selected app."
        }

        let discoveredSet = Set(discoveredFiles)
        let unexpected = selectedFiles.subtracting(discoveredSet)
        guard unexpected.isEmpty else {
            let sample = unexpected.map(\.path).sorted().prefix(3).joined(separator: ", ")
            return "Refused to remove \(unexpected.count) file(s) that are not in the current scan result: \(sample)"
        }

        let evidenceFinder = appFileEvidenceFinder(for: app)
        let protections = selectedFiles.compactMap {
            AppRemovalSafetyPolicy.protection(
                containing: $0,
                selectedApp: app,
                installedApps: installedApps,
                evidence: evidenceFinder.evidence(for: $0)
            )
        }
        guard protections.isEmpty else {
            let protectedFiles = Self.groupedProtectedAppFiles(protections)
            let sample = protectedFiles.map(\.url.path).prefix(3).joined(separator: ", ")
            return "Refused to remove \(protections.count) protected app file candidate(s) across \(protectedFiles.count) root(s): \(sample)"
        }

        return nil
    }

    private func appFileEvidenceFinder(for app: InstalledApp) -> AppPathFinder {
        AppPathFinder(
            appInfo: AppPathFinder.AppInfo(installedApp: app),
            searchPaths: [],
            sensitivity: currentAppSearchSensitivity.pathFinderSensitivity
        )
    }

    private func refuseAppFileRemoval(_ reason: String) {
        Logger.shared.log(reason, level: .warning)
        removalError = reason
        removalNeedsFullDiskAccess = false
        pendingAppRemovalRetry = nil
        selectedFiles.removeAll()
    }

    private func applyRemovedAppFiles(_ urls: [URL], appID: InstalledApp.ID) {
        guard !urls.isEmpty else { return }
        // A permission retry can finish after the user navigates to another
        // app. Only mutate the visible scan if it still belongs to this app.
        if discoveredFilesAppID == appID {
            // Animate the row sweep-out (AppFilesView attaches the per-row
            // transitions). NSWorkspace is the Reduce Motion check available
            // outside a View's Environment.
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                discoveredFiles.removeAll { urls.contains($0) }
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    discoveredFiles.removeAll { urls.contains($0) }
                }
            }
            selectedFiles.subtract(urls)
            for url in urls {
                appFileMatchEvidenceByPath.removeValue(
                    forKey: url.standardizedFileURL.path
                )
            }
        }
        Logger.shared.log("Removed \(urls.count) file\(urls.count == 1 ? "" : "s")", level: .info)
    }

    private func finishRemoval(
        removedAny: Bool,
        needsFullDiskAccess: Bool,
        failed: [URL],
        failureDetails: [String: AppFileRemovalFailure],
        app: InstalledApp,
        historyRecordID: UUID,
        operation: AppRemovalOperation
    ) {
        // Freeze the failed batch before the FDA sheet opens so the retry
        // path can't be poisoned by later selection edits or app switches.
        pendingAppRemovalRetry = needsFullDiskAccess && !failed.isEmpty
            ? (
                app: app,
                urls: failed,
                historyRecordID: historyRecordID,
                operation: operation
            )
            : nil
        removalNeedsFullDiskAccess = needsFullDiskAccess
        if let message = removalFailureMessage(
            needsFullDiskAccess: needsFullDiskAccess,
            failed: failed,
            failureDetails: failureDetails
        ) {
            if let existing = removalError, !existing.isEmpty {
                removalError = existing + "\n" + message
            } else {
                removalError = message
            }
            Logger.shared.log(message, level: .error)
        }
        if removedAny {
            // Keep the detail context while any selected paths failed. The app
            // bundle itself may already be in Trash, but the user still needs
            // a visible, retryable list of the leftovers that stayed behind.
            pruneMissingInstalledApps(preservingSelectedApp: !failed.isEmpty)
        }
    }

    @discardableResult
    private func recordRemovalHistory(
        _ result: AppFileTrashResult,
        requested: [URL],
        app: InstalledApp,
        operation: AppRemovalOperation,
        existingRecordID: UUID?
    ) -> UUID {
        let existingRecord = existingRecordID.flatMap { recordID in
            removalHistoryStore.snapshot().first { $0.id == recordID }
        }
        if let existingRecordID, existingRecord == nil {
            // The user may have cleared this local report while a Full Disk
            // Access sheet was open. Honor that privacy choice: the retry may
            // still finish moving files, but it must not resurrect the record.
            Logger.shared.log(
                "Removal report was cleared before retry; skipping receipt update",
                level: .info
            )
            return existingRecordID
        }
        let existingItemsByPath = Dictionary(
            (existingRecord?.items ?? []).map { ($0.originalPath, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        let trashedByPath: [String: TrashedAppFile] = Dictionary(
            result.trashed.map {
                ($0.originalURL.standardizedFileURL.path, $0)
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        let missingPaths = Set(result.missing.map { $0.standardizedFileURL.path })
        let attemptItems = requested
            .map(\.standardizedFileURL)
            .sorted { $0.path < $1.path }
            .map { url -> AppRemovalHistoryItem in
                let previous = existingItemsByPath[url.path]
                let outcome: AppRemovalItemOutcome
                let trashPath: String?
                let launchdWasLoaded: Bool?
                let failure: AppFileRemovalFailure?
                if let movedItem = trashedByPath[url.path] {
                    outcome = .movedToTrash
                    trashPath = movedItem.trashURL.path
                    launchdWasLoaded = movedItem.launchdWasLoaded
                    failure = nil
                } else if missingPaths.contains(url.path) {
                    outcome = .alreadyMissing
                    trashPath = nil
                    launchdWasLoaded = nil
                    failure = nil
                } else {
                    outcome = .failed
                    trashPath = nil
                    launchdWasLoaded = nil
                    failure = result.failure(for: url)
                }
                return AppRemovalHistoryItem(
                    id: previous?.id ?? UUID(),
                    originalPath: url.path,
                    trashPath: trashPath,
                    outcome: outcome,
                    evidence: previous?.evidence
                        ?? appFileMatchEvidenceByPath[url.path]
                        ?? .legacyUnknown,
                    failure: failure,
                    launchdWasLoaded: launchdWasLoaded,
                    restoredAt: outcome == .movedToTrash ? previous?.restoredAt : nil
                )
            }

        let record: AppRemovalRecord
        let reportSaved: Bool
        if let existingRecord {
            var mergedItems = existingRecord.items
            for item in attemptItems {
                if let index = mergedItems.firstIndex(where: {
                    $0.originalPath == item.originalPath
                }) {
                    mergedItems[index] = item
                } else {
                    mergedItems.append(item)
                }
            }
            mergedItems.sort { $0.originalPath < $1.originalPath }
            record = AppRemovalRecord(
                schemaVersion: 4,
                id: existingRecord.id,
                appName: existingRecord.appName,
                bundleIdentifier: existingRecord.bundleIdentifier,
                removedAt: existingRecord.removedAt,
                operation: existingRecord.operation,
                searchSensitivity: existingRecord.searchSensitivity,
                items: mergedItems,
                protectedItems: existingRecord.protectedItems
            )
            reportSaved = removalHistoryStore.replace(record)
        } else {
            let protectedItems = protectedAppFiles.map {
                AppRemovalProtectedItem(
                    path: $0.url.standardizedFileURL.path,
                    reason: $0.reason,
                    matchedItemCount: $0.matchedItemCount
                )
            }
            record = AppRemovalRecord(
                appName: app.appName,
                bundleIdentifier: app.bundleIdentifier,
                operation: operation,
                searchSensitivity: currentAppSearchSensitivity,
                items: attemptItems,
                protectedItems: protectedItems
            )
            reportSaved = removalHistoryStore.append(record)
        }
        removalHistory = removalHistoryStore.snapshot()
        if !reportSaved {
            removalError = result.trashed.isEmpty
                ? String(localized: "AppSift could not save the local removal report for this attempt.")
                : String(localized: "Items were moved to Trash, but AppSift could not save the local removal report. Restore them manually from Trash.")
        }
        return record.id
    }

    func refreshRemovalHistory() {
        removalHistory = removalHistoryStore.snapshot()
    }

    func deleteRemovalRecord(_ recordID: UUID) {
        guard restoringRemovalItemIDs.isEmpty else { return }
        guard removalHistoryStore.remove(recordID: recordID) else {
            removalHistoryError = String(localized: "AppSift could not delete the local removal report.")
            return
        }
        removalHistory = removalHistoryStore.snapshot()
    }

    func clearRemovalHistory() {
        guard restoringRemovalItemIDs.isEmpty else { return }
        guard removalHistoryStore.removeAll() else {
            removalHistoryError = String(localized: "AppSift could not delete the local removal report.")
            return
        }
        removalHistory = []
    }

    func restoreRemovalItem(recordID: UUID, itemID: UUID) {
        restoreRemovalItems(recordID: recordID, itemIDs: [itemID])
    }

    func restoreAllAvailableItems(recordID: UUID) {
        guard let record = removalHistory.first(where: { $0.id == recordID }) else { return }
        let itemIDs: [UUID] = record.items.compactMap { item in
            guard item.outcome == .movedToTrash,
                  item.restoredAt == nil,
                  let trashPath = item.trashPath,
                  FileManager.default.fileExists(atPath: trashPath) else { return nil }
            return item.id
        }
        restoreRemovalItems(recordID: recordID, itemIDs: itemIDs)
    }

    private func restoreRemovalItems(recordID: UUID, itemIDs: [UUID]) {
        guard !itemIDs.isEmpty,
              let record = removalHistory.first(where: { $0.id == recordID }) else { return }
        let requestedIDs = Set(itemIDs)
        let items = record.items.filter {
            requestedIDs.contains($0.id)
                && $0.outcome == .movedToTrash
                && $0.restoredAt == nil
                && $0.trashPath != nil
        }
        guard !items.isEmpty else { return }

        restoringRemovalItemIDs.formUnion(items.map(\.id))
        removalHistoryError = nil
        let privilegedService = PrivilegedAppRemovalService()
        let restorationTask: Task<[(AppRemovalHistoryItem, AppRemovalRestorer.Outcome)], Never>
        if privilegedService.requiresAdministratorAccessForRestore(items) {
            restorationTask = Task(priority: .userInitiated) {
                let privilegedOutcomes = await privilegedService.restore(items)
                return items.map { item in
                    (item, privilegedOutcomes[item.id] ?? .blocked)
                }
            }
        } else {
            let restorer = appRemovalRestorer
            restorationTask = Task.detached(priority: .userInitiated) {
                items.map { item in
                    (item, restorer.restore(item))
                }
            }
        }
        Task { @MainActor [weak self] in
            let outcomes = await restorationTask.value
            guard let self else { return }
            defer {
                self.restoringRemovalItemIDs.subtract(items.map(\.id))
            }

            var failures: [String] = []
            var restoredAnApp = false
            for (item, outcome) in outcomes {
                switch outcome {
                case .restored:
                    let saved = self.removalHistoryStore.markRestored(
                        recordID: recordID,
                        itemID: item.id
                    )
                    if !saved {
                        failures.append(
                            String(localized: "AppSift could not update the local removal report after restoring this item.")
                        )
                    }
                    if URL(fileURLWithPath: item.originalPath).pathExtension
                        .caseInsensitiveCompare("app") == .orderedSame {
                        restoredAnApp = true
                    }
                case .sourceMissing:
                    failures.append(
                        String(
                            format: String(localized: "%@: no longer in Trash"),
                            (item.originalPath as NSString).lastPathComponent
                        )
                    )
                case .destinationExists:
                    failures.append(
                        String(
                            format: String(localized: "%@: original location is occupied"),
                            (item.originalPath as NSString).lastPathComponent
                        )
                    )
                case .requiresAdministratorAccess:
                    failures.append(
                        String(
                            format: String(localized: "%@: macOS requires administrator access. Restore it from Trash with Finder."),
                            (item.originalPath as NSString).lastPathComponent
                        )
                    )
                case .authorizationCancelled:
                    failures.append(
                        String(
                            format: String(localized: "%@: administrator authorization was cancelled"),
                            (item.originalPath as NSString).lastPathComponent
                        )
                    )
                case .blocked:
                    failures.append(
                        String(
                            format: String(localized: "%@: unsafe restore path"),
                            (item.originalPath as NSString).lastPathComponent
                        )
                    )
                case .failed(let message):
                    failures.append("\((item.originalPath as NSString).lastPathComponent): \(message)")
                }
            }

            self.removalHistory = self.removalHistoryStore.snapshot()
            if !failures.isEmpty {
                self.removalHistoryError = failures.prefix(3).joined(separator: "\n")
            }
            if restoredAnApp {
                self.loadInstalledApps()
            }
        }
    }

    /// Requests Full Disk Access for the frozen app-file batch and retries it
    /// through the same Finder-style Trash boundary. It deliberately does not
    /// convert app files into generic cleaner items because that path may use
    /// administrator-authorized permanent deletion.
    func requestFullDiskAccessAndRetryAppRemoval() {
        guard removalNeedsFullDiskAccess,
              let retry = pendingAppRemovalRetry,
              !retry.urls.isEmpty else { return }

        pendingAppRemovalRetry = nil
        removalError = nil
        removalNeedsFullDiskAccess = false

        let permissionContext: PermissionCoordinator.PromptContext = retry.operation == .reset
            ? .appReset(appName: retry.app.appName, failedCount: retry.urls.count)
            : .uninstall(appName: retry.app.appName, failedCount: retry.urls.count)
        PermissionCoordinator.shared.requestAccess(
            context: permissionContext,
            failedPaths: retry.urls.map(\.path)
        ) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.retryAppFileTrash(
                    retry.urls,
                    app: retry.app,
                    historyRecordID: retry.historyRecordID,
                    operation: retry.operation
                )
            }
        }
    }

    private func retryAppFileTrash(
        _ urls: [URL],
        app: InstalledApp,
        historyRecordID: UUID,
        operation: AppRemovalOperation
    ) async {
        guard !isRemovingAppFiles else {
            Logger.shared.log("Refused duplicate app Trash retry while a removal is active", level: .info)
            return
        }

        guard !AppSelfRemovalPolicy.isCurrentApplication(
            bundleIdentifier: app.bundleIdentifier
        ) else {
            let message = operation == .reset
                ? String(localized: "AppSift cannot reset its own running application.")
                : "AppSift cannot uninstall its own running application."
            failRemovalBeforeTrash(message)
            return
        }

        if let refusal = appFileOperationRefusalReason(
            for: urls,
            app: app,
            operation: operation,
            requireCurrentScan: false
        ) {
            failRemovalBeforeTrash(refusal)
            return
        }

        isRemovingAppFiles = true
        if let reason = await appRuntimeRemovalRefusalReason(
            for: urls,
            app: app,
            operation: operation
        ) {
            failRemovalBeforeTrash(reason)
            return
        }
        trashPreparedAppFiles(
            urls,
            app: app,
            operation: operation,
            historyRecordID: historyRecordID
        )
    }

    private func removalFailureMessage(
        needsFullDiskAccess: Bool,
        failed: [URL],
        failureDetails: [String: AppFileRemovalFailure]
    ) -> String? {
        if needsFullDiskAccess {
            let prefix = failed.isEmpty ? "Some selected files" : "\(failed.count) file\(failed.count == 1 ? "" : "s")"
            return "\(prefix) could not be removed because AppSift does not have Full Disk Access. Grant Full Disk Access in System Settings, then try again."
        }

        if !failed.isEmpty {
            let headline = String(
                format: String(localized: "%lld file(s) could not be moved to Trash."),
                Int64(failed.count)
            )
            let details = failed.prefix(5).map { url in
                let reason = failureDetails[url.standardizedFileURL.path]
                    ?? AppFileRemovalFailure(kind: .finderRejected)
                return "\(url.lastPathComponent): \(reason.localizedDescription)"
            }
            return ([headline] + details).joined(separator: "\n")
        }
        return nil
    }

    private func pruneMissingInstalledApps(preservingSelectedApp: Bool) {
        let fileManager = FileManager.default
        installedApps.removeAll { !fileManager.fileExists(atPath: $0.path.path) }

        if let selectedApp,
           !preservingSelectedApp,
           !fileManager.fileExists(atPath: selectedApp.path.path) {
            self.selectedApp = nil
            resetAppInstallationInspection()
            resetAppRelationshipScan()
            discoveredFiles = []
            protectedAppFiles = []
            appFileMatchEvidenceByPath = [:]
            selectedFiles = []
        }
    }

    private static func groupedProtectedAppFiles(
        _ protections: [AppFileProtection],
        selectedApp: InstalledApp? = nil,
        installedApps: [InstalledApp] = [],
        relationships: AppRelationshipScanResult? = nil
    ) -> [ProtectedAppFile] {
        let grouped = Dictionary(grouping: protections) { protection in
            ProtectedAppFile.ID(
                path: protection.protectedRoot.standardizedFileURL.path,
                reason: protection.reason
            )
        }

        return grouped.compactMap { id, matches in
            guard let representative = matches.first else { return nil }
            return ProtectedAppFile(
                url: representative.protectedRoot.standardizedFileURL,
                reason: id.reason,
                matchedItemCount: matches.count,
                relatedApplications: protectedFileRelationships(
                    for: representative,
                    selectedApp: selectedApp,
                    installedApps: installedApps,
                    relationships: relationships
                )
            )
        }
        .sorted {
            if $0.url.path == $1.url.path {
                return $0.reason.rawValue < $1.reason.rawValue
            }
            return $0.url.path < $1.url.path
        }
    }

    private static func protectedFileRelationships(
        for protection: AppFileProtection,
        selectedApp: InstalledApp?,
        installedApps: [InstalledApp],
        relationships: AppRelationshipScanResult?
    ) -> [AppRelationshipApplication] {
        guard let selectedApp else { return [] }
        var byID = Dictionary(
            AppRemovalSafetyPolicy.relatedApplications(
                for: protection,
                selectedApp: selectedApp,
                installedApps: installedApps
            ).map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )

        if protection.reason == .sharedContainer,
           let relationships {
            let identifier = protection.protectedRoot.lastPathComponent
            for group in relationships.groups(containing: selectedApp.id)
                where group.identifier == identifier {
                for application in group.applications where application.id != selectedApp.id {
                    byID[application.id] = application
                }
            }
        }
        return byID.values.sorted(by: AppRelationshipScanner.applicationSort)
    }

    private func refreshProtectedAppFileRelationships(
        selectedApp: InstalledApp,
        result: AppRelationshipScanResult
    ) {
        protectedAppFiles = protectedAppFiles.map { protectedFile in
            let protection = AppFileProtection(
                candidateURL: protectedFile.url,
                protectedRoot: protectedFile.url,
                reason: protectedFile.reason
            )
            return ProtectedAppFile(
                url: protectedFile.url,
                reason: protectedFile.reason,
                matchedItemCount: protectedFile.matchedItemCount,
                relatedApplications: Self.protectedFileRelationships(
                    for: protection,
                    selectedApp: selectedApp,
                    installedApps: installedApps,
                    relationships: result
                )
            )
        }
    }

    func findOrphans() {
        isSearchingOrphans = true
        orphanedFiles = []
        Task.detached(priority: .userInitiated) {
            let locations = Locations()
            let knownApps = await MainActor.run { self.installedApps }
            let knownIDs = Set(knownApps.map { $0.bundleIdentifier.normalizedForMatching() })
            let knownNames = Set(knownApps.map { $0.appName.normalizedForMatching() })
            // Paths the user marked "Always Ignore" (issue #114). These were
            // false positives for them, so they stay hidden from every scan
            // until the user forgets the list in Settings.
            let ignored = Set(UserDefaults.standard.stringArray(forKey: Self.ignoredOrphansKey) ?? [])

            var orphans: [URL] = []
            let fm = FileManager.default

            for path in locations.reverseSearch.paths {
                guard let contents = try? fm.contentsOfDirectory(atPath: path) else { continue }
                for item in contents {
                    let normalized = item.normalizedForMatching()

                    // Skip known system items
                    if skipReverse.contains(where: { normalized.hasPrefix($0) }) { continue }

                    // Check if this item belongs to any known app
                    let belongsToApp = knownIDs.contains(where: { normalized.contains($0) }) ||
                                       knownNames.contains(where: { normalized.contains($0) })

                    if !belongsToApp {
                        let fullPath = URL(fileURLWithPath: path).appendingPathComponent(item)
                        if ignored.contains(fullPath.path) { continue }
                        if OrphanSafetyPolicy.isSafeCandidate(fullPath) {
                            orphans.append(fullPath)
                        }
                    }
                }
            }

            let sorted = orphans.sorted { $0.lastPathComponent < $1.lastPathComponent }
            await MainActor.run { [weak self] in
                self?.orphanedFiles = sorted
                self?.isSearchingOrphans = false
            }
        }
    }

    // MARK: - Orphan ignore list (#114)

    nonisolated static let ignoredOrphansKey = "settings.orphans.ignored"

    /// Number of paths currently on the "always ignore" list. Read from
    /// UserDefaults each access so the Settings row tracks live changes.
    var ignoredOrphanCount: Int {
        UserDefaults.standard.stringArray(forKey: Self.ignoredOrphansKey)?.count ?? 0
    }

    /// Permanently hide the given orphans from future scans and sweep them out
    /// of the current results.
    func ignoreOrphans(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var ignored = Set(UserDefaults.standard.stringArray(forKey: Self.ignoredOrphansKey) ?? [])
        for url in urls { ignored.insert(url.path) }
        UserDefaults.standard.set(Array(ignored), forKey: Self.ignoredOrphansKey)

        let urlSet = Set(urls)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            orphanedFiles.removeAll { urlSet.contains($0) }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                orphanedFiles.removeAll { urlSet.contains($0) }
            }
        }
        Logger.shared.log("Ignoring \(urls.count) orphan(s) in future scans", level: .info)
    }

    /// Forget every ignored path so they can surface again on the next scan.
    func clearIgnoredOrphans() {
        UserDefaults.standard.removeObject(forKey: Self.ignoredOrphansKey)
        objectWillChange.send()
    }

    // MARK: - Selection

    func isItemSelected(_ item: CleanableItem) -> Bool {
        if item.isSelected {
            return !deselectedItems.contains(item.id)
        }
        return selectedCleanupItems.contains(item.id)
    }

    func toggleItem(_ item: CleanableItem) {
        if isItemSelected(item) {
            if item.isSelected {
                deselectedItems.insert(item.id)
            } else {
                selectedCleanupItems.remove(item.id)
            }
        } else {
            if item.isSelected {
                deselectedItems.remove(item.id)
            } else {
                selectedCleanupItems.insert(item.id)
            }
        }
    }

    func selectAllInCategory(_ category: CleaningCategory) {
        guard let result = categoryResults[category] else { return }
        for item in result.items {
            if item.isSelected {
                deselectedItems.remove(item.id)
            } else {
                selectedCleanupItems.insert(item.id)
            }
        }
    }

    func deselectAllInCategory(_ category: CleaningCategory) {
        guard let result = categoryResults[category] else { return }
        for item in result.items {
            if item.isSelected {
                deselectedItems.insert(item.id)
            } else {
                selectedCleanupItems.remove(item.id)
            }
        }
    }

    func selectedSizeInCategory(_ category: CleaningCategory) -> Int64 {
        guard let result = categoryResults[category] else { return 0 }
        return result.items.filter { isItemSelected($0) }.reduce(0) { $0 + $1.size }
    }

    func selectedCountInCategory(_ category: CleaningCategory) -> Int {
        guard let result = categoryResults[category] else { return 0 }
        return result.items.filter { isItemSelected($0) }.count
    }

    // MARK: - Helper Methods

    func categorySize(for category: CleaningCategory) -> String {
        guard let result = categoryResults[category], result.totalSize > 0 else { return "" }
        return result.formattedSize
    }

    func categoryBinding(for category: CleaningCategory) -> Binding<Bool> {
        Binding<Bool>(
            get: { [weak self] in
                guard let self else { return false }
                return self.selectedCountInCategory(category) > 0
            },
            set: { [weak self] newValue in
                guard let self else { return }
                if newValue {
                    self.selectAllInCategory(category)
                } else {
                    self.deselectAllInCategory(category)
                }
            }
        )
    }

    func itemBinding(for item: CleanableItem) -> Binding<Bool> {
        Binding<Bool>(
            get: { [weak self] in
                self?.isItemSelected(item) ?? false
            },
            set: { [weak self] _ in
                self?.toggleItem(item)
            }
        )
    }

    private func clearSelectionState() {
        selectedCleanupItems.removeAll()
        deselectedItems.removeAll()
    }

    private func clearSelectionState(for category: CleaningCategory) {
        guard let result = categoryResults[category] else { return }
        for item in result.items {
            selectedCleanupItems.remove(item.id)
            deselectedItems.remove(item.id)
        }
    }

    // MARK: - Full Disk Access

    func checkFullDiskAccess() {
        Task.detached {
            let granted = FullDiskAccessManager.shared.hasFullDiskAccess
            await MainActor.run { [weak self] in
                self?.hasFullDiskAccess = granted
            }
        }
    }

    func openFullDiskAccessSettings() {
        FullDiskAccessManager.shared.openFullDiskAccessSettings()
    }

    /// Request Full Disk Access via the rich PermissionCoordinator sheet and
    /// retry the supplied items once the user grants permission. Used by both
    /// the cleanup and app-uninstall flows so they share a single UI surface.
    ///
    /// The retry callback captures `items` directly rather than reading
    /// `pendingPermissionRetryItems` at fire time — that field is mutable
    /// app-wide and a second permission request would clobber it before the
    /// first callback resolves, sending the wrong items to retryCleanItems.
    func requestFullDiskAccessAndRetry(items: [CleanableItem], context: PermissionCoordinator.PromptContext) {
        pendingPermissionRetryItems = items
        let capturedItems = items
        PermissionCoordinator.shared.requestAccess(
            context: context,
            failedPaths: items.map { $0.path }
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingPermissionRetryItems = []
                self.cleanError = nil
                self.cleanErrorIsFDAFixable = false
                guard !capturedItems.isEmpty else { return }
                await self.retryCleanItems(capturedItems)
            }
        }
    }

    private func retryCleanItems(_ items: [CleanableItem]) async {
        scanState = .cleaning(progress: 0)
        cleanProgress = 0

        var result = await cleaningEngine.cleanItems(items) { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.cleanProgress = progress
                self?.scanState = .cleaning(progress: progress)
            }
        }
        if !result.requiresAdmin.isEmpty {
            let admin = await cleaningEngine.cleanWithAdminPrivileges(items: result.requiresAdmin)
            result.cleanedPaths.formUnion(admin.cleanedPaths)
            result.itemsCleaned += admin.itemsCleaned
            result.freedSpace += admin.freedSpace
            result.errors.append(contentsOf: admin.errors)
        }

        totalFreedSpace = result.freedSpace
        lastCleanedDate = Date()

        for (cat, catResult) in categoryResults {
            let remaining = catResult.items.filter { !result.cleanedPaths.contains($0.path) }
            let cleared = catResult.items.filter { result.cleanedPaths.contains($0.path) }
            for item in cleared {
                selectedCleanupItems.remove(item.id)
                deselectedItems.remove(item.id)
            }
            if remaining.isEmpty {
                categoryResults.removeValue(forKey: cat)
            } else {
                categoryResults[cat] = CategoryResult(
                    category: cat,
                    items: remaining,
                    totalSize: remaining.reduce(0) { $0 + $1.size }
                )
            }
        }
        totalJunkSize = categoryResults.values.reduce(0) { $0 + $1.totalSize }

        // Route survivors back through the same outcome path the original
        // cleanup uses. Without this, an FDA revocation between grant and
        // retry would silently drop errors instead of re-popping the sheet.
        let survivors = items.filter { !result.cleanedPaths.contains($0.path) }
        handleCleanOutcome(errors: result.errors, survivors: survivors)

        scanState = .cleaned
        loadDiskInfo()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        scanState = .idle
        totalFreedSpace = 0
    }

    // MARK: - Disk Info

    func loadDiskInfo() {
        Task {
            let info = await scanEngine.getDiskInfo()
            self.diskInfo = info
        }
    }

    // MARK: - Time Machine Snapshots

    func scanLocalTimeMachineSnapshots() {
        guard !isScanningTimeMachineSnapshots, !isDeletingTimeMachineSnapshots else { return }

        isScanningTimeMachineSnapshots = true
        timeMachineSnapshotError = nil

        Task {
            let minimumVisibleScanDuration: TimeInterval = 0.35
            let startedAt = Date()
            do {
                let result = try await timeMachineSnapshotService.scan()
                localTimeMachineSnapshots = result.snapshots
                isTimeMachineBackupRunning = result.isBackupRunning
                selectedTimeMachineSnapshotIDs.formIntersection(Set(result.snapshots.map(\.id)))
                hasScannedTimeMachineSnapshots = true
                lastTimeMachineSnapshotScanDate = Date()
            } catch {
                timeMachineSnapshotError = error.localizedDescription
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed < minimumVisibleScanDuration {
                try? await Task.sleep(nanoseconds: UInt64((minimumVisibleScanDuration - elapsed) * 1_000_000_000))
            }
            isScanningTimeMachineSnapshots = false
        }
    }

    func deleteSelectedTimeMachineSnapshots() {
        guard !isScanningTimeMachineSnapshots,
              !isDeletingTimeMachineSnapshots,
              !isTimeMachineBackupRunning else {
            return
        }

        let snapshots = localTimeMachineSnapshots.filter {
            selectedTimeMachineSnapshotIDs.contains($0.id)
        }
        guard !snapshots.isEmpty else { return }

        isDeletingTimeMachineSnapshots = true
        timeMachineSnapshotError = nil
        lastTimeMachineFreedSpace = 0
        lastTimeMachineDeletedCount = 0

        Task {
            do {
                let deletion = try await timeMachineSnapshotService.delete(snapshots)
                let refreshed = try await timeMachineSnapshotService.scan()

                localTimeMachineSnapshots = refreshed.snapshots
                isTimeMachineBackupRunning = refreshed.isBackupRunning
                selectedTimeMachineSnapshotIDs.formIntersection(Set(refreshed.snapshots.map(\.id)))
                lastTimeMachineFreedSpace = deletion.freedSpace
                lastTimeMachineDeletedCount = deletion.deletedCount

                if deletion.remainingSnapshotIDs.isEmpty {
                    if deletion.deletedCount > 0 { Haptics.successWithSound() }
                } else {
                    timeMachineSnapshotError = String(
                        format: String(localized: "%lld snapshot(s) could not be deleted. Refresh and try again."),
                        Int64(deletion.remainingSnapshotIDs.count)
                    )
                }
                loadDiskInfo()
            } catch {
                timeMachineSnapshotError = error.localizedDescription
            }
            isDeletingTimeMachineSnapshots = false
        }
    }

    func openTimeMachine() {
        timeMachineSnapshotError = nil

        let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.backup.launcher")
            ?? URL(fileURLWithPath: "/System/Applications/Time Machine.app")

        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            timeMachineSnapshotError = String(localized: "Time Machine could not be opened.")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.timeMachineSnapshotError = error.localizedDescription
            }
        }
    }

    // MARK: - Scanning

    /// Leaves scan or cleanup results available while returning the dashboard
    /// to its storage overview. Active work remains visible until it finishes.
    func showDashboardOverview() {
        guard !scanState.isActive else { return }
        scanState = .idle
        totalFreedSpace = 0
    }

    func startSmartScan() {
        guard !scanState.isActive else { return }

        scanState = .scanning(progress: 0, currentCategory: "Preparing...")
        categoryResults = [:]
        totalJunkSize = 0
        scanProgress = 0
        clearSelectionState()

        Task {
            let categories = CleaningCategory.scannable
            let total = categories.count

            for (index, category) in categories.enumerated() {
                let progress = Double(index) / Double(total)
                scanProgress = progress
                currentScanCategory = category.rawValue
                scanState = .scanning(progress: progress, currentCategory: category.rawValue)

                let result = await scanEngine.scanCategory(category) { [weak self] path in
                    Task { @MainActor [weak self] in
                        self?.scanTicker.path = path
                    }
                }
                categoryResults[category] = result
                totalJunkSize += result.totalSize
            }

            scanProgress = 1.0
            scanTicker.path = ""
            scanState = .completed
            loadDiskInfo()
        }
    }

    func scanSingleCategory(_ category: CleaningCategory) {
        guard !scanState.isActive else { return }

        scanState = .scanning(progress: 0, currentCategory: category.rawValue)
        scanProgress = 0

        Task {
            scanProgress = 0.5
            clearSelectionState(for: category)
            let result = await scanEngine.scanCategory(category) { [weak self] path in
                Task { @MainActor [weak self] in
                    self?.scanTicker.path = path
                }
            }
            categoryResults[category] = result

            totalJunkSize = categoryResults.values.reduce(0) { $0 + $1.totalSize }
            scanProgress = 1.0
            scanTicker.path = ""
            scanState = .completed
        }
    }

    // MARK: - Cleaning

    func cleanAll() {
        guard !scanState.isActive else { return }

        let itemsToClean = allResults.flatMap { $0.items }.filter { isItemSelected($0) }
        guard !itemsToClean.isEmpty else { return }

        scanState = .cleaning(progress: 0)
        cleanProgress = 0

        Task {
            var result = await cleaningEngine.cleanItems(itemsToClean) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.cleanProgress = progress
                    self?.scanState = .cleaning(progress: progress)
                }
            }

            // Escalate root-owned items via "with administrator privileges".
            // One auth prompt covers the entire batch.
            if !result.requiresAdmin.isEmpty {
                let admin = await cleaningEngine.cleanWithAdminPrivileges(items: result.requiresAdmin)
                result.cleanedPaths.formUnion(admin.cleanedPaths)
                result.itemsCleaned += admin.itemsCleaned
                result.freedSpace += admin.freedSpace
                result.errors.append(contentsOf: admin.errors)
            }

            totalFreedSpace = result.freedSpace
            lastCleanedDate = Date()
            if result.itemsCleaned > 0 { Haptics.successWithSound() }

            let survivors = itemsToClean.filter { !result.cleanedPaths.contains($0.path) }

            for (cat, catResult) in categoryResults {
                let remaining = catResult.items.filter { !result.cleanedPaths.contains($0.path) }
                let cleared = catResult.items.filter { result.cleanedPaths.contains($0.path) }
                for item in cleared {
                    selectedCleanupItems.remove(item.id)
                    deselectedItems.remove(item.id)
                }
                if remaining.isEmpty {
                    categoryResults.removeValue(forKey: cat)
                } else {
                    categoryResults[cat] = CategoryResult(
                        category: cat,
                        items: remaining,
                        totalSize: remaining.reduce(0) { $0 + $1.size }
                    )
                }
            }
            totalJunkSize = categoryResults.values.reduce(0) { $0 + $1.totalSize }

            handleCleanOutcome(errors: result.errors, survivors: survivors)

            scanState = .cleaned
            loadDiskInfo()

            try? await Task.sleep(nanoseconds: 3_000_000_000)
            scanState = .idle
            totalFreedSpace = 0
        }
    }

    func cleanCategory(_ category: CleaningCategory) {
        guard let result = categoryResults[category], !scanState.isActive else { return }

        let selectedItems = result.items.filter { isItemSelected($0) }
        guard !selectedItems.isEmpty else { return }

        scanState = .cleaning(progress: 0)
        cleanProgress = 0

        Task {
            var cleanResult = await cleaningEngine.cleanItems(selectedItems) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.cleanProgress = progress
                    self?.scanState = .cleaning(progress: progress)
                }
            }

            if !cleanResult.requiresAdmin.isEmpty {
                let admin = await cleaningEngine.cleanWithAdminPrivileges(items: cleanResult.requiresAdmin)
                cleanResult.cleanedPaths.formUnion(admin.cleanedPaths)
                cleanResult.itemsCleaned += admin.itemsCleaned
                cleanResult.freedSpace += admin.freedSpace
                cleanResult.errors.append(contentsOf: admin.errors)
            }

            totalFreedSpace = cleanResult.freedSpace
            lastCleanedDate = Date()

            if let existing = categoryResults[category] {
                let remaining = existing.items.filter { !cleanResult.cleanedPaths.contains($0.path) }
                let cleared = existing.items.filter { cleanResult.cleanedPaths.contains($0.path) }
                for item in cleared {
                    selectedCleanupItems.remove(item.id)
                    deselectedItems.remove(item.id)
                }
                if remaining.isEmpty {
                    categoryResults.removeValue(forKey: category)
                } else {
                    categoryResults[category] = CategoryResult(
                        category: category,
                        items: remaining,
                        totalSize: remaining.reduce(0) { $0 + $1.size }
                    )
                }
            }
            totalJunkSize = categoryResults.values.reduce(0) { $0 + $1.totalSize }

            let survivors = selectedItems.filter { !cleanResult.cleanedPaths.contains($0.path) }
            handleCleanOutcome(errors: cleanResult.errors, survivors: survivors)

            scanState = .cleaned
            loadDiskInfo()

            try? await Task.sleep(nanoseconds: 3_000_000_000)
            scanState = .idle
            totalFreedSpace = 0
        }
    }

    /// Inspect a clean batch's leftovers and either route the user into the
    /// PermissionSheet (FDA is the most likely cause) or surface a richer
    /// error alert that lists actual paths instead of "Check the log".
    private func handleCleanOutcome(errors: [String], survivors: [CleanableItem]) {
        guard !errors.isEmpty || !survivors.isEmpty else {
            cleanError = nil
            cleanErrorIsFDAFixable = false
            pendingPermissionRetryItems = []
            return
        }

        let fdaGranted = FullDiskAccessManager.shared.hasFullDiskAccess
        let likelyFDA = !fdaGranted && !survivors.isEmpty
        cleanErrorIsFDAFixable = likelyFDA
        pendingPermissionRetryItems = survivors

        if likelyFDA {
            cleanError = String(
                format: String(localized: "%lld item(s) need Full Disk Access to remove. Tap Grant Access to fix in one step."),
                Int64(survivors.count)
            )
        } else if !survivors.isEmpty {
            let preview = survivors.prefix(2)
                .map { ($0.path as NSString).abbreviatingWithTildeInPath }
                .joined(separator: ", ")
            let extra = survivors.count > 2 ? String(format: String(localized: " and %lld more"), Int64(survivors.count - 2)) : ""
            cleanError = String(
                format: String(localized: "Couldn't remove %@%@. They may be in use or protected by macOS."),
                preview, extra
            )
        } else if let first = errors.first {
            cleanError = first
        }
    }

    // MARK: - Purgeable

    func purgePurgeable() {
        guard !scanState.isActive else { return }

        scanState = .cleaning(progress: 0)

        Task {
            scanState = .cleaning(progress: 0.5)
            let freed = await cleaningEngine.purgePurgeableSpace()
            totalFreedSpace = freed
            scanState = .cleaned
            loadDiskInfo()

            try? await Task.sleep(nanoseconds: 3_000_000_000)
            scanState = .idle
            totalFreedSpace = 0
        }
    }

    // MARK: - Scheduled Scan

    private func runScheduledScan() async {
        let categories = scheduler.config.categoriesToScan
        var totalFound: Int64 = 0
        clearSelectionState()
        categoryResults = [:]

        for category in categories {
            let result = await scanEngine.scanCategory(category)
            categoryResults[category] = result
            totalFound += result.totalSize
        }

        totalJunkSize = totalFound

        if scheduler.config.autoClean && totalFound >= scheduler.config.minimumCleanSize {
            cleanAll()
        }

        // Purgeable space is intentionally NOT auto-purged: macOS reserves and
        // reclaims it on its own and AppSift does not claim to free it. See
        // CleaningCategory.scannable.

        if scheduler.config.notifyOnCompletion {
            sendNotification(freed: totalFound)
        }
    }

    private func sendNotification(freed: Int64) {
        let content = UNMutableNotificationContent()
        content.title = "AppSift"
        let sizeStr = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
        content.body = String(format: NSLocalizedString("Found %@ of junk files.", comment: ""), sizeStr)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    private nonisolated static let defaultAppFileScanner: AppFileScanner = {
        app, searchPaths, completion in
        let appInfo = AppPathFinder.AppInfo(installedApp: app)
        let sensitivity = SearchSensitivity.stored().pathFinderSensitivity
        let finder = AppPathFinder(
            appInfo: appInfo,
            searchPaths: searchPaths,
            sensitivity: sensitivity
        )
        finder.findPathsAsync(completion: completion)
        return { finder.cancel() }
    }

    private nonisolated static let defaultAppFileTrashHandler: AppFileTrashHandler = { urls in
        await AppFileTrashService.trash(urls)
    }
}
