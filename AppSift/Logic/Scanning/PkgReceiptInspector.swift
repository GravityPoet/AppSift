import Foundation
import Darwin

struct InstallerPackageReceiptMetadata: Hashable, Sendable {
    let identifier: String
    let version: String?
    let installLocation: String
}

enum InstallerPackageComponentOwnership: String, Hashable, Sendable {
    case receiptOnly
    case shared
    case unverified
}

struct InstallerPackageExternalComponent: Identifiable, Hashable, Sendable {
    var id: String { url.standardizedFileURL.path }

    let url: URL
    let payloadPathCount: Int
    let ownership: InstallerPackageComponentOwnership
    let otherOwnerIdentifiers: [String]
    let isSystemSensitive: Bool
}

struct InstallerPackageInsights: Hashable, Sendable {
    let receipts: [InstallerPackageReceiptMetadata]
    let payloadPathCount: Int
    let externalPayloadPathCount: Int
    let existingExternalPayloadPathCount: Int
    let externalComponents: [InstallerPackageExternalComponent]
    let isIncomplete: Bool

    var sharedExternalComponentCount: Int {
        externalComponents.count { $0.ownership == .shared }
    }

    var unverifiedExternalComponentCount: Int {
        externalComponents.count { $0.ownership == .unverified }
    }

    var systemSensitiveExternalComponentCount: Int {
        externalComponents.count { $0.isSystemSensitive }
    }
}

struct PkgCommandResult: Sendable {
    let exitCode: Int32?
    let output: Data
    let timedOut: Bool
    let truncated: Bool

    var succeeded: Bool {
        exitCode == 0 && !timedOut && !truncated
    }
}

/// Read-only access to the Installer receipt database. Receipt payload paths
/// are evidence only: this inspector never adds a path to the uninstall list
/// and never invokes `pkgutil --forget` or any other mutating command.
enum PkgReceiptInspector {
    typealias CommandProvider = @Sendable ([String]) -> PkgCommandResult

    private struct ParsedReceipt {
        let metadata: InstallerPackageReceiptMetadata
        let payloadPaths: Set<URL>
        let wasTruncated: Bool
    }

    private struct ExternalComponentGroup {
        let url: URL
        var payloadPathCount: Int
    }

    private struct ExternalComponentGrouping {
        let groups: [ExternalComponentGroup]
        let wasTruncated: Bool
    }

    private final class OutputBox: @unchecked Sendable {
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

    private static let pkgutilURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
    private static let maximumCommandOutputBytes = 4_000_000
    private static let commandTimeout: TimeInterval = 15
    private static let maximumReceipts = 8
    private static let maximumPayloadPathsPerReceipt = 20_000
    private static let maximumExternalComponents = 256
    private static let maximumOwnershipChecks = 64
    private static let maximumPathLength = 8_192

