import Foundation

enum StorageAuditScanStatus: String, Codable, Hashable, Sendable {
    case scanned
    case metadataOnly
    case inaccessible
    case cancelled
}

struct StorageAuditProgress: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case discovering
        case scanning
        case finalizing
        case completed
        case cancelled
    }

    let phase: Phase
    let volumePath: String
    let examinedItemCount: Int
    let currentPath: String

    static let idle = StorageAuditProgress(
        phase: .discovering,
        volumePath: "",
        examinedItemCount: 0,
        currentPath: ""
    )
}

struct StorageAuditItem: Identifiable, Codable, Hashable, Sendable {
    let path: String
    let name: String
    let kind: String
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let fileCount: Int
    let directoryCount: Int

    var id: String { path }
}

struct StorageAuditVolume: Identifiable, Codable, Hashable, Sendable {
    let path: String
    let name: String
    let totalBytes: Int64
    let availableBytes: Int64
    let isInternal: Bool
    let isRemovable: Bool
    let isReadOnly: Bool
    let deviceIdentifier: String?
    let filesystemType: String?
    let volumeRole: String?
    let containerIdentifier: String?
    let isBackupVolume: Bool
    let isMetadataOnly: Bool
    let status: StorageAuditScanStatus
    let scannedItemCount: Int
    let fileCount: Int
    let directoryCount: Int
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let inaccessibleItemCount: Int
    let inaccessiblePaths: [String]
    let symbolicLinkCount: Int
    let cloudPlaceholderCount: Int
    let nestedVolumeCount: Int
    let firmlinkSkippedCount: Int
    let hardLinkAliasCount: Int
    let topItems: [StorageAuditItem]
    let errorSummary: String?

    var id: String { path }
    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    var isTimeMachineVolume: Bool {
        let value = (name + " " + path).lowercased()
        return value.contains("time machine")
            || value.contains("timemachine")
            || value.contains(".timemachine")
    }
}

struct StorageAuditVirtualMachineAsset: Identifiable, Codable, Hashable, Sendable {
    let path: String
    let kind: String
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let processIDs: [Int32]
    let isRunning: Bool
    let guestScope: String

    var id: String { path }
}

struct StorageAuditReport: Codable, Hashable, Sendable {
    let capturedAt: Date
    let volumes: [StorageAuditVolume]
    let processes: [SystemProcessMemorySnapshot]
    let memory: SystemMemorySnapshot?
    let trash: SystemTrashSnapshot?
    let virtualMachines: [StorageAuditVirtualMachineAsset]
    let coverageNotes: [String]
    let wasCancelled: Bool

    var scannedVolumeCount: Int {
        volumes.filter { $0.status == .scanned }.count
    }

    var totalFileCount: Int {
        volumes.reduce(0) { $0 + $1.fileCount }
    }

    var totalDirectoryCount: Int {
        volumes.reduce(0) { $0 + $1.directoryCount }
    }

    var totalInaccessibleCount: Int {
        volumes.reduce(0) { $0 + $1.inaccessibleItemCount }
    }

    var totalAllocatedBytes: Int64 {
        volumes.reduce(0) { $0 + $1.allocatedBytes }
    }

    var displayedMemoryBytes: Int64 {
        processes.prefix(16).reduce(0) { $0 + $1.residentBytes }
    }
}
