import Foundation
import CoreServices
import CryptoKit
import Darwin
import Sparkle

enum AppUpdateStatus: String, Hashable, Sendable {
    case updateAvailable
    case upToDate
    case couldNotCheck
}

enum ElectronUpdateProvider: Hashable, Sendable {
    case generic(baseURL: URL)
    case github(owner: String, repo: String)
}

enum AppUpdateSource: Hashable, Sendable {
    case macAppStore(productIdentifier: Int64?)
    case homebrewCask(token: String, brewExecutable: URL?)
    case sparkle(feedURL: URL?)
    case electronUpdater(provider: ElectronUpdateProvider, channel: String)
}

enum AppUpdateEvidence: String, CaseIterable, Hashable, Sendable {
    case developerSignature
    case macAppStoreReceipt
    case spotlightProductIdentifier
    case appStoreLookupBundleMatch
    case homebrewReceipt
    case homebrewCaskroomArtifact
    case homebrewOutdatedCommand
    case sparkleHTTPSFeed
    case sparkleAppcast
    case electronUpdaterConfiguration
    case squirrelFramework
    case electronUpdateMetadata
    case githubReleaseIdentity
}

enum AppUpdateFailureReason: String, Error, Hashable, Sendable {
    case missingProductIdentifier
    case missingLocalVersion
    case sourceUnavailable
    case networkUnavailable
    case invalidResponse
    case identityMismatch
    case insecureFeed
    case commandFailed
    case sourceChanged
    case stagedRollout
    case incompatibleSystem
}

struct AppUpdateItem: Identifiable, Hashable, Sendable {
    let id: String
    let appName: String
    let bundleIdentifier: String
    let appURL: URL
    let currentVersion: String?
    let currentBuild: String?
    let availableVersion: String?
    let source: AppUpdateSource
    let status: AppUpdateStatus
    let evidence: Set<AppUpdateEvidence>
    let releaseNotesURL: URL?
    let checkedAt: Date
    let failureReason: AppUpdateFailureReason?
    let expectedTeamIdentifier: String?
    let remoteEvidenceSHA256: String?

    func replacing(
        status: AppUpdateStatus,
        availableVersion: String? = nil,
        failureReason: AppUpdateFailureReason? = nil,
        checkedAt: Date = Date()
    ) -> AppUpdateItem {
        AppUpdateItem(
            id: id,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            appURL: appURL,
            currentVersion: availableVersion ?? currentVersion,
            currentBuild: currentBuild,
            availableVersion: status == .updateAvailable ? availableVersion : nil,
            source: source,
            status: status,
            evidence: evidence,
            releaseNotesURL: releaseNotesURL,
            checkedAt: checkedAt,
            failureReason: failureReason,
            expectedTeamIdentifier: expectedTeamIdentifier,
            remoteEvidenceSHA256: remoteEvidenceSHA256
        )
    }
}

struct AppUpdateScanResult: Sendable {
    let items: [AppUpdateItem]
    let unsupportedAppCount: Int
    let checkedAt: Date

    var availableUpdateCount: Int {
        items.count { $0.status == .updateAvailable }
    }
}

struct AppStoreLookupRecord: Hashable, Sendable {
    let productIdentifier: Int64
    let bundleIdentifier: String
    let version: String
    let productURL: URL?
    let releaseNotesURL: URL?
}

struct SparkleAppcastRecord: Hashable, Sendable {
    let version: String
    let displayVersion: String?
    let minimumSystemVersion: String?
    let maximumSystemVersion: String?
    let channel: String?
    let hardwareRequirements: Set<String>
    let releaseNotesURL: URL?
}

struct ElectronUpdateMetadata: Hashable, Sendable {
    let version: String
    let stagingPercentage: Double?
    let minimumSystemVersion: String?
}

struct ElectronGitHubRelease: Hashable, Sendable {
    let tag: String
    let metadataURL: URL
    let releasePageURL: URL
}

struct BrewCommandResult: Sendable {
    let exitCode: Int32?
    let output: Data
    let timedOut: Bool
    let truncated: Bool

    var succeeded: Bool {
        exitCode == 0 && !timedOut && !truncated
    }
}

enum VerifiedAppUpdateAction: Sendable {
    case macAppStore(productIdentifier: Int64)
    case homebrewCask(executable: URL, token: String)
    case sparkle(appURL: URL, feedURL: URL)
    case electronUpdater(appURL: URL, releasePageURL: URL?)
}

enum AppUpdateScanner {
    typealias SignatureInspector = @Sendable (URL) -> AppSignatureMetadata
    typealias HomebrewMetadataProvider = @Sendable ([InstalledApp]) -> [InstalledApp.ID: HomebrewCaskInstallMetadata]
    typealias BrewExecutableProvider = @Sendable (HomebrewCaskInstallMetadata) -> URL?
    typealias AppStoreIdentifierProvider = @Sendable (URL) -> Int64?
    typealias AppStoreLookupProvider = @Sendable ([Int64]) async throws -> Data
    typealias BrewOutdatedProvider = @Sendable (URL, [String]) -> BrewCommandResult
    typealias SparkleFeedProvider = @Sendable (URL) async throws -> Data
    typealias ElectronUpdateDataProvider = @Sendable (URL) async throws -> Data
    typealias ElectronKernelVersionProvider = @Sendable () -> String

    private struct Candidate: Sendable {
        let appID: String
        let appName: String
        let bundleIdentifier: String
        let appURL: URL
        let currentVersion: String?
        let currentBuild: String?
        let source: AppUpdateSource
        let evidence: Set<AppUpdateEvidence>
        let expectedTeamIdentifier: String?
    }

    private struct LocalDiscovery: Sendable {
        let candidates: [Candidate]
        let immediateItems: [AppUpdateItem]
        let unsupportedAppCount: Int
    }

    private static let maximumAppStoreResponseBytes = 4_000_000
    private static let maximumSparkleFeedBytes = 2_000_000
    private static let maximumElectronConfigurationBytes = 64_000
    private static let maximumElectronMetadataBytes = 512_000
    private static let maximumGitHubReleaseAssets = 512
    private static let maximumBrewOutputBytes = 2_000_000
    private static let maximumAppStoreIdentifiers = 200
    private static let maximumSparkleItems = 500
    private static let networkTimeout: TimeInterval = 12
    private static let brewQueryTimeout: TimeInterval = 120
    private static let brewUpgradeTimeout: TimeInterval = 15 * 60

