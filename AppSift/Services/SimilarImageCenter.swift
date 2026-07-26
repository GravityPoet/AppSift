import AppKit
import CryptoKit
import Foundation

enum SimilarImageScanSource: String, CaseIterable, Identifiable, Sendable {
    case folder
    case photoLibrary

    var id: String { rawValue }
}

@MainActor
final class SimilarImageCenter: ObservableObject {
    static let feature = "similar-images"

    @Published private(set) var rootURL: URL?
    @Published private(set) var source: SimilarImageScanSource
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
    private let photoLibraryGateway: any PhotoLibraryGateway
    private let photoLibraryRemovalService: PhotoLibraryRemovalService
    private let quickLookController = DuplicateFileQuickLookController()
    private var scanTask: Task<Void, Never>?
    private var activeScanID = UUID()

    init(
        rootURL: URL? = nil,
        scanner: SimilarImageScanner = SimilarImageScanner(),
        trashService: ReviewedTrashService = ReviewedTrashService(),
        historyStore: ReviewedTrashHistoryStore = .shared,
        photoLibraryGateway: any PhotoLibraryGateway = PhotoKitLibraryGateway.shared,
        photoLibraryRemovalService: PhotoLibraryRemovalService? = nil
    ) {
        self.rootURL = rootURL?.standardizedFileURL
        self.source = .folder
        self.scanner = scanner
        self.trashService = trashService
        self.photoLibraryGateway = photoLibraryGateway
        self.photoLibraryRemovalService = photoLibraryRemovalService
            ?? PhotoLibraryRemovalService(gateway: photoLibraryGateway)
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
        guard source == .folder else { return nil }
        return history.first { record in
            record.items.contains { item in
                item.status == .movedToTrash
                    && item.restoredAt == nil
                    && item.trashPath.map(FileManager.default.fileExists(atPath:)) == true
            }
        }
    }

    var isPhotoLibrarySource: Bool { source == .photoLibrary }

    func selectSource(_ newSource: SimilarImageScanSource) {
        guard source != newSource else { return }
        cancelScan()
        source = newSource
        groups = []
        selectedIDs = []
        hasScanned = false
        completedImageCount = 0
        discoveredImageCount = 0
        scannedImageCount = 0
        cloudPlaceholderCount = 0
        unreadableCount = 0
        wasTruncated = false
        errorMessage = nil
        actionMessage = nil
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
        source = .folder
        rootURL = url.standardizedFileURL
        scan(force: true)
    }

    func scan(force: Bool = false) {
        let selectedSource = source
        if selectedSource == .folder, rootURL == nil { return }
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
                let progress: SimilarImageScanner.ProgressHandler = { completed, total in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.activeScanID == scanID,
                              !Task.isCancelled else { return }
                        self.completedImageCount = completed
                        self.discoveredImageCount = total
                    }
                }
                let result: SimilarImageScanResult
                switch selectedSource {
                case .folder:
                    guard let rootURL else { return }
                    result = try await scanner.scan(rootURL: rootURL, progress: progress)
                case .photoLibrary:
                    result = try await scanner.scanPhotoLibrary(
                        using: photoLibraryGateway,
                        progress: progress
                    )
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
        guard !isRemoving else { return }
        switch source {
        case .folder:
            removeSelectedFiles()
        case .photoLibrary:
            removeSelectedPhotoAssets()
        }
    }

