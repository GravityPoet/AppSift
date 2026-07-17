import CryptoKit
import Darwin
import Foundation

enum StartupItemControlAction: String, Codable, Hashable, Sendable {
    case disable
    case enable
}

struct StartupItemControlRecord: Codable, Identifiable, Hashable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let itemName: String
    let serviceIdentifier: String
    let itemPath: String
    let action: StartupItemControlAction
    let changedAt: Date
    let originalDisabled: Bool
    let originalLoaded: Bool
    let plistSHA256: String
    var restoredAt: Date?

    init(
        schemaVersion: Int = 1,
        id: UUID = UUID(),
        itemName: String,
        serviceIdentifier: String,
        itemPath: String,
        action: StartupItemControlAction,
        changedAt: Date = Date(),
        originalDisabled: Bool,
        originalLoaded: Bool,
        plistSHA256: String,
        restoredAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.itemName = itemName
        self.serviceIdentifier = serviceIdentifier
        self.itemPath = itemPath
        self.action = action
        self.changedAt = changedAt
        self.originalDisabled = originalDisabled
        self.originalLoaded = originalLoaded
        self.plistSHA256 = plistSHA256
        self.restoredAt = restoredAt
    }
}

struct StartupItemRuntimeState: Equatable, Sendable {
    let isDisabled: Bool
    let isLoaded: Bool
}

struct StartupItemControlOutcome: Sendable {
    let record: StartupItemControlRecord
    let resultingState: StartupItemRuntimeState
}

struct StartupItemUndoOutcome: Sendable {
    let record: StartupItemControlRecord
    let resultingState: StartupItemRuntimeState
    let historyPersisted: Bool
}

enum StartupItemControlError: LocalizedError, Equatable {
    case unsupportedItem
    case unsafePropertyList
    case identityChanged
    case unsafeServiceIdentifier
    case stateUnavailable
    case alreadyInRequestedState
    case commandFailedRolledBack
    case commandFailedRollbackFailed
    case historySaveFailedRolledBack
    case historySaveFailedRollbackFailed
    case staleHistory
    case propertyListChanged

    var errorDescription: String? {
        switch self {
        case .unsupportedItem:
            return String(localized: "Only current-user legacy LaunchAgents can be controlled safely.")
        case .unsafePropertyList:
            return String(localized: "The LaunchAgent property list is no longer safe to control.")
        case .identityChanged:
            return String(localized: "The LaunchAgent identity changed since it was scanned.")
        case .unsafeServiceIdentifier:
            return String(localized: "The LaunchAgent identifier contains unsupported characters.")
        case .stateUnavailable:
            return String(localized: "AppSift could not read the current launchd state.")
        case .alreadyInRequestedState:
            return String(localized: "This LaunchAgent is already in the requested state.")
        case .commandFailedRolledBack:
            return String(localized: "macOS could not complete the change, so AppSift restored the previous state.")
        case .commandFailedRollbackFailed:
            return String(localized: "macOS could not complete or fully roll back the change. Refresh Startup Items before trying again.")
        case .historySaveFailedRolledBack:
            return String(localized: "AppSift restored the previous state because its undo history could not be saved.")
        case .historySaveFailedRollbackFailed:
            return String(localized: "The change could not be recorded or fully rolled back. Refresh Startup Items before trying again.")
        case .staleHistory:
            return String(localized: "Undo newer changes for this LaunchAgent first.")
        case .propertyListChanged:
            return String(localized: "This LaunchAgent plist changed after the recorded action, so AppSift refused to restore an outdated state.")
        }
    }
}

enum StartupItemLaunchctlCommand: Equatable, Sendable {
    case printDisabled(domain: String)
    case printService(target: String)
    case disable(target: String)
    case enable(target: String)
    case bootout(target: String)
    case bootstrap(domain: String, propertyListPath: String)