    static func scan(
        apps: [InstalledApp],
        signatureInspector: @escaping SignatureInspector = { AppSignatureInspector.inspect(at: $0) },
        homebrewMetadataProvider: @escaping HomebrewMetadataProvider = { apps in
            AppInstallationInspector.verifiedHomebrewCasks(
                for: apps,
                shouldCancel: { Task.isCancelled }
            )
        },
        brewExecutableProvider: @escaping BrewExecutableProvider = { metadata in
            brewExecutable(for: metadata)
        },
        appStoreIdentifierProvider: @escaping AppStoreIdentifierProvider = { url in
            appStoreProductIdentifier(for: url)
        },
        appStoreLookupProvider: @escaping AppStoreLookupProvider = { identifiers in
            try await fetchAppStoreLookup(identifiers)
        },
        brewOutdatedProvider: @escaping BrewOutdatedProvider = { executable, tokens in
            queryHomebrewOutdated(executable: executable, tokens: tokens)
        },
        sparkleFeedProvider: @escaping SparkleFeedProvider = { url in
            try await fetchSparkleFeed(url)
        },
        electronUpdateDataProvider: @escaping ElectronUpdateDataProvider = { url in
            try await fetchElectronUpdateData(url)
        },
        electronKernelVersionProvider: @escaping ElectronKernelVersionProvider = {
            currentDarwinKernelVersion()
        }
    ) async -> AppUpdateScanResult {
        let checkedAt = Date()
        let discovery = await Task.detached(priority: .userInitiated) {
            discoverLocalCandidates(
                apps: apps,
                checkedAt: checkedAt,
                signatureInspector: signatureInspector,
                homebrewMetadataProvider: homebrewMetadataProvider,
                brewExecutableProvider: brewExecutableProvider,
                appStoreIdentifierProvider: appStoreIdentifierProvider
            )
        }.value

        guard !Task.isCancelled else {
            return AppUpdateScanResult(
                items: discovery.immediateItems,
                unsupportedAppCount: discovery.unsupportedAppCount,
                checkedAt: checkedAt
            )
        }

        let appStoreCandidates = discovery.candidates.filter {
            if case .macAppStore = $0.source { return true }
            return false
        }
        let homebrewCandidates = discovery.candidates.filter {
            if case .homebrewCask = $0.source { return true }
            return false
        }
        let sparkleCandidates = discovery.candidates.filter {
            if case .sparkle = $0.source { return true }
            return false
        }
        let electronCandidates = discovery.candidates.filter {
            if case .electronUpdater = $0.source { return true }
            return false
        }

        async let appStoreItems = resolveAppStoreCandidates(
            appStoreCandidates,
            checkedAt: checkedAt,
            lookupProvider: appStoreLookupProvider
        )
        async let homebrewItems = resolveHomebrewCandidates(
            homebrewCandidates,
            checkedAt: checkedAt,
            outdatedProvider: brewOutdatedProvider
        )
        async let sparkleItems = resolveSparkleCandidates(
            sparkleCandidates,
            checkedAt: checkedAt,
            feedProvider: sparkleFeedProvider
        )
        async let electronItems = resolveElectronCandidates(
            electronCandidates,
            checkedAt: checkedAt,
            dataProvider: electronUpdateDataProvider,
            currentKernelVersion: electronKernelVersionProvider()
        )

        let resolved = await appStoreItems + homebrewItems + sparkleItems + electronItems
        let items = (discovery.immediateItems + resolved).sorted {
            if $0.status != $1.status {
                return statusSortOrder($0.status) < statusSortOrder($1.status)
            }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
        return AppUpdateScanResult(
            items: items,
            unsupportedAppCount: discovery.unsupportedAppCount,
            checkedAt: checkedAt
        )
    }

    static func appStoreProductIdentifier(for appURL: URL) -> Int64? {
        guard let item = MDItemCreate(kCFAllocatorDefault, appURL.path as CFString),
              let value = MDItemCopyAttribute(
                item,
                "kMDItemAppStoreAdamID" as CFString
              ) else {
            return nil
        }
        if let number = value as? NSNumber {
            let result = number.int64Value
            return result > 0 ? result : nil
        }
        if let string = value as? String,
           let result = Int64(string),
           result > 0 {
            return result
        }
        return nil
    }

    static func parseAppStoreLookup(_ data: Data) -> [Int64: AppStoreLookupRecord]? {
        guard data.count <= maximumAppStoreResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawResults = object["results"] as? [[String: Any]] else { return nil }

        var records: [Int64: AppStoreLookupRecord] = [:]
        for raw in rawResults.prefix(maximumAppStoreIdentifiers) {
            guard let productIdentifier = (raw["trackId"] as? NSNumber)?.int64Value,
                  productIdentifier > 0,
                  let bundleIdentifier = bounded(raw["bundleId"] as? String, maximum: 2_048),
                  let version = bounded(raw["version"] as? String, maximum: 256) else { continue }
            let productURL = validatedAppleProductURL(raw["trackViewUrl"] as? String)
            // Apple Lookup exposes release notes as text rather than a stable
            // notes URL. The product page is the only external link retained.
            records[productIdentifier] = AppStoreLookupRecord(
                productIdentifier: productIdentifier,
                bundleIdentifier: bundleIdentifier,
                version: version,
                productURL: productURL,
                releaseNotesURL: productURL
            )
        }
        return records
    }

    static func parseHomebrewOutdated(
        _ data: Data,
        requestedTokens: Set<String>
    ) -> [String: String]? {
        guard data.count <= maximumBrewOutputBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = object["casks"] as? [[String: Any]] else { return nil }

        var outdated: [String: String] = [:]
        for cask in casks.prefix(requestedTokens.count + 32) {
            let token = bounded(cask["name"] as? String, maximum: 256)
                ?? bounded(cask["token"] as? String, maximum: 256)
            guard let token, requestedTokens.contains(token) else { continue }
            let version = bounded(cask["current_version"] as? String, maximum: 256)
                ?? bounded(cask["version"] as? String, maximum: 256)
                ?? ""
            outdated[token] = version
        }
        return outdated
    }

    static func parseSparkleAppcast(_ data: Data) -> [SparkleAppcastRecord]? {
        guard !data.isEmpty, data.count <= maximumSparkleFeedBytes else { return nil }
        let delegate = SparkleXMLDelegate(maximumItems: maximumSparkleItems)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.error == nil, !delegate.items.isEmpty else { return nil }
        return delegate.items
    }

    static func parseElectronUpdateMetadata(_ data: Data) -> ElectronUpdateMetadata? {
        guard !data.isEmpty,
              data.count <= maximumElectronMetadataBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }

        var version: String?
        var path: String?
        var checksum: String?
        var stagingPercentage: Double?
        var minimumSystemVersion: String?
        var inFiles = false
        var currentFileURL: String?
        var currentFileChecksum: String?
        var hasVerifiedZip = false
        var topLevelKeys: Set<String> = []
        let recognizedTopLevelKeys: Set<String> = [
            "files", "version", "path", "sha512",
            "stagingPercentage", "minimumSystemVersion",
        ]

        func finishFile() -> Bool {
            guard let currentFileURL,
                  isElectronZipAsset(currentFileURL),
                  isSafeElectronChecksum(currentFileChecksum) else { return false }
            return true
        }

        for rawLine in text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \Character.isNewline
        ) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            if inFiles, trimmed.hasPrefix("- url:") {
                hasVerifiedZip = hasVerifiedZip || finishFile()
                currentFileURL = yamlScalar(String(trimmed.dropFirst("- url:".count)))
                currentFileChecksum = nil
                continue
            }
            if inFiles, trimmed.hasPrefix("url:") {
                currentFileURL = yamlScalar(String(trimmed.dropFirst("url:".count)))
                continue
            }
            if inFiles, trimmed.hasPrefix("sha512:") {
                currentFileChecksum = yamlScalar(String(trimmed.dropFirst("sha512:".count)))
                continue
            }

