import AppKit
import Foundation
import Photos

enum PhotoLibraryAuthorization: Int, Hashable, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
    case limited

    var permitsReadWriteAccess: Bool {
        self == .authorized || self == .limited
    }
}

enum PhotoLibraryResourceKind: String, Hashable, Sendable {
    case photo
    case rawPhoto
    case alternatePhoto
    case pairedVideo
    case fullSizePhoto
    case fullSizeVideo
    case fullSizePairedVideo
    case adjustmentData
    case adjustmentBase
    case other
}

struct PhotoLibraryAssetReference: Hashable, Sendable {
    let localIdentifier: String
    let filename: String
    let pixelWidth: Int
    let pixelHeight: Int
    let creationDate: Date?
    let modificationDate: Date?
    let isFavorite: Bool
    let isLivePhoto: Bool
    let isRAW: Bool
    let burstIdentifier: String?
    let resourceKinds: Set<PhotoLibraryResourceKind>
    let resourceSignature: String
}

struct PhotoLibraryAssetFetch: Sendable {
    let assets: [PhotoLibraryAssetReference]
    let wasTruncated: Bool
}

enum PhotoLibraryThumbnailResult: Sendable {
    case data(Data)
    case cloudOnly
    case unavailable
}

protocol PhotoLibraryGateway: Sendable {
    func authorizationStatus() async -> PhotoLibraryAuthorization
    func requestReadWriteAuthorization() async -> PhotoLibraryAuthorization
    func fetchImageAssets(maximumCount: Int) async throws -> PhotoLibraryAssetFetch
    func requestLocalThumbnail(
        for identifier: String,
        maximumPixelSize: Int,
        networkAccessAllowed: Bool
    ) async throws -> PhotoLibraryThumbnailResult
    func refetchAssets(
        withLocalIdentifiers identifiers: [String]
    ) async throws -> [PhotoLibraryAssetReference]
    func deleteAssets(withLocalIdentifiers identifiers: [String]) async throws
}

enum PhotoLibraryScanError: LocalizedError, Equatable {
    case accessDenied
    case accessRestricted
    case libraryUnavailable

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return String(
                localized: "Photos access was denied. Allow read and write access in System Settings to scan the Photos Library."
            )
        case .accessRestricted:
            return String(
                localized: "Photos access is restricted on this Mac and cannot be granted to AppSift."
            )
        case .libraryUnavailable:
            return String(localized: "The Photos Library is unavailable right now.")
        }
    }
}

enum PhotoLibraryRemovalError: LocalizedError, Equatable {
    case accessDenied
    case emptySelection
    case duplicateIdentifier(String)
    case assetMissing(String)
    case assetChanged(String)
    case keeperOverlap(String)
    case deletionFailed
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return String(localized: "AppSift no longer has permission to modify the Photos Library.")
        case .emptySelection:
            return String(localized: "No Photos Library assets were selected.")
        case .duplicateIdentifier:
            return String(localized: "The Photos cleanup request contained a duplicate asset.")
        case .assetMissing:
            return String(
                localized: "A Photos Library asset changed or disappeared after scanning. Nothing was deleted."
            )
        case .assetChanged:
            return String(
                localized: "A Photos Library asset was edited after scanning. Scan again before deleting."
            )
        case .keeperOverlap:
            return String(localized: "An image cannot be deleted and preserved in the same cleanup request.")
        case .deletionFailed:
            return String(localized: "Photos could not move the selected assets to Recently Deleted.")
        case .verificationFailed:
            return String(
                localized: "Photos did not confirm that every selected asset reached Recently Deleted."
            )
        }
    }
}

struct PhotoLibraryRemovalOutcome: Sendable {
    let removedCount: Int
}