    static func inspect(
        app: InstalledApp,
        fileManager: FileManager = .default,
        commandProvider: @escaping CommandProvider = { arguments in
            runPkgutil(arguments: arguments)
        },
        shouldCancel: () -> Bool = { false }
    ) -> InstallerPackageInsights? {
        guard !shouldCancel(),
              app.path.isFileURL,
              fileManager.fileExists(atPath: app.path.path) else { return nil }

        var receiptIdentifiers: Set<String> = []
        for marker in markerURLs(for: app) {
            guard !shouldCancel() else { return nil }
            let result = commandProvider(["--file-info-plist", marker.path])
            guard result.succeeded else { continue }
            receiptIdentifiers.formUnion(parsePackageIdentifiers(from: result.output))
            if receiptIdentifiers.count > maximumReceipts {
                return nil
            }
        }
        guard !receiptIdentifiers.isEmpty else { return nil }

        var parsedReceipts: [ParsedReceipt] = []
        for identifier in receiptIdentifiers.sorted() {
            guard !shouldCancel() else { return nil }
            guard let receipt = loadReceipt(
                identifier: identifier,
                commandProvider: commandProvider
            ), payloadCoversSelectedApp(receipt.payloadPaths, appURL: app.path) else {
                continue
            }
            parsedReceipts.append(receipt)
        }
        guard !parsedReceipts.isEmpty else { return nil }

        let verifiedIdentifiers = Set(parsedReceipts.map(\.metadata.identifier))
        let appPath = app.path.standardizedFileURL.resolvingSymlinksInPath().path
        let payloadPaths = Set(parsedReceipts.flatMap(\.payloadPaths))
        let externalPaths = payloadPaths.filter { url in
            let path = url.standardizedFileURL.path
            return path != appPath && !path.hasPrefix(appPath + "/")
        }.sorted {
            let lhsDepth = $0.pathComponents.count
            let rhsDepth = $1.pathComponents.count
            if lhsDepth == rhsDepth { return $0.path < $1.path }
            return lhsDepth < rhsDepth
        }
        let existingExternalPaths = externalPaths.filter {
            fileManager.fileExists(atPath: $0.path)
        }

        let grouping = externalComponentGroups(
            payloadPaths: Set(externalPaths),
            appURL: app.path,
            maximumComponents: maximumExternalComponents
        )
        let existingGroups = grouping.groups.filter {
            fileManager.fileExists(atPath: $0.url.path)
        }

        var components: [InstallerPackageExternalComponent] = []
        var ownershipChecksIncomplete = existingGroups.count > maximumOwnershipChecks
        for (index, group) in existingGroups.enumerated() {
            guard !shouldCancel() else { return nil }
            let ownership: InstallerPackageComponentOwnership
            var otherOwners: [String] = []
            if index < maximumOwnershipChecks {
                let result = commandProvider(["--file-info-plist", group.url.path])
                if result.succeeded {
                    let owners = parsePackageIdentifiers(from: result.output)
                    otherOwners = owners.subtracting(verifiedIdentifiers).sorted()
                    if !otherOwners.isEmpty {
                        ownership = .shared
                    } else if !owners.isDisjoint(with: verifiedIdentifiers) {
                        ownership = .receiptOnly
                    } else {
                        ownership = .unverified
                        ownershipChecksIncomplete = true
                    }
                } else {
                    ownership = .unverified
                    ownershipChecksIncomplete = true
                }
            } else {
                ownership = .unverified
            }
            components.append(
                InstallerPackageExternalComponent(
                    url: group.url,
                    payloadPathCount: group.payloadPathCount,
                    ownership: ownership,
                    otherOwnerIdentifiers: otherOwners,
                    isSystemSensitive: isSystemSensitivePath(group.url.path)
                )
            )
        }

        return InstallerPackageInsights(
            receipts: parsedReceipts.map(\.metadata).sorted {
                $0.identifier < $1.identifier
            },
            payloadPathCount: payloadPaths.count,
            externalPayloadPathCount: externalPaths.count,
            existingExternalPayloadPathCount: existingExternalPaths.count,
            externalComponents: components,
            isIncomplete: parsedReceipts.contains(where: \.wasTruncated)
                || grouping.wasTruncated
                || ownershipChecksIncomplete
        )
    }

    static func parsePackageIdentifiers(from data: Data) -> Set<String> {
        guard data.count <= maximumCommandOutputBytes,
              let document = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let pathInfo = document["path-info"] as? [[String: Any]] else {
            return []
        }
        return Set(pathInfo.compactMap { entry in
            safePackageIdentifier(entry["pkgid"] as? String)
        })
    }

    static func normalizedPayloadURL(
        _ rawPath: String,
        installLocation: String
    ) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maximumPathLength,
              !trimmed.contains("\0"),
              !trimmed.hasPrefix("/") else { return nil }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else { return nil }

        guard let location = normalizedInstallLocation(installLocation) else { return nil }
        let root = URL(fileURLWithPath: location, isDirectory: true).standardizedFileURL
        let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
        let rootPath = root.path
        guard rootPath == "/"
                || candidate.path == rootPath
                || candidate.path.hasPrefix(rootPath + "/") else { return nil }
        return candidate
    }