            guard line.first?.isWhitespace != true,
                  let separator = line.firstIndex(of: ":") else { continue }
            hasVerifiedZip = hasVerifiedZip || finishFile()
            currentFileURL = nil
            currentFileChecksum = nil

            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: separator)...])
            if recognizedTopLevelKeys.contains(key),
               !topLevelKeys.insert(key).inserted {
                return nil
            }
            switch key {
            case "files":
                inFiles = true
            case "version":
                inFiles = false
                version = yamlScalar(rawValue)
            case "path":
                inFiles = false
                path = yamlScalar(rawValue)
            case "sha512":
                inFiles = false
                checksum = yamlScalar(rawValue)
            case "stagingPercentage":
                inFiles = false
                guard let raw = yamlScalar(rawValue),
                      let value = Double(raw),
                      value.isFinite,
                      (0...100).contains(value) else { return nil }
                stagingPercentage = value
            case "minimumSystemVersion":
                inFiles = false
                guard let value = bounded(yamlScalar(rawValue), maximum: 256),
                      isSafeDottedVersion(value) else { return nil }
                minimumSystemVersion = value
            default:
                inFiles = false
            }
        }
        hasVerifiedZip = hasVerifiedZip || finishFile()

        if let path,
           isElectronZipAsset(path),
           isSafeElectronChecksum(checksum) {
            hasVerifiedZip = true
        }

        guard let version = bounded(version, maximum: 256), hasVerifiedZip else { return nil }
        return ElectronUpdateMetadata(
            version: version,
            stagingPercentage: stagingPercentage,
            minimumSystemVersion: minimumSystemVersion
        )
    }

    static func parseElectronGitHubRelease(
        _ data: Data,
        owner: String,
        repo: String,
        channel: String
    ) -> ElectronGitHubRelease? {
        guard !data.isEmpty,
              data.count <= maximumElectronMetadataBytes,
              isSafeGitHubOwner(owner),
              isSafeGitHubRepo(repo),
              channel == "latest",
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["draft"] as? Bool == false,
              object["prerelease"] as? Bool == false,
              let tag = bounded(object["tag_name"] as? String, maximum: 256),
              isSafeGitHubTag(tag),
              let rawPageURL = bounded(object["html_url"] as? String, maximum: 2_048),
              let releasePageURL = URL(string: rawPageURL),
              isExpectedGitHubReleasePage(
                releasePageURL,
                owner: owner,
                repo: repo,
                tag: tag
              ),
              let assets = object["assets"] as? [[String: Any]],
              assets.count <= maximumGitHubReleaseAssets else { return nil }

        let expectedAssetName = "\(channel)-mac.yml"
        let matchingAssets = assets.compactMap { asset -> URL? in
            guard asset["name"] as? String == expectedAssetName,
                  let rawURL = bounded(
                    asset["browser_download_url"] as? String,
                    maximum: 4_096
                  ),
                  let url = URL(string: rawURL),
                  isExpectedGitHubReleaseAsset(
                    url,
                    owner: owner,
                    repo: repo,
                    tag: tag,
                    assetName: expectedAssetName
                  ) else { return nil }
            return url
        }
        guard matchingAssets.count == 1, let metadataURL = matchingAssets.first else { return nil }
        return ElectronGitHubRelease(
            tag: tag,
            metadataURL: metadataURL,
            releasePageURL: releasePageURL
        )
    }

    static func verifyAction(
        item: AppUpdateItem,
        app: InstalledApp,
        signatureInspector: SignatureInspector = { AppSignatureInspector.inspect(at: $0) },
        appStoreIdentifierProvider: AppStoreIdentifierProvider = { url in
            appStoreProductIdentifier(for: url)
        }
    ) -> Result<VerifiedAppUpdateAction, AppUpdateFailureReason> {
        guard item.id == app.id,
              item.bundleIdentifier == app.bundleIdentifier,
              item.appURL.standardizedFileURL.path == app.path.standardizedFileURL.path,
              FileManager.default.fileExists(atPath: app.path.path) else {
            return .failure(.sourceChanged)
        }

        let refreshed = app.replacingSignature(signatureInspector(app.path))
        switch item.source {
        case .macAppStore(let expectedProductIdentifier):
            guard let expectedProductIdentifier,
                  AppInstallationInspector.hasVerifiedMacAppStoreReceipt(for: refreshed),
                  appStoreIdentifierProvider(app.path) == expectedProductIdentifier else {
                return .failure(.sourceChanged)
            }
            return .success(.macAppStore(productIdentifier: expectedProductIdentifier))

        case .homebrewCask(let expectedToken, let expectedExecutable):
            let insights = AppInstallationInspector.inspect(app: refreshed)
            guard case .homebrewCask(let metadata) = insights.source,
                  metadata.token == expectedToken,
                  let executable = brewExecutable(for: metadata),
                  executable.standardizedFileURL.path == expectedExecutable?.standardizedFileURL.path else {
                return .failure(.sourceChanged)
            }
            return .success(.homebrewCask(executable: executable, token: expectedToken))

        case .sparkle(let expectedFeedURL):
            guard refreshed.signature.status == .developerSigned,
                  refreshed.signature.teamIdentifier == item.expectedTeamIdentifier,
                  let expectedFeedURL,
                  let currentFeedURL = sparkleFeedURL(for: app.path),
                  currentFeedURL == expectedFeedURL,
                  isAllowedPublicHTTPSURL(currentFeedURL) else {
                return .failure(.sourceChanged)
            }
            return .success(.sparkle(appURL: app.path, feedURL: currentFeedURL))

        case .electronUpdater(let provider, _):
            guard refreshed.signature.status == .developerSigned,
                  refreshed.signature.teamIdentifier == item.expectedTeamIdentifier,
                  electronUpdateSource(for: app.path) == item.source else {
                return .failure(.sourceChanged)
            }
            if case .github(let owner, let repo) = provider {
                guard let releasePageURL = item.releaseNotesURL,
                      isExpectedGitHubReleasePage(
                        releasePageURL,
                        owner: owner,
                        repo: repo,
                        tag: nil
                      ) else {
                    return .failure(.sourceChanged)
                }
            } else if item.releaseNotesURL != nil {
                return .failure(.sourceChanged)
            }
            return .success(
                .electronUpdater(appURL: app.path, releasePageURL: item.releaseNotesURL)
            )
        }
    }

    static func verifyActionAtClick(
        item: AppUpdateItem,
        app: InstalledApp,
        signatureInspector: SignatureInspector = {
            AppSignatureInspector.inspect(at: $0)
        },
        appStoreIdentifierProvider: AppStoreIdentifierProvider = { url in
            appStoreProductIdentifier(for: url)
        },
        electronUpdateDataProvider: @escaping ElectronUpdateDataProvider = { url in
            try await fetchElectronUpdateData(url)
        },
        electronKernelVersionProvider: ElectronKernelVersionProvider = {
            currentDarwinKernelVersion()
        }
    ) async -> Result<VerifiedAppUpdateAction, AppUpdateFailureReason> {
        let localVerification = verifyAction(
            item: item,
            app: app,
            signatureInspector: signatureInspector,
            appStoreIdentifierProvider: appStoreIdentifierProvider
        )
        guard case .success(let localAction) = localVerification,
              case .electronUpdater(let provider, let channel) = item.source else {
            return localVerification
        }
        guard item.status == .updateAvailable,
              let expectedVersion = item.availableVersion,
              let currentVersion = item.currentVersion,
              let expectedEvidenceSHA256 = item.remoteEvidenceSHA256 else {
            return .failure(.sourceChanged)
        }

        do {
            let metadataURL: URL
            let releasePageURL: URL?
            var releaseIdentityData: Data?
            switch provider {
            case .generic(let baseURL):
                guard item.releaseNotesURL == nil,
                      let url = electronMetadataURL(
                        baseURL: baseURL,
                        channel: channel
                      ) else {
                    return .failure(.sourceChanged)
                }
                metadataURL = url
                releasePageURL = nil

            case .github(let owner, let repo):
                guard let releaseURL = electronGitHubLatestReleaseURL(
                    owner: owner,
                    repo: repo,
                    channel: channel
                ) else {
                    return .failure(.sourceChanged)
                }
                let releaseData = try await electronUpdateDataProvider(releaseURL)
                guard let release = parseElectronGitHubRelease(
                    releaseData,
                    owner: owner,
                    repo: repo,
                    channel: channel
                ), release.releasePageURL == item.releaseNotesURL else {
                    return .failure(.sourceChanged)
                }
                metadataURL = release.metadataURL
                releasePageURL = release.releasePageURL
                releaseIdentityData = releaseData
            }

            let metadataData = try await electronUpdateDataProvider(metadataURL)
            guard electronUpdateEvidenceSHA256(
                releaseIdentityData: releaseIdentityData,
                metadataData: metadataData
            ) == expectedEvidenceSHA256,
            let metadata = parseElectronUpdateMetadata(metadataData),
            metadata.version == expectedVersion,
            electronCompatibilityFailure(
                metadata,
                currentKernelVersion: electronKernelVersionProvider()
            ) == nil,
            compareVersion(metadata.version, isNewerThan: currentVersion) else {
                return .failure(.sourceChanged)
            }

            switch localAction {
            case .electronUpdater(let appURL, _):
                return .success(
                    .electronUpdater(
                        appURL: appURL,
                        releasePageURL: releasePageURL
                    )
                )
            default:
                return .failure(.sourceChanged)
            }
        } catch {
            return .failure(.networkUnavailable)
        }
    }

    static func runHomebrewUpgrade(executable: URL, token: String) -> BrewCommandResult {
        guard isSafeCaskToken(token), isAllowedBrewExecutable(executable) else {
            return BrewCommandResult(
                exitCode: nil,
                output: Data(),
                timedOut: false,
                truncated: false
            )
        }
        return runProcess(
            executable: executable,
            arguments: ["upgrade", "--cask", token],
            environment: [
                "HOMEBREW_NO_ANALYTICS": "1",
                "NONINTERACTIVE": "1",
            ],
            timeout: brewUpgradeTimeout,
            maximumOutputBytes: maximumBrewOutputBytes
        )
    }

    private static func discoverLocalCandidates(
        apps: [InstalledApp],
        checkedAt: Date,
        signatureInspector: SignatureInspector,
        homebrewMetadataProvider: HomebrewMetadataProvider,
        brewExecutableProvider: BrewExecutableProvider,
        appStoreIdentifierProvider: AppStoreIdentifierProvider
    ) -> LocalDiscovery {
        let homebrew = homebrewMetadataProvider(apps)
        var candidates: [Candidate] = []
        var immediateItems: [AppUpdateItem] = []
        var unsupportedCount = 0

        for original in apps {
            guard !Task.isCancelled else { break }
            if let metadata = homebrew[original.id] {
                let refreshedSignature = signatureInspector(original.path)
                let executable = brewExecutableProvider(metadata)
                let candidate = Candidate(
                    appID: original.id,
                    appName: original.appName,
                    bundleIdentifier: original.bundleIdentifier,
                    appURL: original.path,
                    currentVersion: metadata.version ?? original.version,
                    currentBuild: original.buildNumber,
                    source: .homebrewCask(token: metadata.token, brewExecutable: executable),
                    evidence: [
                        .developerSignature,
                        .homebrewReceipt,
                        .homebrewCaskroomArtifact,
                    ],
                    expectedTeamIdentifier: refreshedSignature.teamIdentifier
                )
                if executable == nil {
                    immediateItems.append(
                        item(from: candidate, checkedAt: checkedAt, failure: .sourceUnavailable)
                    )
                } else {
                    candidates.append(candidate)
                }
                continue
            }

            let receipt = original.path
                .appendingPathComponent("Contents/_MASReceipt/receipt", isDirectory: false)
            if FileManager.default.fileExists(atPath: receipt.path) {
                let refreshed = original.replacingSignature(signatureInspector(original.path))
                if AppInstallationInspector.hasVerifiedMacAppStoreReceipt(for: refreshed) {
                    let productIdentifier = appStoreIdentifierProvider(original.path)
                    let candidate = Candidate(
                        appID: original.id,
                        appName: original.appName,
                        bundleIdentifier: original.bundleIdentifier,
                        appURL: original.path,
                        currentVersion: original.version,
                        currentBuild: original.buildNumber,
                        source: .macAppStore(productIdentifier: productIdentifier),
                        evidence: productIdentifier == nil
                            ? [.developerSignature, .macAppStoreReceipt]
                            : [.developerSignature, .macAppStoreReceipt, .spotlightProductIdentifier],
                        expectedTeamIdentifier: refreshed.signature.teamIdentifier
                    )
                    if productIdentifier == nil {
                        immediateItems.append(
                            item(from: candidate, checkedAt: checkedAt, failure: .missingProductIdentifier)
                        )
                    } else {
                        candidates.append(candidate)
                    }
                    continue
                }
            }

            if let rawFeed = rawSparkleFeedURL(for: original.path) {
                let refreshedSignature = signatureInspector(original.path)
                guard refreshedSignature.status == .developerSigned else {
                    unsupportedCount += 1
                    continue
                }
                guard let feedURL = URL(string: rawFeed),
                      isAllowedPublicHTTPSURL(feedURL) else {
                    let candidate = Candidate(
                        appID: original.id,
                        appName: original.appName,
                        bundleIdentifier: original.bundleIdentifier,
                        appURL: original.path,
                        currentVersion: original.version,
                        currentBuild: original.buildNumber,
                        source: .sparkle(feedURL: nil),
                        evidence: [.developerSignature],
                        expectedTeamIdentifier: refreshedSignature.teamIdentifier
                    )
                    immediateItems.append(
                        item(from: candidate, checkedAt: checkedAt, failure: .insecureFeed)
                    )
                    continue
                }
                candidates.append(
                    Candidate(
                        appID: original.id,
                        appName: original.appName,
                        bundleIdentifier: original.bundleIdentifier,
                        appURL: original.path,
                        currentVersion: original.version,
                        currentBuild: original.buildNumber,
                        source: .sparkle(feedURL: feedURL),
                        evidence: [.developerSignature, .sparkleHTTPSFeed],
                        expectedTeamIdentifier: refreshedSignature.teamIdentifier
                    )
                )
                continue
            }

            if let electronSource = electronUpdateSource(for: original.path) {
                let refreshedSignature = signatureInspector(original.path)
                guard refreshedSignature.status == .developerSigned else {
                    unsupportedCount += 1
                    continue
                }
                var evidence: Set<AppUpdateEvidence> = [
                    .developerSignature,
                    .electronUpdaterConfiguration,
                ]
                if hasSquirrelFramework(in: original.path) {
                    evidence.insert(.squirrelFramework)
                }
                candidates.append(
                    Candidate(
                        appID: original.id,
                        appName: original.appName,
                        bundleIdentifier: original.bundleIdentifier,
                        appURL: original.path,
                        currentVersion: original.version,
                        currentBuild: original.buildNumber,
                        source: electronSource,
                        evidence: evidence,
                        expectedTeamIdentifier: refreshedSignature.teamIdentifier
                    )
                )
                continue
            }

            unsupportedCount += 1
        }

        return LocalDiscovery(
            candidates: candidates,
            immediateItems: immediateItems,
            unsupportedAppCount: unsupportedCount
        )
    }

    private static func resolveAppStoreCandidates(
        _ candidates: [Candidate],
        checkedAt: Date,
        lookupProvider: AppStoreLookupProvider
    ) async -> [AppUpdateItem] {
        guard !candidates.isEmpty else { return [] }
        let identifiers = candidates.compactMap { candidate -> Int64? in
            guard case .macAppStore(let identifier) = candidate.source else { return nil }
            return identifier
        }
        guard !identifiers.isEmpty else { return [] }

        do {
            let data = try await lookupProvider(Array(Set(identifiers)).sorted())
            guard let records = parseAppStoreLookup(data) else {
                return candidates.map { item(from: $0, checkedAt: checkedAt, failure: .invalidResponse) }
            }
            return candidates.map { candidate in
                guard case .macAppStore(let identifier) = candidate.source,
                      let identifier,
                      let record = records[identifier] else {
                    return item(from: candidate, checkedAt: checkedAt, failure: .invalidResponse)
                }
                guard record.bundleIdentifier == candidate.bundleIdentifier else {
                    return item(from: candidate, checkedAt: checkedAt, failure: .identityMismatch)
                }
                guard let currentVersion = candidate.currentVersion else {
                    return item(from: candidate, checkedAt: checkedAt, failure: .missingLocalVersion)
                }
                let available = compareVersion(record.version, isNewerThan: currentVersion)
                return AppUpdateItem(
                    id: candidate.appID,
                    appName: candidate.appName,
                    bundleIdentifier: candidate.bundleIdentifier,
                    appURL: candidate.appURL,
                    currentVersion: candidate.currentVersion,
                    currentBuild: candidate.currentBuild,
                    availableVersion: available ? record.version : nil,
                    source: candidate.source,
                    status: available ? .updateAvailable : .upToDate,
                    evidence: candidate.evidence.union([.appStoreLookupBundleMatch]),
                    releaseNotesURL: record.releaseNotesURL,
                    checkedAt: checkedAt,
                    failureReason: nil,
                    expectedTeamIdentifier: candidate.expectedTeamIdentifier,
                    remoteEvidenceSHA256: nil
                )
            }
        } catch {
            return candidates.map { item(from: $0, checkedAt: checkedAt, failure: .networkUnavailable) }
        }
    }

    private static func resolveHomebrewCandidates(
        _ candidates: [Candidate],
        checkedAt: Date,
        outdatedProvider: @escaping BrewOutdatedProvider
    ) async -> [AppUpdateItem] {
        guard !candidates.isEmpty else { return [] }
        let grouped = Dictionary(grouping: candidates) { candidate -> String in
            guard case .homebrewCask(_, let executable) = candidate.source else { return "" }
            return executable?.standardizedFileURL.path ?? ""
        }

        return await withTaskGroup(of: [AppUpdateItem].self) { group in
            for (path, groupCandidates) in grouped {
                group.addTask {
                    guard !path.isEmpty else {
                        return groupCandidates.map {
                            item(from: $0, checkedAt: checkedAt, failure: .sourceUnavailable)
                        }
                    }
                    let executable = URL(fileURLWithPath: path)
                    let tokens = groupCandidates.compactMap { candidate -> String? in
                        guard case .homebrewCask(let token, _) = candidate.source else { return nil }
                        return token
                    }
                    let result = outdatedProvider(executable, tokens.sorted())
                    if result.succeeded,
                       let outdated = parseHomebrewOutdated(
                        result.output,
                        requestedTokens: Set(tokens)
                       ) {
                        return groupCandidates.map {
                            homebrewItem(
                                from: $0,
                                availableVersions: outdated,
                                checkedAt: checkedAt
                            )
                        }
                    }

                    guard groupCandidates.count > 1 else {
                        return groupCandidates.map {
                            item(from: $0, checkedAt: checkedAt, failure: .commandFailed)
                        }
                    }

                    return await resolveHomebrewCandidatesIndividually(
                        groupCandidates,
                        executable: executable,
                        checkedAt: checkedAt,
                        outdatedProvider: outdatedProvider
                    )
                }
            }

            var items: [AppUpdateItem] = []
            for await resolved in group {
                items.append(contentsOf: resolved)
            }
            return items
        }
    }

    private static func resolveHomebrewCandidatesIndividually(
        _ candidates: [Candidate],
        executable: URL,
        checkedAt: Date,
        outdatedProvider: @escaping BrewOutdatedProvider
    ) async -> [AppUpdateItem] {
        var items: [AppUpdateItem] = []

        // A broken or untrusted tap must not poison every Cask in the shared
        // batch. Retry at most four independent tokens concurrently.
        for batchStart in stride(from: 0, to: candidates.count, by: 4) {
            guard !Task.isCancelled else { break }
            let batchEnd = min(batchStart + 4, candidates.count)
            let batch = Array(candidates[batchStart..<batchEnd])
            let batchItems = await withTaskGroup(of: AppUpdateItem.self) { group in
                for candidate in batch {
                    group.addTask {
                        guard case .homebrewCask(let token, _) = candidate.source else {
                            return item(
                                from: candidate,
                                checkedAt: checkedAt,
                                failure: .invalidResponse
                            )
                        }
                        let result = outdatedProvider(executable, [token])
                        guard result.succeeded,
                              let outdated = parseHomebrewOutdated(
                                result.output,
                                requestedTokens: [token]
                              ) else {
                            return item(
                                from: candidate,
                                checkedAt: checkedAt,
                                failure: .commandFailed
                            )
                        }
                        return homebrewItem(
                            from: candidate,
                            availableVersions: outdated,
                            checkedAt: checkedAt
                        )
                    }
                }

                var resolved: [AppUpdateItem] = []
                for await item in group {
                    resolved.append(item)
                }
                return resolved
            }
            items.append(contentsOf: batchItems)
        }

        return items
    }

    private static func homebrewItem(
        from candidate: Candidate,
        availableVersions: [String: String],
        checkedAt: Date
    ) -> AppUpdateItem {
        guard case .homebrewCask(let token, _) = candidate.source else {
            return item(from: candidate, checkedAt: checkedAt, failure: .invalidResponse)
        }
        let availableVersion = availableVersions[token]
        return AppUpdateItem(
            id: candidate.appID,
            appName: candidate.appName,
            bundleIdentifier: candidate.bundleIdentifier,
            appURL: candidate.appURL,
            currentVersion: candidate.currentVersion,
            currentBuild: candidate.currentBuild,
            availableVersion: availableVersion?.isEmpty == false ? availableVersion : nil,
            source: candidate.source,
            status: availableVersion == nil ? .upToDate : .updateAvailable,
            evidence: candidate.evidence.union([.homebrewOutdatedCommand]),
            releaseNotesURL: nil,
            checkedAt: checkedAt,
            failureReason: nil,
            expectedTeamIdentifier: candidate.expectedTeamIdentifier,
            remoteEvidenceSHA256: nil
        )
    }

    private static func resolveSparkleCandidates(
        _ candidates: [Candidate],
        checkedAt: Date,
        feedProvider: @escaping SparkleFeedProvider
    ) async -> [AppUpdateItem] {
        guard !candidates.isEmpty else { return [] }
        var results: [AppUpdateItem] = []

        // Four feeds at a time keeps the check responsive without creating a
        // burst of requests on systems with many Sparkle-based apps.
        for batchStart in stride(from: 0, to: candidates.count, by: 4) {
            guard !Task.isCancelled else { break }
            let batchEnd = min(batchStart + 4, candidates.count)
            let batch = Array(candidates[batchStart..<batchEnd])
            let batchItems = await withTaskGroup(of: AppUpdateItem.self) { group in
                for candidate in batch {
                    group.addTask {
                        guard case .sparkle(let feedURL) = candidate.source,
                              let feedURL else {
                            return item(from: candidate, checkedAt: checkedAt, failure: .insecureFeed)
                        }
                        do {
                            let data = try await feedProvider(feedURL)
                            guard let records = parseSparkleAppcast(data) else {
                                return item(from: candidate, checkedAt: checkedAt, failure: .invalidResponse)
                            }
                            guard let currentBuild = candidate.currentBuild ?? candidate.currentVersion else {
                                return item(from: candidate, checkedAt: checkedAt, failure: .missingLocalVersion)
                            }
                            let compatible = records.filter(isCompatibleSparkleItem)
                            let newest = compatible
                                .filter { compareVersion($0.version, isNewerThan: currentBuild) }
                                .max { lhs, rhs in
                                    SUStandardVersionComparator.default.compareVersion(
                                        lhs.version,
                                        toVersion: rhs.version
                                    ) == .orderedAscending
                                }
                            return AppUpdateItem(
                                id: candidate.appID,
                                appName: candidate.appName,
                                bundleIdentifier: candidate.bundleIdentifier,
                                appURL: candidate.appURL,
                                currentVersion: candidate.currentVersion,
                                currentBuild: candidate.currentBuild,
                                availableVersion: newest?.displayVersion ?? newest?.version,
                                source: candidate.source,
                                status: newest == nil ? .upToDate : .updateAvailable,
                                evidence: candidate.evidence.union([.sparkleAppcast]),
                                releaseNotesURL: newest?.releaseNotesURL,
                                checkedAt: checkedAt,
                                failureReason: nil,
                                expectedTeamIdentifier: candidate.expectedTeamIdentifier,
                                remoteEvidenceSHA256: nil
                            )
                        } catch {
                            return item(from: candidate, checkedAt: checkedAt, failure: .networkUnavailable)
                        }
                    }
                }

                var values: [AppUpdateItem] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }
            results.append(contentsOf: batchItems)
        }
        return results
    }

    private static func resolveElectronCandidates(
        _ candidates: [Candidate],
        checkedAt: Date,
        dataProvider: @escaping ElectronUpdateDataProvider,
        currentKernelVersion: String
    ) async -> [AppUpdateItem] {
        guard !candidates.isEmpty else { return [] }
        var results: [AppUpdateItem] = []

        for batchStart in stride(from: 0, to: candidates.count, by: 4) {
            guard !Task.isCancelled else { break }
            let batchEnd = min(batchStart + 4, candidates.count)
            let batch = Array(candidates[batchStart..<batchEnd])
            let batchItems = await withTaskGroup(of: AppUpdateItem.self) { group in
                for candidate in batch {
                    group.addTask {
                        guard case .electronUpdater(let provider, let channel) = candidate.source else {
                            return item(from: candidate, checkedAt: checkedAt, failure: .invalidResponse)
                        }
                        do {
                            let metadataURL: URL
                            let releasePageURL: URL?
                            var releaseIdentityData: Data?
                            var additionalEvidence: Set<AppUpdateEvidence> = []
                            switch provider {
                            case .generic(let baseURL):
                                guard let url = electronMetadataURL(
                                    baseURL: baseURL,
                                    channel: channel
                                ) else {
                                    return item(
                                        from: candidate,
                                        checkedAt: checkedAt,
                                        failure: .sourceUnavailable
                                    )
                                }
                                metadataURL = url
                                releasePageURL = nil

                            case .github(let owner, let repo):
                                guard let releaseURL = electronGitHubLatestReleaseURL(
                                    owner: owner,
                                    repo: repo,
                                    channel: channel
                                ) else {
                                    return item(
                                        from: candidate,
                                        checkedAt: checkedAt,
                                        failure: .sourceUnavailable
                                    )
                                }
                                let releaseData = try await dataProvider(releaseURL)
                                guard let release = parseElectronGitHubRelease(
                                    releaseData,
                                    owner: owner,
                                    repo: repo,
                                    channel: channel
                                ) else {
                                    return item(
                                        from: candidate,
                                        checkedAt: checkedAt,
                                        failure: .invalidResponse
                                    )
                                }
                                metadataURL = release.metadataURL
                                releasePageURL = release.releasePageURL
                                releaseIdentityData = releaseData
                                additionalEvidence.insert(.githubReleaseIdentity)
                            }

                            let data = try await dataProvider(metadataURL)
                            guard let metadata = parseElectronUpdateMetadata(data) else {
                                return item(from: candidate, checkedAt: checkedAt, failure: .invalidResponse)
                            }
                            if let failure = electronCompatibilityFailure(
                                metadata,
                                currentKernelVersion: currentKernelVersion
                            ) {
                                return item(
                                    from: candidate,
                                    checkedAt: checkedAt,
                                    failure: failure
                                )
                            }
                            guard let currentVersion = candidate.currentVersion else {
                                return item(from: candidate, checkedAt: checkedAt, failure: .missingLocalVersion)
                            }
                            let available = compareVersion(
                                metadata.version,
                                isNewerThan: currentVersion
                            )
                            return AppUpdateItem(
                                id: candidate.appID,
                                appName: candidate.appName,
                                bundleIdentifier: candidate.bundleIdentifier,
                                appURL: candidate.appURL,
                                currentVersion: candidate.currentVersion,
                                currentBuild: candidate.currentBuild,
                                availableVersion: available ? metadata.version : nil,
                                source: candidate.source,
                                status: available ? .updateAvailable : .upToDate,
                                evidence: candidate.evidence
                                    .union([.electronUpdateMetadata])
                                    .union(additionalEvidence),
                                releaseNotesURL: releasePageURL,
                                checkedAt: checkedAt,
                                failureReason: nil,
                                expectedTeamIdentifier: candidate.expectedTeamIdentifier,
                                remoteEvidenceSHA256: electronUpdateEvidenceSHA256(
                                    releaseIdentityData: releaseIdentityData,
                                    metadataData: data
                                )
                            )
                        } catch {
                            return item(from: candidate, checkedAt: checkedAt, failure: .networkUnavailable)
                        }
                    }
                }

                var values: [AppUpdateItem] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }
            results.append(contentsOf: batchItems)
        }
        return results
    }

    private static func item(
        from candidate: Candidate,
        checkedAt: Date,
        failure: AppUpdateFailureReason
    ) -> AppUpdateItem {
        AppUpdateItem(
            id: candidate.appID,
            appName: candidate.appName,
            bundleIdentifier: candidate.bundleIdentifier,
            appURL: candidate.appURL,
            currentVersion: candidate.currentVersion,
            currentBuild: candidate.currentBuild,
            availableVersion: nil,
            source: candidate.source,
            status: .couldNotCheck,
            evidence: candidate.evidence,
            releaseNotesURL: nil,
            checkedAt: checkedAt,
            failureReason: failure,
            expectedTeamIdentifier: candidate.expectedTeamIdentifier,
            remoteEvidenceSHA256: nil
        )
    }

    private static func fetchAppStoreLookup(_ identifiers: [Int64]) async throws -> Data {
        let boundedIdentifiers = Array(identifiers.filter { $0 > 0 }.prefix(maximumAppStoreIdentifiers))
        guard !boundedIdentifiers.isEmpty else { throw AppUpdateNetworkError.invalidURL }
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "id", value: boundedIdentifiers.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "entity", value: "macSoftware"),
        ]
        guard let url = components?.url else { throw AppUpdateNetworkError.invalidURL }
        return try await BoundedHTTPSClient.load(
            url,
            maximumBytes: maximumAppStoreResponseBytes,
            timeout: networkTimeout
        )
    }

    private static func fetchSparkleFeed(_ url: URL) async throws -> Data {
        try await BoundedHTTPSClient.load(
            url,
            maximumBytes: maximumSparkleFeedBytes,
            timeout: networkTimeout
        )
    }

    private static func fetchElectronUpdateData(_ url: URL) async throws -> Data {
        let headers: [String: String]
        if url.host?.lowercased() == "api.github.com" {
            headers = [
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "AppSift-AppUpdateScanner",
            ]
        } else {
            headers = [
                "Accept": "application/json, application/yaml, text/yaml, text/plain",
            ]
        }
        return try await BoundedHTTPSClient.load(
            url,
            maximumBytes: maximumElectronMetadataBytes,
            timeout: networkTimeout,
            headers: headers
        )
    }

    private static func queryHomebrewOutdated(
        executable: URL,
        tokens: [String]
    ) -> BrewCommandResult {
        guard isAllowedBrewExecutable(executable),
              !tokens.isEmpty,
              tokens.count <= 512,
              tokens.allSatisfy(isSafeCaskToken) else {
            return BrewCommandResult(
                exitCode: nil,
                output: Data(),
                timedOut: false,
                truncated: false
            )
        }
        return runProcess(
            executable: executable,
            arguments: ["outdated", "--cask", "--greedy", "--json=v2"] + tokens,
            environment: [
                "HOMEBREW_NO_AUTO_UPDATE": "1",
                "HOMEBREW_NO_ANALYTICS": "1",
                "NONINTERACTIVE": "1",
            ],
            timeout: brewQueryTimeout,
            maximumOutputBytes: maximumBrewOutputBytes
        )
    }

    private static func runProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) -> BrewCommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let output = LimitedProcessOutput(maximumBytes: maximumOutputBytes)
        let readerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { break }
                output.append(chunk)
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
            return BrewCommandResult(
                exitCode: nil,
                output: Data(),
                timedOut: false,
                truncated: false
            )
        }

        var timedOut = false
        if terminated.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if terminated.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1)
            }
        }
        pipe.fileHandleForWriting.closeFile()
        _ = readerFinished.wait(timeout: .now() + 2)
        let snapshot = output.snapshot()
        return BrewCommandResult(
            exitCode: process.isRunning ? nil : process.terminationStatus,
            output: snapshot.data,
            timedOut: timedOut,
            truncated: snapshot.truncated
        )
    }

    private static func brewExecutable(for metadata: HomebrewCaskInstallMetadata) -> URL? {
        guard isSafeCaskToken(metadata.token) else { return nil }
        let receiptPath = metadata.receiptURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let prefixes = ["/opt/homebrew", "/usr/local"]
        for prefix in prefixes {
            let expectedRoot = "\(prefix)/Caskroom/\(metadata.token)/.metadata/"
            guard receiptPath.hasPrefix(expectedRoot) else { continue }
            let executable = URL(fileURLWithPath: "\(prefix)/bin/brew")
            return isAllowedBrewExecutable(executable) ? executable : nil
        }
        return nil
    }

    private static func isAllowedBrewExecutable(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path == "/opt/homebrew/bin/brew" || path == "/usr/local/bin/brew" else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    private static func isSafeCaskToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= 128,
              let first = token.unicodeScalars.first,
              CharacterSet.lowercaseLetters.union(.decimalDigits).contains(first) else {
            return false
        }
        let allowed = CharacterSet.lowercaseLetters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "@+._-"))
        return token.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func electronUpdateSource(for appURL: URL) -> AppUpdateSource? {
        let configURL = appURL.appendingPathComponent(
            "Contents/Resources/app-update.yml",
            isDirectory: false
        )
        guard !pathContainsSymbolicLink(configURL, stoppingAt: appURL),
              let data = readBoundedRegularFile(
            at: configURL,
            maximumBytes: maximumElectronConfigurationBytes
        ),
        let text = String(data: data, encoding: .utf8) else { return nil }

        let recognizedKeys: Set<String> = [
            "provider", "url", "channel", "owner", "repo", "host", "protocol",
            "private", "token", "requestHeaders",
        ]
        var values: [String: String] = [:]
        for rawLine in text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \Character.isNewline
        ) {
            let line = String(rawLine)
            guard line.first?.isWhitespace != true,
                  let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            guard recognizedKeys.contains(key) else { continue }
            guard values[key] == nil,
                  let value = yamlScalar(String(line[line.index(after: separator)...])) else {
                return nil
            }
            values[key] = value
        }

        guard values["token"] == nil,
              values["requestHeaders"] == nil,
              values["private"]?.lowercased() != "true" else { return nil }
        let channel = values["channel"] ?? "latest"
        guard isSafeElectronChannel(channel) else { return nil }

        switch values["provider"]?.lowercased() {
        case "generic":
            guard let rawURL = values["url"],
                  let baseURL = URL(string: rawURL),
                  isAllowedPublicHTTPSURL(baseURL),
                  baseURL.query == nil,
                  baseURL.fragment == nil else { return nil }
            return .electronUpdater(provider: .generic(baseURL: baseURL), channel: channel)
        case "github":
            guard channel == "latest",
                  values["url"] == nil,
                  values["protocol"]?.lowercased() ?? "https" == "https",
                  {
                    guard let host = values["host"]?.lowercased() else { return true }
                    return host == "github.com" || host == "api.github.com"
                  }(),
                  let owner = values["owner"],
                  let repo = values["repo"],
                  isSafeGitHubOwner(owner),
                  isSafeGitHubRepo(repo) else { return nil }
            return .electronUpdater(
                provider: .github(owner: owner, repo: repo),
                channel: channel
            )
        default:
            return nil
        }
    }

    private static func electronMetadataURL(baseURL: URL, channel: String) -> URL? {
        guard isAllowedPublicHTTPSURL(baseURL), isSafeElectronChannel(channel) else { return nil }
        let url = baseURL.appendingPathComponent("\(channel)-mac.yml", isDirectory: false)
        return isAllowedPublicHTTPSURL(url) ? url : nil
    }

    private static func electronGitHubLatestReleaseURL(
        owner: String,
        repo: String,
        channel: String
    ) -> URL? {
        guard channel == "latest",
              isSafeGitHubOwner(owner),
              isSafeGitHubRepo(repo) else { return nil }
        return URL(
            string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        )
    }

    private static func isSafeGitHubOwner(_ owner: String) -> Bool {
        guard !owner.isEmpty,
              owner.count <= 100,
              owner.first != "-",
              owner.last != "-" else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return owner.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    private static func isSafeGitHubRepo(_ repo: String) -> Bool {
        guard !repo.isEmpty,
              repo.count <= 100,
              repo != ".",
              repo != ".." else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return repo.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    private static func isSafeGitHubTag(_ tag: String) -> Bool {
        guard !tag.isEmpty, tag.count <= 256 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._+-"))
        return tag.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    private static func isExpectedGitHubReleasePage(
        _ url: URL,
        owner: String,
        repo: String,
        tag: String?
    ) -> Bool {
        guard isCanonicalGitHubURL(url),
              isSafeGitHubOwner(owner),
              isSafeGitHubRepo(repo) else { return false }
        let prefix = "/\(owner)/\(repo)/releases/tag/"
        guard url.path.hasPrefix(prefix) else { return false }
        let actualTag = String(url.path.dropFirst(prefix.count))
        guard isSafeGitHubTag(actualTag) else { return false }
        return tag == nil || actualTag == tag
    }

    private static func isExpectedGitHubReleaseAsset(
        _ url: URL,
        owner: String,
        repo: String,
        tag: String,
        assetName: String
    ) -> Bool {
        guard isCanonicalGitHubURL(url),
              isSafeGitHubOwner(owner),
              isSafeGitHubRepo(repo),
              isSafeGitHubTag(tag),
              isSafeElectronChannel(String(assetName.dropLast("-mac.yml".count))) else {
            return false
        }
        return url.path == "/\(owner)/\(repo)/releases/download/\(tag)/\(assetName)"
    }

    private static func isCanonicalGitHubURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "github.com"
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
    }

    private static func isSafeElectronChannel(_ channel: String) -> Bool {
        guard !channel.isEmpty, channel.count <= 64 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return channel.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isSafeElectronChecksum(_ checksum: String?) -> Bool {
        guard let checksum,
              (32...512).contains(checksum.count) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=_-"))
        return checksum.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isElectronZipAsset(_ value: String) -> Bool {
        let withoutFragment = value.split(separator: "#", maxSplits: 1).first.map(String.init) ?? value
        let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1).first.map(String.init)
            ?? withoutFragment
        return withoutQuery.lowercased().hasSuffix(".zip")
    }

    private static func electronUpdateEvidenceSHA256(
        releaseIdentityData: Data?,
        metadataData: Data
    ) -> String {
        let releaseDigest = releaseIdentityData.map(sha256Hex) ?? "none"
        let metadataDigest = sha256Hex(metadataData)
        return sha256Hex(Data("\(releaseDigest):\(metadataDigest)".utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSafeDottedVersion(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(components.count) else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty,
                  component.count <= 6,
                  component.allSatisfy(\.isNumber),
                  let number = Int(component) else { return false }
            return (0...999_999).contains(number)
        }
    }

    private static func yamlScalar(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if value.first == "'", value.last == "'", value.count >= 2 {
            value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        } else if value.first == "\"", value.last == "\"", value.count >= 2 {
            value = String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        } else if let comment = value.range(of: " #") {
            value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard !value.isEmpty, value.count <= 8_192 else { return nil }
        return value
    }

    private static func hasSquirrelFramework(in appURL: URL) -> Bool {
        let framework = appURL.appendingPathComponent(
            "Contents/Frameworks/Squirrel.framework",
            isDirectory: true
        )
        guard !pathContainsSymbolicLink(framework, stoppingAt: appURL) else {
            return false
        }
        var metadata = stat()
        guard lstat(framework.path, &metadata) == 0 else { return false }
        return (metadata.st_mode & S_IFMT) == S_IFDIR
    }

    private static func pathContainsSymbolicLink(
        _ url: URL,
        stoppingAt rootURL: URL
    ) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path
        var current = url.standardizedFileURL
        guard current.path == rootPath
                || current.path.hasPrefix(rootPath + "/") else {
            return true
        }

        while current.path != "/" {
            var metadata = stat()
            guard lstat(current.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT != S_IFLNK else {
                return true
            }
            if current.path == rootPath { return false }
            current.deleteLastPathComponent()
        }
        return true
    }

    private static func readBoundedRegularFile(at url: URL, maximumBytes: Int) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size > 0,
              metadata.st_size <= maximumBytes else { return nil }

        var data = Data(count: Int(metadata.st_size))
        let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                guard count > 0 else { return count == 0 ? offset : -1 }
                offset += count
            }
            return offset
        }
        guard bytesRead == data.count else { return nil }
        return data
    }

    private static func rawSparkleFeedURL(for appURL: URL) -> String? {
        guard let bundle = Bundle(url: appURL) else { return nil }
        return bounded(bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String, maximum: 8_192)
    }

    private static func sparkleFeedURL(for appURL: URL) -> URL? {
        guard let raw = rawSparkleFeedURL(for: appURL),
              let url = URL(string: raw),
              isAllowedPublicHTTPSURL(url) else { return nil }
        return url
    }

    static func isAllowedPublicHTTPSURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              !host.isEmpty,
              !host.hasSuffix("."),
              host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.hasSuffix(".lan"),
              !host.hasSuffix(".internal") else { return false }

        if isIPAddress(host) {
            return isPublicIPAddress(host)
        }
        return host.contains(".")
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var address4 = in_addr()
        var address6 = in6_addr()
        return host.withCString { pointer in
            inet_pton(AF_INET, pointer, &address4) == 1
                || inet_pton(AF_INET6, pointer, &address6) == 1
        }
    }

    private static func isPublicIPAddress(_ host: String) -> Bool {
        var address4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &address4) }) == 1 {
            let value = UInt32(bigEndian: address4.s_addr)
            let a = UInt8((value >> 24) & 0xff)
            let b = UInt8((value >> 16) & 0xff)
            return isPublicIPv4(firstOctet: a, secondOctet: b)
        }

        var address6 = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address6) }) == 1 else {
            return false
        }
        let bytes = withUnsafeBytes(of: &address6) { Array($0) }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return false }
        if bytes[0] & 0xfe == 0xfc { return false }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return false }
        if bytes[0] == 0xff { return false }
        if Array(bytes.prefix(4)) == [0x20, 0x01, 0x0d, 0xb8] { return false }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }),
           bytes[10] == 0xff,
           bytes[11] == 0xff {
            return isPublicIPv4(
                firstOctet: bytes[12],
                secondOctet: bytes[13]
            )
        }
        return true
    }

    private static func isPublicIPv4(
        firstOctet a: UInt8,
        secondOctet b: UInt8
    ) -> Bool {
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && (b == 0 || b == 168) { return false }
        if a == 198 && (b == 18 || b == 19 || b == 51) { return false }
        if a == 203 && b == 0 { return false }
        return true
    }

    private static func validatedAppleProductURL(_ raw: String?) -> URL? {
        guard let raw = bounded(raw, maximum: 8_192),
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "apps.apple.com" || host == "itunes.apple.com" else { return nil }
        return url
    }

    private static func compareVersion(_ candidate: String, isNewerThan current: String) -> Bool {
        SUStandardVersionComparator.default.compareVersion(
            candidate,
            toVersion: current
        ) == .orderedDescending
    }

    static func electronCompatibilityFailure(
        _ metadata: ElectronUpdateMetadata,
        currentKernelVersion: String
    ) -> AppUpdateFailureReason? {
        if let stagingPercentage = metadata.stagingPercentage,
           stagingPercentage < 100 {
            return .stagedRollout
        }
        if let minimumSystemVersion = metadata.minimumSystemVersion,
           compareVersion(minimumSystemVersion, isNewerThan: currentKernelVersion) {
            return .incompatibleSystem
        }
        return nil
    }

    private static func currentDarwinKernelVersion() -> String {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "0" }
        let capacity = MemoryLayout.size(ofValue: systemInfo.release)
        return withUnsafePointer(to: &systemInfo.release) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    private static func isCompatibleSparkleItem(_ item: SparkleAppcastRecord) -> Bool {
        guard item.channel == nil || item.channel?.isEmpty == true else { return false }
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
        let currentSystem = "\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)"
        if let minimum = item.minimumSystemVersion,
           compareVersion(minimum, isNewerThan: currentSystem) {
            return false
        }
        if let maximum = item.maximumSystemVersion,
           compareVersion(currentSystem, isNewerThan: maximum) {
            return false
        }
        if item.hardwareRequirements.contains("arm64"), !isRunningOnAppleSiliconHardware {
            return false
        }
        return true
    }

    private static var isRunningOnAppleSiliconHardware: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 {
            return value == 1
        }
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    private static func statusSortOrder(_ status: AppUpdateStatus) -> Int {
        switch status {
        case .updateAvailable: return 0
        case .couldNotCheck: return 1
        case .upToDate: return 2
        }
    }

    private static func bounded(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximum else { return nil }
        return trimmed
    }
}

