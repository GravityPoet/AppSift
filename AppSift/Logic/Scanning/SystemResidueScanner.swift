import Darwin
import Foundation

enum LegacyUserResidueKind: String, Hashable, Sendable {
    case missingAccount
    case deletedUsersFolder
    case deletedUserDiskImage
    case ownerMismatch
}

struct LegacyUserResidue: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let kind: LegacyUserResidueKind
    let ownerID: UInt32
    let expectedOwnerID: UInt32?
    let allocatedSize: Int64
    let fileCount: Int
    let isAccessible: Bool
    let wasTruncated: Bool
}

struct CorruptPreferenceItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let size: Int64
    let modifiedAt: Date?
    let reason: String
    let fingerprint: ReviewedTrashFingerprint
    let allowedRoot: URL

    var candidate: ReviewedTrashCandidate {
        ReviewedTrashCandidate(
            id: id,
            name: url.lastPathComponent,
            url: url,
            size: size,
            fingerprint: fingerprint,
            allowedRoot: allowedRoot,
            requiresDirectChild: false
        )
    }
}

struct DocumentVersionItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let versionCount: Int
    let newestVersionDate: Date?
    let currentModificationDate: Date?
}

struct SystemResidueScanStatistics: Hashable, Sendable {
    let preferenceFilesChecked: Int
    let documentFilesChecked: Int
    let inaccessibleCount: Int
    let cloudPlaceholderCount: Int
    let wasTruncated: Bool
}

struct SystemResidueScanResult: Sendable {
    let legacyUsers: [LegacyUserResidue]
    let corruptPreferences: [CorruptPreferenceItem]
    let documentVersions: [DocumentVersionItem]
    let statistics: SystemResidueScanStatistics
}