actor PhotoLibraryRemovalService {
    private let gateway: any PhotoLibraryGateway

    init(gateway: any PhotoLibraryGateway) {
        self.gateway = gateway
    }

    func moveToRecentlyDeleted(
        removing: [PhotoLibraryAssetReference],
        preserving: [PhotoLibraryAssetReference]
    ) async throws -> PhotoLibraryRemovalOutcome {
        try Task.checkCancellation()
        guard !removing.isEmpty else { throw PhotoLibraryRemovalError.emptySelection }
        guard (await gateway.authorizationStatus()).permitsReadWriteAccess else {
            throw PhotoLibraryRemovalError.accessDenied
        }

        let removingIDs = removing.map(\.localIdentifier)
        let preservingIDs = preserving.map(\.localIdentifier)
        guard Set(removingIDs).count == removingIDs.count else {
            throw PhotoLibraryRemovalError.duplicateIdentifier(
                removingIDs.first ?? ""
            )
        }
        guard Set(preservingIDs).count == preservingIDs.count else {
            throw PhotoLibraryRemovalError.duplicateIdentifier(
                preservingIDs.first ?? ""
            )
        }
        if let overlap = Set(removingIDs).intersection(preservingIDs).first {
            throw PhotoLibraryRemovalError.keeperOverlap(overlap)
        }

        let expected = removing + preserving
        let identifiers = expected.map(\.localIdentifier)
        let current = try await gateway.refetchAssets(withLocalIdentifiers: identifiers)
        var currentByID: [String: PhotoLibraryAssetReference] = [:]
        for reference in current {
            if currentByID.updateValue(reference, forKey: reference.localIdentifier) != nil {
                throw PhotoLibraryRemovalError.duplicateIdentifier(reference.localIdentifier)
            }
        }
        for reference in expected {
            guard let fresh = currentByID[reference.localIdentifier] else {
                throw PhotoLibraryRemovalError.assetMissing(reference.localIdentifier)
            }
            guard fresh == reference else {
                throw PhotoLibraryRemovalError.assetChanged(reference.localIdentifier)
            }
        }

        try Task.checkCancellation()
        do {
            try await gateway.deleteAssets(withLocalIdentifiers: removingIDs)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PhotoLibraryRemovalError.deletionFailed
        }

        let remaining = try await gateway.refetchAssets(withLocalIdentifiers: removingIDs)
        if let identifier = remaining.first?.localIdentifier {
            throw PhotoLibraryRemovalError.verificationFailed(identifier)
        }
        return PhotoLibraryRemovalOutcome(removedCount: removing.count)
    }
}

