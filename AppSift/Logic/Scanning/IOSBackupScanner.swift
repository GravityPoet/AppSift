import Darwin
import Foundation

enum IOSBackupCompletionState: String, Codable, Hashable, Sendable {
    case finished
    case inProgress
    case unknown
}

struct IOSBackupItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let directoryName: String
    let deviceIdentifier: String
    let deviceName: String
    let productType: String?
    let productVersion: String?
    let lastBackupDate: Date?
    let modificationDate: Date?
    let isEncrypted: Bool
    let completionState: IOSBackupCompletionState
    let logicalSize: Int64
    let allocatedSize: Int64
    let fileCount: Int
    let fingerprint: ReviewedTrashFingerprint
    var isLatestForDevice: Bool

    var isSafeToRemove: Bool {
        completionState != .inProgress
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: allocatedSize, countStyle: .file)
    }
}

struct IOSBackupScanResult: Sendable {
    let rootURL: URL
    let backups: [IOSBackupItem]
    let skippedCount: Int
    let inaccessibleCount: Int
    let wasTruncated: Bool
}

enum IOSBackupScanError: LocalizedError, Equatable {
    case unavailable
    case unsafeRoot

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return String(localized: "The local device backup folder is unavailable.")
        case .unsafeRoot:
            return String(localized: "The local device backup folder could not be validated safely.")
        }
    }
}

