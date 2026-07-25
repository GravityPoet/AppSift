import AppKit
import Foundation

@MainActor
final class SystemResidueCenter: ObservableObject {
    static let preferenceFeature = "corrupt-preferences"

    @Published private(set) var legacyUsers: [LegacyUserResidue] = []
    @Published private(set) var corruptPreferences: [CorruptPreferenceItem] = []
    @Published private(set) var documentVersions: [DocumentVersionItem] = []
    @Published private(set) var statistics = SystemResidueScanStatistics(
        preferenceFilesChecked: 0,
        documentFilesChecked: 0,
        inaccessibleCount: 0,
        cloudPlaceholderCount: 0,
        wasTruncated: false
    )
    @Published var selectedPreferenceIDs: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var isRemoving = false
    @Published private(set) var hasScanned = false
    @Published private(set) var history: [ReviewedTrashRecord]
    @Published var actionMessage: String?
    @Published var errorMessage: String?

    private let scanner: SystemResidueScanner
    private let trashService: ReviewedTrashService
    private let quickLookController = DuplicateFileQuickLookController()
    private var scanTask: Task<Void, Never>?
    private var activeScanID = UUID()

    init(
        scanner: SystemResidueScanner = SystemResidueScanner(),
        trashService: ReviewedTrashService = ReviewedTrashService(),
        historyStore: ReviewedTrashHistoryStore = .shared
    ) {
        self.scanner = scanner
        self.trashService = trashService
        self.history = historyStore.snapshot(feature: Self.preferenceFeature)
    }

    var selectedPreferenceSize: Int64 {
        corruptPreferences.lazy
            .filter { self.selectedPreferenceIDs.contains($0.id) }
            .reduce(0) { $0 + $1.size }
    }

    var latestUndoablePreferenceRecord: ReviewedTrashRecord? {
        history.first { record in
            record.items.contains { item in
                item.status == .movedToTrash
                    && item.restoredAt == nil
                    && item.trashPath.map(FileManager.default.fileExists(atPath:)) == true
            }
        }
    }

    func scan(force: Bool = false) {
        if isScanning {
            guard force else { return }
            scanTask?.cancel()
        }
        guard force || !hasScanned else { return }
        let scanID = UUID()
        activeScanID = scanID
        isScanning = true
        errorMessage = nil
        actionMessage = nil
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await scanner.scan()
                guard !Task.isCancelled, activeScanID == scanID else { return }
                legacyUsers = result.legacyUsers
                corruptPreferences = result.corruptPreferences
                documentVersions = result.documentVersions
                statistics = result.statistics
                selectedPreferenceIDs.formIntersection(Set(result.corruptPreferences.map(\.id)))
                hasScanned = true
            } catch is CancellationError {
                return
            } catch {
                guard activeScanID == scanID else { return }
                errorMessage = error.localizedDescription
                hasScanned = true
            }
            guard activeScanID == scanID else { return }
            isScanning = false
            scanTask = nil
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        activeScanID = UUID()
        isScanning = false
    }

    func togglePreference(_ item: CorruptPreferenceItem) {
        if !selectedPreferenceIDs.insert(item.id).inserted {
            selectedPreferenceIDs.remove(item.id)
        }
    }

    func clearPreferenceSelection() {
        selectedPreferenceIDs.removeAll()
    }

    func removeSelectedPreferences() {
        guard !isRemoving else { return }
        let expected = corruptPreferences.filter { selectedPreferenceIDs.contains($0.id) }
        guard !expected.isEmpty else { return }
        isRemoving = true
        errorMessage = nil
        actionMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let fresh = await scanner.revalidatePreferences(expected)
            guard fresh.count == expected.count else {
                errorMessage = String(localized: "Some preference files changed or became valid. Refresh and review them again.")
                isRemoving = false
                return
            }
            let outcome = await trashService.moveToTrash(
                fresh.map(\.candidate),
                feature: Self.preferenceFeature
            )
            history = await trashService.history(feature: Self.preferenceFeature)
            isRemoving = false
            if outcome.movedCount > 0 {
                actionMessage = String(
                    format: String(localized: "%lld invalid preference files were moved to the Trash."),
                    Int64(outcome.movedCount)
                )
                selectedPreferenceIDs.removeAll()
                scan(force: true)
            }
            if !outcome.historyPersisted {
                errorMessage = String(localized: "The preference cleanup was rolled back because recovery history could not be saved.")
            } else if outcome.failedCount > 0 {
                errorMessage = String(localized: "Some preference files could not be moved safely.")
            }
        }
    }

    func undoPreferenceRemoval(_ record: ReviewedTrashRecord) {
        guard !isRemoving, record.feature == Self.preferenceFeature else { return }
        isRemoving = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let outcome = await trashService.undo(record)
            history = await trashService.history(feature: Self.preferenceFeature)
            isRemoving = false
            if outcome.restoredCount > 0 {
                actionMessage = String(
                    format: String(localized: "%lld preference files were restored."),
                    Int64(outcome.restoredCount)
                )
                scan(force: true)
            }
            if outcome.failedCount > 0 || !outcome.historyPersisted {
                errorMessage = String(localized: "AppSift could not safely restore every preference file.")
            }
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func preview(_ item: CorruptPreferenceItem) {
        quickLookController.present(item.url, alongside: corruptPreferences.map(\.url))
    }
}