    private static func markerURLs(for app: InstalledApp) -> [URL] {
        var markers = [
            app.path.standardizedFileURL,
            app.path.appendingPathComponent("Contents/Info.plist").standardizedFileURL,
        ]
        if let executable = Bundle(url: app.path)?.executableURL {
            markers.append(executable.standardizedFileURL)
        }
        var seen: Set<String> = []
        return markers.filter { seen.insert($0.path).inserted }
    }

    private static func loadReceipt(
        identifier: String,
        commandProvider: CommandProvider
    ) -> ParsedReceipt? {
        guard let safeIdentifier = safePackageIdentifier(identifier) else { return nil }
        let infoResult = commandProvider(["--pkg-info-plist", safeIdentifier])
        guard infoResult.succeeded,
              let info = parseReceiptMetadata(from: infoResult.output, expectedID: safeIdentifier)
        else { return nil }

        let filesResult = commandProvider(["--files", safeIdentifier])
        guard filesResult.exitCode == 0,
              !filesResult.timedOut,
              filesResult.output.count <= maximumCommandOutputBytes,
              let output = String(data: filesResult.output, encoding: .utf8) else {
            return nil
        }

        let lines = output.split(whereSeparator: \.isNewline)
        var paths: Set<URL> = []
        for line in lines.prefix(maximumPayloadPathsPerReceipt) {
            if let url = normalizedPayloadURL(
                String(line),
                installLocation: info.installLocation
            ) {
                paths.insert(url)
            }
        }
        guard !paths.isEmpty else { return nil }
        return ParsedReceipt(
            metadata: info,
            payloadPaths: paths,
            wasTruncated: filesResult.truncated
                || lines.count > maximumPayloadPathsPerReceipt
        )
    }

    private static func parseReceiptMetadata(
        from data: Data,
        expectedID: String
    ) -> InstallerPackageReceiptMetadata? {
        guard data.count <= maximumCommandOutputBytes,
              let document = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              safePackageIdentifier(document["pkgid"] as? String) == expectedID
                || safePackageIdentifier(document["package-id"] as? String) == expectedID
        else { return nil }
        guard let location = normalizedInstallLocation(
            document["install-location"] as? String
        ) else { return nil }
        return InstallerPackageReceiptMetadata(
            identifier: expectedID,
            version: boundedString(document["pkg-version"] as? String, maximum: 256)
                ?? boundedString(document["version"] as? String, maximum: 256),
            installLocation: location
        )
    }

    private static func payloadCoversSelectedApp(
        _ payloadPaths: Set<URL>,
        appURL: URL
    ) -> Bool {
        let appPath = appURL.standardizedFileURL.resolvingSymlinksInPath().path
        return payloadPaths.contains { payloadURL in
            let path = payloadURL.standardizedFileURL.path
            return path == appPath || path.hasPrefix(appPath + "/")
        }
    }

