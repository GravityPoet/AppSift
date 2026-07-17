import Darwin
import Foundation

enum ManagedExtensionKind: String, CaseIterable, Hashable, Sendable {
    case appExtension
    case browserExtension
    case finderExtension
    case shareExtension
    case widget
    case systemExtension
    case preferencePane
    case screenSaver
    case quickLook
    case legacyPlugin
    case kernelExtension
}

enum ManagedExtensionState: String, CaseIterable, Hashable, Sendable {
    case enabled
    case disabled
    case needsApproval
    case systemDefault
    case installed
    case superseded
    case unknown
}

enum ManagedExtensionScope: String, Hashable, Sendable {
    case user
    case system
    case embedded
}

enum ManagedExtensionEvidence: String, Hashable, Sendable {
    case pluginKitRegistry
    case systemExtensionRegistry
    case browserManifest
    case browserProfileRegistry
    case browserPreference
    case filesystemBundle
    case codeSignature
    case ownerCodeSignature
    case containingApplication
}

enum ManagedExtensionScanSource: String, CaseIterable, Hashable, Sendable {
    case appExtensions
    case systemExtensions
    case browserExtensions
    case legacyBundles
}

enum ManagedExtensionManagement: Hashable, Sendable {
    case systemSettings
    case browser(
        bundleIdentifier: String,
        applicationURL: URL?,
        page: String
    )
    case reveal
}

struct ExtensionOwnerApp: Hashable, Sendable {
    let name: String
    let bundleIdentifier: String
    let url: URL
    let teamIdentifier: String?
    let developerName: String?

    init(app: InstalledApp) {
        self.name = app.appName
        self.bundleIdentifier = app.bundleIdentifier
        self.url = app.path.standardizedFileURL
        self.teamIdentifier = app.signature.teamIdentifier
        self.developerName = app.signature.developerName
    }

    init(
        name: String,
        bundleIdentifier: String,
        url: URL,
        teamIdentifier: String? = nil,
        developerName: String? = nil
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.url = url.standardizedFileURL
        self.teamIdentifier = teamIdentifier
        self.developerName = developerName
    }
}

struct ManagedExtension: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let identifier: String
    let version: String?
    let kind: ManagedExtensionKind
    let state: ManagedExtensionState
    let scope: ManagedExtensionScope
    let url: URL?
    let owner: ExtensionOwnerApp?
    let teamIdentifier: String?
    let developerName: String?
    let profileName: String?
    let permissionCount: Int?
    let evidence: Set<ManagedExtensionEvidence>
    let management: ManagedExtensionManagement
}

struct ManagedExtensionScanResult: Sendable {
    let items: [ManagedExtension]
    let incompleteSources: Set<ManagedExtensionScanSource>
}

struct ManagedExtensionCommandOutput: Sendable {
    let output: String?
    let incomplete: Bool

    init(output: String?, incomplete: Bool = false) {
        self.output = output
        self.incomplete = incomplete
    }
}

enum BrowserExtensionFamily: String, Hashable, Sendable {
    case chromium
    case firefox
}

struct BrowserExtensionSource: Hashable, Sendable {
    let family: BrowserExtensionFamily
    let name: String
    let bundleIdentifier: String
    let applicationURL: URL?
    let profileRoot: URL
    let managementPage: String
}

struct FilesystemExtensionRoot: Hashable, Sendable {
    let url: URL
    let kind: ManagedExtensionKind
    let scope: ManagedExtensionScope
    let pathExtensions: Set<String>
}

enum ManagedExtensionScanner {
    typealias CommandOutputProvider = @Sendable () -> ManagedExtensionCommandOutput

    private struct BundleInfo {
        let name: String?
        let identifier: String?
        let version: String?
        let packageType: String?
        let extensionPointIdentifier: String?
    }

    private struct BrowserScanResult {
        var items: [ManagedExtension] = []
        var incomplete = false
    }

    private struct FilesystemScanResult {
        var items: [ManagedExtension] = []
        var incomplete = false
    }

    private final class ProcessOutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var truncated = false

        func append(_ value: Data, limit: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard !value.isEmpty else { return }
            let remaining = max(0, limit - data.count)
            if remaining > 0 {
                data.append(value.prefix(remaining))
            }
            if value.count > remaining {
                truncated = true
            }
        }

