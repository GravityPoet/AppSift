import Foundation
import Photos
import XCTest
@testable import AppSift

final class PhotoLibrarySimilarImageTests: XCTestCase {
    func testPhotoKitFetchOptionsIncludeEveryBurstMemberAndExcludeHiddenAssets() {
        let options = PhotoKitLibraryGateway.makeImageFetchOptions(maximumCount: 20_000)

        XCTAssertTrue(options.includeAllBurstAssets)
        XCTAssertFalse(options.includeHiddenAssets)
        XCTAssertEqual(options.fetchLimit, 20_001)
    }

    func testScanRequestsReadWriteAccessAndKeepsCompoundAssetMetadata() async throws {
        let fixture = try makePhotoFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let live = makeAsset(
            id: "live-asset",
            name: "IMG_1001.HEIC",
            isLivePhoto: true,
            resourceKinds: [.photo, .pairedVideo],
            burstIdentifier: "burst-1"
        )
        let raw = makeAsset(
            id: "raw-asset",
            name: "IMG_1002.DNG",
            isRAW: true,
            resourceKinds: [.rawPhoto, .alternatePhoto],
            burstIdentifier: "burst-1"
        )
        let gateway = FakePhotoLibraryGateway(
            status: .notDetermined,
            requestedStatus: .authorized,
            assets: [live, raw],
            previews: [
                live.localIdentifier: .data(fixture.high),
                raw.localIdentifier: .data(fixture.low),
            ]
        )

        let result = try await SimilarImageScanner().scanPhotoLibrary(using: gateway)

        XCTAssertEqual(result.scannedImageCount, 2)
        XCTAssertEqual(result.skippedCloudPlaceholderCount, 0)
        let group = try XCTUnwrap(result.groups.first)
        XCTAssertEqual(group.items.count, 2)
        let references = group.items.compactMap { item -> PhotoLibraryAssetReference? in
            guard case let .photoLibrary(reference) = item.source else { return nil }
            return reference
        }
        XCTAssertEqual(Set(references.map(\.localIdentifier)), ["live-asset", "raw-asset"])
        XCTAssertTrue(references.contains { $0.isLivePhoto && $0.resourceKinds.contains(.pairedVideo) })
        XCTAssertTrue(references.contains { $0.isRAW && $0.resourceKinds.contains(.rawPhoto) })
        XCTAssertEqual(Set(references.compactMap(\.burstIdentifier)), ["burst-1"])

        let audit = await gateway.auditSnapshot()
        XCTAssertEqual(audit.authorizationRequests, 1)
        XCTAssertEqual(audit.fetchLimits, [SimilarImageScanner.Limits.production.maximumImages])
        XCTAssertEqual(Set(audit.thumbnailIdentifiers), ["live-asset", "raw-asset"])
        XCTAssertTrue(audit.networkAccessFlags.allSatisfy { !$0 })
    }

    func testScanLeavesICloudOnlyAndUnavailableAssetsUntouched() async throws {
        let fixture = try makePhotoFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let local = makeAsset(id: "local", name: "local.png")
        let cloud = makeAsset(id: "cloud", name: "cloud.heic")
        let unreadable = makeAsset(id: "unreadable", name: "broken.jpg")
        let gateway = FakePhotoLibraryGateway(
            status: .authorized,
            assets: [local, cloud, unreadable],
            previews: [
                local.localIdentifier: .data(fixture.high),
                cloud.localIdentifier: .cloudOnly,
                unreadable.localIdentifier: .unavailable,
            ]
        )

        let result = try await SimilarImageScanner().scanPhotoLibrary(using: gateway)

        XCTAssertEqual(result.scannedImageCount, 1)
        XCTAssertEqual(result.skippedCloudPlaceholderCount, 1)
        XCTAssertEqual(result.unreadableCount, 1)
        let audit = await gateway.auditSnapshot()
        XCTAssertTrue(audit.networkAccessFlags.allSatisfy { !$0 })
    }