    private static func safePackageIdentifier(_ value: String?) -> String? {
        guard let value = boundedString(value, maximum: 512),
              value.first != "-" else { return nil }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".+_-")
        )
        return value.unicodeScalars.allSatisfy(allowed.contains) ? value : nil
    }

    private static func normalizedInstallLocation(_ value: String?) -> String? {
        let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard raw.count <= 4_096,
              !raw.contains("\0"),
              !raw.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else { return nil }
        if raw.isEmpty { return "/" }
        let absolute = raw.hasPrefix("/") ? raw : "/" + raw
        return URL(fileURLWithPath: absolute, isDirectory: true).standardizedFileURL.path
    }

    private static func boundedString(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximum else { return nil }
        return trimmed
    }

    static func collapsedExternalComponentRoots(
        payloadPaths: Set<URL>,
        appURL: URL
    ) -> [URL] {
        externalComponentGroups(
            payloadPaths: payloadPaths,
            appURL: appURL,
            maximumComponents: maximumExternalComponents
        ).groups.map(\.url)
    }

    private static func externalComponentGroups(
        payloadPaths: Set<URL>,
        appURL: URL,
        maximumComponents: Int
    ) -> ExternalComponentGrouping {
        let appPath = appURL.standardizedFileURL.resolvingSymlinksInPath().path
        let externalPaths = payloadPaths.compactMap { url -> URL? in
            let standardized = url.standardizedFileURL
            let path = standardized.path
            guard path != appPath,
                  !path.hasPrefix(appPath + "/"),
                  !isStructuralPayloadContainer(path) else { return nil }
            return standardized
        }.sorted {
            let lhsDepth = $0.pathComponents.count
            let rhsDepth = $1.pathComponents.count
            if lhsDepth == rhsDepth { return $0.path < $1.path }
            return lhsDepth < rhsDepth
        }

        var groups: [ExternalComponentGroup] = []
        var wasTruncated = false
        for url in externalPaths {
            let path = url.path
            if let index = groups.firstIndex(where: { group in
                let root = group.url.path
                return path == root || path.hasPrefix(root + "/")
            }) {
                groups[index].payloadPathCount += 1
            } else if groups.count < maximumComponents {
                groups.append(
                    ExternalComponentGroup(url: url, payloadPathCount: 1)
                )
            } else {
                wasTruncated = true
            }
        }
        return ExternalComponentGrouping(groups: groups, wasTruncated: wasTruncated)
    }

    private static func isStructuralPayloadContainer(_ path: String) -> Bool {
        let containers: Set<String> = [
            "/",
            "/Applications",
            "/Applications/Utilities",
            "/Library",
            "/Library/Application Support",
            "/Library/Audio",
            "/Library/Audio/Plug-Ins",
            "/Library/Extensions",
            "/Library/Frameworks",
            "/Library/Internet Plug-Ins",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons",
            "/Library/PreferencePanes",
            "/Library/PrivilegedHelperTools",
            "/Library/QuickLook",
            "/Library/Spotlight",
            "/Library/SystemExtensions",
            "/Users",
            "/Users/Shared",
            "/opt",
            "/private",
            "/private/etc",
            "/private/var",
            "/usr",
            "/usr/local",
            "/usr/local/bin",
            "/usr/local/lib",
            "/usr/local/libexec",
            "/usr/local/sbin",
            "/usr/local/share",
        ]
        return containers.contains(path)
    }

    static func isSystemSensitivePath(_ path: String) -> Bool {
        if path == "/usr/local" || path.hasPrefix("/usr/local/") {
            return false
        }
        let sensitiveRoots = [
            "/System",
            "/bin",
            "/sbin",
            "/usr",
            "/Library/Apple",
            "/Library/Extensions",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons",
            "/Library/PrivilegedHelperTools",
            "/Library/SystemExtensions",
            "/private/etc",
            "/private/var/db",
        ]
        return sensitiveRoots.contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }

    private static func runPkgutil(arguments: [String]) -> PkgCommandResult {
        let allowedCommands = [
            "--file-info-plist",
            "--pkg-info-plist",
            "--files",
        ]
        guard arguments.count == 2,
              allowedCommands.contains(arguments[0]),
              FileManager.default.isExecutableFile(atPath: pkgutilURL.path) else {
            return PkgCommandResult(
                exitCode: nil,
                output: Data(),
                timedOut: false,
                truncated: false
            )
        }

        let process = Process()
        process.executableURL = pkgutilURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let output = OutputBox()
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
            return PkgCommandResult(
                exitCode: nil,
                output: Data(),
                timedOut: false,
                truncated: false
            )
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
        return PkgCommandResult(
            exitCode: process.isRunning ? nil : process.terminationStatus,
            output: snapshot.0,
            timedOut: timedOut,
            truncated: snapshot.1
        )
    }
}
