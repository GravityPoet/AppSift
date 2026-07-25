import AppKit
import Foundation

@MainActor
final class DownloadSourceCenter: ObservableObject {
    static let feature = "downloads-by-source"

    @Published private(set) var items: [DownloadSourceItem] = []
    @Published var selectedIDs: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var isRemoving = false
    @Published private(set) var hasScanned = false
    @Published private(set) var inaccessibleCount = 0
    @Published private(set) var cloudPlaceholderCount = 0
    @Published private(set) var wasTruncated = false
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var history: [ReviewedTrashRecord]
    @Published var errorMessage: String?
    @Published var actionMessage: String?

    private let scanner: DownloadSourceScanner
    private let trashService: ReviewedTrashService
    private let rootURL: URL
    private let quickLookController = DuplicateFileQuickLookController()
    private var scanTask: Task<Void, Never>?

    init(
        rootURL: URL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true),
        scanner: DownloadSourceScanner? = nil,
        trashService: ReviewedTrashService = ReviewedTrashService(),
        historyStore: ReviewedTrashHistoryStore = .shared
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.scanner = scanner ?? DownloadSourceScanner(rootURL: rootURL)
        self.trashService = trashService
        self.history = historyStore.snapshot(feature: Self.feature)
    }

    var selectedSize: Int64 {
        items.lazy.filter { self.selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.size }
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

    func scan(force: Bool = false) {
        if isScanning {
            guard force else { return }
            scanTask?.cancel()
        }
        guard force || !hasScanned else { return }
        errorMessage = nil
        actionMessage = nil
        isScanning = true
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await scanner.scan()
                guard !Task.isCancelled else { return }
                items = result.items
                selectedIDs.formIntersection(Set(result.items.map(\.id)))
                inaccessibleCount = result.inaccessibleCount
                cloudPlaceholderCount = result.cloudPlaceholderCount
                wasTruncated = result.wasTruncated
                lastScanDate = result.scannedAt
                hasScanned = true
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                hasScanned = true
            }
            isScanning = false
            scanTask = nil
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func toggleSelection(_ item: DownloadSourceItem) {
        if !selectedIDs.insert(item.id).inserted { selectedIDs.remove(item.id) }
    }

    func selectAll(in source: DownloadSource) {
        selectedIDs.formUnion(items.lazy.filter { $0.source == source }.map(\.id))
    }

    func deselectAll(in source: DownloadSource) {
        selectedIDs.subtract(items.lazy.filter { $0.source == source }.map(\.id))
    }

    func removeSelected() {
        guard !isRemoving else { return }
        let selected = items.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        isRemoving = true
        errorMessage = nil
        actionMessage = nil
        let candidates = selected.map { item in
            ReviewedTrashCandidate(
                id: item.id,
                name: item.name,
                url: item.url,
                size: item.size,
                fingerprint: item.fingerprint,
                allowedRoot: rootURL,
                requiresDirectChild: false
            )
        }

        Task { [weak self] in
            guard let self else { return }
            let outcome = await trashService.moveToTrash(candidates, feature: Self.feature)
            history = await trashService.history(feature: Self.feature)
            isRemoving = false
            if outcome.movedCount > 0 {
                let movedIDs = Set(outcome.record?.items.compactMap { item in
                    item.status == .movedToTrash ? item.candidateID : nil
                } ?? [])
                items.removeAll { movedIDs.contains($0.id) }
                selectedIDs.subtract(movedIDs)
                actionMessage = String(
                    format: String(localized: "%lld downloads were moved to the Trash."),
                    Int64(outcome.movedCount)
                )
            }
            if !outcome.historyPersisted {
                errorMessage = String(
                    localized: "The download cleanup was rolled back because recovery history could not be saved."
                )
            } else if outcome.failedCount > 0 {
                errorMessage = String(
                    format: String(localized: "%lld downloads could not be moved safely."),
                    Int64(outcome.failedCount)
                )
            }
        }
    }

    func undo(_ record: ReviewedTrashRecord) {
        guard !isRemoving, record.feature == Self.feature else { return }
        isRemoving = true
        errorMessage = nil
        actionMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let outcome = await trashService.undo(record)
            history = await trashService.history(feature: Self.feature)
            isRemoving = false
            if outcome.restoredCount > 0 {
                actionMessage = String(
                    format: String(localized: "%lld downloads were restored."),
                    Int64(outcome.restoredCount)
                )
                scan(force: true)
            }
            if outcome.failedCount > 0 || !outcome.historyPersisted {
                errorMessage = String(localized: "AppSift could not safely restore every download.")
            }
        }
    }

    func reveal(_ item: DownloadSourceItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func preview(_ item: DownloadSourceItem, sourceItems: [DownloadSourceItem]) {
        quickLookController.present(item.url, alongside: sourceItems.map(\.url))
    }

    func openDownloadsFolder() {
        NSWorkspace.shared.open(rootURL)
    }
}