    private func removeSelectedFiles() {
        guard let rootURL else { return }
        var selectedItems: [SimilarImageItem] = []
        var preservedCount = 0
        for group in groups {
            var groupSelection = group.items.filter { selectedIDs.contains($0.id) }
            groupSelection.removeAll {
                guard let url = $0.source.fileURL else { return true }
                return SimilarImageScanner.isProtectedPhotoLibraryPath(url)
            }
            let currentUnselectedItemExists = group.items.contains { item in
                !selectedIDs.contains(item.id)
                    && item.source.fileURL.flatMap(ReviewedTrashFingerprint.read(at:)) != nil
            }
            if !currentUnselectedItemExists,
               let itemToKeep = group.items.first(where: { item in
                   item.id == group.recommendedKeepID
                       && item.source.fileURL.flatMap(ReviewedTrashFingerprint.read(at:)) != nil
               }) ?? group.items.first(where: {
                   $0.source.fileURL.flatMap(ReviewedTrashFingerprint.read(at:)) != nil
               }) {
                groupSelection.removeAll { $0.id == itemToKeep.id }
                selectedIDs.remove(itemToKeep.id)
                preservedCount += 1
            }
            selectedItems.append(contentsOf: groupSelection)
        }
        guard !selectedItems.isEmpty else { return }
        let candidates = selectedItems.compactMap { item -> ReviewedTrashCandidate? in
            guard case let .file(url, fingerprint) = item.source else { return nil }
            return ReviewedTrashCandidate(
                id: item.id,
                name: item.name,
                url: url,
                size: item.fileSize,
                fingerprint: fingerprint,
                allowedRoot: rootURL,
                requiresDirectChild: false
            )
        }
        guard candidates.count == selectedItems.count else {
            errorMessage = String(localized: "The selected images came from mixed sources. Scan again before deleting.")
            return
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
                let message = String(
                    format: String(localized: "%lld similar images were moved to the Trash; one image remains in every group."),
                    Int64(outcome.movedCount)
                )
                selectedIDs.removeAll()
                scan(force: true)
                actionMessage = message
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

    private func removeSelectedPhotoAssets() {
        var removing: [PhotoLibraryAssetReference] = []
        var preserving: [PhotoLibraryAssetReference] = []
        var preservedCount = 0
        for group in groups {
            var selected = group.items.filter { selectedIDs.contains($0.id) }
            guard !selected.isEmpty else { continue }
            let unselected = group.items.filter { !selectedIDs.contains($0.id) }
            let itemToKeep: SimilarImageItem?
            if let existingKeeper = unselected.first(where: { $0.id == group.recommendedKeepID })
                ?? unselected.first {
                itemToKeep = existingKeeper
            } else {
                itemToKeep = selected.first(where: { $0.id == group.recommendedKeepID })
                    ?? selected.first
                if let itemToKeep {
                    selected.removeAll { $0.id == itemToKeep.id }
                    selectedIDs.remove(itemToKeep.id)
                    preservedCount += 1
                }
            }
            guard let keeper = itemToKeep?.source.photoLibraryReference else {
                errorMessage = String(localized: "The Photos Library selection is no longer valid. Scan again before deleting.")
                return
            }
            let selectedReferences = selected.compactMap(\.source.photoLibraryReference)
            guard selectedReferences.count == selected.count else {
                errorMessage = String(localized: "The selected images came from mixed sources. Scan again before deleting.")
                return
            }
            preserving.append(keeper)
            removing.append(contentsOf: selectedReferences)
        }
        guard !removing.isEmpty else { return }
        guard Set(removing.map(\.localIdentifier)).count == removing.count,
              Set(preserving.map(\.localIdentifier)).count == preserving.count else {
            errorMessage = String(localized: "The Photos Library selection contains duplicate assets. Scan again before deleting.")
            return
        }

        isRemoving = true
        errorMessage = nil
        actionMessage = preservedCount > 0
            ? String(localized: "AppSift kept the best-scored photo in every group.")
            : nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await photoLibraryRemovalService.moveToRecentlyDeleted(
                    removing: removing,
                    preserving: preserving
                )
                isRemoving = false
                selectedIDs.removeAll()
                let message = String(
                    format: String(localized: "%lld Photos Library assets were moved to Recently Deleted; one photo remains in every group."),
                    Int64(outcome.removedCount)
                )
                scan(force: true)
                actionMessage = message
            } catch is CancellationError {
                isRemoving = false
            } catch {
                isRemoving = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func undo(_ record: ReviewedTrashRecord) {
        guard source == .folder, !isRemoving, record.feature == Self.feature else { return }
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
        switch item.source {
        case let .file(url, _):
            let companions = group.items.compactMap(\.source.fileURL)
            quickLookController.present(url, alongside: companions)
        case let .photoLibrary(reference):
            Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await photoLibraryGateway.requestLocalThumbnail(
                        for: reference.localIdentifier,
                        maximumPixelSize: 2_048,
                        networkAccessAllowed: false
                    )
                    guard case let .data(data) = result else {
                        errorMessage = String(localized: "This photo is stored only in iCloud and was left untouched.")
                        return
                    }
                    let url = try Self.writePhotoLibraryPreview(
                        data,
                        identifier: reference.localIdentifier
                    )
                    quickLookController.present(url, alongside: [url])
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func reveal(_ item: SimilarImageItem) {
        switch item.source {
        case let .file(url, _):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .photoLibrary:
            let photosURL = URL(fileURLWithPath: "/System/Applications/Photos.app", isDirectory: true)
            NSWorkspace.shared.openApplication(
                at: photosURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }

    func thumbnail(for item: SimilarImageItem) async -> NSImage? {
        switch item.source {
        case let .file(url, _):
            return NSImage(byReferencing: url)
        case let .photoLibrary(reference):
            guard let result = try? await photoLibraryGateway.requestLocalThumbnail(
                for: reference.localIdentifier,
                maximumPixelSize: 512,
                networkAccessAllowed: false
            ), case let .data(data) = result else { return nil }
            return NSImage(data: data)
        }
    }

    private static func writePhotoLibraryPreview(
        _ data: Data,
        identifier: String
    ) throws -> URL {
        let digest = SHA256.hash(data: Data(identifier.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppSift/PhotoLibraryPreviews", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("\(digest).tiff")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
