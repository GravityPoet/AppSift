import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

struct DefaultApplicationControlRecord: Codable, Identifiable, Hashable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let contentTypeIdentifier: String
    let displayName: String
    let filenameExtensions: [String]
    let previousApplicationName: String
    let previousApplicationBundleIdentifier: String
    let previousApplicationPath: String
    let newApplicationName: String
    let newApplicationBundleIdentifier: String
    let newApplicationPath: String
    let changedAt: Date
    var restoredAt: Date?

    init(
        schemaVersion: Int = 1,
        id: UUID = UUID(),
        contentTypeIdentifier: String,
        displayName: String,
        filenameExtensions: [String],
        previousApplication: DefaultApplicationCandidate,
        newApplication: DefaultApplicationCandidate,
        changedAt: Date = Date(),
        restoredAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.contentTypeIdentifier = contentTypeIdentifier
        self.displayName = displayName
        self.filenameExtensions = filenameExtensions
        self.previousApplicationName = previousApplication.name
        self.previousApplicationBundleIdentifier = previousApplication.bundleIdentifier
        self.previousApplicationPath = previousApplication.url.path
        self.newApplicationName = newApplication.name
        self.newApplicationBundleIdentifier = newApplication.bundleIdentifier
        self.newApplicationPath = newApplication.url.path
        self.changedAt = changedAt
        self.restoredAt = restoredAt
    }
}

struct DefaultApplicationControlOutcome: Sendable {
    let record: DefaultApplicationControlRecord
    let currentApplication: DefaultApplicationCandidate
}

struct DefaultApplicationUndoOutcome: Sendable {
    let record: DefaultApplicationControlRecord
    let currentApplication: DefaultApplicationCandidate
    let historyPersisted: Bool
}

enum DefaultApplicationControlError: LocalizedError, Equatable {
    case unsupportedContentType
    case unsafeApplication
    case sourceChanged
    case candidateUnavailable
    case alreadyCurrent
    case changeNotApplied
    case changeFailedRolledBack
    case changeFailedRollbackFailed
    case historySaveFailedRolledBack
    case historySaveFailedRollbackFailed
    case staleHistory
    case currentHandlerChanged
    case previousApplicationUnavailable
    case undoNotApplied
    case undoFailedRollbackFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedContentType:
            return String(localized: "This file type is no longer registered with macOS.")
        case .unsafeApplication:
            return String(localized: "AppSift rejected an unsafe or missing application bundle.")
        case .sourceChanged:
            return String(localized: "The current default application changed after this list was scanned. Refresh and try again.")
        case .candidateUnavailable:
            return String(localized: "The selected application is no longer registered to open this file type.")
        case .alreadyCurrent:
            return String(localized: "This application is already the default for the selected file type.")
        case .changeNotApplied:
            return String(localized: "macOS kept the existing default application.")
        case .changeFailedRolledBack:
            return String(localized: "macOS could not complete the change, so AppSift restored the previous default.")
        case .changeFailedRollbackFailed:
            return String(localized: "macOS could not complete or fully roll back the change. Refresh Default Applications before trying again.")
        case .historySaveFailedRolledBack:
            return String(localized: "AppSift restored the previous default because its undo history could not be saved.")
        case .historySaveFailedRollbackFailed:
            return String(localized: "The change could not be recorded or fully rolled back. Refresh Default Applications before trying again.")
        case .staleHistory:
            return String(localized: "Undo newer changes for this file type first.")
        case .currentHandlerChanged:
            return String(localized: "The default application changed after this action, so AppSift refused to overwrite the newer choice.")
        case .previousApplicationUnavailable:
            return String(localized: "The previous application is no longer available for this file type.")
        case .undoNotApplied:
            return String(localized: "macOS kept the current default application instead of restoring the previous one.")
        case .undoFailedRollbackFailed:
            return String(localized: "macOS could not restore the previous default or return to the current one. Refresh Default Applications before trying again.")
        }
    }
}

final class DefaultApplicationControlHistoryStore: @unchecked Sendable {
    static let shared = DefaultApplicationControlHistoryStore()

    private static let maximumRecords = 100
    private static let maximumBytes = 512_000