private enum AppUpdateNetworkError: Error {
    case invalidURL
    case rejectedURL
    case invalidResponse
    case responseTooLarge
}

private final class BoundedHTTPSClient: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private var data = Data()
    private var terminalError: Error?
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var finished = false

    private init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    static func load(
        _ url: URL,
        maximumBytes: Int,
        timeout: TimeInterval,
        headers: [String: String] = [:]
    ) async throws -> Data {
        guard AppUpdateScanner.isAllowedPublicHTTPSURL(url) else {
            throw AppUpdateNetworkError.rejectedURL
        }
        let client = BoundedHTTPSClient(maximumBytes: maximumBytes)
        return try await withCheckedThrowingContinuation { continuation in
            client.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            configuration.waitsForConnectivity = false
            let session = URLSession(
                configuration: configuration,
                delegate: client,
                delegateQueue: nil
            )
            client.session = session
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue(
                "application/json, application/xml, text/xml, application/rss+xml",
                forHTTPHeaderField: "Accept"
            )
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              AppUpdateScanner.isAllowedPublicHTTPSURL(url) else {
            terminalError = AppUpdateNetworkError.rejectedURL
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let url = http.url,
              AppUpdateScanner.isAllowedPublicHTTPSURL(url) else {
            terminalError = AppUpdateNetworkError.invalidResponse
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            terminalError = AppUpdateNetworkError.responseTooLarge
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive newData: Data
    ) {
        guard terminalError == nil else { return }
        guard data.count + newData.count <= maximumBytes else {
            terminalError = AppUpdateNetworkError.responseTooLarge
            dataTask.cancel()
            return
        }
        data.append(newData)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        finish(with: terminalError ?? error)
    }

    private func finish(with error: Error?) {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        session?.invalidateAndCancel()
        session = nil
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: data)
        }
    }
}

