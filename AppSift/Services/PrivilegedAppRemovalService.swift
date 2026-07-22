import AppKit
import Darwin
import Foundation

enum AppFileRemovalFailureKind: String, Codable, Hashable, Sendable {
    case fullDiskAccessRequired
    case administratorAccessRequired
    case administratorAuthorizationCancelled
    case administratorAuthorizationFailed
    case batchTooLarge
    case unsafePath
    case destinationConflict
    case launchdControlFailed
    case transactionRolledBack
    case rollbackFailed
    case itemChanged
    case finderRejected
    case verificationFailed
}

struct AppFileRemovalFailure: Codable, Hashable, Sendable {
    let kind: AppFileRemovalFailureKind
    let detail: String?

    init(kind: AppFileRemovalFailureKind, detail: String? = nil) {
        self.kind = kind
        let normalized = detail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.detail = normalized.map { String($0.prefix(2_048)) }
    }

    var localizedDescription: String {
        switch kind {
        case .fullDiskAccessRequired:
            return String(localized: "Full Disk Access is required.")
        case .administratorAccessRequired:
            return String(localized: "Administrator access is required.")
        case .administratorAuthorizationCancelled:
            return String(localized: "Administrator authorization was cancelled; nothing in the protected batch was moved.")
        case .administratorAuthorizationFailed:
            return detail ?? String(localized: "Administrator authorization failed; nothing in the protected batch was moved.")
        case .batchTooLarge:
            return String(localized: "The selected batch is too large to authorize safely in one transaction. Select fewer top-level items and try again.")
        case .unsafePath:
            return String(localized: "The path changed after review or is outside AppSift’s removal boundary.")
        case .destinationConflict:
            return String(localized: "A file already occupies the planned Trash or restore location.")
        case .launchdControlFailed:
            return String(localized: "A background service could not be stopped or restored safely.")
        case .transactionRolledBack:
            return String(localized: "The operation failed and AppSift restored every item to its starting location.")
        case .rollbackFailed:
            return String(localized: "The operation failed and at least one item could not be rolled back automatically.")
        case .itemChanged:
            return String(localized: "The item changed after review, so AppSift left the batch untouched.")
        case .finderRejected:
            return detail ?? String(localized: "Finder could not move this item to Trash.")
        case .verificationFailed:
            return String(localized: "AppSift could not verify the item’s final location.")
        }
    }
}

struct PrivilegedAppRemovalFileMetadata: Equatable, Sendable {
    let ownerUserID: uid_t
    let deviceID: UInt64
    let isDirectory: Bool
    let isSymbolicLink: Bool
}

struct PrivilegedAppRemovalPlan: Equatable, Sendable {
    enum Operation: String, Equatable, Sendable {
        case trash
        case restore
    }

    struct Item: Equatable, Sendable {
        let originalURL: URL
        let sourceURL: URL
        let destinationURL: URL
        let restartLaunchdAfterRestore: Bool
    }

    let operation: Operation
    let currentUserID: uid_t
    let trashRoot: URL
    let allowedSourceRoots: [URL]
    let items: [Item]
}

enum PrivilegedAppRemovalExecution: Equatable, Sendable {
    case succeeded(loadedLaunchdItemIndexes: Set<Int>)
    case authorizationCancelled
    case failed(String)
    case rolledBack(String)
    case rollbackFailed(String)
}

struct PrivilegedAppRemovalService: Sendable {
    static let maximumItemCount = 1_024
    static let maximumCommandUTF8Bytes = 512 * 1_024
    private static let maximumPathUTF8Bytes = 4_096

    typealias FileExists = @Sendable (String) -> Bool
    typealias MetadataProvider = @Sendable (URL) -> PrivilegedAppRemovalFileMetadata?
    typealias ParentIsWritable = @Sendable (URL) -> Bool
    typealias AuthorizationRunner = @Sendable (
        PrivilegedAppRemovalPlan
    ) async -> PrivilegedAppRemovalExecution

    private struct PreparedTrashBatch: Sendable {
        let plan: PrivilegedAppRemovalPlan?
        let missing: [URL]
        let failures: [String: AppFileRemovalFailure]
        let requiresAdministratorAccess: Bool
    }