actor IOSBackupScanner {
    private static let maximumBackups = 512
    private static let maximumEntries = 2_000_000
    private static let maximumPlistBytes = 8_000_000

    private let fileManager: FileManager
    private let currentUserID: uid_t

    init(fileManager: FileManager = .default, currentUserID: uid_t = getuid()) {
        self.fileManager = fileManager
        self.currentUserID = currentUserID
    }

    func scan(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MobileSync/Backup", isDirectory: true)
    ) throws -> IOSBackupScanResult {
        try Task.checkCancellation()
        let standardizedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard standardizedRoot.path.hasPrefix("/"),
              !standardizedRoot.path.contains("\0") else {
            throw IOSBackupScanError.unsafeRoot
        }

        var rootStat = stat()
        guard lstat(standardizedRoot.path, &rootStat) == 0 else {
            if errno == ENOENT {
                return IOSBackupScanResult(
                    rootURL: standardizedRoot,
                    backups: [],
                    skippedCount: 0,
                    inaccessibleCount: 0,
                    wasTruncated: false
                )
            }
            throw IOSBackupScanError.unavailable
        }
        guard rootStat.st_mode & S_IFMT == S_IFDIR,
              rootStat.st_uid == currentUserID else {
            throw IOSBackupScanError.unsafeRoot
        }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: standardizedRoot,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                ],
                options: []
            )
        } catch {
            throw IOSBackupScanError.unavailable
        }

        var backups: [IOSBackupItem] = []
        var skipped = 0
        var inaccessible = 0
        var truncated = false
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            guard backups.count < Self.maximumBackups else {
                truncated = true
                break
            }
            guard isDirectChild(child, of: standardizedRoot),
                  let values = try? child.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                  ]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let fingerprint = ReviewedTrashFingerprint.read(at: child),
                  fingerprint.owner == UInt32(currentUserID) else {
                skipped += 1
                continue
            }

            let info = readPlist(child.appendingPathComponent("Info.plist"))
            let manifest = readPlist(child.appendingPathComponent("Manifest.plist"))
            let status = readPlist(child.appendingPathComponent("Status.plist"))
            guard info != nil || manifest != nil || status != nil else {
                skipped += 1
                continue
            }

            let size = directorySize(child)
            if size.inaccessible { inaccessible += 1 }
            if size.wasTruncated { truncated = true }

            let directoryName = child.lastPathComponent
            let targetIdentifier = stringValue(info?["Target Identifier"])
                ?? stringValue(info?["Unique Identifier"])
                ?? directoryName.split(separator: "-").first.map(String.init)
                ?? directoryName
            let deviceName = stringValue(info?["Device Name"])
                ?? stringValue(info?["Display Name"])
                ?? String(localized: "Unknown Device")
            let state = completionState(
                status: status,
                modificationDate: values.contentModificationDate
            )

            backups.append(
                IOSBackupItem(
                    id: child.path,
                    url: child,
                    directoryName: directoryName,
                    deviceIdentifier: targetIdentifier,
                    deviceName: deviceName,
                    productType: stringValue(info?["Product Type"]),
                    productVersion: stringValue(info?["Product Version"]),
                    lastBackupDate: dateValue(info?["Last Backup Date"])
                        ?? dateValue(status?["Date"])
                        ?? values.contentModificationDate,
                    modificationDate: values.contentModificationDate,
                    isEncrypted: boolValue(manifest?["IsEncrypted"]),
                    completionState: state,
                    logicalSize: size.logical,
                    allocatedSize: size.allocated,
                    fileCount: size.fileCount,
                    fingerprint: fingerprint,
                    isLatestForDevice: false
                )
            )
        }
        try Task.checkCancellation()

        markLatestBackups(&backups)
        backups.sort {
            let lhsDate = $0.lastBackupDate ?? $0.modificationDate ?? .distantPast
            let rhsDate = $1.lastBackupDate ?? $1.modificationDate ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending
        }
        return IOSBackupScanResult(
            rootURL: standardizedRoot,
            backups: backups,
            skippedCount: skipped,
            inaccessibleCount: inaccessible,
            wasTruncated: truncated
        )
    }

    private func directorySize(
        _ root: URL
    ) -> (logical: Int64, allocated: Int64, fileCount: Int, inaccessible: Bool, wasTruncated: Bool) {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        var inaccessible = false
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                inaccessible = true
                return true
            }
        ) else {
            return (0, 0, 0, true, false)
        }

        var logical: Int64 = 0
        var allocated: Int64 = 0
        var fileCount = 0
        var entryCount = 0
        var truncated = false
        var seenFiles: Set<FileIdentity> = []

        for case let url as URL in enumerator {
            entryCount += 1
            if entryCount & 127 == 0, Task.isCancelled {
                truncated = true
                break
            }
            guard entryCount <= Self.maximumEntries else {
                truncated = true
                break
            }
            guard let values = try? url.resourceValues(forKeys: keys) else {
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
               values.ubiquitousItemDownloadingStatus != .current {
                continue
            }
            var information = stat()
            guard lstat(url.path, &information) == 0,
                  information.st_mode & S_IFMT == S_IFREG else {
                inaccessible = true
                continue
            }
            let identity = FileIdentity(device: UInt64(information.st_dev), inode: UInt64(information.st_ino))
            guard seenFiles.insert(identity).inserted else { continue }
            fileCount += 1
            logical += Int64(values.fileSize ?? Int(information.st_size))
            allocated += Int64(values.totalFileAllocatedSize ?? Int(information.st_blocks) * 512)
        }
        return (logical, allocated, fileCount, inaccessible, truncated)
    }

    private func readPlist(_ url: URL) -> [String: Any]? {
        guard let values = try? url.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .isSymbolicLinkKey,
                  .fileSizeKey,
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= Self.maximumPlistBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= Self.maximumPlistBytes,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any] else {
            return nil
        }
        return plist
    }

    private func completionState(
        status: [String: Any]?,
        modificationDate: Date?
    ) -> IOSBackupCompletionState {
        if let raw = stringValue(status?["SnapshotState"])?.lowercased() {
            if raw == "finished" || raw == "complete" { return .finished }
            if raw.contains("progress") || raw.contains("backup") || raw.contains("writing") {
                return .inProgress
            }
        }
        if let modificationDate,
           Date().timeIntervalSince(modificationDate) < 15 * 60 {
            return .inProgress
        }
        return .unknown
    }

    private func markLatestBackups(_ backups: inout [IOSBackupItem]) {
        var latestIndexByDevice: [String: Int] = [:]
        for index in backups.indices {
            let key = backups[index].deviceIdentifier
            guard let previous = latestIndexByDevice[key] else {
                latestIndexByDevice[key] = index
                continue
            }
            let currentDate = backups[index].lastBackupDate ?? backups[index].modificationDate ?? .distantPast
            let previousDate = backups[previous].lastBackupDate ?? backups[previous].modificationDate ?? .distantPast
            if currentDate > previousDate { latestIndexByDevice[key] = index }
        }
        for index in latestIndexByDevice.values {
            backups[index].isLatestForDevice = true
        }
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(256))
    }

    private func dateValue(_ value: Any?) -> Date? {
        value as? Date
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private func isDirectChild(_ child: URL, of root: URL) -> Bool {
        child.standardizedFileURL.deletingLastPathComponent().path == root.standardizedFileURL.path
    }

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }
}