    fileprivate var arguments: [String] {
        switch self {
        case let .printDisabled(domain):
            return ["print-disabled", domain]
        case let .printService(target):
            return ["print", target]
        case let .disable(target):
            return ["disable", target]
        case let .enable(target):
            return ["enable", target]
        case let .bootout(target):
            return ["bootout", target]
        case let .bootstrap(domain, propertyListPath):
            return ["bootstrap", domain, propertyListPath]
        }
    }
}

struct StartupItemCommandResult: Sendable {
    let exitCode: Int32?
    let output: Data
    let timedOut: Bool
    let truncated: Bool

    static let rejected = StartupItemCommandResult(
        exitCode: nil,
        output: Data(),
        timedOut: false,
        truncated: false
    )
}

final class StartupItemControlHistoryStore: @unchecked Sendable {
    static let shared = StartupItemControlHistoryStore()

    private static let maximumRecords = 100
    private static let maximumBytes = 512_000

    private let fileURL: URL
    private let allowedLaunchAgentsRoot: URL
    private let lock = NSLock()
    private var records: [StartupItemControlRecord]

    init(
        fileURL: URL = StartupItemControlHistoryStore.defaultFileURL,
        allowedLaunchAgentsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    ) {
        self.fileURL = fileURL
        self.allowedLaunchAgentsRoot = allowedLaunchAgentsRoot.standardizedFileURL
        self.records = Self.load(
            from: fileURL,
            allowedLaunchAgentsRoot: allowedLaunchAgentsRoot.standardizedFileURL
        )
    }

    func snapshot() -> [StartupItemControlRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func isLatestActive(_ record: StartupItemControlRecord) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return records.first {
            $0.itemPath == record.itemPath && $0.restoredAt == nil
        }?.id == record.id
    }

    @discardableResult
    func append(_ record: StartupItemControlRecord) -> Bool {
        guard Self.isValid(record, allowedLaunchAgentsRoot: allowedLaunchAgentsRoot) else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        guard !records.contains(where: { $0.id == record.id }) else { return false }
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
                  $0.itemPath == records[index].itemPath && $0.restoredAt == nil
              })?.id == recordID else {
            return false
        }
        records[index].restoredAt = date
        return persistLocked()
    }

    @discardableResult
    func removeAll() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !records.isEmpty || FileManager.default.fileExists(atPath: fileURL.path) else {
            return true
        }
        guard Self.isSafeHistoryContainer(fileURL.deletingLastPathComponent()),
              !Self.isSymbolicLink(fileURL) else {
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            records.removeAll()
            return true
        } catch {
            Logger.shared.log(
                "Could not clear startup-item control history: \(error.localizedDescription)",
                level: .warning
            )
            return false
        }
    }

    private func persistLocked() -> Bool {
        guard let data = try? JSONEncoder().encode(records),
              data.count <= Self.maximumBytes else {
            Logger.shared.log(
                "Startup-item control history exceeded its safety limit",
                level: .warning
            )
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard Self.isSafeHistoryContainer(fileURL.deletingLastPathComponent()),
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
                "Could not persist startup-item control history: \(error.localizedDescription)",
                level: .warning
            )
            return false
        }
    }

    private static func load(
        from fileURL: URL,
        allowedLaunchAgentsRoot: URL
    ) -> [StartupItemControlRecord] {
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
                [StartupItemControlRecord].self,
                from: data
              ),
              decoded.count <= maximumRecords,
              Set(decoded.map(\.id)).count == decoded.count,
              decoded.allSatisfy({
                  isValid($0, allowedLaunchAgentsRoot: allowedLaunchAgentsRoot)
              }) else {
            return []
        }
        return decoded.sorted { $0.changedAt > $1.changedAt }
    }

    private static func isValid(
        _ record: StartupItemControlRecord,
        allowedLaunchAgentsRoot: URL
    ) -> Bool {
        guard record.schemaVersion == 1,
              !record.itemName.isEmpty,
              record.itemName.count <= 512,
              record.itemName.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              StartupItemControlValidation.isSafeServiceIdentifier(
                record.serviceIdentifier
              ),
              record.itemPath.count <= 4_096,
              StartupItemControlValidation.isDirectChild(
                URL(fileURLWithPath: record.itemPath),
                of: allowedLaunchAgentsRoot
              ),
              record.plistSHA256.count == 64,
              record.plistSHA256.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
              }),
              record.changedAt.timeIntervalSinceReferenceDate.isFinite else {
            return false
        }
        if let restoredAt = record.restoredAt {
            return restoredAt.timeIntervalSinceReferenceDate.isFinite
                && restoredAt >= record.changedAt
        }
        return true
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
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
            .appendingPathComponent("startup-item-control-history.json")
    }
}