    func testDeniedAuthorizationDoesNotFetchAssets() async {
        let gateway = FakePhotoLibraryGateway(status: .denied, assets: [], previews: [:])

        do {
            _ = try await SimilarImageScanner().scanPhotoLibrary(using: gateway)
            XCTFail("Denied Photos access must stop before fetching assets.")
        } catch {
            XCTAssertEqual(error as? PhotoLibraryScanError, .accessDenied)
        }

        let audit = await gateway.auditSnapshot()
        XCTAssertTrue(audit.fetchLimits.isEmpty)
        XCTAssertTrue(audit.thumbnailIdentifiers.isEmpty)
    }

    func testPhotoLibraryLimitIsReportedWithoutReadingPastLimit() async throws {
        let fixture = try makePhotoFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let assets = (0..<5).map { makeAsset(id: "asset-\($0)", name: "\($0).png") }
        let gateway = FakePhotoLibraryGateway(
            status: .authorized,
            assets: assets,
            previews: Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, .data(fixture.high)) })
        )
        let scanner = SimilarImageScanner(
            limits: .init(maximumImages: 2, maximumCandidatePairs: 10)
        )

        let result = try await scanner.scanPhotoLibrary(using: gateway)

        XCTAssertEqual(result.scannedImageCount, 2)
        XCTAssertTrue(result.wasTruncated)
        let audit = await gateway.auditSnapshot()
        XCTAssertEqual(audit.fetchLimits, [2])
        XCTAssertEqual(audit.thumbnailIdentifiers.count, 2)
    }

    func testRemovalRevalidatesThenDeletesExactAssetsAsOnePhotoKitChange() async throws {
        let removing = makeAsset(id: "remove", name: "remove.heic", isLivePhoto: true, resourceKinds: [.photo, .pairedVideo])
        let keeper = makeAsset(id: "keep", name: "keep.dng", isRAW: true, resourceKinds: [.rawPhoto, .alternatePhoto])
        let gateway = FakePhotoLibraryGateway(
            status: .authorized,
            assets: [removing, keeper],
            previews: [:]
        )
        let service = PhotoLibraryRemovalService(gateway: gateway)

        let outcome = try await service.moveToRecentlyDeleted(
            removing: [removing],
            preserving: [keeper]
        )

        XCTAssertEqual(outcome.removedCount, 1)
        let audit = await gateway.auditSnapshot()
        XCTAssertEqual(audit.deleteBatches, [["remove"]])
        XCTAssertEqual(Set(audit.revalidationIdentifiers), ["remove", "keep"])
        let removedAssetStillExists = await gateway.containsAsset("remove")
        let keeperStillExists = await gateway.containsAsset("keep")
        XCTAssertFalse(removedAssetStillExists)
        XCTAssertTrue(keeperStillExists)
    }

    func testRemovalRejectsChangedAssetWithoutCallingDelete() async {
        let scanned = makeAsset(id: "remove", name: "remove.jpg")
        let changed = makeAsset(
            id: "remove",
            name: "remove.jpg",
            modificationDate: Date(timeIntervalSince1970: 1_900_000_000)
        )
        let keeper = makeAsset(id: "keep", name: "keep.jpg")
        let gateway = FakePhotoLibraryGateway(
            status: .authorized,
            assets: [changed, keeper],
            previews: [:]
        )
        let service = PhotoLibraryRemovalService(gateway: gateway)

        do {
            _ = try await service.moveToRecentlyDeleted(
                removing: [scanned],
                preserving: [keeper]
            )
            XCTFail("Changed assets must stop the whole PhotoKit deletion.")
        } catch {
            XCTAssertEqual(error as? PhotoLibraryRemovalError, .assetChanged("remove"))
        }

        let audit = await gateway.auditSnapshot()
        XCTAssertTrue(audit.deleteBatches.isEmpty)
    }

    func testRemovalRejectsMissingKeeperWithoutCallingDelete() async {
        let removing = makeAsset(id: "remove", name: "remove.jpg")
        let missingKeeper = makeAsset(id: "keep", name: "keep.jpg")
        let gateway = FakePhotoLibraryGateway(
            status: .authorized,
            assets: [removing],
            previews: [:]
        )
        let service = PhotoLibraryRemovalService(gateway: gateway)

        do {
            _ = try await service.moveToRecentlyDeleted(
                removing: [removing],
                preserving: [missingKeeper]
            )
            XCTFail("A missing keeper must stop the whole PhotoKit deletion.")
        } catch {
            XCTAssertEqual(error as? PhotoLibraryRemovalError, .assetMissing("keep"))
        }

        let audit = await gateway.auditSnapshot()
        XCTAssertTrue(audit.deleteBatches.isEmpty)
    }

    func testRemovalPermissionRevocationStopsBeforeRevalidation() async {
        let removing = makeAsset(id: "remove", name: "remove.jpg")
        let keeper = makeAsset(id: "keep", name: "keep.jpg")
        let gateway = FakePhotoLibraryGateway(
            status: .denied,
            assets: [removing, keeper],
            previews: [:]
        )
        let service = PhotoLibraryRemovalService(gateway: gateway)

        do {
            _ = try await service.moveToRecentlyDeleted(
                removing: [removing],
                preserving: [keeper]
            )
            XCTFail("Revoked Photos access must stop deletion.")
        } catch {
            XCTAssertEqual(error as? PhotoLibraryRemovalError, .accessDenied)
        }

        let audit = await gateway.auditSnapshot()
        XCTAssertTrue(audit.revalidationIdentifiers.isEmpty)
        XCTAssertTrue(audit.deleteBatches.isEmpty)
    }

    func testPhotoKitFailureLeavesAssetsInPlaceAndReturnsStableError() async {
        let removing = makeAsset(id: "remove", name: "remove.jpg")
        let keeper = makeAsset(id: "keep", name: "keep.jpg")
        let gateway = FakePhotoLibraryGateway(
            status: .authorized,
            assets: [removing, keeper],
            previews: [:],
            deleteShouldFail: true
        )
        let service = PhotoLibraryRemovalService(gateway: gateway)

        do {
            _ = try await service.moveToRecentlyDeleted(
                removing: [removing],
                preserving: [keeper]
            )
            XCTFail("A failed PhotoKit transaction must not report success.")
        } catch {
            XCTAssertEqual(error as? PhotoLibraryRemovalError, .deletionFailed)
        }

        let removingStillExists = await gateway.containsAsset("remove")
        let keeperStillExists = await gateway.containsAsset("keep")
        XCTAssertTrue(removingStillExists)
        XCTAssertTrue(keeperStillExists)
    }

    func testPostDeleteVerificationRejectsAnAssetThatStillExists() async {
        let removing = makeAsset(id: "remove", name: "remove.jpg")
        let keeper = makeAsset(id: "keep", name: "keep.jpg")
        let gateway = FakePhotoLibraryGateway(
            status: .authorized,
            assets: [removing, keeper],
            previews: [:],
            retainAssetsAfterDelete: true
        )
        let service = PhotoLibraryRemovalService(gateway: gateway)

        do {
            _ = try await service.moveToRecentlyDeleted(
                removing: [removing],
                preserving: [keeper]
            )
            XCTFail("Unverified deletion must not report success.")
        } catch {
            XCTAssertEqual(
                error as? PhotoLibraryRemovalError,
                .verificationFailed("remove")
            )
        }
    }

    func testPreCancelledRemovalDoesNotCallPhotoKit() async {
        let removing = makeAsset(id: "remove", name: "remove.jpg")
        let keeper = makeAsset(id: "keep", name: "keep.jpg")
        let gateway = FakePhotoLibraryGateway(
            status: .authorized,
            assets: [removing, keeper],
            previews: [:]
        )
        let service = PhotoLibraryRemovalService(gateway: gateway)
        let task = Task {
            try await service.moveToRecentlyDeleted(
                removing: [removing],
                preserving: [keeper]
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A pre-cancelled removal must stop.")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }

        let audit = await gateway.auditSnapshot()
        XCTAssertTrue(audit.deleteBatches.isEmpty)
    }

    func testPreCancelledScanDoesNotRequestPhotosAuthorization() async {
        let gateway = FakePhotoLibraryGateway(status: .notDetermined, assets: [], previews: [:])
        let task = Task {
            try await SimilarImageScanner().scanPhotoLibrary(using: gateway)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A pre-cancelled scan must stop.")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }

        let audit = await gateway.auditSnapshot()
        XCTAssertEqual(audit.authorizationRequests, 0)
        XCTAssertTrue(audit.fetchLimits.isEmpty)
    }

    @MainActor
    func testCenterRoutesPhotosCleanupToRecentlyDeletedServiceInsteadOfTrash() async throws {
        let fixture = try makePhotoFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = makeAsset(id: "photo-first", name: "first.png")
        let second = makeAsset(id: "photo-second", name: "second.png")
        let gateway = FakePhotoLibraryGateway(
            status: .authorized,
            assets: [first, second],
            previews: [
                first.localIdentifier: .data(fixture.high),
                second.localIdentifier: .data(fixture.low),
            ]
        )
        let historyStore = ReviewedTrashHistoryStore(
            fileURL: fixture.root.appendingPathComponent("History/reviewed.json")
        )
        let trashService = try makeQATrashService(
            historyStore: historyStore,
            trashRoot: fixture.root.appendingPathComponent("Trash", isDirectory: true)
        )
        let removalService = PhotoLibraryRemovalService(gateway: gateway)
        let center = SimilarImageCenter(
            scanner: SimilarImageScanner(),
            trashService: trashService,
            historyStore: historyStore,
            photoLibraryGateway: gateway,
            photoLibraryRemovalService: removalService
        )

        center.selectSource(.photoLibrary)
        center.scan(force: true)
        try await waitForQACondition(timeout: 20) { center.hasScanned && !center.isScanning }
        XCTAssertEqual(center.groups.first?.items.count, 2)
        center.useSuggestions()
        XCTAssertEqual(center.selectedIDs.count, 1)
        center.removeSelected()

        var audit = await gateway.auditSnapshot()
        for _ in 0..<200 where audit.deleteBatches.isEmpty {
            try await Task.sleep(nanoseconds: 25_000_000)
            audit = await gateway.auditSnapshot()
        }
        XCTAssertEqual(audit.deleteBatches.count, 1)
        XCTAssertEqual(audit.deleteBatches[0].count, 1)
        XCTAssertTrue(center.history.isEmpty)
        XCTAssertNotNil(center.actionMessage)
    }

    private func makePhotoFixture() throws -> (root: URL, high: Data, low: Data) {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftPhotoLibrary")
        let highURL = root.appendingPathComponent("high.png")
        let lowURL = root.appendingPathComponent("low.png")
        try writeQAGradientPNG(to: highURL, width: 512, height: 384)
        try writeQAGradientPNG(to: lowURL, width: 128, height: 96)
        return (root, try Data(contentsOf: highURL), try Data(contentsOf: lowURL))
    }

    private func makeAsset(
        id: String,
        name: String,
        modificationDate: Date = Date(timeIntervalSince1970: 1_800_000_000),
        isLivePhoto: Bool = false,
        isRAW: Bool = false,
        resourceKinds: Set<PhotoLibraryResourceKind> = [.photo],
        burstIdentifier: String? = nil
    ) -> PhotoLibraryAssetReference {
        PhotoLibraryAssetReference(
            localIdentifier: id,
            filename: name,
            pixelWidth: 512,
            pixelHeight: 384,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: modificationDate,
            isFavorite: false,
            isLivePhoto: isLivePhoto,
            isRAW: isRAW,
            burstIdentifier: burstIdentifier,
            resourceKinds: resourceKinds,
            resourceSignature: resourceKinds.map(\.rawValue).sorted().joined(separator: "|")
        )
    }
}

private actor FakePhotoLibraryGateway: PhotoLibraryGateway {
    struct Audit: Sendable {
        let authorizationRequests: Int
        let fetchLimits: [Int]
        let thumbnailIdentifiers: [String]
        let networkAccessFlags: [Bool]
        let revalidationIdentifiers: [String]
        let deleteBatches: [[String]]
    }

    private var status: PhotoLibraryAuthorization
    private let requestedStatus: PhotoLibraryAuthorization
    private var assets: [String: PhotoLibraryAssetReference]
    private let orderedIdentifiers: [String]
    private let previews: [String: PhotoLibraryThumbnailResult]
    private let deleteShouldFail: Bool
    private let retainAssetsAfterDelete: Bool
    private var authorizationRequests = 0
    private var fetchLimits: [Int] = []
    private var thumbnailIdentifiers: [String] = []
    private var networkAccessFlags: [Bool] = []
    private var revalidationIdentifiers: [String] = []
    private var deleteBatches: [[String]] = []

    init(
        status: PhotoLibraryAuthorization,
        requestedStatus: PhotoLibraryAuthorization = .authorized,
        assets: [PhotoLibraryAssetReference],
        previews: [String: PhotoLibraryThumbnailResult],
        deleteShouldFail: Bool = false,
        retainAssetsAfterDelete: Bool = false
    ) {
        self.status = status
        self.requestedStatus = requestedStatus
        self.assets = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        self.orderedIdentifiers = assets.map(\.localIdentifier)
        self.previews = previews
        self.deleteShouldFail = deleteShouldFail
        self.retainAssetsAfterDelete = retainAssetsAfterDelete
    }

    func authorizationStatus() -> PhotoLibraryAuthorization { status }

    func requestReadWriteAuthorization() async -> PhotoLibraryAuthorization {
        authorizationRequests += 1
        status = requestedStatus
        return requestedStatus
    }

    func fetchImageAssets(maximumCount: Int) throws -> PhotoLibraryAssetFetch {
        fetchLimits.append(maximumCount)
        let available = orderedIdentifiers.compactMap { assets[$0] }
        return PhotoLibraryAssetFetch(
            assets: Array(available.prefix(maximumCount)),
            wasTruncated: available.count > maximumCount
        )
    }

    func requestLocalThumbnail(
        for identifier: String,
        maximumPixelSize: Int,
        networkAccessAllowed: Bool
    ) throws -> PhotoLibraryThumbnailResult {
        thumbnailIdentifiers.append(identifier)
        networkAccessFlags.append(networkAccessAllowed)
        return previews[identifier] ?? .unavailable
    }

    func refetchAssets(
        withLocalIdentifiers identifiers: [String]
    ) throws -> [PhotoLibraryAssetReference] {
        revalidationIdentifiers.append(contentsOf: identifiers)
        return identifiers.compactMap { assets[$0] }
    }

    func deleteAssets(withLocalIdentifiers identifiers: [String]) async throws {
        deleteBatches.append(identifiers)
        if deleteShouldFail {
            throw NSError(domain: "PhotoLibrarySimilarImageTests", code: 1)
        }
        if !retainAssetsAfterDelete {
            identifiers.forEach { assets.removeValue(forKey: $0) }
        }
    }

    func auditSnapshot() -> Audit {
        Audit(
            authorizationRequests: authorizationRequests,
            fetchLimits: fetchLimits,
            thumbnailIdentifiers: thumbnailIdentifiers,
            networkAccessFlags: networkAccessFlags,
            revalidationIdentifiers: revalidationIdentifiers,
            deleteBatches: deleteBatches
        )
    }

    func containsAsset(_ identifier: String) -> Bool {
        assets[identifier] != nil
    }

}
