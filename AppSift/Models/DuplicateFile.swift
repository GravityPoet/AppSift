import Foundation

enum DuplicateFileProtectionReason: String, Codable, Hashable, Sendable {
    case hardLinked
    case systemLocation
    case notWritable
}

struct DuplicateFileFingerprint: Codable, Hashable, Sendable {
    let deviceID: UInt64
    let inode: UInt64
    let fileSize: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let ownerUserID: UInt32
    let hardLinkCount: UInt64
    let allocatedSize: Int64
}

struct DuplicateFileItem: Identifiable, Codable, Hashable, Sendable {
    var id: String { url.standardizedFileURL.path }

    let url: URL
    let name: String
    let size: Int64
    let allocatedSize: Int64
    let createdAt: Date?
    let modifiedAt: Date?
    let contentTypeIdentifier: String?
    let fingerprint: DuplicateFileFingerprint
    let protectionReason: DuplicateFileProtectionReason?

    var isRemovalEligible: Bool { protectionReason == nil }
}

enum DuplicateKeepReason: String, Codable, Hashable, Sendable {
    case protectedReference
    case preferredLocation
    case originalLookingName
    case oldestCopy
    case shortestPath
}

struct DuplicateFileGroup: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(fileSize):\(contentHash)" }

    let contentHash: String
    let fileSize: Int64
    let files: [DuplicateFileItem]
    let suggestedKeeperID: String
    let keepReason: DuplicateKeepReason

    var duplicateCount: Int { max(0, files.count - 1) }

    var logicalReclaimableSize: Int64 {
        guard files.count > 1 else { return 0 }
        return fileSize * Int64(files.count - 1)
    }

    var estimatedAllocatedReclaimableSize: Int64 {
        files
            .filter { $0.id != suggestedKeeperID && $0.isRemovalEligible }
            .reduce(0) { partial, file in
                partial + max(0, file.allocatedSize)
            }
    }
}

enum DuplicateScanPhase: String, Codable, Hashable, Sendable {
    case enumerating
    case sampling
    case verifying
    case completed
}

struct DuplicateScanProgress: Equatable, Sendable {
    let phase: DuplicateScanPhase
    let fraction: Double?
    let examinedFileCount: Int
    let candidateFileCount: Int
    let currentPath: String

    static let idle = DuplicateScanProgress(
        phase: .enumerating,
        fraction: nil,
        examinedFileCount: 0,
        candidateFileCount: 0,
        currentPath: ""
    )
}

struct DuplicateScanStatistics: Equatable, Sendable {
    var examinedFileCount = 0
    var candidateFileCount = 0
    var inaccessibleItemCount = 0
    var cloudPlaceholderCount = 0
    var ignoredItemCount = 0
    var hardLinkAliasCount = 0
    var changedFileCount = 0
    var hashingFailureCount = 0
}

struct DuplicateFileScanResult: Sendable {
    let groups: [DuplicateFileGroup]
    let statistics: DuplicateScanStatistics
    let scannedAt: Date

    var duplicateFileCount: Int {
        groups.reduce(0) { $0 + $1.duplicateCount }
    }

    var logicalReclaimableSize: Int64 {
        groups.reduce(0) { $0 + $1.logicalReclaimableSize }
    }
}