final class StartupItemController: @unchecked Sendable {
    typealias CommandRunner = @Sendable (StartupItemLaunchctlCommand) -> StartupItemCommandResult
    typealias StateProvider = @Sendable (String) throws -> StartupItemRuntimeState

    private struct ValidatedLaunchAgent {
        let url: URL
        let label: String
        let sha256: String
    }

    private struct FileSnapshot: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let owner: uid_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    private final class LimitedOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var truncated = false

        func append(_ chunk: Data, maximumBytes: Int) {
            lock.lock()
            defer { lock.unlock() }
            let remaining = max(0, maximumBytes - data.count)
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                truncated = true
            }
        }

        func snapshot() -> (Data, Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (data, truncated)
        }
    }

    private static let maximumPropertyListBytes: off_t = 1_000_000
    private static let maximumCommandOutputBytes = 1_000_000
    private static let commandTimeout: TimeInterval = 8

    private let allowedLaunchAgentsRoot: URL
    private let uid: uid_t
    private let historyStore: StartupItemControlHistoryStore
    private let commandRunner: CommandRunner
    private let stateProvider: StateProvider
    private let operationLock = NSLock()

    init(
        allowedLaunchAgentsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
        uid: uid_t = getuid(),
        historyStore: StartupItemControlHistoryStore = .shared,
        commandRunner: @escaping CommandRunner = { command in
            StartupItemController.runLaunchctl(command)
        },
        stateProvider: StateProvider? = nil
    ) {
        self.allowedLaunchAgentsRoot = allowedLaunchAgentsRoot.standardizedFileURL
        self.uid = uid
        self.historyStore = historyStore
        self.commandRunner = commandRunner
        if let stateProvider {
            self.stateProvider = stateProvider
        } else {
            self.stateProvider = { label in
                try StartupItemController.readRuntimeState(
                    label: label,
                    uid: uid,
                    commandRunner: commandRunner
                )
            }
        }
    }

    func canControl(_ item: StartupItem) -> Bool {
        guard item.kind == .launchAgent,
              item.scope == .user,
              item.isLegacy,
              !item.isMissing,
              item.state != .requiresApproval,
              item.evidence.contains(.launchdPropertyList),
              let itemURL = item.itemURL,
              StartupItemControlValidation.isSafeServiceIdentifier(
                item.displayIdentifier
              ) else {
            return false
        }
        return StartupItemControlValidation.isDirectChild(
            itemURL,
            of: allowedLaunchAgentsRoot
        )
    }

    func historySnapshot() -> [StartupItemControlRecord] {
        historyStore.snapshot()
    }

    func canUndo(_ record: StartupItemControlRecord) -> Bool {
        record.restoredAt == nil && historyStore.isLatestActive(record)
    }

    @discardableResult
    func clearHistory() -> Bool {
        historyStore.removeAll()
    }

    func perform(
        _ action: StartupItemControlAction,
        on item: StartupItem,
        changedAt: Date = Date()
    ) throws -> StartupItemControlOutcome {
        operationLock.lock()
        defer { operationLock.unlock() }

        let validated = try validate(item)
        let original = try state(for: validated.label)
        let desired = desiredState(for: action)
        guard original != desired else {
            throw StartupItemControlError.alreadyInRequestedState
        }

        do {
            try transition(
                label: validated.label,
                propertyListURL: validated.url,
                to: desired
            )
        } catch {
            if restore(
                label: validated.label,
                propertyListURL: validated.url,
                state: original
            ) {
                throw StartupItemControlError.commandFailedRolledBack
            }
            throw StartupItemControlError.commandFailedRollbackFailed
        }

        let record = StartupItemControlRecord(
            itemName: item.name,
            serviceIdentifier: validated.label,
            itemPath: validated.url.path,
            action: action,
            changedAt: changedAt,
            originalDisabled: original.isDisabled,
            originalLoaded: original.isLoaded,
            plistSHA256: validated.sha256
        )
        guard historyStore.append(record) else {
            if restore(
                label: validated.label,
                propertyListURL: validated.url,
                state: original
            ) {
                throw StartupItemControlError.historySaveFailedRolledBack
            }
            throw StartupItemControlError.historySaveFailedRollbackFailed
        }
        return StartupItemControlOutcome(
            record: record,
            resultingState: desired
        )
    }

    func undo(
        _ record: StartupItemControlRecord,
        restoredAt: Date = Date()
    ) throws -> StartupItemUndoOutcome {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard historyStore.isLatestActive(record) else {
            throw StartupItemControlError.staleHistory
        }
        let validated = try validate(record)
        let current = try state(for: validated.label)
        let desired = StartupItemRuntimeState(
            isDisabled: record.originalDisabled,
            isLoaded: record.originalLoaded
        )
        if current != desired {
            do {
                try transition(
                    label: validated.label,
                    propertyListURL: validated.url,
                    to: desired
                )
            } catch {
                if restore(
                    label: validated.label,
                    propertyListURL: validated.url,
                    state: current
                ) {
                    throw StartupItemControlError.commandFailedRolledBack
                }
                throw StartupItemControlError.commandFailedRollbackFailed
            }
        }

        let persisted = historyStore.markRestored(
            recordID: record.id,
            at: restoredAt
        )
        var updated = record
        updated.restoredAt = restoredAt
        return StartupItemUndoOutcome(
            record: updated,
            resultingState: desired,
            historyPersisted: persisted
        )
    }

    private func validate(_ item: StartupItem) throws -> ValidatedLaunchAgent {
        guard canControl(item), let url = item.itemURL else {
            throw StartupItemControlError.unsupportedItem
        }
        let validated = try readValidatedPropertyList(at: url)
        guard validated.label == item.displayIdentifier else {
            throw StartupItemControlError.identityChanged
        }
        return validated
    }

    private func validate(
        _ record: StartupItemControlRecord
    ) throws -> ValidatedLaunchAgent {
        guard record.schemaVersion == 1,
              record.restoredAt == nil,
              StartupItemControlValidation.isSafeServiceIdentifier(
                record.serviceIdentifier
              ),
              StartupItemControlValidation.isDirectChild(
                URL(fileURLWithPath: record.itemPath),
                of: allowedLaunchAgentsRoot
              ) else {
            throw StartupItemControlError.staleHistory
        }
        let validated = try readValidatedPropertyList(
            at: URL(fileURLWithPath: record.itemPath)
        )
        guard validated.label == record.serviceIdentifier else {
            throw StartupItemControlError.identityChanged
        }
        guard validated.sha256.caseInsensitiveCompare(record.plistSHA256) == .orderedSame else {
            throw StartupItemControlError.propertyListChanged
        }
        return validated
    }

    private func readValidatedPropertyList(
        at url: URL
    ) throws -> ValidatedLaunchAgent {
        guard url.isFileURL,
              url.pathExtension.caseInsensitiveCompare("plist") == .orderedSame,
              StartupItemControlValidation.isDirectChild(
                url,
                of: allowedLaunchAgentsRoot
              ) else {
            throw StartupItemControlError.unsafePropertyList
        }

        let rootPath = allowedLaunchAgentsRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let parentPath = url.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard let rootSnapshot = fileSnapshot(at: allowedLaunchAgentsRoot),
              rootSnapshot.owner == uid,
              (rootSnapshot.mode & S_IFMT) == S_IFDIR,
              (rootSnapshot.mode & (S_IWGRP | S_IWOTH)) == 0,
              rootPath == parentPath,
              let before = fileSnapshot(at: url),
              before.owner == uid,
              (before.mode & S_IFMT) == S_IFREG,
              (before.mode & (S_IWGRP | S_IWOTH)) == 0,
              before.size > 0,
              before.size <= Self.maximumPropertyListBytes,
              let data = try? Data(contentsOf: url),
              data.count == Int(before.size),
              data.count <= Int(Self.maximumPropertyListBytes),
              let after = fileSnapshot(at: url),
              before == after,
              let document = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let label = document["Label"] as? String else {
            throw StartupItemControlError.unsafePropertyList
        }
        guard StartupItemControlValidation.isSafeServiceIdentifier(label) else {
            throw StartupItemControlError.unsafeServiceIdentifier
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return ValidatedLaunchAgent(
            url: url.standardizedFileURL,
            label: label,
            sha256: digest
        )
    }

    private func fileSnapshot(at url: URL) -> FileSnapshot? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &info)
        }
        guard result == 0 else { return nil }
        return FileSnapshot(
            device: info.st_dev,
            inode: info.st_ino,
            mode: info.st_mode,
            owner: info.st_uid,
            size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec
        )
    }

    private func desiredState(
        for action: StartupItemControlAction
    ) -> StartupItemRuntimeState {
        switch action {
        case .disable:
            return StartupItemRuntimeState(isDisabled: true, isLoaded: false)
        case .enable:
            return StartupItemRuntimeState(isDisabled: false, isLoaded: true)
        }
    }

    private func state(for label: String) throws -> StartupItemRuntimeState {
        do {
            return try stateProvider(label)
        } catch {
            throw StartupItemControlError.stateUnavailable
        }
    }

    private func transition(
        label: String,
        propertyListURL: URL,
        to desired: StartupItemRuntimeState
    ) throws {
        applyCommands(
            label: label,
            propertyListURL: propertyListURL,
            state: desired
        )
        guard try state(for: label) == desired else {
            throw StartupItemControlError.commandFailedRolledBack
        }
    }

    private func restore(
        label: String,
        propertyListURL: URL,
        state desired: StartupItemRuntimeState
    ) -> Bool {
        applyCommands(
            label: label,
            propertyListURL: propertyListURL,
            state: desired
        )
        return (try? state(for: label)) == desired
    }

    private func applyCommands(
        label: String,
        propertyListURL: URL,
        state: StartupItemRuntimeState
    ) {
        let domain = "gui/\(uid)"
        let target = "\(domain)/\(label)"
        switch (state.isDisabled, state.isLoaded) {
        case (true, false):
            _ = commandRunner(.disable(target: target))
            _ = commandRunner(.bootout(target: target))
        case (false, true):
            _ = commandRunner(.enable(target: target))
            _ = commandRunner(.bootstrap(
                domain: domain,
                propertyListPath: propertyListURL.path
            ))
        case (false, false):
            _ = commandRunner(.enable(target: target))
            _ = commandRunner(.bootout(target: target))
        case (true, true):
            _ = commandRunner(.enable(target: target))
            _ = commandRunner(.bootstrap(
                domain: domain,
                propertyListPath: propertyListURL.path
            ))
            _ = commandRunner(.disable(target: target))
        }
    }

    private static func readRuntimeState(
        label: String,
        uid: uid_t,
        commandRunner: CommandRunner
    ) throws -> StartupItemRuntimeState {
        guard StartupItemControlValidation.isSafeServiceIdentifier(label) else {
            throw StartupItemControlError.unsafeServiceIdentifier
        }
        let domain = "gui/\(uid)"
        let target = "\(domain)/\(label)"
        let disabledResult = commandRunner(.printDisabled(domain: domain))
        guard disabledResult.exitCode == 0,
              !disabledResult.timedOut,
              !disabledResult.truncated,
              let output = String(data: disabledResult.output, encoding: .utf8) else {
            throw StartupItemControlError.stateUnavailable
        }
        let serviceResult = commandRunner(.printService(target: target))
        guard serviceResult.exitCode != nil,
              !serviceResult.timedOut else {
            throw StartupItemControlError.stateUnavailable
        }
        return StartupItemRuntimeState(
            isDisabled: disabledState(for: label, in: output),
            isLoaded: serviceResult.exitCode == 0
        )
    }

    static func disabledState(for label: String, in output: String) -> Bool {
        for line in output.components(separatedBy: .newlines) {
            guard let separator = line.range(of: "=>") else { continue }
            let rawIdentifier = line[..<separator.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard rawIdentifier == label else { continue }
            let rawState = line[separator.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return rawState == "disabled" || rawState == "true"
        }
        return false
    }

    static func runLaunchctl(
        _ command: StartupItemLaunchctlCommand
    ) -> StartupItemCommandResult {
        guard StartupItemControlValidation.isSafe(command) else {
            return .rejected
        }
        let executable = URL(fileURLWithPath: "/bin/launchctl")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .rejected
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let output = LimitedOutput()
        let readerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { break }
                output.append(chunk, maximumBytes: maximumCommandOutputBytes)
            }
            readerFinished.signal()
        }

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForWriting.closeFile()
            _ = readerFinished.wait(timeout: .now() + 1)
            return .rejected
        }

        var timedOut = false
        if terminated.wait(timeout: .now() + commandTimeout) == .timedOut {
            timedOut = true
            process.terminate()
            if terminated.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1)
            }
        }
        pipe.fileHandleForWriting.closeFile()
        _ = readerFinished.wait(timeout: .now() + 2)
        let snapshot = output.snapshot()
        return StartupItemCommandResult(
            exitCode: process.isRunning ? nil : process.terminationStatus,
            output: snapshot.0,
            timedOut: timedOut,
            truncated: snapshot.1
        )
    }
}

