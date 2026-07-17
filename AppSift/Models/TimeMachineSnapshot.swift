import Foundation

struct TimeMachineSnapshot: Identifiable, Hashable {
    let name: String
    let dateToken: String
    let createdAt: Date
    let privateSize: Int64?

    init(name: String, dateToken: String, createdAt: Date, privateSize: Int64? = nil) {
        self.name = name
        self.dateToken = dateToken
        self.createdAt = createdAt
        self.privateSize = privateSize
    }

    var id: String { dateToken }
}

struct TimeMachineSnapshotScanResult {
    let snapshots: [TimeMachineSnapshot]
    let isBackupRunning: Bool
}

struct TimeMachineSnapshotDeletionResult {
    let deletedCount: Int
    let freedSpace: Int64
    let remainingSnapshotIDs: Set<String>
}