    private let trashRoot: URL
    private let allowedSourceRoots: [URL]
    private let currentUserID: uid_t
    private let fileExists: FileExists
    private let metadataProvider: MetadataProvider
    private let parentIsWritable: ParentIsWritable
    private let authorizationRunner: AuthorizationRunner
    private let destinationToken: @Sendable () -> String

    init(
        trashRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true),
        allowedSourceRoots: [URL] = PrivilegedAppRemovalService.defaultAllowedSourceRoots,
        currentUserID: uid_t = getuid(),
        fileExists: @escaping FileExists = {
            FileManager.default.fileExists(atPath: $0)
        },
        metadataProvider: @escaping MetadataProvider = {
            PrivilegedAppRemovalService.metadata($0)
        },
        parentIsWritable: @escaping ParentIsWritable = {
            access($0.path, W_OK) == 0
        },
        destinationToken: @escaping @Sendable () -> String = {
            let timestamp = PrivilegedAppRemovalService.destinationDateFormatter.string(from: Date())
            return "\(timestamp)-\(UUID().uuidString.prefix(8))"
        },
        authorizationRunner: @escaping AuthorizationRunner = {
            await PrivilegedAppRemovalAuthorizationRunner.run($0)
        }
    ) {
        self.trashRoot = Self.canonicalExistingURL(trashRoot)
            ?? trashRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.allowedSourceRoots = allowedSourceRoots.map {
            Self.canonicalExistingURL($0)
                ?? $0.standardizedFileURL.resolvingSymlinksInPath()
        }
        self.currentUserID = currentUserID
        self.fileExists = fileExists
        self.metadataProvider = metadataProvider
        self.parentIsWritable = parentIsWritable
        self.destinationToken = destinationToken
        self.authorizationRunner = authorizationRunner
    }

    func requiresAdministratorAccess(for urls: [URL]) -> Bool {
        prepareTrashBatch(urls).requiresAdministratorAccess
    }

    func shouldHandleTrash(_ urls: [URL]) -> Bool {
        let prepared = prepareTrashBatch(urls)
        return prepared.requiresAdministratorAccess || !prepared.failures.isEmpty
    }

    func requiresAdministratorAccessForRestore(
        _ items: [AppRemovalHistoryItem]
    ) -> Bool {
        guard items.count <= Self.maximumItemCount else { return true }
        return items.contains { item in
            guard let trashPath = item.trashPath else { return false }
            let source = URL(fileURLWithPath: trashPath).standardizedFileURL
            let destination = URL(fileURLWithPath: item.originalPath).standardizedFileURL
            guard fileExists(source.path) else { return false }
            return metadataProvider(source)?.ownerUserID != currentUserID
                || !parentIsWritable(destination.deletingLastPathComponent())
                || launchdDomain(for: destination) != nil
        }
    }

    func trash(_ urls: [URL]) async -> AppFileTrashResult {
        let prepared = prepareTrashBatch(urls)
        guard let plan = prepared.plan, !plan.items.isEmpty else {
            let failed = orderedUnique(urls).filter {
                prepared.failures[$0.standardizedFileURL.path] != nil
            }
            return AppFileTrashResult(
                trashed: [],
                missing: prepared.missing,
                needsFullDiskAccess: false,
                failed: failed,
                failureDetails: prepared.failures
            )
        }

        let execution = await authorizationRunner(plan)
        return trashResult(
            plan: plan,
            execution: execution,
            missing: prepared.missing,
            preflightFailures: prepared.failures
        )
    }

    func restore(
        _ items: [AppRemovalHistoryItem]
    ) async -> [UUID: AppRemovalRestorer.Outcome] {
        var outcomes: [UUID: AppRemovalRestorer.Outcome] = [:]
        var planItems: [PrivilegedAppRemovalPlan.Item] = []
        var historyItemsByDestination: [String: AppRemovalHistoryItem] = [:]

        guard items.count <= Self.maximumItemCount else {
            let message = AppFileRemovalFailure(kind: .batchTooLarge).localizedDescription
            for item in items { outcomes[item.id] = .failed(message) }
            return outcomes
        }

        guard isSafeTrashRoot else {
            for item in items { outcomes[item.id] = .blocked }
            return outcomes
        }

        for item in items {
            guard item.outcome == .movedToTrash,
                  item.restoredAt == nil,
                  let trashPath = item.trashPath else {
                outcomes[item.id] = .blocked
                continue
            }

            let source = URL(fileURLWithPath: trashPath).standardizedFileURL
            let requestedDestination = URL(fileURLWithPath: item.originalPath).standardizedFileURL
            guard isSupportedPath(source.path),
                  isSupportedPath(requestedDestination.path) else {
                outcomes[item.id] = .blocked
                continue
            }
            guard fileExists(source.path) else {
                outcomes[item.id] = .sourceMissing
                continue
            }
            guard !fileExists(requestedDestination.path) else {
                outcomes[item.id] = .destinationExists
                continue
            }
            guard let sourceMetadata = metadataProvider(source),
                  !sourceMetadata.isSymbolicLink,
                  isDirectChild(source, of: trashRoot),
                  let resolvedDestination = safeResolvedDestination(requestedDestination),
                  isInsideAllowedRoot(resolvedDestination),
                  sourceMetadata.deviceID == metadataProvider(trashRoot)?.deviceID,
                  sourceMetadata.deviceID
                    == metadataProvider(resolvedDestination.deletingLastPathComponent())?.deviceID else {
                outcomes[item.id] = .blocked
                continue
            }

            let planItem = PrivilegedAppRemovalPlan.Item(
                originalURL: requestedDestination,
                sourceURL: source,
                destinationURL: resolvedDestination,
                restartLaunchdAfterRestore: item.launchdWasLoaded == true
            )
            planItems.append(planItem)
            historyItemsByDestination[resolvedDestination.path] = item
        }

        guard !planItems.isEmpty else { return outcomes }
        guard !containsOverlappingPaths(planItems.map(\.destinationURL)) else {
            for item in planItems {
                if let historyItem = historyItemsByDestination[item.destinationURL.path] {
                    outcomes[historyItem.id] = .blocked
                }
            }
            return outcomes
        }

        let plan = PrivilegedAppRemovalPlan(
            operation: .restore,
            currentUserID: currentUserID,
            trashRoot: trashRoot,
            allowedSourceRoots: allowedSourceRoots,
            items: planItems
        )
        let execution = await authorizationRunner(plan)

        for planItem in plan.items {
            guard let historyItem = historyItemsByDestination[planItem.destinationURL.path] else {
                continue
            }
            if fileExists(planItem.destinationURL.path), !fileExists(planItem.sourceURL.path) {
                outcomes[historyItem.id] = .restored
                continue
            }
            switch execution {
            case .authorizationCancelled:
                outcomes[historyItem.id] = .authorizationCancelled
            case .rolledBack(let detail):
                outcomes[historyItem.id] = .failed(
                    AppFileRemovalFailure(
                        kind: .transactionRolledBack,
                        detail: detail
                    ).localizedDescription
                )
            case .rollbackFailed(let detail):
                outcomes[historyItem.id] = .failed(
                    AppFileRemovalFailure(
                        kind: .rollbackFailed,
                        detail: detail
                    ).localizedDescription
                )
            case .failed(let detail):
                outcomes[historyItem.id] = .failed(
                    AppFileRemovalFailure(
                        kind: .administratorAuthorizationFailed,
                        detail: detail
                    ).localizedDescription
                )
            case .succeeded:
                outcomes[historyItem.id] = .failed(
                    AppFileRemovalFailure(kind: .verificationFailed).localizedDescription
                )
            }
        }
        return outcomes
    }

    private func prepareTrashBatch(_ urls: [URL]) -> PreparedTrashBatch {
        let requested = orderedUnique(urls)
        guard !requested.isEmpty else {
            return PreparedTrashBatch(
                plan: nil,
                missing: [],
                failures: [:],
                requiresAdministratorAccess: false
            )
        }
        guard requested.count <= Self.maximumItemCount else {
            return failedPreflight(requested, kind: .batchTooLarge)
        }
        guard requested.allSatisfy({ isSupportedPath($0.path) }) else {
            return failedPreflight(requested, kind: .unsafePath)
        }
        guard isSafeTrashRoot, let trashMetadata = metadataProvider(trashRoot) else {
            return failedPreflight(requested, kind: .unsafePath)
        }

        var missing: [URL] = []
        var planItems: [PrivilegedAppRemovalPlan.Item] = []
        var failures: [String: AppFileRemovalFailure] = [:]
        var requiresAdministratorAccess = false
        var reservedDestinations = Set<String>()

        for original in requested {
            guard fileExists(original.path) else {
                missing.append(original)
                continue
            }
            guard let originalMetadata = metadataProvider(original),
                  !originalMetadata.isSymbolicLink else {
                failures[original.path] = AppFileRemovalFailure(kind: .unsafePath)
                continue
            }

            let source = Self.canonicalExistingURL(original)
                ?? original.resolvingSymlinksInPath().standardizedFileURL
            guard let sourceMetadata = metadataProvider(source),
                  !sourceMetadata.isSymbolicLink,
                  isInsideAllowedRoot(source),
                  !isProtectedHomePath(source),
                  sourceMetadata.deviceID == trashMetadata.deviceID,
                  safeResolvedDestination(source) != nil else {
                failures[original.path] = AppFileRemovalFailure(kind: .unsafePath)
                continue
            }

            let destination = uniqueTrashDestination(
                for: original,
                reserved: &reservedDestinations
            )
            planItems.append(
                PrivilegedAppRemovalPlan.Item(
                    originalURL: original,
                    sourceURL: source,
                    destinationURL: destination,
                    restartLaunchdAfterRestore: false
                )
            )
            if sourceMetadata.ownerUserID != currentUserID
                || !parentIsWritable(source.deletingLastPathComponent())
                || launchdDomain(for: source) != nil {
                requiresAdministratorAccess = true
            }
        }

        if !failures.isEmpty || containsOverlappingPaths(planItems.map(\.sourceURL)) {
            return failedPreflight(requested, missing: missing, kind: .unsafePath)
        }

        guard !planItems.isEmpty else {
            return PreparedTrashBatch(
                plan: nil,
                missing: missing,
                failures: failures,
                requiresAdministratorAccess: false
            )
        }
        return PreparedTrashBatch(
            plan: PrivilegedAppRemovalPlan(
                operation: .trash,
                currentUserID: currentUserID,
                trashRoot: trashRoot,
                allowedSourceRoots: allowedSourceRoots,
                items: planItems
            ),
            missing: missing,
            failures: failures,
            requiresAdministratorAccess: requiresAdministratorAccess
        )
    }

    private func failedPreflight(
        _ requested: [URL],
        missing: [URL] = [],
        kind: AppFileRemovalFailureKind
    ) -> PreparedTrashBatch {
        let missingPaths = Set(missing.map { $0.standardizedFileURL.path })
        var failures: [String: AppFileRemovalFailure] = [:]
        for url in requested {
            let standardized = url.standardizedFileURL
            guard !missingPaths.contains(standardized.path) else { continue }
            failures[standardized.path] = AppFileRemovalFailure(kind: kind)
        }
        return PreparedTrashBatch(
            plan: nil,
            missing: missing,
            failures: failures,
            requiresAdministratorAccess: false
        )
    }

    private func trashResult(
        plan: PrivilegedAppRemovalPlan,
        execution: PrivilegedAppRemovalExecution,
        missing: [URL],
        preflightFailures: [String: AppFileRemovalFailure]
    ) -> AppFileTrashResult {
        var trashed: [TrashedAppFile] = []
        var failed: [URL] = []
        var failureDetails = preflightFailures
        let loadedIndexes: Set<Int>
        let executionFailure: AppFileRemovalFailure?

        switch execution {
        case .succeeded(let indexes):
            loadedIndexes = indexes
            executionFailure = nil
        case .authorizationCancelled:
            loadedIndexes = []
            executionFailure = AppFileRemovalFailure(
                kind: .administratorAuthorizationCancelled
            )
        case .failed(let detail):
            loadedIndexes = []
            executionFailure = AppFileRemovalFailure(
                kind: .administratorAuthorizationFailed,
                detail: detail
            )
        case .rolledBack(let detail):
            loadedIndexes = []
            executionFailure = AppFileRemovalFailure(
                kind: .transactionRolledBack,
                detail: detail
            )
        case .rollbackFailed(let detail):
            loadedIndexes = []
            executionFailure = AppFileRemovalFailure(
                kind: .rollbackFailed,
                detail: detail
            )
        }

        for (index, item) in plan.items.enumerated() {
            if fileExists(item.destinationURL.path), !fileExists(item.sourceURL.path) {
                trashed.append(
                    TrashedAppFile(
                        originalURL: item.originalURL,
                        trashURL: item.destinationURL,
                        launchdWasLoaded: launchdDomain(for: item.sourceURL) == nil
                            ? nil
                            : loadedIndexes.contains(index)
                    )
                )
            } else {
                failed.append(item.originalURL)
                failureDetails[item.originalURL.path] = executionFailure
                    ?? AppFileRemovalFailure(kind: .verificationFailed)
            }
        }

        return AppFileTrashResult(
            trashed: trashed,
            missing: missing,
            needsFullDiskAccess: false,
            failed: failed,
            failureDetails: failureDetails
        )
    }

    private var isSafeTrashRoot: Bool {
        guard let metadata = metadataProvider(trashRoot),
              metadata.isDirectory,
              !metadata.isSymbolicLink,
              metadata.ownerUserID == currentUserID else {
            return false
        }
        let canonicalPath = Self.canonicalExistingURL(trashRoot)?.path
            ?? trashRoot.standardizedFileURL.resolvingSymlinksInPath().path
        return canonicalPath == trashRoot.path
    }

    private func safeResolvedDestination(_ url: URL) -> URL? {
        let parent = url.deletingLastPathComponent()
        guard let metadata = metadataProvider(parent),
              metadata.isDirectory,
              !metadata.isSymbolicLink else {
            return nil
        }
        let resolvedParent = Self.canonicalExistingURL(parent)
            ?? parent.resolvingSymlinksInPath().standardizedFileURL
        return resolvedParent.appendingPathComponent(url.lastPathComponent)
    }

    private func isInsideAllowedRoot(_ url: URL) -> Bool {
        let path = url.path
        return allowedSourceRoots.contains { root in
            path.hasPrefix(root.path + "/")
        }
    }

    private func isSupportedPath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && !path.utf8.contains(0)
            && path.utf8.count <= Self.maximumPathUTF8Bytes
    }

    private func isProtectedHomePath(_ url: URL) -> Bool {
        let path = url.path
        return highRiskHomeDotPaths.contains {
            let protected = URL(fileURLWithPath: $0).standardizedFileURL
            let protectedPath = Self.canonicalExistingURL(protected)?.path
                ?? protected.resolvingSymlinksInPath().path
            return path == protectedPath || path.hasPrefix(protectedPath + "/")
        }
    }

    private func isDirectChild(_ url: URL, of root: URL) -> Bool {
        url.deletingLastPathComponent().path == root.path
    }

    private func uniqueTrashDestination(
        for original: URL,
        reserved: inout Set<String>
    ) -> URL {
        let direct = trashRoot.appendingPathComponent(original.lastPathComponent)
        if !fileExists(direct.path), reserved.insert(direct.path).inserted {
            return direct
        }

        let pathExtension = original.pathExtension
        let stem = pathExtension.isEmpty
            ? original.lastPathComponent
            : original.deletingPathExtension().lastPathComponent
        var attempt = 0
        while true {
            attempt += 1
            let suffix = attempt == 1 ? destinationToken() : "\(destinationToken())-\(attempt)"
            let name = pathExtension.isEmpty
                ? "\(stem) AppSift \(suffix)"
                : "\(stem) AppSift \(suffix).\(pathExtension)"
            let candidate = trashRoot.appendingPathComponent(name)
            if !fileExists(candidate.path), reserved.insert(candidate.path).inserted {
                return candidate
            }
        }
    }

    private func containsOverlappingPaths(_ urls: [URL]) -> Bool {
        let paths = urls.map(\.path).sorted()
        for index in paths.indices.dropLast() {
            if paths[index + 1].hasPrefix(paths[index] + "/") {
                return true
            }
        }
        return false
    }

    private func orderedUnique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            return seen.insert(standardized.path).inserted ? standardized : nil
        }
    }

    private func launchdDomain(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/Library/LaunchDaemons/") && path.hasSuffix(".plist") {
            return "system"
        }
        let homePath = trashRoot.deletingLastPathComponent().path
        if (path.hasPrefix("/Library/LaunchAgents/")
            || path.hasPrefix(homePath + "/Library/LaunchAgents/"))
            && path.hasSuffix(".plist") {
            return "gui/\(currentUserID)"
        }
        return nil
    }

    private static func metadata(_ url: URL) -> PrivilegedAppRemovalFileMetadata? {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return nil }
        let kind = information.st_mode & S_IFMT
        return PrivilegedAppRemovalFileMetadata(
            ownerUserID: information.st_uid,
            deviceID: UInt64(information.st_dev),
            isDirectory: kind == S_IFDIR,
            isSymbolicLink: kind == S_IFLNK
        )
    }

    private static func canonicalExistingURL(_ url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        return path.withCString { source in
            guard let resolved = Darwin.realpath(source, nil) else { return nil }
            defer { Darwin.free(resolved) }
            return URL(
                fileURLWithPath: String(cString: resolved),
                isDirectory: url.hasDirectoryPath
            )
        }
    }

    private static let destinationDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    private static let defaultAllowedSourceRoots: [URL] = {
        Array(Set(Locations().appSearch.paths.filter { !$0.isEmpty })).sorted().map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }()
}