        func snapshot() -> (Data, Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (data, truncated)
        }
    }

    private static let maximumCommandOutputBytes = 8_000_000
    private static let maximumBundleInfoBytes = 2_000_000
    private static let maximumBrowserJSONBytes = 24_000_000
    private static let maximumProfilesPerBrowser = 64
    private static let maximumExtensionsPerProfile = 2_000
    private static let maximumFilesystemItemsPerRoot = 2_000
    private static let maximumEmbeddedSystemExtensionsPerApp = 64
    private static let commandTimeout: TimeInterval = 20

    static func scan(
        ownerApps: [ExtensionOwnerApp],
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        pluginKitOutputProvider: CommandOutputProvider = {
            runCommand(
                executable: "/usr/bin/pluginkit",
                arguments: ["-m", "-v"]
            )
        },
        systemExtensionsOutputProvider: CommandOutputProvider = {
            runCommand(
                executable: "/usr/bin/systemextensionsctl",
                arguments: ["list"]
            )
        },
        browserSources: [BrowserExtensionSource]? = nil,
        filesystemRoots: [FilesystemExtensionRoot]? = nil
    ) -> ManagedExtensionScanResult {
        var items: [ManagedExtension] = []
        var incompleteSources: Set<ManagedExtensionScanSource> = []

        let pluginKitOutput = pluginKitOutputProvider()
        if let output = pluginKitOutput.output {
            items.append(contentsOf: parsePluginKitOutput(
                output,
                ownerApps: ownerApps,
                fileManager: fileManager
            ))
        } else {
            incompleteSources.insert(.appExtensions)
        }
        if pluginKitOutput.incomplete {
            incompleteSources.insert(.appExtensions)
        }

        let systemOutput = systemExtensionsOutputProvider()
        if let output = systemOutput.output {
            items.append(contentsOf: parseSystemExtensionsOutput(
                output,
                ownerApps: ownerApps,
                fileManager: fileManager
            ))
        } else {
            incompleteSources.insert(.systemExtensions)
        }
        if systemOutput.incomplete {
            incompleteSources.insert(.systemExtensions)
        }

        let resolvedBrowserSources = browserSources ?? defaultBrowserSources(
            homeURL: homeURL,
            ownerApps: ownerApps
        )
        let browserResult = scanBrowserExtensions(
            sources: resolvedBrowserSources,
            fileManager: fileManager
        )
        items.append(contentsOf: browserResult.items)
        if browserResult.incomplete {
            incompleteSources.insert(.browserExtensions)
        }

        let resolvedFilesystemRoots = filesystemRoots
            ?? defaultFilesystemRoots(homeURL: homeURL)
        let filesystemResult = scanFilesystemBundles(
            roots: resolvedFilesystemRoots,
            ownerApps: ownerApps,
            fileManager: fileManager
        )
        items.append(contentsOf: filesystemResult.items)
        if filesystemResult.incomplete {
            incompleteSources.insert(.legacyBundles)
        }

        var unique: [String: ManagedExtension] = [:]
        for item in items where unique[item.id] == nil {
            unique[item.id] = item
        }

        return ManagedExtensionScanResult(
            items: unique.values.sorted(by: extensionSort),
            incompleteSources: incompleteSources
        )
    }

    static func parsePluginKitOutput(
        _ output: String,
        ownerApps: [ExtensionOwnerApp],
        fileManager: FileManager = .default
    ) -> [ManagedExtension] {
        var items: [ManagedExtension] = []

        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(
                separator: "\t",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard fields.count >= 4 else { continue }

            let rawHeader = fields[0]
            let marker = rawHeader.first
            var header = rawHeader.trimmingCharacters(in: .whitespacesAndNewlines)
            if let marker = header.first,
               ["+", "-", "!", "=", "?"].contains(marker) {
                header.removeFirst()
                header = header.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let parsed = parseIdentifierAndVersion(header) else { continue }

            let rawPath = fields.last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !rawPath.isEmpty else { continue }
            let url = URL(fileURLWithPath: rawPath, isDirectory: true)
                .standardizedFileURL
            guard url.pathExtension.caseInsensitiveCompare("appex") == .orderedSame,
                  !isAppleSystemItem(identifier: parsed.identifier, url: url) else {
                continue
            }

            let info = loadBundleInfo(at: url, fileManager: fileManager)
            let owner = owner(for: url, ownerApps: ownerApps)
                ?? containingApplicationOwner(
                    for: url,
                    fileManager: fileManager
                )
            let signature = owner == nil && fileManager.fileExists(atPath: url.path)
                ? AppSignatureInspector.inspect(at: url)
                : .unknown
            var evidence: Set<ManagedExtensionEvidence> = [.pluginKitRegistry]
            if owner != nil { evidence.insert(.containingApplication) }
            if signature.status == .developerSigned {
                evidence.insert(.codeSignature)
            }
            if owner?.teamIdentifier != nil {
                evidence.insert(.ownerCodeSignature)
            }

            let identifier = info?.identifier ?? parsed.identifier
            let name = info?.name
                ?? owner.map { "\($0.name) Extension" }
                ?? url.deletingPathExtension().lastPathComponent
            let kind = kindForAppExtension(
                extensionPointIdentifier: info?.extensionPointIdentifier,
                identifier: identifier,
                path: url.path
            )
            let state: ManagedExtensionState
            switch marker {
            case "+", "!": state = .enabled
            case "-": state = .disabled
            case "=": state = .superseded
            case "?": state = .unknown
            default: state = .systemDefault
            }

            items.append(
                ManagedExtension(
                    id: "pluginkit|\(identifier)|\(url.path)",
                    name: name,
                    identifier: identifier,
                    version: info?.version ?? parsed.version,
                    kind: kind,
                    state: state,
                    scope: .embedded,
                    url: url,
                    owner: owner,
                    teamIdentifier: signature.teamIdentifier ?? owner?.teamIdentifier,
                    developerName: signature.developerName ?? owner?.developerName,
                    profileName: nil,
                    permissionCount: nil,
                    evidence: evidence,
                    management: .systemSettings
                )
            )
        }

        return items
    }

    static func parseSystemExtensionsOutput(
        _ output: String,
        ownerApps: [ExtensionOwnerApp],
        fileManager: FileManager = .default
    ) -> [ManagedExtension] {
        var items: [ManagedExtension] = []
        var currentCategory = "system"
        let embeddedOwners = embeddedSystemExtensionOwners(
            ownerApps: ownerApps,
            fileManager: fileManager
        )

        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("--- ") {
                currentCategory = line
                    .dropFirst(4)
                    .split(separator: " ", maxSplits: 1)
                    .first
                    .map(String.init) ?? "system"
                continue
            }

            let fields = line.split(
                separator: "\t",
                omittingEmptySubsequences: false
            ).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard fields.count >= 6,
                  fields[0] != "enabled",
                  !fields[2].isEmpty,
                  let parsed = parseIdentifierAndVersion(fields[3]),
                  !parsed.identifier.hasPrefix("com.apple.") else {
                continue
            }

            let stateDescription = fields[5].lowercased()
            let state: ManagedExtensionState
            if fields[0] == "*" {
                state = .enabled
            } else if stateDescription.contains("waiting for user")
                        || stateDescription.contains("awaiting user") {
                state = .needsApproval
            } else if stateDescription.contains("uninstalled")
                        || stateDescription.contains("terminated") {
                state = .disabled
            } else {
                state = .installed
            }

            let teamIdentifier = fields[2]
            let owner = embeddedOwners[parsed.identifier]
            let name = fields[4].isEmpty
                ? parsed.identifier
                : fields[4]
            var evidence: Set<ManagedExtensionEvidence> = [.systemExtensionRegistry]
            if owner != nil {
                evidence.insert(.containingApplication)
            }
            if owner?.teamIdentifier != nil {
                evidence.insert(.ownerCodeSignature)
            }

            items.append(
                ManagedExtension(
                    id: "system|\(parsed.identifier)",
                    name: name,
                    identifier: parsed.identifier,
                    version: parsed.version,
                    kind: .systemExtension,
                    state: state,
                    scope: .system,
                    url: nil,
                    owner: owner,
                    teamIdentifier: teamIdentifier,
                    developerName: owner?.developerName,
                    profileName: systemCategoryName(currentCategory),
                    permissionCount: nil,
                    evidence: evidence,
                    management: .systemSettings
                )
            )
        }

        return items
    }

    static func defaultBrowserSources(
        homeURL: URL,
        ownerApps: [ExtensionOwnerApp]
    ) -> [BrowserExtensionSource] {
        let applicationSupport = homeURL
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        func appURL(bundleIdentifier: String, fallbackName: String) -> URL? {
            if let owner = ownerApps.first(where: {
                $0.bundleIdentifier == bundleIdentifier
            }) {
                return owner.url
            }
            let fallback = URL(
                fileURLWithPath: "/Applications/\(fallbackName).app",
                isDirectory: true
            )
            return FileManager.default.fileExists(atPath: fallback.path)
                ? fallback
                : nil
        }

        return [
            BrowserExtensionSource(
                family: .chromium,
                name: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                applicationURL: appURL(
                    bundleIdentifier: "com.google.Chrome",
                    fallbackName: "Google Chrome"
                ),
                profileRoot: applicationSupport
                    .appendingPathComponent("Google/Chrome", isDirectory: true),
                managementPage: "chrome://extensions/"
            ),
            BrowserExtensionSource(
                family: .chromium,
                name: "Brave Browser",
                bundleIdentifier: "com.brave.Browser",
                applicationURL: appURL(
                    bundleIdentifier: "com.brave.Browser",
                    fallbackName: "Brave Browser"
                ),
                profileRoot: applicationSupport
                    .appendingPathComponent("BraveSoftware/Brave-Browser", isDirectory: true),
                managementPage: "brave://extensions/"
            ),
            BrowserExtensionSource(
                family: .chromium,
                name: "Microsoft Edge",
                bundleIdentifier: "com.microsoft.edgemac",
                applicationURL: appURL(
                    bundleIdentifier: "com.microsoft.edgemac",
                    fallbackName: "Microsoft Edge"
                ),
                profileRoot: applicationSupport
                    .appendingPathComponent("Microsoft Edge", isDirectory: true),
                managementPage: "edge://extensions/"
            ),
            BrowserExtensionSource(
                family: .chromium,
                name: "Arc",
                bundleIdentifier: "company.thebrowser.Browser",
                applicationURL: appURL(
                    bundleIdentifier: "company.thebrowser.Browser",
                    fallbackName: "Arc"
                ),
                profileRoot: applicationSupport
                    .appendingPathComponent("Arc/User Data", isDirectory: true),
                managementPage: "arc://extensions/"
            ),
            BrowserExtensionSource(
                family: .chromium,
                name: "Chromium",
                bundleIdentifier: "org.chromium.Chromium",
                applicationURL: appURL(
                    bundleIdentifier: "org.chromium.Chromium",
                    fallbackName: "Chromium"
                ),
                profileRoot: applicationSupport
                    .appendingPathComponent("Chromium", isDirectory: true),
                managementPage: "chrome://extensions/"
            ),
            BrowserExtensionSource(
                family: .chromium,
                name: "Vivaldi",
                bundleIdentifier: "com.vivaldi.Vivaldi",
                applicationURL: appURL(
                    bundleIdentifier: "com.vivaldi.Vivaldi",
                    fallbackName: "Vivaldi"
                ),
                profileRoot: applicationSupport
                    .appendingPathComponent("Vivaldi", isDirectory: true),
                managementPage: "vivaldi://extensions/"
            ),
            BrowserExtensionSource(
                family: .chromium,
                name: "Opera",
                bundleIdentifier: "com.operasoftware.Opera",
                applicationURL: appURL(
                    bundleIdentifier: "com.operasoftware.Opera",
                    fallbackName: "Opera"
                ),
                profileRoot: applicationSupport
                    .appendingPathComponent("com.operasoftware.Opera", isDirectory: true),
                managementPage: "opera://extensions/"
            ),
            BrowserExtensionSource(
                family: .firefox,
                name: "Firefox",
                bundleIdentifier: "org.mozilla.firefox",
                applicationURL: appURL(
                    bundleIdentifier: "org.mozilla.firefox",
                    fallbackName: "Firefox"
                ),
                profileRoot: applicationSupport
                    .appendingPathComponent("Firefox/Profiles", isDirectory: true),
                managementPage: "about:addons"
            ),
        ]
    }

    static func defaultFilesystemRoots(homeURL: URL) -> [FilesystemExtensionRoot] {
        [
            FilesystemExtensionRoot(
                url: homeURL.appendingPathComponent("Library/PreferencePanes", isDirectory: true),
                kind: .preferencePane,
                scope: .user,
                pathExtensions: ["prefpane"]
            ),
            FilesystemExtensionRoot(
                url: URL(fileURLWithPath: "/Library/PreferencePanes", isDirectory: true),
                kind: .preferencePane,
                scope: .system,
                pathExtensions: ["prefpane"]
            ),
            FilesystemExtensionRoot(
                url: homeURL.appendingPathComponent("Library/Screen Savers", isDirectory: true),
                kind: .screenSaver,
                scope: .user,
                pathExtensions: ["saver"]
            ),
            FilesystemExtensionRoot(
                url: URL(fileURLWithPath: "/Library/Screen Savers", isDirectory: true),
                kind: .screenSaver,
                scope: .system,
                pathExtensions: ["saver"]
            ),
            FilesystemExtensionRoot(
                url: homeURL.appendingPathComponent("Library/QuickLook", isDirectory: true),
                kind: .quickLook,
                scope: .user,
                pathExtensions: ["qlgenerator"]
            ),
            FilesystemExtensionRoot(
                url: URL(fileURLWithPath: "/Library/QuickLook", isDirectory: true),
                kind: .quickLook,
                scope: .system,
                pathExtensions: ["qlgenerator"]
            ),
            FilesystemExtensionRoot(
                url: homeURL.appendingPathComponent("Library/Internet Plug-Ins", isDirectory: true),
                kind: .legacyPlugin,
                scope: .user,
                pathExtensions: ["plugin", "webplugin"]
            ),
            FilesystemExtensionRoot(
                url: URL(fileURLWithPath: "/Library/Internet Plug-Ins", isDirectory: true),
                kind: .legacyPlugin,
                scope: .system,
                pathExtensions: ["plugin", "webplugin"]
            ),
            FilesystemExtensionRoot(
                url: URL(fileURLWithPath: "/Library/Extensions", isDirectory: true),
                kind: .kernelExtension,
                scope: .system,
                pathExtensions: ["kext"]
            ),
        ]
    }

    private static func scanBrowserExtensions(
        sources: [BrowserExtensionSource],
        fileManager: FileManager
    ) -> BrowserScanResult {
        var result = BrowserScanResult()
        for source in sources {
            switch source.family {
            case .chromium:
                let partial = scanChromiumSource(source, fileManager: fileManager)
                result.items.append(contentsOf: partial.items)
                result.incomplete = result.incomplete || partial.incomplete
            case .firefox:
                let partial = scanFirefoxSource(source, fileManager: fileManager)
                result.items.append(contentsOf: partial.items)
                result.incomplete = result.incomplete || partial.incomplete
            }
        }
        return result
    }

    private static func scanChromiumSource(
        _ source: BrowserExtensionSource,
        fileManager: FileManager
    ) -> BrowserScanResult {
        var result = BrowserScanResult()
        guard fileManager.fileExists(atPath: source.profileRoot.path) else {
            return result
        }
        guard isRealDirectory(source.profileRoot),
              let rootContents = try? fileManager.contentsOfDirectory(
                at: source.profileRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else {
            result.incomplete = true
            return result
        }

        var profiles: [URL] = []
        let rootExtensions = source.profileRoot.appendingPathComponent(
            "Extensions",
            isDirectory: true
        )
        if isRealDirectory(rootExtensions) {
            profiles.append(source.profileRoot)
        }
        profiles.append(contentsOf: rootContents.filter { profile in
            guard isSafeDirectChild(profile, of: source.profileRoot),
                  isRealDirectory(profile) else { return false }
            return isRealDirectory(
                profile.appendingPathComponent("Extensions", isDirectory: true)
            )
        })

        if profiles.count > maximumProfilesPerBrowser {
            result.incomplete = true
        }
        for profile in profiles.prefix(maximumProfilesPerBrowser) {
            let extensionsRoot = profile.appendingPathComponent("Extensions", isDirectory: true)
            guard let extensionContents = try? fileManager.contentsOfDirectory(
                    at: extensionsRoot,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                result.incomplete = true
                continue
            }

            let extensionDirectories = extensionContents.filter {
                isSafeDirectChild($0, of: extensionsRoot) && isRealDirectory($0)
            }
            if extensionDirectories.count > maximumExtensionsPerProfile {
                result.incomplete = true
            }
            let preferences = chromiumExtensionSettings(
                profileURL: profile,
                fileManager: fileManager
            )
            if preferences.wasUnreadable {
                result.incomplete = true
            }

            for extensionDirectory in extensionDirectories.prefix(maximumExtensionsPerProfile) {
                let extensionID = extensionDirectory.lastPathComponent
                guard isReasonableIdentifier(extensionID),
                      let versionURL = newestExtensionVersion(
                        at: extensionDirectory,
                        fileManager: fileManager
                      ),
                      let manifest = loadJSONObject(
                        at: versionURL.appendingPathComponent("manifest.json"),
                        maximumBytes: maximumBundleInfoBytes,
                        fileManager: fileManager,
                        containedIn: versionURL
                      ) as? [String: Any] else {
                    continue
                }

                let name = resolvedChromiumName(
                    manifest: manifest,
                    versionURL: versionURL,
                    fileManager: fileManager
                ) ?? extensionID
                let version = nonEmptyString(manifest["version_name"])
                    ?? nonEmptyString(manifest["version"])
                let preferenceState = preferences.settings[extensionID]
                let state = chromiumExtensionState(preferenceState)
                var evidence: Set<ManagedExtensionEvidence> = [.browserManifest]
                if preferenceState != nil { evidence.insert(.browserPreference) }
                let owner = ExtensionOwnerApp(
                    name: source.name,
                    bundleIdentifier: source.bundleIdentifier,
                    url: source.applicationURL ?? source.profileRoot,
                    teamIdentifier: nil,
                    developerName: nil
                )

                result.items.append(
                    ManagedExtension(
                        id: "browser|\(source.bundleIdentifier)|\(profileDisplayName(profile, source: source))|\(extensionID)",
                        name: name,
                        identifier: extensionID,
                        version: version,
                        kind: .browserExtension,
                        state: state,
                        scope: .user,
                        url: versionURL,
                        owner: owner,
                        teamIdentifier: nil,
                        developerName: nil,
                        profileName: profileDisplayName(profile, source: source),
                        permissionCount: browserPermissionCount(manifest),
                        evidence: evidence,
                        management: .browser(
                            bundleIdentifier: source.bundleIdentifier,
                            applicationURL: source.applicationURL,
                            page: source.managementPage
                        )
                    )
                )
            }
        }

        return result
    }

    private static func scanFirefoxSource(
        _ source: BrowserExtensionSource,
        fileManager: FileManager
    ) -> BrowserScanResult {
        var result = BrowserScanResult()
        guard fileManager.fileExists(atPath: source.profileRoot.path) else {
            return result
        }
        guard isRealDirectory(source.profileRoot),
              let profiles = try? fileManager.contentsOfDirectory(
                at: source.profileRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else {
            result.incomplete = true
            return result
        }

        if profiles.count > maximumProfilesPerBrowser {
            result.incomplete = true
        }
        for profile in profiles.prefix(maximumProfilesPerBrowser) {
            guard isSafeDirectChild(profile, of: source.profileRoot),
                  isRealDirectory(profile) else { continue }
            let extensionsURL = profile.appendingPathComponent("extensions.json")
            guard fileManager.fileExists(atPath: extensionsURL.path) else { continue }
            guard let json = loadJSONObject(
                at: extensionsURL,
                maximumBytes: maximumBrowserJSONBytes,
                fileManager: fileManager,
                containedIn: profile
            ) as? [String: Any],
                  let addOns = json["addons"] as? [[String: Any]] else {
                result.incomplete = true
                continue
            }

            if addOns.count > maximumExtensionsPerProfile {
                result.incomplete = true
            }
            for addOn in addOns.prefix(maximumExtensionsPerProfile) {
                guard let identifier = nonEmptyString(addOn["id"]),
                      isReasonableIdentifier(identifier),
                      (nonEmptyString(addOn["type"]) ?? "extension") == "extension",
                      (addOn["isBuiltin"] as? Bool) != true,
                      (addOn["hidden"] as? Bool) != true,
                      nonEmptyString(addOn["location"]) != "app-system-defaults" else {
                    continue
                }
                let locale = addOn["defaultLocale"] as? [String: Any]
                let name = nonEmptyString(locale?["name"])
                    ?? nonEmptyString(addOn["name"])
                    ?? identifier
                let state: ManagedExtensionState
                if (addOn["active"] as? Bool) == true {
                    state = .enabled
                } else if (addOn["userDisabled"] as? Bool) == true
                            || (addOn["appDisabled"] as? Bool) == true {
                    state = .disabled
                } else {
                    state = .unknown
                }
                let addOnURL = safeFirefoxAddOnURL(
                    nonEmptyString(addOn["path"]),
                    profileURL: profile
                )
                let owner = ExtensionOwnerApp(
                    name: source.name,
                    bundleIdentifier: source.bundleIdentifier,
                    url: source.applicationURL ?? source.profileRoot,
                    teamIdentifier: nil,
                    developerName: nil
                )

                result.items.append(
                    ManagedExtension(
                        id: "browser|\(source.bundleIdentifier)|\(profile.lastPathComponent)|\(identifier)",
                        name: name,
                        identifier: identifier,
                        version: nonEmptyString(addOn["version"]),
                        kind: .browserExtension,
                        state: state,
                        scope: .user,
                        url: addOnURL,
                        owner: owner,
                        teamIdentifier: nil,
                        developerName: nil,
                        profileName: profile.lastPathComponent,
                        permissionCount: firefoxPermissionCount(addOn),
                        evidence: [.browserProfileRegistry, .browserPreference],
                        management: .browser(
                            bundleIdentifier: source.bundleIdentifier,
                            applicationURL: source.applicationURL,
                            page: source.managementPage
                        )
                    )
                )
            }
        }

        return result
    }

    private static func scanFilesystemBundles(
        roots: [FilesystemExtensionRoot],
        ownerApps: [ExtensionOwnerApp],
        fileManager: FileManager
    ) -> FilesystemScanResult {
        var result = FilesystemScanResult()

        for root in roots {
            guard fileManager.fileExists(atPath: root.url.path) else { continue }
            guard isRealDirectory(root.url),
                  let contents = try? fileManager.contentsOfDirectory(
                    at: root.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                result.incomplete = true
                continue
            }
            if contents.count > maximumFilesystemItemsPerRoot {
                result.incomplete = true
            }

            for url in contents.prefix(maximumFilesystemItemsPerRoot) {
                let pathExtension = url.pathExtension.lowercased()
                guard root.pathExtensions.contains(pathExtension),
                      isSafeDirectChild(url, of: root.url),
                      isRealDirectory(url),
                      let info = loadBundleInfo(at: url, fileManager: fileManager),
                      let identifier = info.identifier,
                      !isAppleSystemItem(identifier: identifier, url: url) else {
                    continue
                }
                let owner = owner(for: url, ownerApps: ownerApps)
                let signature = owner == nil
                    ? AppSignatureInspector.inspect(at: url)
                    : .unknown
                var evidence: Set<ManagedExtensionEvidence> = [.filesystemBundle]
                if owner != nil { evidence.insert(.containingApplication) }
                if signature.status == .developerSigned {
                    evidence.insert(.codeSignature)
                }
                if owner?.teamIdentifier != nil {
                    evidence.insert(.ownerCodeSignature)
                }

                result.items.append(
                    ManagedExtension(
                        id: "filesystem|\(identifier)|\(url.path)",
                        name: info.name ?? url.deletingPathExtension().lastPathComponent,
                        identifier: identifier,
                        version: info.version,
                        kind: root.kind,
                        state: .installed,
                        scope: root.scope,
                        url: url,
                        owner: owner,
                        teamIdentifier: signature.teamIdentifier ?? owner?.teamIdentifier,
                        developerName: signature.developerName ?? owner?.developerName,
                        profileName: nil,
                        permissionCount: nil,
                        evidence: evidence,
                        management: .reveal
                    )
                )
            }
        }

        return result
    }

    private static func chromiumExtensionSettings(
        profileURL: URL,
        fileManager: FileManager
    ) -> (settings: [String: [String: Any]], wasUnreadable: Bool) {
        var settings: [String: [String: Any]] = [:]
        var wasUnreadable = false

        // Current Chromium stores extension state in the integrity-protected
        // Secure Preferences file. Older builds and some Chromium forks keep
        // the same dictionary in Preferences, so merge both without allowing
        // the legacy file to overwrite a protected record.
        for fileName in ["Secure Preferences", "Preferences"] {
            let preferencesURL = profileURL.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: preferencesURL.path) else {
                continue
            }
            guard let json = loadJSONObject(
                at: preferencesURL,
                maximumBytes: maximumBrowserJSONBytes,
                fileManager: fileManager,
                containedIn: profileURL
            ) as? [String: Any] else {
                wasUnreadable = true
                continue
            }
            guard let extensions = json["extensions"] as? [String: Any],
                  let rawSettings = extensions["settings"] as? [String: Any] else {
                continue
            }
            for (identifier, rawValue) in rawSettings where settings[identifier] == nil {
                guard let value = rawValue as? [String: Any] else { continue }
                settings[identifier] = value
            }
        }
        return (settings, wasUnreadable)
    }

    private static func chromiumExtensionState(
        _ settings: [String: Any]?
    ) -> ManagedExtensionState {
        guard let settings else { return .unknown }

        // Chromium's current ExtensionPrefs implementation treats a non-empty
        // disable_reasons list as disabled and an empty/missing list as enabled.
        // Keep support for the legacy integer state used by older forks.
        if settings.keys.contains("disable_reasons") {
            guard let reasons = settings["disable_reasons"] as? [Any] else {
                return .unknown
            }
            return reasons.isEmpty ? .enabled : .disabled
        }
        if let rawState = (settings["state"] as? NSNumber)?.intValue {
            return rawState == 1 ? .enabled : .disabled
        }
        return .enabled
    }

    private static func profileDisplayName(
        _ profileURL: URL,
        source: BrowserExtensionSource
    ) -> String {
        profileURL.standardizedFileURL.path == source.profileRoot.standardizedFileURL.path
            ? "Default"
            : profileURL.lastPathComponent
    }

    private static func newestExtensionVersion(
        at extensionDirectory: URL,
        fileManager: FileManager
    ) -> URL? {
        guard let versions = try? fileManager.contentsOfDirectory(
            at: extensionDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return versions
            .filter {
                isSafeDirectChild($0, of: extensionDirectory)
                    && isRealDirectory($0)
                    && isSafeRegularFile(
                        $0.appendingPathComponent("manifest.json"),
                        containedIn: $0
                    )
            }
            .max {
                $0.lastPathComponent.compare(
                    $1.lastPathComponent,
                    options: [.numeric, .caseInsensitive]
                ) == .orderedAscending
            }
    }

    private static func resolvedChromiumName(
        manifest: [String: Any],
        versionURL: URL,
        fileManager: FileManager
    ) -> String? {
        guard let rawName = nonEmptyString(manifest["name"]) else { return nil }
        guard rawName.hasPrefix("__MSG_"), rawName.hasSuffix("__") else {
            return rawName
        }
        let key = String(rawName.dropFirst(6).dropLast(2))
        guard isReasonableLocaleKey(key),
              let locale = nonEmptyString(manifest["default_locale"]),
              isReasonableLocaleKey(locale) else {
            return rawName
        }
        let messagesURL = versionURL
            .appendingPathComponent("_locales", isDirectory: true)
            .appendingPathComponent(locale, isDirectory: true)
            .appendingPathComponent("messages.json")
        guard messagesURL.standardizedFileURL.path.hasPrefix(
            versionURL.standardizedFileURL.path + "/"
        ),
              let messages = loadJSONObject(
                at: messagesURL,
                maximumBytes: maximumBundleInfoBytes,
                fileManager: fileManager,
                containedIn: versionURL
              ) as? [String: Any],
              let record = (messages[key] as? [String: Any])
                ?? messages.first(where: {
                    $0.key.caseInsensitiveCompare(key) == .orderedSame
                })?.value as? [String: Any],
              let message = nonEmptyString(record["message"]) else {
            return rawName
        }
        return message
    }

    private static func browserPermissionCount(_ manifest: [String: Any]) -> Int? {
        let permissions = (manifest["permissions"] as? [Any] ?? [])
            + (manifest["host_permissions"] as? [Any] ?? [])
            + (manifest["optional_permissions"] as? [Any] ?? [])
            + (manifest["optional_host_permissions"] as? [Any] ?? [])
        let count = min(permissions.count, 512)
        return count == 0 ? nil : count
    }

    private static func firefoxPermissionCount(_ addOn: [String: Any]) -> Int? {
        guard let permissions = addOn["userPermissions"] as? [String: Any] else {
            return nil
        }
        let count = min(
            (permissions["permissions"] as? [Any] ?? []).count
                + (permissions["origins"] as? [Any] ?? []).count,
            512
        )
        return count == 0 ? nil : count
    }

    private static func safeFirefoxAddOnURL(
        _ rawPath: String?,
        profileURL: URL
    ) -> URL? {
        guard let rawPath else { return nil }
        let url = rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath).standardizedFileURL
            : profileURL.appendingPathComponent(rawPath).standardizedFileURL
        let profilePath = profileURL.standardizedFileURL.path
        let resolvedProfilePath = profileURL.standardizedFileURL
            .resolvingSymlinksInPath().path
        let resolvedPath = url.resolvingSymlinksInPath().path
        guard (url.path == profilePath || url.path.hasPrefix(profilePath + "/")),
              (resolvedPath == resolvedProfilePath
                || resolvedPath.hasPrefix(resolvedProfilePath + "/")) else {
            return nil
        }
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) != S_IFLNK else { return nil }
        return url
    }

    private static func loadBundleInfo(
        at url: URL,
        fileManager: FileManager
    ) -> BundleInfo? {
        let candidates = [
            url.appendingPathComponent("Contents/Info.plist"),
            url.appendingPathComponent("Resources/Info.plist"),
            url.appendingPathComponent("Versions/Current/Resources/Info.plist"),
            url.appendingPathComponent("Info.plist"),
        ]
        for plistURL in candidates {
            guard let dictionary = loadPropertyListDictionary(
                at: plistURL,
                maximumBytes: maximumBundleInfoBytes,
                fileManager: fileManager,
                containedIn: url
            ) else { continue }
            let extensionDictionary = dictionary["NSExtension"] as? [String: Any]
            return BundleInfo(
                name: nonEmptyString(dictionary["CFBundleDisplayName"])
                    ?? nonEmptyString(dictionary["CFBundleName"]),
                identifier: nonEmptyString(dictionary["CFBundleIdentifier"]),
                version: nonEmptyString(dictionary["CFBundleShortVersionString"])
                    ?? nonEmptyString(dictionary["CFBundleVersion"]),
                packageType: nonEmptyString(dictionary["CFBundlePackageType"]),
                extensionPointIdentifier: nonEmptyString(
                    extensionDictionary?["NSExtensionPointIdentifier"]
                )
            )
        }
        return nil
    }

    private static func loadPropertyListDictionary(
        at url: URL,
        maximumBytes: Int,
        fileManager: FileManager,
        containedIn rootURL: URL
    ) -> [String: Any]? {
        guard isSafeRegularFile(url, containedIn: rootURL),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0,
              size <= maximumBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maximumBytes,
              let value = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return nil
        }
        return value
    }

    private static func loadJSONObject(
        at url: URL,
        maximumBytes: Int,
        fileManager: FileManager,
        containedIn rootURL: URL
    ) -> Any? {
        guard isSafeRegularFile(url, containedIn: rootURL),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0,
              size <= maximumBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maximumBytes else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func isSafeRegularFile(
        _ url: URL,
        containedIn rootURL: URL
    ) -> Bool {
        let standardized = url.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath()
        let resolvedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(resolvedRoot.path + "/") else {
            return false
        }

        var info = stat()
        guard lstat(standardized.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func owner(
        for url: URL,
        ownerApps: [ExtensionOwnerApp]
    ) -> ExtensionOwnerApp? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return ownerApps
            .filter {
                let ownerPath = $0.url.standardizedFileURL
                    .resolvingSymlinksInPath().path
                return path == ownerPath || path.hasPrefix(ownerPath + "/")
            }
            .max {
                $0.url.path.count < $1.url.path.count
            }
    }

    private static func containingApplicationOwner(
        for url: URL,
        fileManager: FileManager
    ) -> ExtensionOwnerApp? {
        let components = url.standardizedFileURL.pathComponents
        guard let appIndex = components.lastIndex(where: {
            ($0 as NSString).pathExtension.caseInsensitiveCompare("app") == .orderedSame
        }) else { return nil }
        let appPath = NSString.path(withComponents: Array(components[...appIndex]))
        let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
        guard isRealDirectory(appURL),
              let info = loadBundleInfo(at: appURL, fileManager: fileManager),
              let identifier = info.identifier else { return nil }
        let signature = AppSignatureInspector.inspect(at: appURL)
        return ExtensionOwnerApp(
            name: info.name ?? appURL.deletingPathExtension().lastPathComponent,
            bundleIdentifier: identifier,
            url: appURL,
            teamIdentifier: signature.teamIdentifier,
            developerName: signature.developerName
        )
    }

    private static func embeddedSystemExtensionOwners(
        ownerApps: [ExtensionOwnerApp],
        fileManager: FileManager
    ) -> [String: ExtensionOwnerApp] {
        var matches: [String: [ExtensionOwnerApp]] = [:]

        for owner in ownerApps {
            let root = owner.url.appendingPathComponent(
                "Contents/Library/SystemExtensions",
                isDirectory: true
            )
            guard isRealDirectory(root),
                  let contents = try? fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            for url in contents.prefix(maximumEmbeddedSystemExtensionsPerApp) {
                guard url.pathExtension.caseInsensitiveCompare("systemextension") == .orderedSame,
                      isSafeDirectChild(url, of: root),
                      isRealDirectory(url),
                      let identifier = loadBundleInfo(
                        at: url,
                        fileManager: fileManager
                      )?.identifier else {
                    continue
                }
                matches[identifier, default: []].append(owner)
            }
        }

        return matches.reduce(into: [String: ExtensionOwnerApp]()) {
            guard $1.value.count == 1 else { return }
            $0[$1.key] = $1.value[0]
        }
    }

    private static func kindForAppExtension(
        extensionPointIdentifier: String?,
        identifier: String,
        path: String
    ) -> ManagedExtensionKind {
        let value = [extensionPointIdentifier, identifier, path]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if value.contains("safari") || value.contains("content-blocker") {
            return .browserExtension
        }
        if value.contains("findersync") || value.contains("finder-sync") {
            return .finderExtension
        }
        if value.contains("share") {
            return .shareExtension
        }
        if value.contains("widget") {
            return .widget
        }
        if value.contains("quicklook") || value.contains("thumbnail")
            || value.contains("preview") {
            return .quickLook
        }
        return .appExtension
    }

    private static func parseIdentifierAndVersion(
        _ value: String
    ) -> (identifier: String, version: String?)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.lastIndex(of: "("), trimmed.hasSuffix(")") else {
            return nil
        }
        let identifier = String(trimmed[..<open])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let versionStart = trimmed.index(after: open)
        let versionEnd = trimmed.index(before: trimmed.endIndex)
        let rawVersion = String(trimmed[versionStart..<versionEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isReasonableIdentifier(identifier) else { return nil }
        let version = rawVersion == "(null)" || rawVersion == "null"
            ? nil
            : rawVersion.split(separator: "/", maxSplits: 1).first.map(String.init)
        return (identifier, version)
    }

    private static func systemCategoryName(_ rawValue: String) -> String {
        switch rawValue {
        case "com.apple.system_extension.network_extension": return "Network"
        case "com.apple.system_extension.driver_extension": return "Driver"
        case "com.apple.system_extension.endpoint_security": return "Endpoint Security"
        case "com.apple.system_extension.cmio": return "Camera"
        default: return "System"
        }
    }

    private static func isAppleSystemItem(identifier: String, url: URL) -> Bool {
        identifier.hasPrefix("com.apple.")
            || url.path.hasPrefix("/System/")
            || url.path.hasPrefix("/System/Volumes/Preboot/")
    }

    private static func isReasonableIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || [".", "-", "_", "@", "{", "}"].contains(Character(String($0)))
        }
    }

    private static func isReasonableLocaleKey(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || ["-", "_"].contains(Character(String($0)))
        }
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            return false
        }
        return true
    }

    private static func isSafeDirectChild(_ url: URL, of parent: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let directParent = standardized.deletingLastPathComponent()
        let expectedParent = parent.standardizedFileURL
        let pathMatches = directParent.path == expectedParent.path
            || directParent.resolvingSymlinksInPath().path
                == expectedParent.resolvingSymlinksInPath().path
        guard pathMatches else { return false }
        var info = stat()
        guard lstat(standardized.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) != S_IFLNK
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 8_192 else { return nil }
        return trimmed
    }

    private static func extensionSort(
        _ lhs: ManagedExtension,
        _ rhs: ManagedExtension
    ) -> Bool {
        let lhsOrder = kindSortOrder(lhs.kind)
        let rhsOrder = kindSortOrder(rhs.kind)
        if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if comparison == .orderedSame { return lhs.id < rhs.id }
        return comparison == .orderedAscending
    }

    private static func kindSortOrder(_ kind: ManagedExtensionKind) -> Int {
        switch kind {
        case .systemExtension: return 0
        case .browserExtension: return 1
        case .finderExtension: return 2
        case .shareExtension: return 3
        case .widget: return 4
        case .appExtension: return 5
        case .preferencePane: return 6
        case .screenSaver: return 7
        case .quickLook: return 8
        case .legacyPlugin: return 9
        case .kernelExtension: return 10
        }
    }

    private static func runCommand(
        executable: String,
        arguments: [String]
    ) -> ManagedExtensionCommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let box = ProcessOutputBox()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            box.append(
                handle.availableData,
                limit: maximumCommandOutputBytes
            )
        }
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return ManagedExtensionCommandOutput(output: nil, incomplete: true)
        }

        let timedOut = terminated.wait(timeout: .now() + commandTimeout) == .timedOut
        if timedOut, process.isRunning {
            process.terminate()
            _ = terminated.wait(timeout: .now() + 2)
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        box.append(
            pipe.fileHandleForReading.readDataToEndOfFile(),
            limit: maximumCommandOutputBytes
        )
        let snapshot = box.snapshot()
        let output = String(data: snapshot.0, encoding: .utf8)
        let failed = process.isRunning || process.terminationStatus != 0
        return ManagedExtensionCommandOutput(
            output: output,
            incomplete: timedOut || snapshot.1 || failed
        )
    }
}