private final class LimitedProcessOutput: @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ chunk: Data) {
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

    func snapshot() -> (data: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, truncated)
    }
}

private final class SparkleXMLDelegate: NSObject, XMLParserDelegate {
    private struct MutableItem {
        var version: String?
        var displayVersion: String?
        var minimumSystemVersion: String?
        var maximumSystemVersion: String?
        var channel: String?
        var hardwareRequirements: Set<String> = []
        var releaseNotesURL: URL?
    }

    let maximumItems: Int
    private(set) var items: [SparkleAppcastRecord] = []
    private(set) var error: Error?
    private var currentItem: MutableItem?
    private var currentElement: String?
    private var text = ""

    init(maximumItems: Int) {
        self.maximumItems = maximumItems
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = normalized(elementName)
        if name == "item" {
            guard items.count < maximumItems else {
                parser.abortParsing()
                return
            }
            currentItem = MutableItem()
            return
        }
        guard currentItem != nil else { return }
        if name == "enclosure" {
            // Do not read and mutate the same optional-chained property in a
            // single nil-coalescing assignment. Feeds that put version values
            // in child elements (rather than enclosure attributes) otherwise
            // trigger Swift's runtime exclusivity trap.
            if let version = attribute(attributeDict, named: "version") {
                currentItem?.version = version
            }
            if let displayVersion = attribute(attributeDict, named: "shortVersionString") {
                currentItem?.displayVersion = displayVersion
            }
            return
        }
        let captured = [
            "version",
            "shortVersionString",
            "minimumSystemVersion",
            "maximumSystemVersion",
            "channel",
            "hardwareRequirements",
            "releaseNotesLink",
        ]
        if captured.contains(name) {
            currentElement = name
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentElement != nil, text.count < 32_768 else { return }
        text.append(String(string.prefix(32_768 - text.count)))
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = normalized(elementName)
        if name == "item" {
            if let currentItem,
               let version = bounded(currentItem.version, maximum: 256) {
                items.append(
                    SparkleAppcastRecord(
                        version: version,
                        displayVersion: bounded(currentItem.displayVersion, maximum: 256),
                        minimumSystemVersion: bounded(currentItem.minimumSystemVersion, maximum: 256),
                        maximumSystemVersion: bounded(currentItem.maximumSystemVersion, maximum: 256),
                        channel: bounded(currentItem.channel, maximum: 256),
                        hardwareRequirements: currentItem.hardwareRequirements,
                        releaseNotesURL: currentItem.releaseNotesURL
                    )
                )
            }
            self.currentItem = nil
            currentElement = nil
            text = ""
            return
        }
        guard currentElement == name else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "version": currentItem?.version = value
        case "shortVersionString": currentItem?.displayVersion = value
        case "minimumSystemVersion": currentItem?.minimumSystemVersion = value
        case "maximumSystemVersion": currentItem?.maximumSystemVersion = value
        case "channel": currentItem?.channel = value
        case "hardwareRequirements":
            currentItem?.hardwareRequirements = Set(
                value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }.filter { !$0.isEmpty }
            )
        case "releaseNotesLink":
            if let url = URL(string: value), AppUpdateScanner.isAllowedPublicHTTPSURL(url) {
                currentItem?.releaseNotesURL = url
            }
        default: break
        }
        currentElement = nil
        text = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = parseError
    }

    private func normalized(_ value: String) -> String {
        value.split(separator: ":").last.map(String.init) ?? value
    }

    private func attribute(_ attributes: [String: String], named name: String) -> String? {
        attributes.first { normalized($0.key) == name }?.value
    }

    private func bounded(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximum else { return nil }
        return trimmed
    }
}