    private let fileURL: URL
    private let lock = NSLock()
    private var records: [DefaultApplicationControlRecord]

    init(
        fileURL: URL = DefaultApplicationControlHistoryStore.defaultFileURL
    ) {
        self.fileURL = fileURL
        self.records = Self.load(from: fileURL)
    }

    func snapshot() -> [DefaultApplicationControlRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func isLatestActive(_ record: DefaultApplicationControlRecord) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return records.first {
            $0.contentTypeIdentifier == record.contentTypeIdentifier
                && $0.restoredAt == nil
        }?.id == record.id
    }

    @discardableResult
    func append(_ record: DefaultApplicationControlRecord) -> Bool {
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
    func markRestored(recordID: UUID, at date: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              records[index].restoredAt == nil,
              records.first(where: {
                  $0.contentTypeIdentifier
                      == records[index].contentTypeIdentifier
                      && $0.restoredAt == nil
              })?.id == recordID else {
            return false
        }
        records[index].restoredAt = date
        return persistLocked()
    }

    private func persistLocked() -> Bool {
        guard let data = try? JSONEncoder().encode(records),
              data.count <= Self.maximumBytes else {
            Logger.shared.log(
                "Default-application history exceeded its safety limit",
                level: .warning
            )
            return false
        }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
            guard Self.isSafeHistoryContainer(directory),
                  !Self.isSymbolicLink(fileURL) else {
                return false
            }
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            Logger.shared.log(
                "Could not persist default-application history: \(error.localizedDescription)",
                level: .warning
            )
            return false
        }
    }

    private static func load(
        from fileURL: URL
    ) -> [DefaultApplicationControlRecord] {
        guard isSafeHistoryContainer(fileURL.deletingLastPathComponent()),
              !isSymbolicLink(fileURL),
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
                [DefaultApplicationControlRecord].self,
                from: data
              ),
              decoded.count <= maximumRecords,
              Set(decoded.map(\.id)).count == decoded.count,
              decoded.allSatisfy(isValid) else {
            return []
        }
        return decoded.sorted { $0.changedAt > $1.changedAt }
    }

    private static func isValid(
        _ record: DefaultApplicationControlRecord
    ) -> Bool {
        guard record.schemaVersion == 1,
              isReasonableIdentifier(record.contentTypeIdentifier),
              isReasonableText(record.displayName, maximum: 512),
              record.filenameExtensions.count <= 32,
              record.filenameExtensions.allSatisfy({
                  isReasonableFilenameExtension($0)
              }),
              isReasonableText(record.previousApplicationName, maximum: 512),
              isReasonableIdentifier(
                record.previousApplicationBundleIdentifier
              ),
              isReasonableApplicationPath(record.previousApplicationPath),
              isReasonableText(record.newApplicationName, maximum: 512),
              isReasonableIdentifier(record.newApplicationBundleIdentifier),
              isReasonableApplicationPath(record.newApplicationPath),
              record.previousApplicationPath != record.newApplicationPath,
              record.changedAt.timeIntervalSinceReferenceDate.isFinite else {
            return false
        }
        if let restoredAt = record.restoredAt {
            return restoredAt.timeIntervalSinceReferenceDate.isFinite
                && restoredAt >= record.changedAt
        }
        return true
    }

    private static func isReasonableIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || [".", "-", "_"].contains(Character(String($0)))
        }
    }

    private static func isReasonableFilenameExtension(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || ["+", "-", "_"].contains(Character(String($0)))
        }
    }

    private static func isReasonableText(
        _ value: String,
        maximum: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximum
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isReasonableApplicationPath(_ value: String) -> Bool {
        guard value.hasPrefix("/"),
              value.utf8.count <= 4_096,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return false
        }
        let url = URL(fileURLWithPath: value)
        return url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            && !url.pathComponents.contains(".Trash")
            && !url.pathComponents.contains(".Trashes")
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ).isSymbolicLink) == true
    }

    private static func isSafeHistoryContainer(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
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
            .appendingPathComponent(
                "default-application-control-history.json"
            )
    }
}

