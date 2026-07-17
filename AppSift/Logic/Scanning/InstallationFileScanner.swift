import CoreServices
import Darwin
import Foundation
import UniformTypeIdentifiers

enum InstallationFileKind: String, CaseIterable, Codable, Hashable, Sendable {
    case diskImage
    case installerPackage
    case installerMetaPackage
    case xipArchive
    case applicationArchive

    fileprivate var filenameExtension: String {
        switch self {
        case .diskImage: "dmg"
        case .installerPackage: "pkg"
        case .installerMetaPackage: "mpkg"
        case .xipArchive: "xip"
        case .applicationArchive: "zip"
        }
    }
}

enum InstallationFileSignatureStatus: String, Codable, Hashable, Sendable {
    case developerSigned
    case appleSigned
    case locallySigned
    case adHoc
    case unsigned
    case invalid
    case unknown
}

enum InstallationFileNotarizationStatus: String, Codable, Hashable, Sendable {
    case notarized
    case notNotarized
    case unknown
}

struct InstallationFileSignatureMetadata: Codable, Hashable, Sendable {
    let status: InstallationFileSignatureStatus
    let signingIdentifier: String?
    let teamIdentifier: String?
    let developerName: String?
    let notarizationStatus: InstallationFileNotarizationStatus

    static let unknown = InstallationFileSignatureMetadata(
        status: .unknown,
        signingIdentifier: nil,
        teamIdentifier: nil,
        developerName: nil,
        notarizationStatus: .unknown
    )
}

struct InstallationFileApplicationReference: Codable, Hashable, Sendable {
    let name: String
    let bundleIdentifier: String
    let url: URL
    let teamIdentifier: String?

    init(
        name: String,
        bundleIdentifier: String,
        url: URL,
        teamIdentifier: String?
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.teamIdentifier = teamIdentifier
    }

    init(app: InstalledApp) {
        self.init(
            name: app.appName,
            bundleIdentifier: app.bundleIdentifier,
            url: app.path,
            teamIdentifier: app.signature.teamIdentifier
        )
    }
}

enum InstallationFileEvidence: String, Codable, Hashable, Sendable {
    case spotlightMetadata
    case filenameExtension
    case uniformType
    case regularFile
    case quarantineOrigin
    case quarantineAgent
    case codeSignature
    case developerTeam
    case notarization
    case installerPackageSignature
    case installerPackagePayload
    case applicationArchiveContents
    case installedApplicationNameMatch
    case installedApplicationTeamMatch
}

enum InstallationFileProtectionReason: String, Codable, Hashable, Sendable {
    case applicationManagedCache
    case differentDataVolume
    case differentOwner
    case hardLinked
    case outsideUserHome
}

enum InstallationFileRemovalEligibility: Codable, Hashable, Sendable {
    case eligible
    case protected(InstallationFileProtectionReason)

    var isEligible: Bool {
        if case .eligible = self { return true }
        return false
    }

    var allowsExplicitSelection: Bool {
        if case .protected(.applicationManagedCache) = self { return true }
        return false
    }
}

struct InstallationFileFingerprint: Codable, Hashable, Sendable {
    let deviceID: UInt64
    let inode: UInt64
    let fileSize: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let ownerUserID: UInt32
    let hardLinkCount: UInt64
}

struct InstallationFileItem: Identifiable, Codable, Hashable, Sendable {
    var id: String { url.standardizedFileURL.path }

    let url: URL
    let name: String
    let kind: InstallationFileKind
    let size: Int64
    let createdAt: Date?
    let modifiedAt: Date?
    let quarantineOriginURL: URL?
    let quarantineAgentName: String?
    let signature: InstallationFileSignatureMetadata
    let relatedApplication: InstallationFileApplicationReference?
    let containedApplicationName: String?
    let evidence: Set<InstallationFileEvidence>
    let removalEligibility: InstallationFileRemovalEligibility
    let fingerprint: InstallationFileFingerprint

    var isRemovable: Bool { removalEligibility.isEligible }
    var allowsExplicitSelection: Bool {
        removalEligibility.allowsExplicitSelection
    }

    init(
        url: URL,
        name: String,
        kind: InstallationFileKind,
        size: Int64,
        createdAt: Date?,
        modifiedAt: Date?,
        quarantineOriginURL: URL?,
        quarantineAgentName: String?,
        signature: InstallationFileSignatureMetadata,
        relatedApplication: InstallationFileApplicationReference?,
        containedApplicationName: String? = nil,
        evidence: Set<InstallationFileEvidence>,
        removalEligibility: InstallationFileRemovalEligibility,
        fingerprint: InstallationFileFingerprint
    ) {
        self.url = url
        self.name = name
        self.kind = kind
        self.size = size
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.quarantineOriginURL = quarantineOriginURL
        self.quarantineAgentName = quarantineAgentName
        self.signature = signature
        self.relatedApplication = relatedApplication
        self.containedApplicationName = containedApplicationName
        self.evidence = evidence
        self.removalEligibility = removalEligibility
        self.fingerprint = fingerprint
    }
}