actor PhotoKitLibraryGateway: PhotoLibraryGateway {
    static let shared = PhotoKitLibraryGateway()

    private static let rawExtensions: Set<String> = [
        "3fr", "arw", "cr2", "cr3", "dcr", "dng", "erf", "fff", "iiq", "kdc",
        "mef", "mos", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2",
        "rwl", "sr2", "srw", "x3f",
    ]

    private let imageManager = PHImageManager.default()
    private let photoLibrary = PHPhotoLibrary.shared()

    func authorizationStatus() -> PhotoLibraryAuthorization {
        Self.mapAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestReadWriteAuthorization() async -> PhotoLibraryAuthorization {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: Self.mapAuthorization(status))
            }
        }
    }

    func fetchImageAssets(maximumCount: Int) async throws -> PhotoLibraryAssetFetch {
        guard maximumCount > 0 else {
            return PhotoLibraryAssetFetch(assets: [], wasTruncated: false)
        }
        let options = Self.makeImageFetchOptions(maximumCount: maximumCount)
        let fetch = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PhotoLibraryAssetReference] = []
        assets.reserveCapacity(min(maximumCount, fetch.count))
        for index in 0..<min(maximumCount, fetch.count) {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            let reference = autoreleasepool {
                Self.makeReference(fetch.object(at: index))
            }
            assets.append(reference)
        }
        try Task.checkCancellation()
        return PhotoLibraryAssetFetch(
            assets: assets,
            wasTruncated: fetch.count > maximumCount
        )
    }

    static func makeImageFetchOptions(maximumCount: Int) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeAllBurstAssets = true
        options.includeHiddenAssets = false
        options.fetchLimit = maximumCount < Int.max ? maximumCount + 1 : maximumCount
        return options
    }

    func requestLocalThumbnail(
        for identifier: String,
        maximumPixelSize: Int,
        networkAccessAllowed: Bool
    ) throws -> PhotoLibraryThumbnailResult {
        guard let asset = Self.fetchAsset(identifier) else { return .unavailable }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.version = .current
        options.isNetworkAccessAllowed = networkAccessAllowed
        options.isSynchronous = true

        var imageData: Data?
        var isCloudOnly = false
        imageManager.requestImage(
            for: asset,
            targetSize: CGSize(width: maximumPixelSize, height: maximumPixelSize),
            contentMode: .aspectFit,
            options: options
        ) { image, information in
            if information?[PHImageResultIsInCloudKey] as? Bool == true {
                isCloudOnly = true
            }
            if information?[PHImageCancelledKey] as? Bool == true { return }
            if information?[PHImageErrorKey] != nil { return }
            guard information?[PHImageResultIsDegradedKey] as? Bool != true,
                  let image,
                  let data = image.tiffRepresentation else { return }
            imageData = data
        }
        if let imageData { return .data(imageData) }
        return isCloudOnly ? .cloudOnly : .unavailable
    }

    func refetchAssets(
        withLocalIdentifiers identifiers: [String]
    ) throws -> [PhotoLibraryAssetReference] {
        guard !identifiers.isEmpty else { return [] }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var byIdentifier: [String: PhotoLibraryAssetReference] = [:]
        fetch.enumerateObjects { asset, _, _ in
            byIdentifier[asset.localIdentifier] = Self.makeReference(asset)
        }
        return identifiers.compactMap { byIdentifier[$0] }
    }

    func deleteAssets(withLocalIdentifiers identifiers: [String]) async throws {
        guard !identifiers.isEmpty else { return }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard fetch.count == identifiers.count else {
            throw PhotoLibraryRemovalError.assetMissing(
                identifiers.first(where: { identifier in
                    PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).count == 0
                }) ?? identifiers[0]
            )
        }
        try await withCheckedThrowingContinuation { continuation in
            photoLibrary.performChanges {
                PHAssetChangeRequest.deleteAssets(fetch)
            } completionHandler: { success, error in
                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(
                        throwing: error ?? PhotoLibraryRemovalError.deletionFailed
                    )
                }
            }
        }
    }

    private static func fetchAsset(_ identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    private static func mapAuthorization(
        _ status: PHAuthorizationStatus
    ) -> PhotoLibraryAuthorization {
        switch status.rawValue {
        case PHAuthorizationStatus.notDetermined.rawValue: return .notDetermined
        case PHAuthorizationStatus.restricted.rawValue: return .restricted
        case PHAuthorizationStatus.denied.rawValue: return .denied
        case PHAuthorizationStatus.authorized.rawValue: return .authorized
        case PHAuthorizationStatus.limited.rawValue: return .limited
        default: return .restricted
        }
    }

    private static func makeReference(_ asset: PHAsset) -> PhotoLibraryAssetReference {
        let resources = PHAssetResource.assetResources(for: asset)
        let filename = resources.first(where: {
            $0.type == .fullSizePhoto || $0.type == .photo || $0.type == .alternatePhoto
        })?.originalFilename ?? resources.first?.originalFilename ?? String(localized: "Photos asset")
        let isRAW = resources.contains { resource in
            rawExtensions.contains(
                URL(fileURLWithPath: resource.originalFilename).pathExtension.lowercased()
            )
        }
        let kinds = Set(resources.map { resourceKind($0, isRAWAsset: isRAW) })
        let signature = resources.map { resource in
            "\(resource.type.rawValue):\(resource.originalFilename):\(resource.uniformTypeIdentifier)"
        }
        .sorted()
        .joined(separator: "|")
        return PhotoLibraryAssetReference(
            localIdentifier: asset.localIdentifier,
            filename: filename,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            isFavorite: asset.isFavorite,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            isRAW: isRAW,
            burstIdentifier: asset.burstIdentifier,
            resourceKinds: kinds,
            resourceSignature: signature
        )
    }

    private static func resourceKind(
        _ resource: PHAssetResource,
        isRAWAsset: Bool
    ) -> PhotoLibraryResourceKind {
        let isRawResource = rawExtensions.contains(
            URL(fileURLWithPath: resource.originalFilename).pathExtension.lowercased()
        )
        switch resource.type {
        case .photo: return isRawResource ? .rawPhoto : .photo
        case .alternatePhoto: return isRawResource ? .rawPhoto : .alternatePhoto
        case .fullSizePhoto: return isRawResource ? .rawPhoto : .fullSizePhoto
        case .pairedVideo: return .pairedVideo
        case .fullSizePairedVideo: return .fullSizePairedVideo
        case .fullSizeVideo, .video: return .fullSizeVideo
        case .adjustmentData: return .adjustmentData
        case .adjustmentBasePhoto, .adjustmentBasePairedVideo, .adjustmentBaseVideo:
            return .adjustmentBase
        default:
            return isRAWAsset && isRawResource ? .rawPhoto : .other
        }
    }
}
