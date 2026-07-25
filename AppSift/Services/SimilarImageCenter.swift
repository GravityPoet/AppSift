import AppKit
import Foundation

@MainActor
final class SimilarImageCenter: ObservableObject {
    static let feature = "similar-images"

    @Published private(set) var rootURL: URL?
    @Published private(set) var groups: [SimilarImageGroup] = []
    @Published var selectedIDs: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var isRemoving = false
    @Published private(set) var hasScanned = false
    @Published private(set) var completedImageCount = 0
    @Published private(set) var discoveredImageCount = 0
    @Published private(set) var scannedImageCount = 0
    @Published private(set) var cloudPlaceholderCount = 0
    @Published private(set) var unreadableCount = 0
    @Published private(set) var wasTruncated = false
    @Published private(set) var history: [ReviewedTrashRecord]
    @Published var errorMessage: String?
    @Published var actionMessage: String?

    private let scanner: SimilarImageScanner
    private let trashService: ReviewedTrashService
    private let quickLookController = DuplicateFileQuickLookController()
    private var scanTask: Task<Void, Never>?
    private var activeScanID = UUID()

    init(
        scanner: SimilarImageScanner = SimilarImageScanner(),
        trashService: ReviewedTrashService = ReviewedTrashService(),
        historyStore: ReviewedTrashHistoryStore = .shared
    ) {
        self.scanner = scanner
        self.trashService = trashService
        self.history = historyStore.snapshot(feature: Self.feature)
    }

    var suggestedRemovalIDs: Set<String> {
        Set(groups.flatMap { group in
            group.items.lazy.filter { $0.id != group.recommendedKeepID }.map(\.id)
        })
    }

    var selectedSize: Int64 {
        groups.lazy.flatMap(\.items)
            .filter { self.selectedIDs.contains($0.id) }
            .reduce(0) { $0 + $1.fileSize }
    }

    var latestUndoableRecord: ReviewedTrashRecord? {
        history.first { record in
            record.items.contains { item in
                item.status == .movedToTrash
                    && item.restoredAt == nil
                    && item.trashPath.map(FileManager.default.fileExists(atPath:)) == true
            }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a Folder to Scan for Similar Images")
        panel.prompt = String(localized: "Choose Folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let rootURL {
            panel.directoryURL = rootURL
        } else {
            panel.directoryURL = FileManager.default.urls(
                for: .picturesDirectory,
                in: .userDomainMask
            ).first
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootURL = url.standardizedFileURL
        scan(force: true)
    }

    func scan(force: Bool = false) {
        guard let rootURL else { return }
        if isScanning {
            guard force else { return }
            scanTask?.cancel()
        }
        guard force || !hasScanned else { return }
        isScanning = true
        errorMessage = nil
        actionMessage = nil
        completedImageCount = 0
        discoveredImageCount = 0
        let scanID = UUID()
        activeScanID = scanID
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await scanner.scan(rootURL: rootURL) { completed, total in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.activeScanID == scanID,
                              !Task.isCancelled else { return }
                        self.completedImageCount = completed
                        self.discoveredImageCount = total
                    }
                }
                guard !Task.isCancelled, activeScanID == scanID else { return }
                groups = result.groups
                selectedIDs.formIntersection(Set(result.groups.flatMap { $0.items.map(\.id) }))
                scannedImageCount = result.scannedImageCount
                cloudPlaceholderCount = result.skippedCloudPlaceholderCount
                unreadableCount = result.unreadableCount
                wasTruncated = result.wasTruncated
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

    func useSuggestions() {
        selectedIDs = suggestedRemovalIDs
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }

    func toggle(_ item: SimilarImageItem) {
        if !selectedIDs.insert(item.id).inserted { selectedIDs.remove(item.id) }
    }

    func removeSelected() {
        guard !isRemoving, let rootURL else { return }
        var selectedItems: [SimilarImageItem] = []
        var preservedCount = 0
        for group in groups {
            var groupSelection = group.items.filter { selectedIDs.contains($0.id) }
            let currentUnselectedItemExists = group.items.contains { item in
                !selectedIDs.contains(item.id)
                    && ReviewedTrashFingerprint.read(at: item.url) != nil
            }
            if !currentUnselectedItemExists,
               let itemToKeep = group.items.first(where: { item in
                   item.id == group.recommendedKeepID
                       && ReviewedTrashFingerprint.read(at: item.url) != nil
               }) ?? group.items.first(where: {
                   ReviewedTrashFingerprint.read(at: $0.url) != nil
               }) {
                groupSelection.removeAll { $0.id == itemToKeep.id }
                selectedIDs.remove(itemToKeep.id)
                preservedCount += 1
            }
            selectedItems.append(contentsOf: groupSelection)
        }
        guard !selectedItems.isEmpty else { return }
        let candidates = selectedItems.map { item in
            ReviewedTrashCandidate(
                id: item.id,
                name: item.name,
                url: item.url,
                size: item.fileSize,
                fingerprint: item.fingerprint,
                allowedRoot: rootURL,
                requiresDirectChild: false
            )
        }
        isRemoving = true
        errorMessage = nil
        actionMessage = preservedCount > 0
            ? String(localized: "AppSift kept the best-scored image in every group.")
            : nil
        Task { [weak self] in
            guard let self else { return }
            let outcome = await trashService.moveToTrash(candidates, feature: Self.feature)
            history = await trashService.history(feature: Self.feature)
            isRemoving = false
            if outcome.movedCount > 0 {
                actionMessage = String(
                    format: String(localized: "%lld similar images were moved to the Trash; one image remains in every group."),
                    Int64(outcome.movedCount)
                )
                selectedIDs.removeAll()
                scan(force: true)
            }
            if !outcome.historyPersisted {
                errorMessage = String(
                    localized: "The similar-image cleanup was rolled back because recovery history could not be saved."
                )
            } else if outcome.failedCount > 0 {
                errorMessage = String(
                    format: String(localized: "%lld images could not be moved safely."),
                    Int64(outcome.failedCount)
                )
            }
        }
    }

    func undo(_ record: ReviewedTrashRecord) {
        guard !isRemoving, record.feature == Self.feature else { return }
        isRemoving = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let outcome = await trashService.undo(record)
            history = await trashService.history(feature: Self.feature)
            isRemoving = false
            if outcome.restoredCount > 0 {
                actionMessage = String(
                    format: String(localized: "%lld similar images were restored."),
                    Int64(outcome.restoredCount)
                )
                scan(force: true)
            }
            if outcome.failedCount > 0 || !outcome.historyPersisted {
                errorMessage = String(localized: "AppSift could not safely restore every image.")
            }
        }
    }

    func preview(_ item: SimilarImageItem, group: SimilarImageGroup) {
        quickLookController.present(item.url, alongside: group.items.map(\.url))
    }

    func reveal(_ item: SimilarImageItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}