actor SystemResidueScanner {
    typealias LocalAccountsProvider = @Sendable () -> [String: UInt32]

    private static let maximumPreferenceFiles = 50_000
    private static let maximumPreferenceBytes = 16_000_000
    private static let maximumDocumentFiles = 50_000
    private static let maximumVersionResults = 5_000
    private static let maximumLegacyEntriesPerDirectory = 1_000_000

    private let fileManager: FileManager
    private let currentUserID: uid_t
    private let usersRootURL: URL
    private let homeURL: URL
    private let documentRoots: [URL]?
    private let localAccountsProvider: LocalAccountsProvider

    init(
        fileManager: FileManager = .default,
        currentUserID: uid_t = getuid(),
        usersRootURL: URL = URL(fileURLWithPath: "/Users", isDirectory: true),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        documentRoots: [URL]? = nil,
        localAccountsProvider: LocalAccountsProvider? = nil
    ) {
        self.fileManager = fileManager
        self.currentUserID = currentUserID
        self.usersRootURL = usersRootURL.standardizedFileURL
        self.homeURL = homeURL.standardizedFileURL
        self.documentRoots = documentRoots?.map(\.standardizedFileURL)
        self.localAccountsProvider = localAccountsProvider ?? { Self.localAccounts() }
    }

    func scan() throws -> SystemResidueScanResult {
        try Task.checkCancellation()
        var inaccessibleCount = 0
        var cloudPlaceholderCount = 0
        var wasTruncated = false

        let legacyUsers = try scanLegacyUsers(
            inaccessibleCount: &inaccessibleCount,
            wasTruncated: &wasTruncated
        )
        let preferenceResult = try scanPreferences()
        inaccessibleCount += preferenceResult.inaccessible
        wasTruncated = wasTruncated || preferenceResult.truncated
        let versionResult = try scanDocumentVersions()
        inaccessibleCount += versionResult.inaccessible
        cloudPlaceholderCount += versionResult.cloudPlaceholders
        wasTruncated = wasTruncated || versionResult.truncated

        return SystemResidueScanResult(
            legacyUsers: legacyUsers,
            corruptPreferences: preferenceResult.items,
            documentVersions: versionResult.items,
            statistics: SystemResidueScanStatistics(
                preferenceFilesChecked: preferenceResult.checked,
                documentFilesChecked: versionResult.checked,
                inaccessibleCount: inaccessibleCount,
                cloudPlaceholderCount: cloudPlaceholderCount,
                wasTruncated: wasTruncated
            )
        )
    }

    func revalidatePreferences(_ expected: [CorruptPreferenceItem]) -> [CorruptPreferenceItem] {
        expected.compactMap { item in
            guard item.url.path.hasPrefix(item.allowedRoot.path + "/"),
                  ReviewedTrashFingerprint.read(at: item.url) == item.fingerprint,
                  let current = Self.preferenceFailure(at: item.url),
                  current.reason == item.reason else {
                return nil
            }
            return item
        }
    }

    private func scanLegacyUsers(
        inaccessibleCount: inout Int,
        wasTruncated: inout Bool
    ) throws -> [LegacyUserResidue] {
        let usersRoot = usersRootURL
        guard Self.isDirectory(usersRoot) else { return [] }
        let accounts = localAccountsProvider()
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: usersRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            inaccessibleCount += 1
            return []
        }

        var results: [LegacyUserResidue] = []
        for url in children {
            try Task.checkCancellation()
            let name = url.lastPathComponent
            guard name != "Shared",
                  let values = try? url.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                  ]),
                  values.isSymbolicLink != true,
                  let ownerID = Self.ownerID(url) else {
                continue
            }

            let kind: LegacyUserResidueKind?
            let extensionName = url.pathExtension.lowercased()
            let isDiskImage = values.isRegularFile == true
                && ["dmg", "sparseimage"].contains(extensionName)
            let isSparseBundle = values.isDirectory == true && extensionName == "sparsebundle"
            let accountName = (isDiskImage || isSparseBundle)
                ? url.deletingPathExtension().lastPathComponent
                : name
            let expectedOwnerID = accounts[accountName.lowercased()]
            if values.isDirectory == true && name == "Deleted Users" {
                kind = .deletedUsersFolder
            } else if (isDiskImage || isSparseBundle), expectedOwnerID == nil {
                kind = .deletedUserDiskImage
            } else if values.isDirectory != true {
                kind = nil
            } else if let expectedOwnerID, expectedOwnerID != ownerID {
                kind = .ownerMismatch
            } else if expectedOwnerID == nil {
                kind = .missingAccount
            } else {
                kind = nil
            }
            guard let kind else { continue }

            let measurement: (
                allocatedSize: Int64,
                fileCount: Int,
                isAccessible: Bool,
                wasTruncated: Bool
            )
            if values.isRegularFile == true {
                measurement = Self.regularFileSize(url)
            } else {
                measurement = try directorySize(url)
            }
            if !measurement.isAccessible { inaccessibleCount += 1 }
            if measurement.wasTruncated { wasTruncated = true }
            results.append(
                LegacyUserResidue(
                    id: url.path,
                    url: url,
                    kind: kind,
                    ownerID: ownerID,
                    expectedOwnerID: expectedOwnerID,
                    allocatedSize: measurement.allocatedSize,
                    fileCount: measurement.fileCount,
                    isAccessible: measurement.isAccessible,
                    wasTruncated: measurement.wasTruncated
                )
            )
        }

        return results.sorted {
            if $0.allocatedSize != $1.allocatedSize { return $0.allocatedSize > $1.allocatedSize }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    private func scanPreferences() throws -> (
        items: [CorruptPreferenceItem], checked: Int, inaccessible: Int, truncated: Bool
    ) {
        let root = homeURL
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .standardizedFileURL
        guard Self.isOwnedDirectory(root, owner: currentUserID) else {
            return ([], 0, FileManager.default.fileExists(atPath: root.path) ? 1 : 0, false)
        }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        var inaccessible = 0
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                inaccessible += 1
                return true
            }
        ) else {
            return ([], 0, 1, false)
        }

        var results: [CorruptPreferenceItem] = []
        var checked = 0
        var truncated = false
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard checked < Self.maximumPreferenceFiles else {
                truncated = true
                break
            }
            guard let values = try? url.resourceValues(forKeys: keys) else {
                inaccessible += 1
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true,
                  url.pathExtension.lowercased() == "plist" else { continue }
            checked += 1
            guard let failure = Self.preferenceFailure(at: url) else { continue }
            guard let fingerprint = ReviewedTrashFingerprint.read(at: url),
                  fingerprint.owner == UInt32(currentUserID) else {
                inaccessible += 1
                continue
            }
            results.append(
                CorruptPreferenceItem(
                    id: url.path,
                    url: url.standardizedFileURL,
                    size: failure.size,
                    modifiedAt: values.contentModificationDate,
                    reason: failure.reason,
                    fingerprint: fingerprint,
                    allowedRoot: root
                )
            )
        }
        results.sort {
            ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
        }
        return (results, checked, inaccessible, truncated)
    }

    private func scanDocumentVersions() throws -> (
        items: [DocumentVersionItem], checked: Int, inaccessible: Int,
        cloudPlaceholders: Int, truncated: Bool
    ) {
        let roots = (documentRoots ?? [
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first,
        ]
        .compactMap { $0?.standardizedFileURL })
        .filter { Self.isOwnedDirectory($0, owner: currentUserID) }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .contentModificationDateKey,
        ]
        var results: [DocumentVersionItem] = []
        var checked = 0
        var inaccessible = 0
        var cloudPlaceholders = 0
        var truncated = false
        var seenPaths: Set<String> = []

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    inaccessible += 1
                    return true
                }
            ) else {
                inaccessible += 1
                continue
            }
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                guard checked < Self.maximumDocumentFiles,
                      results.count < Self.maximumVersionResults else {
                    truncated = true
                    break
                }
                guard seenPaths.insert(url.standardizedFileURL.path).inserted else { continue }
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    continue
                }
                checked += 1
                if values.isUbiquitousItem == true,
                   values.ubiquitousItemDownloadingStatus != .current {
                    cloudPlaceholders += 1
                    continue
                }
                guard let fingerprint = ReviewedTrashFingerprint.read(at: url),
                      fingerprint.owner == UInt32(currentUserID) else {
                    inaccessible += 1
                    continue
                }
                let versions = NSFileVersion.otherVersionsOfItem(at: url) ?? []
                guard !versions.isEmpty else { continue }
                results.append(
                    DocumentVersionItem(
                        id: url.path,
                        url: url.standardizedFileURL,
                        name: url.lastPathComponent,
                        versionCount: versions.count,
                        newestVersionDate: versions.compactMap(\.modificationDate).max(),
                        currentModificationDate: values.contentModificationDate
                    )
                )
            }
            if truncated { break }
        }
        results.sort {
            if $0.versionCount != $1.versionCount { return $0.versionCount > $1.versionCount }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        return (results, checked, inaccessible, cloudPlaceholders, truncated)
    }

    private func directorySize(
        _ root: URL
    ) throws -> (allocatedSize: Int64, fileCount: Int, isAccessible: Bool, wasTruncated: Bool) {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        var accessible = true
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                accessible = false
                return true
            }
        ) else {
            return (0, 0, false, false)
        }
        var size: Int64 = 0
        var count = 0
        var entryCount = 0
        var truncated = false
        var seen: Set<FileIdentity> = []
        while let url = enumerator.nextObject() as? URL {
            entryCount += 1
            if entryCount & 127 == 0 { try Task.checkCancellation() }
            guard entryCount <= Self.maximumLegacyEntriesPerDirectory else {
                truncated = true
                break
            }
            guard let values = try? url.resourceValues(forKeys: keys) else {
                accessible = false
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            if values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus != .current {
                continue
            }
            var information = stat()
            guard lstat(url.path, &information) == 0 else {
                accessible = false
                continue
            }
            let identity = FileIdentity(device: UInt64(information.st_dev), inode: UInt64(information.st_ino))
            guard seen.insert(identity).inserted else { continue }
            count += 1
            size += Int64(values.totalFileAllocatedSize ?? Int(information.st_blocks) * 512)
        }
        return (size, count, accessible, truncated)
    }

    private static func preferenceFailure(at url: URL) -> (reason: String, size: Int64)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0 else {
            return nil
        }
        guard fileSize <= maximumPreferenceBytes else { return nil }
        if fileSize == 0 {
            return (String(localized: "The property list is empty."), 0)
        }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= maximumPreferenceBytes else { return nil }
            _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            return nil
        } catch {
            return (
                String(localized: "The property list cannot be parsed."),
                Int64(fileSize)
            )
        }
    }

    private static func localAccounts() -> [String: UInt32] {
        var result: [String: UInt32] = [:]
        setpwent()
        defer { endpwent() }
        while let account = getpwent() {
            let name = String(cString: account.pointee.pw_name)
            guard !name.isEmpty, !name.contains("/") else { continue }
            result[name.lowercased()] = UInt32(account.pointee.pw_uid)
        }
        return result
    }

    private static func ownerID(_ url: URL) -> UInt32? {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return nil }
        return UInt32(information.st_uid)
    }

    private static func regularFileSize(
        _ url: URL
    ) -> (allocatedSize: Int64, fileCount: Int, isAccessible: Bool, wasTruncated: Bool) {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else {
            return (0, 0, false, false)
        }
        return (Int64(information.st_blocks) * 512, 1, true, false)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0
            && information.st_mode & S_IFMT == S_IFDIR
    }

    private static func isOwnedDirectory(_ url: URL, owner: uid_t) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0
            && information.st_mode & S_IFMT == S_IFDIR
            && information.st_uid == owner
            && information.st_mode & S_IWOTH == 0
    }

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }
}