final class DefaultApplicationController: @unchecked Sendable {
    typealias SnapshotProvider = DefaultApplicationScanner.HandlerProvider
    typealias Setter = @Sendable (
        _ applicationURL: URL,
        _ contentTypeIdentifier: String
    ) async -> Error?

    private struct ValidatedChange {
        let current: DefaultApplicationCandidate
        let target: DefaultApplicationCandidate
    }

    private let historyStore: DefaultApplicationControlHistoryStore
    private let snapshotProvider: SnapshotProvider
    private let setter: Setter
    private let fileManager: FileManager

    init(
        historyStore: DefaultApplicationControlHistoryStore = .shared,
        fileManager: FileManager = .default,
        snapshotProvider: @escaping SnapshotProvider = { identifier in
            guard let type = UTType(identifier) else { return nil }
            return DefaultApplicationHandlerSnapshot(
                defaultApplicationURL: NSWorkspace.shared.urlForApplication(
                    toOpen: type
                ),
                candidateApplicationURLs: NSWorkspace.shared
                    .urlsForApplications(toOpen: type)
            )
        },
        setter: Setter? = nil
    ) {
        self.historyStore = historyStore
        self.fileManager = fileManager
        self.snapshotProvider = snapshotProvider
        if let setter {
            self.setter = setter
        } else {
            self.setter = { applicationURL, identifier in
                guard let type = UTType(identifier) else {
                    return DefaultApplicationControlError
                        .unsupportedContentType
                }
                return await withCheckedContinuation { continuation in
                    NSWorkspace.shared.setDefaultApplication(
                        at: applicationURL,
                        toOpen: type
                    ) { error in
                        continuation.resume(returning: error)
                    }
                }
            }
        }
    }

    func historySnapshot() -> [DefaultApplicationControlRecord] {
        historyStore.snapshot()
    }

    func canUndo(_ record: DefaultApplicationControlRecord) -> Bool {
        record.restoredAt == nil && historyStore.isLatestActive(record)
    }

    func perform(
        item: DefaultApplicationItem,
        target requestedTarget: DefaultApplicationCandidate,
        changedAt: Date = Date()
    ) async throws -> DefaultApplicationControlOutcome {
        let validated = try validate(item: item, target: requestedTarget)
        guard validated.current.id != validated.target.id else {
            throw DefaultApplicationControlError.alreadyCurrent
        }

        let setterError = await setter(
            validated.target.url,
            item.contentTypeIdentifier
        )
        if let setterError {
            Logger.shared.log(
                "Default application change returned an error: \(setterError.localizedDescription)",
                level: .warning
            )
        }
        let resulting = currentApplication(
            for: item.contentTypeIdentifier
        )
        if resulting?.id != validated.target.id {
            if resulting?.id == validated.current.id {
                throw DefaultApplicationControlError.changeNotApplied
            }
            if await restore(
                validated.current,
                contentTypeIdentifier: item.contentTypeIdentifier
            ) {
                throw DefaultApplicationControlError.changeFailedRolledBack
            }
            throw DefaultApplicationControlError.changeFailedRollbackFailed
        }

        let record = DefaultApplicationControlRecord(
            contentTypeIdentifier: item.contentTypeIdentifier,
            displayName: item.displayName,
            filenameExtensions: item.filenameExtensions,
            previousApplication: validated.current,
            newApplication: validated.target,
            changedAt: changedAt
        )
        guard historyStore.append(record) else {
            if await restore(
                validated.current,
                contentTypeIdentifier: item.contentTypeIdentifier
            ) {
                throw DefaultApplicationControlError
                    .historySaveFailedRolledBack
            }
            throw DefaultApplicationControlError
                .historySaveFailedRollbackFailed
        }
        return DefaultApplicationControlOutcome(
            record: record,
            currentApplication: validated.target
        )
    }