struct InstallationFileScanResult: Sendable {
    let items: [InstallationFileItem]
    let ignoredPathCount: Int
    let inaccessibleCandidateCount: Int
    let wasTruncated: Bool
    let wasCancelled: Bool
    let scannedAt: Date

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var removableSize: Int64 {
        items.lazy.filter(\.isRemovable).reduce(0) { $0 + $1.size }
    }
    var protectedCount: Int { items.count { !$0.isRemovable } }
}

struct InstallationPackageCommandResult: Sendable {
    let exitCode: Int32?
    let output: Data
    let timedOut: Bool
    let truncated: Bool

    var succeeded: Bool {
        exitCode == 0 && !timedOut && !truncated
    }
}

struct InstallationArchiveListingResult: Sendable {
    let exitCode: Int32?
    let output: Data
    let reportedEntryCount: Int?
    let timedOut: Bool
    let truncated: Bool

    var succeeded: Bool {
        exitCode == 0
            && reportedEntryCount != nil
            && !timedOut
            && !truncated
    }
}

enum InstallationFileScanner {
    typealias PackageCommandProvider = @Sendable (
        _ arguments: [String]
    ) -> InstallationPackageCommandResult
    typealias SignatureProvider = @Sendable (
        _ url: URL
    ) -> InstallationFileSignatureMetadata
    typealias ArchiveListingProvider = @Sendable (
        _ url: URL,
        _ expectedFingerprint: InstallationFileFingerprint
    ) -> InstallationArchiveListingResult

    private static let maximumCandidates = 5_000
    private static let maximumCommandOutputBytes = 1_048_576
    private static let commandTimeout: TimeInterval = 5
    private static let maximumArchiveEntries = 20_000
    private static let pkgutilURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
    private static let zipinfoURL = URL(fileURLWithPath: "/usr/bin/zipinfo")

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var truncated = false

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            let remaining = maximumCommandOutputBytes - data.count
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