@MainActor
final class ExternalSparkleUpdateCoordinator {
    private final class Session: NSObject, SPUUpdaterDelegate {
        let appID: String
        let feedURL: URL
        let completion: (String, Error?) -> Void
        var userDriver: SPUStandardUserDriver?
        var updater: SPUUpdater?

        init(appID: String, feedURL: URL, completion: @escaping (String, Error?) -> Void) {
            self.appID = appID
            self.feedURL = feedURL
            self.completion = completion
        }

        @MainActor
        func start(bundle: Bundle) throws {
            let userDriver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
            let updater = SPUUpdater(
                hostBundle: bundle,
                applicationBundle: bundle,
                userDriver: userDriver,
                delegate: self
            )
            self.userDriver = userDriver
            self.updater = updater
            try updater.start()
            updater.checkForUpdates()
        }

        func feedURLString(for updater: SPUUpdater) -> String? {
            feedURL.absoluteString
        }

        func feedParameters(
            for updater: SPUUpdater,
            sendingSystemProfile: Bool
        ) -> [[String: String]] {
            []
        }

        func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
            []
        }

        func allowedChannels(for updater: SPUUpdater) -> Set<String> {
            []
        }

        func updater(
            _ updater: SPUUpdater,
            shouldProceedWithUpdate updateItem: SUAppcastItem,
            updateCheck: SPUUpdateCheck
        ) throws {
            if let fileURL = updateItem.fileURL {
                guard AppUpdateScanner.isAllowedPublicHTTPSURL(fileURL) else {
                    throw NSError(
                        domain: "AppSift.AppUpdate",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "AppSift refused a non-public or non-HTTPS update download URL.",
                        ]
                    )
                }
            } else if let infoURL = updateItem.infoURL {
                guard AppUpdateScanner.isAllowedPublicHTTPSURL(infoURL) else {
                    throw NSError(
                        domain: "AppSift.AppUpdate",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "AppSift refused a non-public or non-HTTPS update information URL.",
                        ]
                    )
                }
            }
        }

        func updater(
            _ updater: SPUUpdater,
            didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
            error: Error?
        ) {
            completion(appID, error)
        }
    }

    private var sessions: [String: Session] = [:]

    func presentUpdate(
        appID: String,
        appURL: URL,
        feedURL: URL,
        completion: @escaping (Error?) -> Void
    ) throws {
        guard sessions[appID] == nil,
              let bundle = Bundle(url: appURL) else {
            throw AppUpdateNetworkError.invalidResponse
        }
        let session = Session(appID: appID, feedURL: feedURL) { [weak self] appID, error in
            self?.sessions.removeValue(forKey: appID)
            completion(error)
        }
        sessions[appID] = session
        do {
            try session.start(bundle: bundle)
        } catch {
            sessions.removeValue(forKey: appID)
            throw error
        }
    }
}
