import CoreServices
import Darwin
import Foundation

enum DownloadSource: String, CaseIterable, Codable, Hashable, Sendable {
    case safari
    case chrome
    case firefox
    case slack
    case mail
    case airDrop
    case otherApplication
    case unknown
}

struct DownloadSourceItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let size: Int64
    let modifiedAt: Date?
    let source: DownloadSource
    let sourceAgentName: String?
    let originHost: String?
    let fingerprint: ReviewedTrashFingerprint
}

struct DownloadSourceScanResult: Sendable {
    let items: [DownloadSourceItem]
    let inaccessibleCount: Int
    let cloudPlaceholderCount: Int
    let wasTruncated: Bool
    let scannedAt: Date
}

enum DownloadSourceScanError: LocalizedError, Equatable {
    case rootUnavailable
    case unsafeRoot

    var errorDescription: String? {
        switch self {
        case .rootUnavailable:
            return String(localized: "The Downloads folder is unavailable.")
        case .unsafeRoot:
            return String(localized: "AppSift refused to scan an unsafe Downloads folder path.")
        }
    }
}

actor DownloadSourceScanner {
    private static let maximumItems = 100_000
    private let rootURL: URL
    private let homeURL: URL
    private let currentUserID: uid_t

    init(
        rootURL: URL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        currentUserID: uid_t = getuid()
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.homeURL = homeURL.standardizedFileURL
        self.currentUserID = currentUserID
    }

    func scan() throws -> DownloadSourceScanResult {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            throw DownloadSourceScanError.rootUnavailable
        }
        guard Self.isOwnedSafeDirectory(rootURL, currentUserID: currentUserID),
              rootURL.path != homeURL.path,
              rootURL.path.hasPrefix(homeURL.path + "/") else {
            throw DownloadSourceScanError.unsafeRoot
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .quarantinePropertiesKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw DownloadSourceScanError.rootUnavailable
        }

        var items: [DownloadSourceItem] = []
        var inaccessible = 0
        var cloudPlaceholders = 0
        var truncated = false

        while let candidate = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            if items.count >= Self.maximumItems {
                truncated = true
                break
            }
            guard let values = try? candidate.resourceValues(forKeys: keys) else {
                inaccessible += 1
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            if values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus != .current {
                cloudPlaceholders += 1
                continue
            }
            guard let fingerprint = ReviewedTrashFingerprint.read(at: candidate),
                  fingerprint.owner == UInt32(currentUserID) else {
                inaccessible += 1
                continue
            }
            let quarantine = Self.quarantineMetadata(values.quarantineProperties)
            let source = Self.classify(
                agentName: quarantine.agentName,
                bundleIdentifier: quarantine.bundleIdentifier,
                originHost: quarantine.originHost
            )
            items.append(
                DownloadSourceItem(
                    id: candidate.standardizedFileURL.path,
                    url: candidate.standardizedFileURL,
                    name: candidate.lastPathComponent,
                    size: Int64(max(0, values.totalFileAllocatedSize ?? values.fileSize ?? 0)),
                    modifiedAt: values.contentModificationDate,
                    source: source,
                    sourceAgentName: quarantine.agentName,
                    originHost: quarantine.originHost,
                    fingerprint: fingerprint
                )
            )
        }

        items.sort {
            if $0.source != $1.source { return $0.source.sortOrder < $1.source.sortOrder }
            if $0.modifiedAt != $1.modifiedAt {
                return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
            }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        return DownloadSourceScanResult(
            items: items,
            inaccessibleCount: inaccessible,
            cloudPlaceholderCount: cloudPlaceholders,
            wasTruncated: truncated,
            scannedAt: Date()
        )
    }

    static func classify(
        agentName: String?,
        bundleIdentifier: String?,
        originHost _: String?
    ) -> DownloadSource {
        let evidence = [agentName, bundleIdentifier]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if evidence.contains("com.apple.safari") || evidence.contains("safari") {
            return .safari
        }
        if evidence.contains("com.google.chrome")
            || evidence.contains("google chrome")
            || evidence.contains("chromium") {
            return .chrome
        }
        if evidence.contains("org.mozilla.firefox") || evidence.contains("firefox") {
            return .firefox
        }
        if evidence.contains("com.tinyspeck.slackmacgap")
            || evidence.contains("slack") {
            return .slack
        }
        if evidence.contains("com.apple.mail") || evidence.contains("apple mail") {
            return .mail
        }
        if evidence.contains("airdrop") || evidence.contains("sharingd") {
            return .airDrop
        }
        if agentName != nil || bundleIdentifier != nil { return .otherApplication }
        return .unknown
    }

    private static func quarantineMetadata(
        _ properties: [String: Any]?
    ) -> (agentName: String?, bundleIdentifier: String?, originHost: String?) {
        guard let properties else { return (nil, nil, nil) }
        let agentName = sanitized(properties[kLSQuarantineAgentNameKey as String] as? String, maximum: 256)
        let bundleIdentifier = sanitized(
            properties[kLSQuarantineAgentBundleIdentifierKey as String] as? String,
            maximum: 512
        )
        let urlValue = properties[kLSQuarantineDataURLKey as String]
            ?? properties[kLSQuarantineOriginURLKey as String]
        let url: URL?
        if let value = urlValue as? URL {
            url = value
        } else if let value = urlValue as? String, value.count <= 2_048 {
            url = URL(string: value)
        } else {
            url = nil
        }
        let host: String?
        if let url,
           url.user == nil,
           url.password == nil,
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           let rawHost = url.host {
            host = sanitized(rawHost, maximum: 253)
        } else {
            host = nil
        }
        return (agentName, bundleIdentifier, host)
    }

    private static func sanitized(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let result = value.components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.count <= maximum else { return nil }
        return result
    }

    private static func isOwnedSafeDirectory(_ url: URL, currentUserID: uid_t) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFDIR
            && information.st_uid == currentUserID
            && information.st_mode & S_IWOTH == 0
    }
}

private extension DownloadSource {
    var sortOrder: Int {
        switch self {
        case .safari: return 0
        case .chrome: return 1
        case .firefox: return 2
        case .slack: return 3
        case .mail: return 4
        case .airDrop: return 5
        case .otherApplication: return 6
        case .unknown: return 7
        }
    }
}