    static func discover(
        installedApps: [InstallationFileApplicationReference],
        additionalCandidateURLs: [URL] = [],
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        currentUserID: uid_t = getuid()
    ) async -> InstallationFileScanResult {
        let worker = Task.detached(priority: .utility) {
            let discovery = spotlightCandidateURLs(shouldCancel: { Task.isCancelled })
            let indexedResult = scan(
                candidateURLs: discovery.urls,
                installedApps: installedApps,
                homeURL: homeURL,
                currentUserID: currentUserID,
                candidateListWasTruncated: discovery.wasTruncated,
                candidateURLsAreSpotlightResults: true,
                shouldCancel: { Task.isCancelled }
            )
            guard !Task.isCancelled,
                  !additionalCandidateURLs.isEmpty else {
                return indexedResult
            }
            let indexedPaths = Set(discovery.urls.map {
                $0.standardizedFileURL.path
            })
            let supplementalURLs = additionalCandidateURLs.filter {
                !indexedPaths.contains($0.standardizedFileURL.path)
            }
            guard !supplementalURLs.isEmpty else { return indexedResult }
            let supplementalResult = scan(
                candidateURLs: supplementalURLs,
                installedApps: installedApps,
                homeURL: homeURL,
                currentUserID: currentUserID,
                shouldCancel: { Task.isCancelled }
            )
            return merging(indexedResult, supplementalResult)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func merging(
        _ primary: InstallationFileScanResult,
        _ supplemental: InstallationFileScanResult
    ) -> InstallationFileScanResult {
        var itemsByPath = Dictionary(
            uniqueKeysWithValues: supplemental.items.map { ($0.id, $0) }
        )
        for item in primary.items {
            itemsByPath[item.id] = item
        }
        let items = itemsByPath.values.sorted {
            if $0.modifiedAt != $1.modifiedAt {
                return ($0.modifiedAt ?? .distantPast)
                    > ($1.modifiedAt ?? .distantPast)
            }
            return $0.url.path.localizedStandardCompare($1.url.path)
                == .orderedAscending
        }
        return InstallationFileScanResult(
            items: items,
            ignoredPathCount: primary.ignoredPathCount
                + supplemental.ignoredPathCount,
            inaccessibleCandidateCount: primary.inaccessibleCandidateCount
                + supplemental.inaccessibleCandidateCount,
            wasTruncated: primary.wasTruncated || supplemental.wasTruncated,
            wasCancelled: primary.wasCancelled || supplemental.wasCancelled,
            scannedAt: max(primary.scannedAt, supplemental.scannedAt)
        )
    }

    static func scan(
        candidateURLs: [URL],
        installedApps: [InstallationFileApplicationReference],
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        homeDeviceID: UInt64? = nil,
        currentUserID: uid_t = getuid(),
        candidateListWasTruncated: Bool = false,
        candidateURLsAreSpotlightResults: Bool = false,
        packageCommandProvider: @escaping PackageCommandProvider = {
            runPkgutil(arguments: $0)
        },
        archiveListingProvider: @escaping ArchiveListingProvider = {
            listApplicationArchive(at: $0, expectedFingerprint: $1)
        },
        signatureProvider: @escaping SignatureProvider = {
            signatureMetadata(at: $0)
        },
        shouldCancel: () -> Bool = { false }
    ) -> InstallationFileScanResult {
        // The complete evidence-validation pass is implemented below this
        // model surface; retain a safe empty result if cancellation wins
        // before filesystem inspection begins.
        guard !shouldCancel() else {
            return InstallationFileScanResult(
                items: [],
                ignoredPathCount: 0,
                inaccessibleCandidateCount: 0,
                wasTruncated: candidateListWasTruncated
                    || candidateURLs.count > maximumCandidates,
                wasCancelled: true,
                scannedAt: Date()
            )
        }
        return scanCandidates(
            candidateURLs: candidateURLs,
            installedApps: installedApps,
            homeURL: homeURL,
            homeDeviceID: homeDeviceID,
            currentUserID: currentUserID,
            candidateListWasTruncated: candidateListWasTruncated,
            candidateURLsAreSpotlightResults: candidateURLsAreSpotlightResults,
            packageCommandProvider: packageCommandProvider,
            archiveListingProvider: archiveListingProvider,
            signatureProvider: signatureProvider,
            shouldCancel: shouldCancel
        )
    }

    static func kind(
        for url: URL,
        contentTypeIdentifier: String? = nil
    ) -> InstallationFileKind? {
        let candidate: InstallationFileKind?
        switch url.pathExtension.lowercased() {
        case "dmg": candidate = .diskImage
        case "pkg": candidate = .installerPackage
        case "mpkg": candidate = .installerMetaPackage
        case "xip": candidate = .xipArchive
        case "zip": candidate = .applicationArchive
        default: candidate = nil
        }
        guard let candidate else { return nil }
        guard let contentTypeIdentifier,
              !contentTypeIdentifier.isEmpty else {
            return candidate
        }
        guard let observed = UTType(contentTypeIdentifier),
              let expected = expectedContentType(for: candidate) else {
            return nil
        }
        return observed == expected || observed.conforms(to: expected)
            ? candidate
            : nil
    }

    static func currentFingerprint(
        for url: URL
    ) -> InstallationFileFingerprint? {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return InstallationFileFingerprint(
            deviceID: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            fileSize: information.st_size,
            modificationSeconds: Int64(information.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            ownerUserID: information.st_uid,
            hardLinkCount: UInt64(information.st_nlink)
        )
    }

    static func isIgnoredPath(_ url: URL, homeURL: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let homePath = homeURL.standardizedFileURL.path
        let fixedRoots = [
            "/System", "/private", "/usr", "/bin", "/sbin",
            "/Library/Developer",
        ]
        if fixedRoots.contains(where: { isPath(path, inside: $0) }) {
            return true
        }
        if isPath(path, inside: homePath + "/.Trash") {
            return true
        }
        return URL(fileURLWithPath: path).pathComponents.contains {
            $0.lowercased().hasSuffix(".app")
        }
    }

    static func pathContainsSymbolicLink(
        _ url: URL,
        stoppingAt stopURL: URL? = nil
    ) -> Bool {
        let path = url.standardizedFileURL.path
        let stopPath = stopURL?.standardizedFileURL.path
        var current = URL(fileURLWithPath: path)
        while current.path != "/" {
            if current.path == stopPath { return false }
            var information = stat()
            if lstat(current.path, &information) != 0 {
                return true
            }
            if information.st_mode & S_IFMT == S_IFLNK {
                return true
            }
            current.deleteLastPathComponent()
        }
        return false
    }

    private static func scanCandidates(
        candidateURLs: [URL],
        installedApps: [InstallationFileApplicationReference],
        homeURL: URL,
        homeDeviceID: UInt64?,
        currentUserID: uid_t,
        candidateListWasTruncated: Bool,
        candidateURLsAreSpotlightResults: Bool,
        packageCommandProvider: @escaping PackageCommandProvider,
        archiveListingProvider: @escaping ArchiveListingProvider,
        signatureProvider: @escaping SignatureProvider,
        shouldCancel: () -> Bool
    ) -> InstallationFileScanResult {
        let resolvedHomeDeviceID = homeDeviceID
            ?? currentFingerprint(for: homeURL)?.deviceID
            ?? deviceID(forExistingPath: homeURL)
        var seenPaths = Set<String>()
        var items: [InstallationFileItem] = []
        var ignoredPathCount = 0
        var inaccessibleCandidateCount = 0
        var wasCancelled = false

        for rawURL in candidateURLs.prefix(maximumCandidates) {
            if shouldCancel() {
                wasCancelled = true
                break
            }
            let url = rawURL.standardizedFileURL
            let path = url.path
            guard seenPaths.insert(path).inserted else { continue }
            guard !isIgnoredPath(url, homeURL: homeURL) else {
                ignoredPathCount += 1
                continue
            }
            guard !pathContainsSymbolicLink(url) else {
                inaccessibleCandidateCount += 1
                continue
            }
            guard let fingerprint = currentFingerprint(for: url) else {
                inaccessibleCandidateCount += 1
                continue
            }

            let values = try? url.resourceValues(forKeys: [
                .contentTypeKey,
                .creationDateKey,
                .contentModificationDateKey,
                .quarantinePropertiesKey,
            ])
            let typeIdentifier = values?.contentType?.identifier
            guard let fileKind = kind(
                for: url,
                contentTypeIdentifier: typeIdentifier
            ) else {
                ignoredPathCount += 1
                continue
            }

            var evidence: Set<InstallationFileEvidence> = [
                .filenameExtension,
                .regularFile,
            ]
            if candidateURLsAreSpotlightResults {
                evidence.insert(.spotlightMetadata)
            }
            if typeIdentifier != nil {
                evidence.insert(.uniformType)
            }

            let quarantine = quarantineMetadata(
                values?.quarantineProperties
            )
            if quarantine.originURL != nil {
                evidence.insert(.quarantineOrigin)
            }
            if quarantine.agentName != nil {
                evidence.insert(.quarantineAgent)
            }

            let signature: InstallationFileSignatureMetadata
            var relatedApplication: InstallationFileApplicationReference?
            var containedApplicationName: String?
            if fileKind == .installerPackage
                || fileKind == .installerMetaPackage {
                let packageInspection = inspectPackage(
                    at: url,
                    installedApps: installedApps,
                    commandProvider: packageCommandProvider
                )
                signature = packageInspection.signature
                evidence.formUnion(packageInspection.evidence)
                relatedApplication = packageInspection.relatedApplication
            } else if fileKind == .applicationArchive {
                guard isEligibleApplicationArchiveLocation(
                    url,
                    homeURL: homeURL,
                    quarantineOriginURL: quarantine.originURL
                ),
                let archiveInspection = inspectApplicationArchive(
                    archiveListingProvider(url, fingerprint)
                ) else {
                    ignoredPathCount += 1
                    continue
                }
                signature = .unknown
                containedApplicationName = archiveInspection.applicationName
                evidence.insert(.applicationArchiveContents)
            } else {
                signature = signatureProvider(url)
                addSignatureEvidence(signature, to: &evidence)
            }

            let eligibility = removalEligibility(
                for: url,
                fingerprint: fingerprint,
                homeURL: homeURL,
                homeDeviceID: resolvedHomeDeviceID,
                currentUserID: currentUserID
            )
            items.append(
                InstallationFileItem(
                    url: url,
                    name: url.lastPathComponent,
                    kind: fileKind,
                    size: max(0, fingerprint.fileSize),
                    createdAt: values?.creationDate,
                    modifiedAt: values?.contentModificationDate
                        ?? Date(timeIntervalSince1970: TimeInterval(
                            fingerprint.modificationSeconds
                        )),
                    quarantineOriginURL: quarantine.originURL,
                    quarantineAgentName: quarantine.agentName,
                    signature: signature,
                    relatedApplication: relatedApplication,
                    containedApplicationName: containedApplicationName,
                    evidence: evidence,
                    removalEligibility: eligibility,
                    fingerprint: fingerprint
                )
            )
        }

        items.sort {
            if $0.modifiedAt != $1.modifiedAt {
                return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
            }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        return InstallationFileScanResult(
            items: items,
            ignoredPathCount: ignoredPathCount,
            inaccessibleCandidateCount: inaccessibleCandidateCount,
            wasTruncated: candidateListWasTruncated
                || candidateURLs.count > maximumCandidates,
            wasCancelled: wasCancelled,
            scannedAt: Date()
        )
    }

    private static func spotlightCandidateURLs(
        shouldCancel: () -> Bool
    ) -> (urls: [URL], wasTruncated: Bool) {
        guard !shouldCancel() else { return ([], false) }
        let queryText = "(kMDItemFSName == '*.dmg'cd || "
            + "kMDItemFSName == '*.pkg'cd || "
            + "kMDItemFSName == '*.mpkg'cd || "
            + "kMDItemFSName == '*.xip'cd || "
            + "kMDItemFSName == '*.zip'cd)"
        guard let query = MDQueryCreate(
            kCFAllocatorDefault,
            queryText as CFString,
            nil,
            nil
        ) else {
            return ([], false)
        }
        MDQuerySetSearchScope(
            query,
            [kMDQueryScopeComputerIndexed] as CFArray,
            0
        )
        guard MDQueryExecute(
            query,
            CFOptionFlags(kMDQuerySynchronous.rawValue)
        ) else {
            return ([], false)
        }
        MDQueryDisableUpdates(query)
        defer {
            MDQueryEnableUpdates(query)
            MDQueryStop(query)
        }
        let resultCount = MDQueryGetResultCount(query)
        var urls: [URL] = []
        urls.reserveCapacity(min(resultCount, maximumCandidates + 1))
        let cappedCount = min(resultCount, maximumCandidates + 1)
        for index in 0..<cappedCount {
            if shouldCancel() { break }
            guard let rawResult = MDQueryGetResultAtIndex(query, index) else {
                continue
            }
            let item = unsafeBitCast(rawResult, to: MDItem.self)
            guard let value = MDItemCopyAttribute(item, kMDItemPath),
                  let path = value as? String,
                  !path.isEmpty,
                  path.count <= 4_096 else {
                continue
            }
            urls.append(URL(fileURLWithPath: path))
        }
        return (
            Array(urls.prefix(maximumCandidates)),
            resultCount > maximumCandidates
        )
    }

    private struct PackageInspection {
        let signature: InstallationFileSignatureMetadata
        let relatedApplication: InstallationFileApplicationReference?
        let evidence: Set<InstallationFileEvidence>
    }

    private static func expectedContentType(
        for kind: InstallationFileKind
    ) -> UTType? {
        switch kind {
        case .diskImage:
            return UTType("public.disk-image")
        case .installerPackage:
            return UTType("com.apple.installer-package-archive")
        case .installerMetaPackage:
            return UTType("com.apple.installer-package-archive")
        case .xipArchive:
            return UTType("com.apple.xip-archive")
        case .applicationArchive:
            return UTType("public.zip-archive")
        }
    }

    private static func isPath(_ path: String, inside root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    static func deviceID(forExistingPath url: URL) -> UInt64? {
        var information = stat()
        guard stat(url.path, &information) == 0 else { return nil }
        return UInt64(information.st_dev)
    }

    static func removalEligibility(
        for url: URL,
        fingerprint: InstallationFileFingerprint,
        homeURL: URL,
        homeDeviceID: UInt64?,
        currentUserID: uid_t
    ) -> InstallationFileRemovalEligibility {
        let path = url.standardizedFileURL.path
        let homePath = homeURL.standardizedFileURL.path
        guard isPath(path, inside: homePath) else {
            return .protected(.outsideUserHome)
        }
        let managedRoots = [
            homePath + "/Library/Application Support",
            homePath + "/Library/Caches",
            homePath + "/Library/Containers",
            homePath + "/Library/Group Containers",
            homePath + "/Library/Developer",
        ]
        if managedRoots.contains(where: { isPath(path, inside: $0) }) {
            return .protected(.applicationManagedCache)
        }
        if let homeDeviceID, fingerprint.deviceID != homeDeviceID {
            return .protected(.differentDataVolume)
        }
        if fingerprint.ownerUserID != currentUserID {
            return .protected(.differentOwner)
        }
        if fingerprint.hardLinkCount > 1 {
            return .protected(.hardLinked)
        }
        return .eligible
    }

    private static func quarantineMetadata(
        _ properties: [String: Any]?
    ) -> (originURL: URL?, agentName: String?) {
        guard let properties else { return (nil, nil) }
        let dataKey = kLSQuarantineDataURLKey as String
        let originKey = kLSQuarantineOriginURLKey as String
        let agentKey = kLSQuarantineAgentNameKey as String
        let originURL = safePublicOriginURL(properties[dataKey])
            ?? safePublicOriginURL(properties[originKey])
        let agentName: String? = {
            guard let value = properties[agentKey] as? String else { return nil }
            let cleaned = value
                .components(separatedBy: .controlCharacters)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned.count <= 256 else { return nil }
            return cleaned
        }()
        return (originURL, agentName)
    }

    private static func safePublicOriginURL(_ value: Any?) -> URL? {
        let url: URL?
        if let candidate = value as? URL {
            url = candidate
        } else if let candidate = value as? String {
            url = URL(string: candidate)
        } else {
            url = nil
        }
        guard let url,
              url.absoluteString.count <= 2_048,
              url.user == nil,
              url.password == nil,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return url
    }

    private struct ApplicationArchiveInspection {
        let applicationName: String
    }

    private static func isEligibleApplicationArchiveLocation(
        _ url: URL,
        homeURL: URL,
        quarantineOriginURL: URL?
    ) -> Bool {
        if quarantineOriginURL != nil { return true }
        let path = url.standardizedFileURL.path
        let homePath = homeURL.standardizedFileURL.path
        return isPath(path, inside: homePath + "/Downloads")
            || isPath(path, inside: homePath + "/Desktop")
    }

    private static func inspectApplicationArchive(
        _ result: InstallationArchiveListingResult
    ) -> ApplicationArchiveInspection? {
        guard result.succeeded,
              let reportedEntryCount = result.reportedEntryCount,
              reportedEntryCount > 0,
              reportedEntryCount <= maximumArchiveEntries,
              let listing = String(data: result.output, encoding: .utf8) else {
            return nil
        }

        var lines = listing.components(separatedBy: "\n")
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard lines.count == reportedEntryCount,
              lines.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        var observedRoots = Set<String>()
        var infoPlistRoots = Set<String>()
        var executableRoots = Set<String>()
        var applicationNames = [String: String]()
        var entriesOutsideApplication: [(
            components: [String],
            isDirectory: Bool
        )] = []

        for line in lines {
            let isDirectoryEntry = line.hasSuffix("/")
            guard line.utf8.count <= 4_096,
                  !line.hasPrefix("/"),
                  !line.contains("\\"),
                  line.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }) else {
                return nil
            }

            var components = line.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            if components.last?.isEmpty == true {
                components.removeLast()
            }
            guard !components.isEmpty,
                  components.allSatisfy({
                      !$0.isEmpty && $0 != "." && $0 != ".."
                  }) else {
                return nil
            }
            if components[0].count == 2,
               components[0].last == ":",
               components[0].first?.isASCII == true,
               components[0].first?.isLetter == true {
                return nil
            }
            guard components[0].caseInsensitiveCompare("__MACOSX")
                != .orderedSame else {
                continue
            }
            guard let appIndex = components.firstIndex(where: {
                $0.lowercased().hasSuffix(".app")
            }) else {
                entriesOutsideApplication.append((
                    components: components.map {
                        canonicalArchiveComponent(String($0))
                    },
                    isDirectory: isDirectoryEntry
                ))
                continue
            }

            let rootComponents = components[...appIndex].map(String.init)
            let canonicalRoot = rootComponents.map(canonicalArchiveComponent)
                .joined(separator: "/")
            observedRoots.insert(canonicalRoot)

            let appComponent = String(components[appIndex])
            let applicationName = String(appComponent.dropLast(4))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !applicationName.isEmpty,
                  applicationName.count <= 256 else {
                return nil
            }
            applicationNames[canonicalRoot] = applicationName

            let remainder = components.dropFirst(appIndex + 1)
            if remainder.count == 2,
               remainder[remainder.startIndex]
                .caseInsensitiveCompare("Contents") == .orderedSame,
               remainder[remainder.index(after: remainder.startIndex)]
                .caseInsensitiveCompare("Info.plist") == .orderedSame {
                infoPlistRoots.insert(canonicalRoot)
            }
            if remainder.count >= 3,
               remainder[remainder.startIndex]
                .caseInsensitiveCompare("Contents") == .orderedSame {
                let macOSIndex = remainder.index(after: remainder.startIndex)
                if remainder[macOSIndex]
                    .caseInsensitiveCompare("MacOS") == .orderedSame {
                    executableRoots.insert(canonicalRoot)
                }
            }
        }

        guard observedRoots.count == 1,
              infoPlistRoots == observedRoots,
              executableRoots == observedRoots,
              let root = observedRoots.first,
              let applicationName = applicationNames[root] else {
            return nil
        }
        let rootComponents = root.split(separator: "/").map(String.init)
        guard entriesOutsideApplication.allSatisfy({ entry in
            entry.isDirectory
                && entry.components.count < rootComponents.count
                && zip(entry.components, rootComponents).allSatisfy { pair in
                    pair.0 == pair.1
                }
        }) else {
            return nil
        }
        return ApplicationArchiveInspection(applicationName: applicationName)
    }

    private static func canonicalArchiveComponent(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }

    private static func addSignatureEvidence(
        _ signature: InstallationFileSignatureMetadata,
        to evidence: inout Set<InstallationFileEvidence>
    ) {
        if signature.status != .unknown {
            evidence.insert(.codeSignature)
        }
        if signature.teamIdentifier != nil {
            evidence.insert(.developerTeam)
        }
        if signature.notarizationStatus != .unknown {
            evidence.insert(.notarization)
        }
    }

    private static func inspectPackage(
        at url: URL,
        installedApps: [InstallationFileApplicationReference],
        commandProvider: PackageCommandProvider
    ) -> PackageInspection {
        let signatureResult = commandProvider([
            "--check-signature", url.path,
        ])
        let signature = parsePackageSignature(signatureResult)
        let payloadResult = commandProvider([
            "--payload-files", url.path,
        ])
        let payloadAppNames = parsePayloadApplicationNames(payloadResult)
        var evidence = Set<InstallationFileEvidence>()
        if signatureResult.succeeded {
            evidence.insert(.installerPackageSignature)
        }
        if payloadResult.succeeded {
            evidence.insert(.installerPackagePayload)
        }
        addSignatureEvidence(signature, to: &evidence)

        let relatedApplication: InstallationFileApplicationReference?
        if let teamIdentifier = signature.teamIdentifier,
           !payloadAppNames.isEmpty {
            let matches = installedApps.filter { app in
                guard app.teamIdentifier == teamIdentifier else { return false }
                let appName = canonicalApplicationName(app.name)
                return payloadAppNames.contains(appName)
            }
            if matches.count == 1 {
                relatedApplication = matches[0]
                evidence.insert(.installedApplicationNameMatch)
                evidence.insert(.installedApplicationTeamMatch)
            } else {
                relatedApplication = nil
            }
        } else {
            relatedApplication = nil
        }

        return PackageInspection(
            signature: signature,
            relatedApplication: relatedApplication,
            evidence: evidence
        )
    }

    private static func parsePackageSignature(
        _ result: InstallationPackageCommandResult
    ) -> InstallationFileSignatureMetadata {
        guard result.succeeded else { return .unknown }
        let output = String(decoding: result.output, as: UTF8.self)
        let lowercased = output.lowercased()

        let status: InstallationFileSignatureStatus
        if lowercased.contains("status: signed by apple") {
            status = .appleSigned
        } else if lowercased.contains("status: signed by") {
            status = .developerSigned
        } else if lowercased.contains("status: no signature")
            || lowercased.contains("status: unsigned") {
            status = .unsigned
        } else if lowercased.contains("status: invalid")
            || lowercased.contains("not trusted") {
            status = .invalid
        } else {
            status = .unknown
        }

        let certificateLine = output.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .first {
                $0.localizedCaseInsensitiveContains("Developer ID Installer:")
                    || $0.localizedCaseInsensitiveContains("Mac Installer Distribution:")
            }
        let teamIdentifier = certificateLine.flatMap(extractTeamIdentifier)
        let developerName = certificateLine.flatMap(extractDeveloperName)
        let notarization: InstallationFileNotarizationStatus
        if lowercased.contains("notarization: trusted")
            || lowercased.contains("trusted by the apple notary service") {
            notarization = .notarized
        } else if lowercased.contains("notarization: not") {
            notarization = .notNotarized
        } else {
            notarization = .unknown
        }
        return InstallationFileSignatureMetadata(
            status: status,
            signingIdentifier: nil,
            teamIdentifier: teamIdentifier,
            developerName: developerName,
            notarizationStatus: notarization
        )
    }

    private static func extractTeamIdentifier(_ line: String) -> String? {
        let pattern = #"\(([A-Z0-9]{10})\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.matches(
                in: line,
                range: NSRange(line.startIndex..., in: line)
              ).last,
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[range])
    }

    private static func extractDeveloperName(_ line: String) -> String? {
        let components = line.split(separator: ":", maxSplits: 1)
        guard components.count == 2 else { return nil }
        let value = components[1]
            .replacingOccurrences(
                of: #"\s*\([A-Z0-9]{10}\)\s*$"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.count > 512 ? nil : value
    }

    private static func parsePayloadApplicationNames(
        _ result: InstallationPackageCommandResult
    ) -> Set<String> {
        guard result.succeeded else { return [] }
        let output = String(decoding: result.output, as: UTF8.self)
        var names = Set<String>()
        for rawLine in output.split(separator: "\n").prefix(100_000) {
            let path = String(rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.count <= 4_096 else { continue }
            let components = path.split(separator: "/").map(String.init)
            guard components.contains(where: {
                $0.caseInsensitiveCompare("Applications") == .orderedSame
            }),
            let appComponent = components.first(where: {
                $0.lowercased().hasSuffix(".app")
            }) else {
                continue
            }
            names.insert(canonicalApplicationName(appComponent))
        }
        return names
    }

    private static func canonicalApplicationName(_ value: String) -> String {
        let name = value.lowercased().hasSuffix(".app")
            ? String(value.dropLast(4))
            : value
        return name
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func runPkgutil(
        arguments: [String]
    ) -> InstallationPackageCommandResult {
        let allowedCommands = ["--check-signature", "--payload-files"]
        guard arguments.count == 2,
              allowedCommands.contains(arguments[0]),
              arguments[1].count <= 4_096,
              !arguments[1].contains("\0"),
              FileManager.default.isExecutableFile(atPath: pkgutilURL.path) else {
            return InstallationPackageCommandResult(
                exitCode: nil,
                output: Data(),
                timedOut: false,
                truncated: false
            )
        }
        return runBoundedCommand(
            executableURL: pkgutilURL,
            arguments: arguments
        )
    }

    private static func listApplicationArchive(
        at url: URL,
        expectedFingerprint: InstallationFileFingerprint
    ) -> InstallationArchiveListingResult {
        let path = url.standardizedFileURL.path
        let wildcardCharacters = CharacterSet(charactersIn: "*?[]")
        guard path.count <= 4_096,
              !path.contains("\0"),
              path.rangeOfCharacter(from: wildcardCharacters) == nil,
              currentFingerprint(for: url) == expectedFingerprint else {
            return failedArchiveListing()
        }

        let listing = runZipinfo(arguments: ["-1", path])
        guard listing.succeeded,
              currentFingerprint(for: url) == expectedFingerprint else {
            return InstallationArchiveListingResult(
                exitCode: listing.exitCode,
                output: listing.output,
                reportedEntryCount: nil,
                timedOut: listing.timedOut,
                truncated: listing.truncated
            )
        }
        let totals = runZipinfo(arguments: ["-t", path])
        guard totals.succeeded,
              currentFingerprint(for: url) == expectedFingerprint,
              let entryCount = parseZipinfoEntryCount(totals.output) else {
            return InstallationArchiveListingResult(
                exitCode: totals.exitCode,
                output: listing.output,
                reportedEntryCount: nil,
                timedOut: listing.timedOut || totals.timedOut,
                truncated: listing.truncated || totals.truncated
            )
        }
        return InstallationArchiveListingResult(
            exitCode: 0,
            output: listing.output,
            reportedEntryCount: entryCount,
            timedOut: false,
            truncated: false
        )
    }

    private static func failedArchiveListing()
        -> InstallationArchiveListingResult {
        InstallationArchiveListingResult(
            exitCode: nil,
            output: Data(),
            reportedEntryCount: nil,
            timedOut: false,
            truncated: false
        )
    }

    private static func parseZipinfoEntryCount(_ data: Data) -> Int? {
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2,
                  let count = Int(fields[0]),
                  fields[1].lowercased().hasPrefix("file") else {
                continue
            }
            return count
        }
        return nil
    }

    private static func runZipinfo(
        arguments: [String]
    ) -> InstallationPackageCommandResult {
        guard arguments.count == 2,
              arguments[0] == "-1" || arguments[0] == "-t",
              arguments[1].hasPrefix("/"),
              arguments[1].count <= 4_096,
              !arguments[1].contains("\0"),
              FileManager.default.isExecutableFile(atPath: zipinfoURL.path) else {
            return InstallationPackageCommandResult(
                exitCode: nil,
                output: Data(),
                timedOut: false,
                truncated: false
            )
        }
        return runBoundedCommand(
            executableURL: zipinfoURL,
            arguments: arguments
        )
    }

    private static func runBoundedCommand(
        executableURL: URL,
        arguments: [String]
    ) -> InstallationPackageCommandResult {

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "C"
        environment["LC_ALL"] = "C"
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["ZIPINFO"] = ""
        environment["ZIPINFOOPT"] = ""
        process.environment = environment
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
            return InstallationPackageCommandResult(
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
        return InstallationPackageCommandResult(
            exitCode: process.isRunning ? nil : process.terminationStatus,
            output: snapshot.0,
            timedOut: timedOut,
            truncated: snapshot.1
        )
    }

    private static func signatureMetadata(
        at url: URL
    ) -> InstallationFileSignatureMetadata {
        let metadata = AppSignatureInspector.inspect(at: url)
        let status: InstallationFileSignatureStatus
        switch metadata.status {
        case .developerSigned: status = .developerSigned
        case .locallySigned: status = .locallySigned
        case .adHoc: status = .adHoc
        case .unsigned: status = .unsigned
        case .invalid: status = .invalid
        case .unknown: status = .unknown
        }
        let notarization: InstallationFileNotarizationStatus
        switch metadata.notarizationStatus {
        case .notarized: notarization = .notarized
        case .notNotarized: notarization = .notNotarized
        case .unknown: notarization = .unknown
        }
        return InstallationFileSignatureMetadata(
            status: status,
            signingIdentifier: metadata.signingIdentifier,
            teamIdentifier: metadata.teamIdentifier,
            developerName: metadata.developerName,
            notarizationStatus: notarization
        )
    }
}
