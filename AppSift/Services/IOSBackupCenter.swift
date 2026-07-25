import AppKit
import Foundation

@MainActor
final class IOSBackupCenter: ObservableObject {
    static let featureIdentifier = "ios-device-backups"

    @Published private(set) var backups: [IOSBackupItem] = []
    @Published var selectedIDs: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var isRemoving = false
    @Published private(set) var hasScanned = false
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var skippedCount = 0
    @Published private(set) var inaccessibleCount = 0
    @Published private(set) var wasTruncated = false
    @Published var errorMessage: String?
    @Published var actionMessage: String?
    @Published private(set) var removalHistory: [ReviewedTrashRecord] = []

    private let scanner: IOSBackupScanner
    private let trashService: ReviewedTrashService
    private var scanTask: Task<Void, Never>?

    init(
        scanner: IOSBackupScanner = IOSBackupScanner(),
        trashService: ReviewedTrashService = ReviewedTrashService()
    ) {
        self.scanner = scanner
        self.trashService = trashService
        Task { removalHistory = await trashService.history(feature: Self.featureIdentifier) }
    }

    var selectedBackups: [IOSBackupItem] {
        backups.filter { selectedIDs.contains($0.id) && $0.isSafeToRemove }
    }

    var selectedSize: Int64 {
        selectedBackups.reduce(0) { $0 + $1.allocatedSize }
    }

    var latestUndoableRecord: ReviewedTrashRecord? {
        removalHistory.first { record in
            record.items.contains { $0.status == .movedToTrash && $0.restoredAt == nil }
        }
    }

    func scan() {
        guard !isScanning, !isRemoving else { return }
        scanTask?.cancel()
        isScanning = true
        errorMessage = nil
        actionMessage = nil
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await scanner.scan()
                guard !Task.isCancelled else { return }
                backups = result.backups
                selectedIDs.formIntersection(Set(result.backups.map(\.id)))
                skippedCount = result.skippedCount
                inaccessibleCount = result.inaccessibleCount
                wasTruncated = result.wasTruncated
                hasScanned = true
                lastScanDate = Date()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                hasScanned = true
            }
            isScanning = false
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func selectOlderBackups() {
        selectedIDs = Set(backups.filter { !$0.isLatestForDevice && $0.isSafeToRemove }.map(\.id))
    }

    func removeSelected() {
        let selected = selectedBackups
        guard !selected.isEmpty, !isRemoving else { return }
        isRemoving = true
        errorMessage = nil
        actionMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let candidates = selected.map {
                ReviewedTrashCandidate(
                    id: $0.id,
                    name: $0.deviceName,
                    url: $0.url,
                    size: $0.allocatedSize,
                    fingerprint: $0.fingerprint,
                    allowedRoot: $0.url.deletingLastPathComponent(),
                    requiresDirectChild: true
                )
            }
            let outcome = await trashService.moveToTrash(
                candidates,
                feature: Self.featureIdentifier
            )
            removalHistory = await trashService.history(feature: Self.featureIdentifier)
            isRemoving = false
            selectedIDs.removeAll()
            if !outcome.historyPersisted {
                errorMessage = String(localized: "The backups were restored because AppSift could not save undo history.")
            } else if outcome.failedCount > 0 {
                errorMessage = String(
                    format: String(localized: "%lld backup(s) could not be moved to Trash."),
                    Int64(outcome.failedCount)
                )
            } else {
                actionMessage = String(
                    format: String(localized: "%lld backup(s) moved to Trash."),
                    Int64(outcome.movedCount)
                )
            }
            scan()
        }
    }

    func undoLatest() {
        guard let record = latestUndoableRecord, !isRemoving else { return }
        isRemoving = true
        Task { [weak self] in
            guard let self else { return }
            let outcome = await trashService.undo(record)
            removalHistory = await trashService.history(feature: Self.featureIdentifier)
            isRemoving = false
            if outcome.failedCount > 0 || !outcome.historyPersisted {
                errorMessage = String(localized: "Some backups could not be restored from Trash.")
            } else {
                actionMessage = String(
                    format: String(localized: "%lld backup(s) restored."),
                    Int64(outcome.restoredCount)
                )
            }
            scan()
        }
    }

    func reveal(_ backup: IOSBackupItem) {
        NSWorkspace.shared.activateFileViewerSelecting([backup.url])
    }
}