    func undo(
        _ record: DefaultApplicationControlRecord,
        restoredAt: Date = Date()
    ) async throws -> DefaultApplicationUndoOutcome {
        guard historyStore.isLatestActive(record),
              record.schemaVersion == 1,
              record.restoredAt == nil,
              UTType(record.contentTypeIdentifier) != nil else {
            throw DefaultApplicationControlError.staleHistory
        }
        guard let current = currentApplication(
            for: record.contentTypeIdentifier
        ),
              current.id == normalizedPath(record.newApplicationPath),
              current.bundleIdentifier
                == record.newApplicationBundleIdentifier else {
            throw DefaultApplicationControlError.currentHandlerChanged
        }
        guard let previous = registeredCandidate(
            path: record.previousApplicationPath,
            bundleIdentifier: record.previousApplicationBundleIdentifier,
            contentTypeIdentifier: record.contentTypeIdentifier
        ) else {
            throw DefaultApplicationControlError.previousApplicationUnavailable
        }

        let setterError = await setter(
            previous.url,
            record.contentTypeIdentifier
        )
        if let setterError {
            Logger.shared.log(
                "Default application undo returned an error: \(setterError.localizedDescription)",
                level: .warning
            )
        }
        let resulting = currentApplication(
            for: record.contentTypeIdentifier
        )
        if resulting?.id != previous.id {
            if resulting?.id == current.id {
                throw DefaultApplicationControlError.undoNotApplied
            }
            if await restore(
                current,
                contentTypeIdentifier: record.contentTypeIdentifier
            ) {
                throw DefaultApplicationControlError.undoNotApplied
            }
            throw DefaultApplicationControlError.undoFailedRollbackFailed
        }

        let persisted = historyStore.markRestored(
            recordID: record.id,
            at: restoredAt
        )
        var updated = record
        updated.restoredAt = restoredAt
        return DefaultApplicationUndoOutcome(
            record: updated,
            currentApplication: previous,
            historyPersisted: persisted
        )
    }

    private func validate(
        item: DefaultApplicationItem,
        target requestedTarget: DefaultApplicationCandidate
    ) throws -> ValidatedChange {
        guard UTType(item.contentTypeIdentifier) != nil else {
            throw DefaultApplicationControlError.unsupportedContentType
        }
        guard let snapshot = snapshotProvider(item.contentTypeIdentifier),
              let currentURL = snapshot.defaultApplicationURL,
              let current = DefaultApplicationScanner.candidate(
                at: currentURL,
                fileManager: fileManager
              ) else {
            throw DefaultApplicationControlError.sourceChanged
        }
        guard current.id == item.currentApplication.id,
              current.bundleIdentifier
                == item.currentApplication.bundleIdentifier else {
            throw DefaultApplicationControlError.sourceChanged
        }
        guard let target = snapshot.candidateApplicationURLs
            .compactMap({
                DefaultApplicationScanner.candidate(
                    at: $0,
                    fileManager: fileManager
                )
            })
            .first(where: {
                $0.id == requestedTarget.id
                    && $0.bundleIdentifier
                        == requestedTarget.bundleIdentifier
            }) else {
            throw DefaultApplicationControlError.candidateUnavailable
        }
        return ValidatedChange(current: current, target: target)
    }

    private func currentApplication(
        for contentTypeIdentifier: String
    ) -> DefaultApplicationCandidate? {
        guard let url = snapshotProvider(
            contentTypeIdentifier
        )?.defaultApplicationURL else {
            return nil
        }
        return DefaultApplicationScanner.candidate(
            at: url,
            fileManager: fileManager
        )
    }

    private func registeredCandidate(
        path: String,
        bundleIdentifier: String,
        contentTypeIdentifier: String
    ) -> DefaultApplicationCandidate? {
        guard let snapshot = snapshotProvider(contentTypeIdentifier) else {
            return nil
        }
        let expectedPath = normalizedPath(path)
        return snapshot.candidateApplicationURLs
            .compactMap {
                DefaultApplicationScanner.candidate(
                    at: $0,
                    fileManager: fileManager
                )
            }
            .first {
                $0.id == expectedPath
                    && $0.bundleIdentifier == bundleIdentifier
            }
    }

    private func restore(
        _ application: DefaultApplicationCandidate,
        contentTypeIdentifier: String
    ) async -> Bool {
        guard DefaultApplicationScanner.candidate(
            at: application.url,
            fileManager: fileManager
        )?.bundleIdentifier == application.bundleIdentifier else {
            return false
        }
        _ = await setter(application.url, contentTypeIdentifier)
        return currentApplication(for: contentTypeIdentifier)?.id
            == application.id
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
