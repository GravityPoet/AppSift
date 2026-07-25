import CoreServices
import Darwin
import Foundation

enum BrowserPrivacyBrowser: String, CaseIterable, Codable, Hashable, Sendable {
    case safari
    case chrome
    case firefox

    var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .firefox: return "Firefox"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .firefox: return "org.mozilla.firefox"
        }
    }

    var icon: String {
        switch self {
        case .safari: return "safari.fill"
        case .chrome: return "globe"
        case .firefox: return "flame.fill"
        }
    }
}

enum BrowserPrivacyDataKind: String, CaseIterable, Codable, Hashable, Sendable {
    case historyAndDownloads
    case cookies
    case caches

    var title: String {
        switch self {
        case .historyAndDownloads: return String(localized: "History & Downloads")
        case .cookies: return String(localized: "Cookies")
        case .caches: return String(localized: "Caches")
        }
    }

    var icon: String {
        switch self {
        case .historyAndDownloads: return "clock.arrow.circlepath"
        case .cookies: return "circle.grid.3x3.fill"
        case .caches: return "shippingbox.fill"
        }
    }
}

enum BrowserPrivacyTargetAction: String, Codable, Hashable, Sendable {
    case trash
    case firefoxHistoryDatabase
}

struct BrowserPrivacyTarget: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let allowedRoot: URL
    let size: Int64
    let fingerprint: ReviewedTrashFingerprint
    let action: BrowserPrivacyTargetAction
}

struct BrowserPrivacyGroup: Identifiable, Hashable, Sendable {
    let id: String
    let browser: BrowserPrivacyBrowser
    let kind: BrowserPrivacyDataKind
    let profileCount: Int
    let targets: [BrowserPrivacyTarget]
    let allocatedSize: Int64
    let latestModificationDate: Date?

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: allocatedSize, countStyle: .file)
    }
}

struct BrowserPrivacyScanResult: Sendable {
    let groups: [BrowserPrivacyGroup]
    let inaccessibleCount: Int
    let wasTruncated: Bool
}

