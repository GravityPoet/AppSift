import Foundation
import ServiceManagement
import Darwin

enum StartupItemKind: String, CaseIterable, Hashable, Sendable {
    case loginItem
    case backgroundItem
    case launchAgent
    case launchDaemon
}

enum StartupItemState: String, CaseIterable, Hashable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case unknown
}

enum StartupItemScope: String, Hashable, Sendable {
    case user
    case system
}

enum StartupItemEvidence: String, Hashable, Sendable {
    case backgroundTaskManagement
    case launchdPropertyList
    case appleAttribution
}

struct StartupItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let developerName: String?
    let teamIdentifier: String?
    let serviceIdentifier: String
    let kind: StartupItemKind
    let state: StartupItemState
    let scope: StartupItemScope
    let itemURL: URL?
    let executableURL: URL?
    let associatedBundleIdentifiers: [String]
    let evidence: Set<StartupItemEvidence>
    let isLegacy: Bool
    let isMissing: Bool

    var displayIdentifier: String {
        let components = serviceIdentifier.split(separator: ".", maxSplits: 1)
        if components.count == 2,
           components[0].allSatisfy(\.isNumber) {
            return String(components[1])
        }
        return serviceIdentifier
    }

    var revealURL: URL? {
        if let itemURL, itemURL.isFileURL {
            return itemURL
        }
        return executableURL
    }

    func replacingState(_ state: StartupItemState) -> StartupItem {
        StartupItem(
            id: id,
            name: name,
            developerName: developerName,
            teamIdentifier: teamIdentifier,
            serviceIdentifier: serviceIdentifier,
            kind: kind,
            state: state,
            scope: scope,
            itemURL: itemURL,
            executableURL: executableURL,
            associatedBundleIdentifiers: associatedBundleIdentifiers,
            evidence: evidence,
            isLegacy: isLegacy,
            isMissing: isMissing
        )
    }
}

struct StartupItemScanResult: Sendable {
    let items: [StartupItem]
    let backgroundTaskDataAvailable: Bool
    let backgroundTaskDataTruncated: Bool
}

enum StartupItemScanner {
    struct BackgroundTaskDump: Sendable {
        let output: String?
        let incomplete: Bool

        init(output: String?, incomplete: Bool = false) {
            self.output = output
            self.incomplete = incomplete
        }
    }

    typealias BackgroundTaskOutputProvider = @Sendable () -> BackgroundTaskDump
    typealias LegacyStatusProvider = @Sendable (URL) -> StartupItemState?

    struct LaunchdRoot: Hashable, Sendable {
        let url: URL
        let kind: StartupItemKind
        let scope: StartupItemScope
    }

    private struct RawBackgroundRecord {
        var fields: [String: String] = [:]
    }

    private struct AppleAttribution {
        let name: String?
        let teamIdentifier: String?
        let associatedBundleIdentifiers: [String]
        let programPath: String?
    }

    private final class ProcessOutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        private var truncated = false

        func append(_ data: Data, limit: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard !data.isEmpty else { return }
            let remaining = max(0, limit - storage.count)
            if remaining > 0 {
                storage.append(data.prefix(remaining))
            }
            if data.count > remaining {
                truncated = true
            }
        }

