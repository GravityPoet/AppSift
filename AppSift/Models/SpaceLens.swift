import Foundation

enum SpaceLensNodeKind: String, Codable, Hashable, Sendable {
    case file
    case directory
    case package

    var isContainer: Bool {
        self == .directory || self == .package
    }
}

enum SpaceLensProtectionReason: String, Codable, Hashable, Sendable {
    case scanRoot
    case systemLocation
    case appManagedLibrary
    case inaccessible
    case differentOwner
    case notWritable
    case hardLinked
    case cloudPlaceholder
}

struct SpaceLensFingerprint: Codable, Equatable, Hashable, Sendable {
    let deviceID: UInt64
    let inode: UInt64
    let logicalSize: Int64
    let allocatedSize: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let ownerUserID: UInt32
    let hardLinkCount: UInt64
    let mode: UInt16
}

struct SpaceLensNode: Identifiable, Sendable {
    var id: String { url.path }

    let url: URL
    let name: String
    let kind: SpaceLensNodeKind
    let logicalSize: Int64
    let allocatedSize: Int64
    let ownAllocatedSize: Int64
    let fileCount: Int
    let directoryCount: Int
    let modifiedAt: Date?
    let contentTypeIdentifier: String?
    let fingerprint: SpaceLensFingerprint
    let verificationToken: String
    let protectionReason: SpaceLensProtectionReason?
    let protectedDescendantCount: Int
    let isCloneAlias: Bool
    let isCloudPlaceholder: Bool
    let children: [SpaceLensNode]

    var isContainer: Bool { kind.isContainer }

    var isRemovalEligible: Bool {
        protectionReason == nil && protectedDescendantCount == 0
    }

    var removableAllocatedSize: Int64 {
        isRemovalEligible ? allocatedSize : 0
    }

    func descendant(withID targetID: String) -> SpaceLensNode? {
        if id == targetID {
            return self
        }
        for child in children where child.isContainer {
            if let match = child.descendant(withID: targetID) {
                return match
            }
        }
        return nil
    }
}

enum SpaceLensScanPhase: String, Codable, Equatable, Sendable {
    case scanning
    case finalizing
    case completed
}

struct SpaceLensScanProgress: Equatable, Sendable {
    let phase: SpaceLensScanPhase
    let examinedItemCount: Int
    let fileCount: Int
    let directoryCount: Int
    let allocatedBytes: Int64
    let currentPath: String

    static let idle = SpaceLensScanProgress(
        phase: .scanning,
        examinedItemCount: 0,
        fileCount: 0,
        directoryCount: 0,
        allocatedBytes: 0,
        currentPath: ""
    )
}

struct SpaceLensScanStatistics: Equatable, Sendable {
    var examinedItemCount = 0
    var fileCount = 0
    var directoryCount = 0
    var inaccessibleItemCount = 0
    var symbolicLinkCount = 0
    var cloudPlaceholderCount = 0
    var hardLinkAliasCount = 0
    var cloneCandidateCount = 0
    var cloneAliasCount = 0
    var nestedVolumeCount = 0
}

struct SpaceLensVolumeInfo: Equatable, Sendable {
    let totalCapacity: Int64?
    let availableCapacity: Int64?
    let importantUsageAvailableCapacity: Int64?
    let volumeName: String?
    let isVolumeRoot: Bool

    var usedCapacity: Int64? {
        guard let totalCapacity, let availableCapacity else { return nil }
        return max(0, totalCapacity - availableCapacity)
    }
}

struct SpaceLensScanResult: Sendable {
    let root: SpaceLensNode
    let statistics: SpaceLensScanStatistics
    let volumeInfo: SpaceLensVolumeInfo
    let scannedAt: Date

    var unaccountedAllocatedSize: Int64? {
        guard volumeInfo.isVolumeRoot,
              let usedCapacity = volumeInfo.usedCapacity else {
            return nil
        }
        return max(0, usedCapacity - root.allocatedSize)
    }
}

enum SpaceLensSizeMode: String, CaseIterable, Identifiable, Sendable {
    case allocated
    case logical

    var id: String { rawValue }

    func size(of node: SpaceLensNode) -> Int64 {
        switch self {
        case .allocated:
            return node.allocatedSize
        case .logical:
            return node.logicalSize
        }
    }
}