actor BrowserPrivacyScanner {
    private static let maximumEntriesPerTarget = 1_000_000
    private static let maximumTargets = 10_000

    private let fileManager: FileManager
    private let currentUserID: uid_t
    private let homeURL: URL

    init(
        fileManager: FileManager = .default,
        currentUserID: uid_t = getuid(),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.currentUserID = currentUserID
        self.homeURL = homeURL.standardizedFileURL
    }

    func scan() throws -> BrowserPrivacyScanResult {
        try Task.checkCancellation()
        var groups: [BrowserPrivacyGroup] = []
        var inaccessible = 0
        var truncated = false

        let safari = scanSafari(inaccessible: &inaccessible, truncated: &truncated)
        groups.append(contentsOf: safari)
        try Task.checkCancellation()
        let chrome = scanChrome(inaccessible: &inaccessible, truncated: &truncated)
        groups.append(contentsOf: chrome)
        try Task.checkCancellation()
        let firefox = scanFirefox(inaccessible: &inaccessible, truncated: &truncated)
        groups.append(contentsOf: firefox)
        try Task.checkCancellation()

        return BrowserPrivacyScanResult(
            groups: groups.sorted {
                if $0.browser.rawValue != $1.browser.rawValue {
                    return $0.browser.rawValue < $1.browser.rawValue
                }
                return $0.kind.rawValue < $1.kind.rawValue
            },
            inaccessibleCount: inaccessible,
            wasTruncated: truncated
        )
    }

    private func scanSafari(
        inaccessible: inout Int,
        truncated: inout Bool
    ) -> [BrowserPrivacyGroup] {
        let supportRoot = homeURL.appendingPathComponent("Library/Safari", isDirectory: true)
        let containerLibrary = homeURL.appendingPathComponent(
            "Library/Containers/com.apple.Safari/Data/Library",
            isDirectory: true
        )
        let cacheRoot = homeURL.appendingPathComponent("Library/Caches", isDirectory: true)

        let historyCandidates = [
            supportRoot.appendingPathComponent("History.db"),
            supportRoot.appendingPathComponent("History.db-wal"),
            supportRoot.appendingPathComponent("History.db-shm"),
            supportRoot.appendingPathComponent("Downloads.plist"),
            containerLibrary.appendingPathComponent("Safari/Downloads.plist"),
        ]
        let cookieCandidates = [
            homeURL.appendingPathComponent("Library/Cookies/Cookies.binarycookies"),
            containerLibrary.appendingPathComponent("Cookies/Cookies.binarycookies"),
            containerLibrary.appendingPathComponent("Cookies/Cookies.binarycookies-wal"),
            containerLibrary.appendingPathComponent("Cookies/Cookies.binarycookies-shm"),
        ]
        let cacheCandidates = [
            cacheRoot.appendingPathComponent("com.apple.Safari", isDirectory: true),
            containerLibrary.appendingPathComponent("Caches", isDirectory: true),
            containerLibrary.appendingPathComponent("WebKit/WebsiteData/NetworkCache", isDirectory: true),
        ]

        return makeGroups(
            browser: .safari,
            profileCount: 1,
            candidates: [
                (.historyAndDownloads, historyCandidates, .trash),
                (.cookies, cookieCandidates, .trash),
                (.caches, cacheCandidates, .trash),
            ],
            roots: [supportRoot, containerLibrary, cacheRoot],
            inaccessible: &inaccessible,
            truncated: &truncated
        )
    }

    private func scanChrome(
        inaccessible: inout Int,
        truncated: inout Bool
    ) -> [BrowserPrivacyGroup] {
        let supportRoot = homeURL.appendingPathComponent(
            "Library/Application Support/Google/Chrome",
            isDirectory: true
        )
        let cacheRoot = homeURL.appendingPathComponent("Library/Caches/Google/Chrome", isDirectory: true)
        let profiles = profileDirectories(
            under: supportRoot,
            names: { name in
                name == "Default" || name == "Guest Profile" || name.hasPrefix("Profile ")
            }
        )

        var history: [URL] = []
        var cookies: [URL] = []
        var caches: [URL] = []
        for profile in profiles {
            history.append(contentsOf: sidecarPaths(for: profile.appendingPathComponent("History")))
            cookies.append(contentsOf: sidecarPaths(for: profile.appendingPathComponent("Network/Cookies")))
            caches.append(contentsOf: [
                profile.appendingPathComponent("Cache", isDirectory: true),
                profile.appendingPathComponent("Code Cache", isDirectory: true),
                profile.appendingPathComponent("GPUCache", isDirectory: true),
            ])
        }
        if profiles.isEmpty, fileManager.fileExists(atPath: supportRoot.path) {
            inaccessible += 1
        }
        caches.append(cacheRoot)

        return makeGroups(
            browser: .chrome,
            profileCount: max(1, profiles.count),
            candidates: [
                (.historyAndDownloads, history, .trash),
                (.cookies, cookies, .trash),
                (.caches, caches, .trash),
            ],
            roots: [supportRoot, cacheRoot],
            inaccessible: &inaccessible,
            truncated: &truncated
        )
    }

    private func scanFirefox(
        inaccessible: inout Int,
        truncated: inout Bool
    ) -> [BrowserPrivacyGroup] {
        let supportRoot = homeURL.appendingPathComponent(
            "Library/Application Support/Firefox/Profiles",
            isDirectory: true
        )
        let cacheRoot = homeURL.appendingPathComponent("Library/Caches/Firefox/Profiles", isDirectory: true)
        let profiles = profileDirectories(under: supportRoot) { !$0.hasPrefix(".") }

        var history: [URL] = []
        var cookies: [URL] = []
        var caches: [URL] = []
        for profile in profiles {
            history.append(profile.appendingPathComponent("places.sqlite"))
            cookies.append(contentsOf: sidecarPaths(for: profile.appendingPathComponent("cookies.sqlite")))
            caches.append(cacheRoot.appendingPathComponent(profile.lastPathComponent, isDirectory: true))
        }

        return makeGroups(
            browser: .firefox,
            profileCount: max(1, profiles.count),
            candidates: [
                (.historyAndDownloads, history, .firefoxHistoryDatabase),
                (.cookies, cookies, .trash),
                (.caches, caches, .trash),
            ],
            roots: [supportRoot, cacheRoot],
            inaccessible: &inaccessible,
            truncated: &truncated
        )
    }

    private func makeGroups(
        browser: BrowserPrivacyBrowser,
        profileCount: Int,
        candidates: [(BrowserPrivacyDataKind, [URL], BrowserPrivacyTargetAction)],
        roots: [URL],
        inaccessible: inout Int,
        truncated: inout Bool
    ) -> [BrowserPrivacyGroup] {
        var groups: [BrowserPrivacyGroup] = []
        var targetCount = 0
        for (kind, urls, action) in candidates {
            var targets: [BrowserPrivacyTarget] = []
            var latestDate: Date?
            for candidate in Array(Set(urls.map(\.standardizedFileURL))).sorted(by: { $0.path < $1.path }) {
                if targetCount >= Self.maximumTargets {
                    truncated = true
                    break
                }
                guard let root = roots.first(where: { isDescendant(candidate, of: $0) || candidate.path == $0.path }),
                      let fingerprint = ReviewedTrashFingerprint.read(at: candidate),
                      fingerprint.owner == UInt32(currentUserID) else {
                    if fileManager.fileExists(atPath: candidate.path) { inaccessible += 1 }
                    continue
                }
                let measurement = measure(candidate)
                if measurement.inaccessible { inaccessible += 1 }
                if measurement.wasTruncated { truncated = true }
                guard measurement.allocated > 0 || fileManager.fileExists(atPath: candidate.path) else { continue }
                let modificationDate = try? candidate.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                if let modificationDate,
                   latestDate == nil || modificationDate > latestDate! {
                    latestDate = modificationDate
                }
                targets.append(
                    BrowserPrivacyTarget(
                        id: candidate.path,
                        url: candidate,
                        allowedRoot: root,
                        size: measurement.allocated,
                        fingerprint: fingerprint,
                        action: action
                    )
                )
                targetCount += 1
            }
            guard !targets.isEmpty else { continue }
            groups.append(
                BrowserPrivacyGroup(
                    id: "\(browser.rawValue):\(kind.rawValue)",
                    browser: browser,
                    kind: kind,
                    profileCount: profileCount,
                    targets: targets,
                    allocatedSize: targets.reduce(0) { $0 + $1.size },
                    latestModificationDate: latestDate
                )
            )
        }
        return groups
    }

    private func measure(_ url: URL) -> (allocated: Int64, inaccessible: Bool, wasTruncated: Bool) {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return (0, true, false) }
        if information.st_mode & S_IFMT == S_IFREG {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return (
                Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? Int(information.st_blocks) * 512),
                false,
                false
            )
        }
        var inaccessible = false
        guard information.st_mode & S_IFMT == S_IFDIR,
              let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .totalFileAllocatedSizeKey,
                    .isUbiquitousItemKey,
                    .ubiquitousItemDownloadingStatusKey,
                ],
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in
                    inaccessible = true
                    return true
                }
              ) else { return (0, true, false) }

        var allocated: Int64 = 0
        var entryCount = 0
        var seen: Set<FileIdentity> = []
        for case let child as URL in enumerator {
            entryCount += 1
            if entryCount & 127 == 0, Task.isCancelled {
                return (allocated, inaccessible, true)
            }
            guard entryCount <= Self.maximumEntriesPerTarget else {
                return (allocated, inaccessible, true)
            }
            guard let values = try? child.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey,
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
            ]) else {
                inaccessible = true
                continue
            }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                inaccessible = true
                continue
            }
            if values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus != .current { continue }
            var childStat = stat()
            guard lstat(child.path, &childStat) == 0,
                  childStat.st_mode & S_IFMT == S_IFREG else {
                inaccessible = true
                continue
            }
            let identity = FileIdentity(device: UInt64(childStat.st_dev), inode: UInt64(childStat.st_ino))
            guard seen.insert(identity).inserted else { continue }
            allocated += Int64(values.totalFileAllocatedSize ?? Int(childStat.st_blocks) * 512)
        }
        return (allocated, inaccessible, false)
    }

    private func profileDirectories(
        under root: URL,
        names: (String) -> Bool
    ) -> [URL] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.filter { child in
            guard names(child.lastPathComponent),
                  let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    private func sidecarPaths(for database: URL) -> [URL] {
        [
            database,
            URL(fileURLWithPath: database.path + "-wal"),
            URL(fileURLWithPath: database.path + "-shm"),
        ]
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path != rootPath && path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }
}