        func snapshot() -> (data: Data, truncated: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (storage, truncated)
        }
    }

    private static let maximumBackgroundTaskOutputBytes = 8_000_000
    private static let maximumLaunchdPlistBytes = 1_000_000
    private static let maximumLaunchdItemsPerRoot = 2_000
    private static let backgroundTaskTimeout: TimeInterval = 35

    static var defaultLaunchdRoots: [LaunchdRoot] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            LaunchdRoot(
                url: home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
                kind: .launchAgent,
                scope: .user
            ),
            LaunchdRoot(
                url: URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
                kind: .launchAgent,
                scope: .system
            ),
            LaunchdRoot(
                url: URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
                kind: .launchDaemon,
                scope: .system
            ),
        ]
    }

    static var defaultAttributionURL: URL {
        URL(
            fileURLWithPath: "/System/Library/PrivateFrameworks/BackgroundTaskManagement.framework/Versions/A/Resources/attributions.plist"
        )
    }

    static func scan(
        fileManager: FileManager = .default,
        backgroundTaskOutputProvider: BackgroundTaskOutputProvider = {
            runBackgroundTaskDump()
        },
        launchdRoots: [LaunchdRoot] = defaultLaunchdRoots,
        attributionURL: URL = defaultAttributionURL,
        legacyStatusProvider: LegacyStatusProvider = { url in
            defaultLegacyStatus(for: url)
        }
    ) -> StartupItemScanResult {
        let dump = backgroundTaskOutputProvider()
        let outputData = dump.output?.data(using: .utf8)
        let outputWithinLimit = outputData.map {
            !$0.isEmpty && $0.count <= maximumBackgroundTaskOutputBytes
        } == true
        let backgroundItems = outputWithinLimit
            ? parseBackgroundTaskOutput(dump.output ?? "", fileManager: fileManager)
            : []

        let attributions = loadAttributions(
            from: attributionURL,
            fileManager: fileManager
        )
        let launchdItems = scanLaunchdPropertyLists(
            roots: launchdRoots,
            attributions: attributions,
            fileManager: fileManager,
            legacyStatusProvider: legacyStatusProvider
        )
        let merged = merge(backgroundItems: backgroundItems, launchdItems: launchdItems)
            .sorted {
                if $0.kind != $1.kind {
                    return kindSortOrder($0.kind) < kindSortOrder($1.kind)
                }
                let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
                if comparison == .orderedSame {
                    return $0.displayIdentifier < $1.displayIdentifier
                }
                return comparison == .orderedAscending
            }

        return StartupItemScanResult(
            items: merged,
            backgroundTaskDataAvailable: outputWithinLimit,
            backgroundTaskDataTruncated: dump.incomplete || outputData.map {
                $0.count > maximumBackgroundTaskOutputBytes
            } == true
        )
    }

    static func parseBackgroundTaskOutput(
        _ output: String,
        fileManager: FileManager = .default
    ) -> [StartupItem] {
        var records: [RawBackgroundRecord] = []
        var current: RawBackgroundRecord?

        func flushCurrent() {
            if let current, !current.fields.isEmpty {
                records.append(current)
            }
            current = nil
        }

        for line in output.components(separatedBy: .newlines) {
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if leadingSpaces <= 1,
               trimmed.hasPrefix("#"),
               trimmed.hasSuffix(":"),
               trimmed.dropFirst().dropLast().allSatisfy(\.isNumber) {
                flushCurrent()
                current = RawBackgroundRecord()
                continue
            }
            guard current != nil,
                  let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            current?.fields[key] = value
        }
        flushCurrent()

        let recordsByIdentifier = Dictionary(
            records.compactMap { record -> (String, RawBackgroundRecord)? in
                guard let identifier = bounded(record.fields["Identifier"], maximum: 2_048) else {
                    return nil
                }
                return (identifier, record)
            },
            uniquingKeysWith: { existing, _ in existing }
        )

        return records.compactMap { record in
            item(
                from: record,
                parentRecords: recordsByIdentifier,
                fileManager: fileManager
            )
        }
    }

    static func runBackgroundTaskDump() -> BackgroundTaskDump {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sfltool")
        process.arguments = ["dumpbtm"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let outputBox = ProcessOutputBox()
        let readerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let handle = pipe.fileHandleForReading
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                // Continue draining after reaching the cap so the child cannot
                // block on a full pipe, but never retain more than 8 MB.
                outputBox.append(data, limit: maximumBackgroundTaskOutputBytes)
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
            return BackgroundTaskDump(output: nil)
        }

        var timedOut = false
        if terminated.wait(timeout: .now() + backgroundTaskTimeout) == .timedOut {
            timedOut = true
            process.terminate()
            if terminated.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1)
            }
        }
        pipe.fileHandleForWriting.closeFile()
        guard readerFinished.wait(timeout: .now() + 2) == .success else {
            return BackgroundTaskDump(output: nil, incomplete: true)
        }
        let snapshot = outputBox.snapshot()
        guard !timedOut,
              !snapshot.truncated,
              process.terminationStatus == 0,
              !snapshot.data.isEmpty,
              let output = String(data: snapshot.data, encoding: .utf8) else {
            return BackgroundTaskDump(
                output: nil,
                incomplete: timedOut || snapshot.truncated
            )
        }
        return BackgroundTaskDump(output: output)
    }

    static func defaultLegacyStatus(for url: URL) -> StartupItemState? {
        guard #available(macOS 13.0, *) else { return nil }
        switch SMAppService.statusForLegacyPlist(at: url) {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .disabled
        case .notFound:
            return nil
        @unknown default:
            return nil
        }
    }

    private static func item(
        from record: RawBackgroundRecord,
        parentRecords: [String: RawBackgroundRecord],
        fileManager: FileManager
    ) -> StartupItem? {
        guard let rawType = bounded(record.fields["Type"], maximum: 256),
              !rawType.lowercased().hasPrefix("developer"),
              let kind = kind(from: rawType),
              let identifier = bounded(record.fields["Identifier"], maximum: 2_048)
        else { return nil }

        let parentIdentifier = bounded(record.fields["Parent Identifier"], maximum: 2_048)
        let parent = parentIdentifier.flatMap { parentRecords[$0] }
        let rawURL = bounded(record.fields["URL"], maximum: 8_192)
        let parentURL = fileURL(from: parent?.fields["URL"])
        let itemURL = resolveItemURL(rawURL, parentURL: parentURL)
        let executableURL = fileURL(from: record.fields["Executable Path"])
        let associatedBundleIdentifiers = parseList(record.fields["Assoc. Bundle IDs"])
            + parseList(record.fields["Bundle Identifier"])
            + parseList(parent?.fields["Bundle Identifier"])
        let uniqueBundleIdentifiers = Array(
            Set(associatedBundleIdentifiers.filter { !$0.isEmpty })
        ).sorted()
        let developerName = meaningful(
            record.fields["Developer Name"],
            fallback: parent?.fields["Developer Name"]
        )
        let teamIdentifier = meaningful(
            record.fields["Team Identifier"],
            fallback: parent?.fields["Team Identifier"]
        )
        let parentName = meaningful(parent?.fields["Name"], fallback: nil)
        let recordName = meaningful(record.fields["Name"], fallback: nil)
        let name = preferredName(recordName, parentName: parentName, identifier: identifier)
        let state = state(fromDisposition: record.fields["Disposition"])
        let scope = scopeFor(itemURL: itemURL, executableURL: executableURL)
        let missing = isMissing(
            itemURL: itemURL,
            executableURL: executableURL,
            fileManager: fileManager
        )

        return StartupItem(
            id: "btm|\(identifier)|\(itemURL?.path ?? executableURL?.path ?? name)",
            name: name,
            developerName: developerName,
            teamIdentifier: teamIdentifier,
            serviceIdentifier: identifier,
            kind: kind,
            state: state,
            scope: scope,
            itemURL: itemURL,
            executableURL: executableURL,
            associatedBundleIdentifiers: uniqueBundleIdentifiers,
            evidence: [.backgroundTaskManagement],
            isLegacy: rawType.lowercased().contains("legacy"),
            isMissing: missing
        )
    }

    private static func scanLaunchdPropertyLists(
        roots: [LaunchdRoot],
        attributions: [String: AppleAttribution],
        fileManager: FileManager,
        legacyStatusProvider: LegacyStatusProvider
    ) -> [StartupItem] {
        var items: [StartupItem] = []
        for root in roots {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: root.url,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in urls
                .filter({ $0.pathExtension.caseInsensitiveCompare("plist") == .orderedSame })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                .prefix(maximumLaunchdItemsPerRoot) {
                guard let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size > 0,
                  size <= maximumLaunchdPlistBytes,
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  data.count <= maximumLaunchdPlistBytes,
                  let plist = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ) as? [String: Any] else { continue }

                let label = bounded(plist["Label"] as? String, maximum: 2_048)
                    ?? url.deletingPathExtension().lastPathComponent
                let attribution = attributions[label]
                let program = bounded(plist["Program"] as? String, maximum: 8_192)
                    ?? (plist["ProgramArguments"] as? [String])?.first
                    ?? attribution?.programPath
                let executableURL = fileURL(from: program)
                let state = legacyStatusProvider(url)
                    ?? ((plist["Disabled"] as? Bool) == true ? .disabled : .unknown)
                var evidence: Set<StartupItemEvidence> = [.launchdPropertyList]
                if attribution != nil {
                    evidence.insert(.appleAttribution)
                }
                let name = attribution?.name ?? label
                let missing = isMissing(
                    itemURL: url,
                    executableURL: executableURL,
                    fileManager: fileManager
                )
                items.append(
                    StartupItem(
                        id: "launchd|\(url.standardizedFileURL.path)",
                        name: name,
                        // Apple's attribution file identifies the owning app,
                        // not necessarily a legal developer name. Do not
                        // relabel that value as publisher evidence.
                        developerName: nil,
                        teamIdentifier: attribution?.teamIdentifier,
                        serviceIdentifier: label,
                        kind: root.kind,
                        state: state,
                        scope: root.scope,
                        itemURL: url.standardizedFileURL,
                        executableURL: executableURL,
                        associatedBundleIdentifiers: attribution?.associatedBundleIdentifiers ?? [],
                        evidence: evidence,
                        isLegacy: true,
                        isMissing: missing
                    )
                )
            }
        }
        return items
    }

    private static func loadAttributions(
        from url: URL,
        fileManager: FileManager
    ) -> [String: AppleAttribution] {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= maximumLaunchdPlistBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let document = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: [String: Any]] else { return [:] }

        return document.reduce(into: [:]) { result, entry in
            let key = entry.key
            let value = entry.value
            guard !key.isEmpty, key.count <= 2_048 else { return }
            let name = bounded(value["Attribution"] as? String, maximum: 512)
            let associated = (value["AssociatedBundleIdentifiers"] as? [String] ?? [])
                .filter { !$0.isEmpty && $0.count <= 2_048 }
            let program = bounded(value["Program"] as? String, maximum: 8_192)
                ?? (value["ProgramArguments"] as? [String])?.first
            result[key] = AppleAttribution(
                name: name,
                teamIdentifier: bounded(value["TeamIdentifier"] as? String, maximum: 1_024),
                associatedBundleIdentifiers: associated,
                programPath: bounded(program, maximum: 8_192)
            )
        }
    }

    private static func merge(
        backgroundItems: [StartupItem],
        launchdItems: [StartupItem]
    ) -> [StartupItem] {
        var merged = backgroundItems
        for launchdItem in launchdItems {
            let matchingIndex = merged.firstIndex { existing in
                if let existingURL = existing.itemURL,
                   let launchdURL = launchdItem.itemURL,
                   existingURL.standardizedFileURL.path == launchdURL.standardizedFileURL.path {
                    return true
                }
                return existing.displayIdentifier == launchdItem.displayIdentifier
                    && existing.kind == launchdItem.kind
            }
            guard let matchingIndex else {
                merged.append(launchdItem)
                continue
            }
            merged[matchingIndex] = merge(
                primary: merged[matchingIndex],
                fallback: launchdItem
            )
        }

        var unique: [String: StartupItem] = [:]
        for item in merged {
            let key = "\(item.kind.rawValue)|\(item.displayIdentifier)|\(item.itemURL?.path ?? "")"
            if let existing = unique[key] {
                unique[key] = merge(primary: existing, fallback: item)
            } else {
                unique[key] = item
            }
        }
        return Array(unique.values)
    }

    private static func merge(primary: StartupItem, fallback: StartupItem) -> StartupItem {
        StartupItem(
            id: primary.id,
            name: preferred(primary.name, fallback: fallback.name),
            developerName: primary.developerName ?? fallback.developerName,
            teamIdentifier: primary.teamIdentifier ?? fallback.teamIdentifier,
            serviceIdentifier: primary.serviceIdentifier,
            kind: primary.kind,
            state: primary.state == .unknown ? fallback.state : primary.state,
            scope: primary.scope,
            itemURL: primary.itemURL ?? fallback.itemURL,
            executableURL: primary.executableURL ?? fallback.executableURL,
            associatedBundleIdentifiers: Array(
                Set(primary.associatedBundleIdentifiers + fallback.associatedBundleIdentifiers)
            ).sorted(),
            evidence: primary.evidence.union(fallback.evidence),
            isLegacy: primary.isLegacy || fallback.isLegacy,
            isMissing: primary.isMissing || fallback.isMissing
        )
    }

    private static func kind(from rawType: String) -> StartupItemKind? {
        let value = rawType.lowercased()
        if value.contains("daemon") { return .launchDaemon }
        if value.contains("agent") { return .launchAgent }
        if value.contains("login item") { return .loginItem }
        if value.hasPrefix("app ") || value == "app" { return .backgroundItem }
        return nil
    }

    private static func state(fromDisposition disposition: String?) -> StartupItemState {
        let value = disposition?.lowercased() ?? ""
        if value.contains("disallowed") || value.contains("requires approval") {
            return .requiresApproval
        }
        if value.contains("enabled") { return .enabled }
        if value.contains("disabled") { return .disabled }
        return .unknown
    }

    private static func resolveItemURL(_ rawValue: String?, parentURL: URL?) -> URL? {
        guard let value = bounded(rawValue, maximum: 8_192), value != "(null)" else {
            return nil
        }
        if let absolute = fileURL(from: value) {
            return absolute
        }
        guard let parentURL, parentURL.isFileURL else { return nil }
        guard let resolved = URL(string: value, relativeTo: parentURL)?
            .absoluteURL
            .standardizedFileURL,
              resolved.isFileURL else { return nil }
        let parentPath = parentURL.standardizedFileURL.path
        guard resolved.path == parentPath
                || resolved.path.hasPrefix(parentPath + "/") else {
            return nil
        }
        return resolved
    }

    private static func fileURL(from rawValue: String?) -> URL? {
        guard let value = bounded(rawValue, maximum: 8_192), value != "(null)" else {
            return nil
        }
        if value.hasPrefix("file://"),
           let url = URL(string: value),
           url.isFileURL {
            return url.standardizedFileURL
        }
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    private static func parseList(_ rawValue: String?) -> [String] {
        guard let value = bounded(rawValue, maximum: 8_192) else { return [] }
        let stripped = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return stripped
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "(null)" }
    }

    private static func meaningful(_ primary: String?, fallback: String?) -> String? {
        let normalizedPrimary = bounded(primary, maximum: 1_024)
        if normalizedPrimary != nil, normalizedPrimary != "(null)" {
            return normalizedPrimary
        }
        let normalizedFallback = bounded(fallback, maximum: 1_024)
        return normalizedFallback == "(null)" ? nil : normalizedFallback
    }

    private static func preferredName(
        _ recordName: String?,
        parentName: String?,
        identifier: String
    ) -> String {
        if let recordName,
           !looksLikeReverseDNS(recordName) {
            return recordName
        }
        if let parentName,
           !looksLikeReverseDNS(parentName) {
            return parentName
        }
        return recordName ?? parentName ?? identifier
    }

    private static func preferred(_ primary: String, fallback: String) -> String {
        if looksLikeReverseDNS(primary), !looksLikeReverseDNS(fallback) {
            return fallback
        }
        return primary
    }

    private static func looksLikeReverseDNS(_ value: String) -> Bool {
        value.split(separator: ".").count >= 3 && !value.contains(" ")
    }

    private static func scopeFor(itemURL: URL?, executableURL: URL?) -> StartupItemScope {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let paths = [itemURL?.path, executableURL?.path].compactMap { $0 }
        return paths.contains(where: { $0 == homePath || $0.hasPrefix(homePath + "/") })
            ? .user
            : .system
    }

    private static func isMissing(
        itemURL: URL?,
        executableURL: URL?,
        fileManager: FileManager
    ) -> Bool {
        if let executableURL {
            return !fileManager.fileExists(atPath: executableURL.path)
        }
        if let itemURL, itemURL.isFileURL {
            return !fileManager.fileExists(atPath: itemURL.path)
        }
        return false
    }

    private static func bounded(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximum else { return nil }
        return trimmed
    }

    private static func kindSortOrder(_ kind: StartupItemKind) -> Int {
        switch kind {
        case .loginItem: return 0
        case .backgroundItem: return 1
        case .launchAgent: return 2
        case .launchDaemon: return 3
        }
    }
}