enum PrivilegedAppRemovalAuthorizationRunner {
    static func run(
        _ plan: PrivilegedAppRemovalPlan
    ) async -> PrivilegedAppRemovalExecution {
        let command = PrivilegedAppRemovalCommandBuilder.command(for: plan)
        guard command.utf8.count <= PrivilegedAppRemovalService.maximumCommandUTF8Bytes else {
            return .failed(
                AppFileRemovalFailure(kind: .batchTooLarge).localizedDescription
            )
        }
        let source = "do shell script \(appleScriptLiteral(command)) with administrator privileges"
        let response: (descriptor: NSAppleEventDescriptor?, error: NSDictionary?) =
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let script = NSAppleScript(source: source)
                    var errorInfo: NSDictionary?
                    let descriptor = script?.executeAndReturnError(&errorInfo)
                    continuation.resume(returning: (descriptor, errorInfo))
                }
            }

        if response.error?[NSAppleScript.errorNumber] as? Int == -128 {
            return .authorizationCancelled
        }
        if let error = response.error {
            let rawDetail = error[NSAppleScript.errorMessage] as? String
            let detail = rawDetail?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(512)
            return .failed(detail.map(String.init) ?? "Administrator authorization failed.")
        }

        let output = response.descriptor?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if output.hasPrefix("APPSIFT_OK|") {
            let rawIndexes = output.dropFirst("APPSIFT_OK|".count)
            let indexes = Set(rawIndexes.split(separator: ",").compactMap { Int($0) })
            return .succeeded(loadedLaunchdItemIndexes: indexes)
        }
        if output.hasPrefix("APPSIFT_ROLLED_BACK|") {
            return .rolledBack(String(output.dropFirst("APPSIFT_ROLLED_BACK|".count)))
        }
        if output.hasPrefix("APPSIFT_ROLLBACK_FAILED|") {
            return .rollbackFailed(String(output.dropFirst("APPSIFT_ROLLBACK_FAILED|".count)))
        }
        return .failed("The administrator operation returned an invalid verification result.")
    }

    static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