private enum StartupItemControlValidation {
    static func isSafeServiceIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 255,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        let forbidden = CharacterSet.controlCharacters.union(
            CharacterSet(charactersIn: "/\\\"")
        )
        return value.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }

    static func isDirectChild(_ url: URL, of root: URL) -> Bool {
        guard url.isFileURL else { return false }
        let standardizedURL = url.standardizedFileURL
        let standardizedRoot = root.standardizedFileURL
        return standardizedURL.deletingLastPathComponent().path == standardizedRoot.path
            && standardizedURL.lastPathComponent.count <= 255
            && standardizedURL.path.count <= 4_096
    }

    static func isSafe(_ command: StartupItemLaunchctlCommand) -> Bool {
        switch command {
        case let .printDisabled(domain):
            return isSafeDomain(domain)
        case let .printService(target),
             let .disable(target),
             let .enable(target),
             let .bootout(target):
            return isSafeTarget(target)
        case let .bootstrap(domain, propertyListPath):
            return isSafeDomain(domain)
                && propertyListPath.hasPrefix("/")
                && propertyListPath.count <= 4_096
                && !propertyListPath.contains("\0")
        }
    }

    private static func isSafeDomain(_ value: String) -> Bool {
        guard value.hasPrefix("gui/") else { return false }
        let suffix = value.dropFirst(4)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    private static func isSafeTarget(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == "gui",
              !components[1].isEmpty,
              components[1].allSatisfy(\.isNumber) else {
            return false
        }
        return isSafeServiceIdentifier(String(components[2]))
    }
}