enum PrivilegedAppRemovalCommandBuilder {
    static func command(
        for plan: PrivilegedAppRemovalPlan,
        requireEffectiveRoot: Bool = true
    ) -> String {
        var arguments = [
            requireEffectiveRoot ? "1" : "0",
            String(plan.currentUserID),
            plan.trashRoot.path,
            String(plan.allowedSourceRoots.count),
        ]
        arguments.append(contentsOf: plan.allowedSourceRoots.map(\.path))
        arguments.append(plan.operation.rawValue)
        arguments.append(String(plan.items.count))
        for item in plan.items {
            arguments.append(item.sourceURL.path)
            arguments.append(item.destinationURL.path)
            arguments.append(item.restartLaunchdAfterRestore ? "1" : "0")
        }

        let quotedScript = shellSingleQuoted(transactionScript)
        let quotedArguments = arguments.map(shellSingleQuoted).joined(separator: " ")
        return "/bin/bash -c \(quotedScript) appsift \(quotedArguments)"
    }

    private static let transactionScript = #"""
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
require_root=$1
shift
expected_uid=$1
shift
trash=$1
shift
root_count=$1
shift
allowed_roots=()
for ((i=0; i<root_count; i++)); do
    allowed_roots+=("$1")
    shift
done
operation=$1
shift
item_count=$1
shift
sources=()
destinations=()
restart_flags=()
for ((i=0; i<item_count; i++)); do
    sources+=("$1")
    destinations+=("$2")
    restart_flags+=("$3")
    shift 3
done

moved_indices=()
stopped_indices=()
started_indices=()
job_domains=()
job_labels=()
rollback_failed=0

emit_failure() {
    local code=$1
    trap - EXIT HUP INT TERM
    if [ "$rollback_failed" -eq 0 ]; then
        /usr/bin/printf 'APPSIFT_ROLLED_BACK|%s\n' "$code"
    else
        /usr/bin/printf 'APPSIFT_ROLLBACK_FAILED|%s\n' "$code"
    fi
    exit 0
}

exact_move() {
    /usr/bin/osascript -l JavaScript -e 'ObjC.import("Foundation"); function run(argv) { var error = Ref(); var ok = $.NSFileManager.defaultManager.moveItemAtPathToPathError($(argv[0]), $(argv[1]), error); if (!ok) { throw new Error("move failed"); } }' "$1" "$2" >/dev/null 2>&1
}

bootout_started_jobs() {
    local position index domain destination
    for ((position=${#started_indices[@]}-1; position>=0; position--)); do
        index=${started_indices[$position]}
        domain=${job_domains[$index]}
        destination=${destinations[$index]}
        /bin/launchctl bootout "$domain" "$destination" >/dev/null 2>&1 || rollback_failed=1
    done
}

rollback_moves() {
    local position index source destination
    for ((position=${#moved_indices[@]}-1; position>=0; position--)); do
        index=${moved_indices[$position]}
        source=${sources[$index]}
        destination=${destinations[$index]}
        if [ -e "$destination" ] && [ ! -e "$source" ]; then
            exact_move "$destination" "$source" || rollback_failed=1
        elif [ ! -e "$source" ]; then
            rollback_failed=1
        fi
    done
}

restart_stopped_jobs() {
    local index domain source label
    if [ "${#stopped_indices[@]}" -eq 0 ]; then
        return
    fi
    for index in "${stopped_indices[@]}"; do
        domain=${job_domains[$index]}
        source=${sources[$index]}
        label=${job_labels[$index]}
        if ! /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
            /bin/launchctl bootstrap "$domain" "$source" >/dev/null 2>&1 || rollback_failed=1
        fi
    done
}

rollback_all() {
    if [ "$operation" = "restore" ]; then
        bootout_started_jobs
    fi
    rollback_moves
    if [ "$operation" = "trash" ]; then
        restart_stopped_jobs
    fi
}

interrupted() {
    trap - EXIT HUP INT TERM
    rollback_all
    emit_failure interrupted
}

unexpected_exit() {
    trap - EXIT HUP INT TERM
    rollback_all
    emit_failure unexpected-shell-exit
}
trap interrupted HUP INT TERM
trap unexpected_exit EXIT

case "$operation" in
    trash|restore) ;;
    *) emit_failure operation ;;
esac
if [ "$require_root" = "1" ] && [ "$(/usr/bin/id -u)" != "0" ]; then
    emit_failure authorization
fi
if [ ! -d "$trash" ] || [ -L "$trash" ]; then
    emit_failure trash
fi
if [ "$(/usr/bin/stat -f '%u' "$trash" 2>/dev/null)" != "$expected_uid" ]; then
    emit_failure trash-owner
fi
trash_mode=$(/usr/bin/stat -f '%Lp' "$trash" 2>/dev/null) || emit_failure trash-mode
case "$trash_mode" in
    *00) ;;
    *) emit_failure trash-mode ;;
esac
canonical_trash=$(cd "$trash" 2>/dev/null && /bin/pwd -P) || emit_failure trash-path
if [ "$canonical_trash" != "$trash" ]; then
    emit_failure trash-path
fi
trash_device=$(/usr/bin/stat -f '%d' "$trash" 2>/dev/null) || emit_failure trash-device

home=${trash%/.Trash}
for ((i=0; i<item_count; i++)); do
    source=${sources[$i]}
    destination=${destinations[$i]}
    if [ ! -e "$source" ] || [ -L "$source" ]; then
        emit_failure source-changed
    fi
    source_parent=${source%/*}
    source_name=${source##*/}
    [ -n "$source_parent" ] || source_parent=/
    canonical_parent=$(cd "$source_parent" 2>/dev/null && /bin/pwd -P) || emit_failure source-parent
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        emit_failure destination
    fi
    source_device=$(/usr/bin/stat -f '%d' "$source" 2>/dev/null) || emit_failure source-device
    if [ "$source_device" != "$trash_device" ]; then
        emit_failure cross-device
    fi

    allowed=0
    if [ "$operation" = "trash" ]; then
        if [ "$canonical_parent/$source_name" != "$source" ]; then
            emit_failure source-parent
        fi
        for root in "${allowed_roots[@]}"; do
            case "$source" in
                "$root"/*) allowed=1; break ;;
            esac
        done
        if [ "$allowed" -ne 1 ]; then
            emit_failure source-boundary
        fi
        destination_parent=${destination%/*}
        if [ "$destination_parent" != "$trash" ]; then
            emit_failure destination
        fi
    else
        if [ "$canonical_parent" != "$canonical_trash" ] \
            || [ "$canonical_parent/$source_name" != "$source" ]; then
            emit_failure source-boundary
        fi
        destination_parent=${destination%/*}
        destination_name=${destination##*/}
        [ -n "$destination_parent" ] || destination_parent=/
        canonical_destination_parent=$(cd "$destination_parent" 2>/dev/null && /bin/pwd -P) \
            || emit_failure destination
        if [ "$canonical_destination_parent/$destination_name" != "$destination" ]; then
            emit_failure destination
        fi
        for root in "${allowed_roots[@]}"; do
            case "$destination" in
                "$root"/*) allowed=1; break ;;
            esac
        done
        if [ "$allowed" -ne 1 ]; then
            emit_failure destination-boundary
        fi
        destination_device=$(/usr/bin/stat -f '%d' "$destination_parent" 2>/dev/null) \
            || emit_failure destination-device
        if [ "$destination_device" != "$trash_device" ]; then
            emit_failure cross-device
        fi
    fi

    job_path=$source
    if [ "$operation" = "restore" ]; then
        job_path=$destination
    fi
    domain=
    case "$job_path" in
        /Library/LaunchDaemons/*.plist) domain=system ;;
        /Library/LaunchAgents/*.plist|"$home"/Library/LaunchAgents/*.plist) domain="gui/$expected_uid" ;;
    esac
    job_domains[$i]=$domain
    job_labels[$i]=
    if [ -n "$domain" ]; then
        label=$(/usr/bin/plutil -extract Label raw -o - "$source" 2>/dev/null) || emit_failure launchd-label
        case "$label" in
            ''|*$'\n'*|*$'\r'*) emit_failure launchd-label ;;
        esac
        job_labels[$i]=$label
    fi
done

if [ "$operation" = "trash" ]; then
    for ((i=0; i<item_count; i++)); do
        domain=${job_domains[$i]}
        label=${job_labels[$i]}
        if [ -n "$domain" ] && /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
            if ! /bin/launchctl bootout "$domain" "${sources[$i]}" >/dev/null 2>&1; then
                rollback_all
                emit_failure launchd-stop
            fi
            stopped_indices+=("$i")
            for attempt in 1 2 3 4 5 6 7 8 9 10; do
                /bin/launchctl print "$domain/$label" >/dev/null 2>&1 || break
                /bin/sleep 0.1
            done
            if /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
                rollback_all
                emit_failure launchd-stop
            fi
        fi
    done
fi

for ((i=0; i<item_count; i++)); do
    if ! exact_move "${sources[$i]}" "${destinations[$i]}"; then
        rollback_all
        emit_failure move
    fi
    moved_indices+=("$i")
    if [ -e "${sources[$i]}" ] || [ ! -e "${destinations[$i]}" ]; then
        rollback_all
        emit_failure verify-move
    fi
done

if [ "$operation" = "restore" ]; then
    for ((i=0; i<item_count; i++)); do
        if [ "${restart_flags[$i]}" = "1" ]; then
            domain=${job_domains[$i]}
            label=${job_labels[$i]}
            if [ -z "$domain" ] || [ -z "$label" ]; then
                rollback_all
                emit_failure launchd-restore
            fi
            if ! /bin/launchctl bootstrap "$domain" "${destinations[$i]}" >/dev/null 2>&1; then
                rollback_all
                emit_failure launchd-restore
            fi
            started_indices+=("$i")
            if ! /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
                rollback_all
                emit_failure launchd-restore
            fi
        fi
    done
fi

loaded=
if [ "$operation" = "trash" ] && [ "${#stopped_indices[@]}" -gt 0 ]; then
    loaded=$(IFS=,; /usr/bin/printf '%s' "${stopped_indices[*]}")
fi
trap - EXIT HUP INT TERM
/usr/bin/printf 'APPSIFT_OK|%s\n' "$loaded"
"""#

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
