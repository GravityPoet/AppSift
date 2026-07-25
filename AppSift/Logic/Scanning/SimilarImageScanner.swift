import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct SimilarImageQuality: Hashable, Sendable {
    let overall: Double
    let resolution: Double
    let sharpness: Double
    let exposure: Double
    let face: Double
}

struct SimilarImageItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let fileSize: Int64
    let pixelWidth: Int
    let pixelHeight: Int
    let modifiedAt: Date?
    let quality: SimilarImageQuality
    let fingerprint: ReviewedTrashFingerprint
}

struct SimilarImageGroup: Identifiable, Hashable, Sendable {
    let id: String
    let items: [SimilarImageItem]
    let recommendedKeepID: String
}

struct SimilarImageScanResult: Sendable {
    let groups: [SimilarImageGroup]
    let scannedImageCount: Int
    let skippedCloudPlaceholderCount: Int
    let unreadableCount: Int
    let wasTruncated: Bool
    let scannedAt: Date
}

enum SimilarImageScanError: LocalizedError, Equatable {
    case invalidRoot
    case rootUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidRoot:
            return String(localized: "Choose a specific local folder or mounted disk to scan for similar images.")
        case .rootUnavailable:
            return String(localized: "The selected image folder is unavailable or inaccessible.")
        }
    }
}

actor SimilarImageScanner {
    typealias ProgressHandler = @Sendable (Int, Int) -> Void

    private struct AnalyzedImage {
        let url: URL
        let name: String
        let fileSize: Int64
        let width: Int
        let height: Int
        let modifiedAt: Date?
        let dHash: UInt64
        let sharpness: Double
        let exposure: Double
        let face: Double
        let featurePrint: VNFeaturePrintObservation?
        let fingerprint: ReviewedTrashFingerprint
    }

    private static let maximumImages = 20_000
    private static let maximumCandidatePairs = 2_000_000
    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"
    ]

    func scan(
        rootURL: URL,
        progress: ProgressHandler? = nil
    ) throws -> SimilarImageScanResult {
        let root = rootURL.standardizedFileURL
        guard root.path != "/",
              root.path != FileManager.default.homeDirectoryForCurrentUser.path,
              !Self.isProtectedSystemPath(root.path) else {
            throw SimilarImageScanError.invalidRoot
        }
        guard Self.isSafeDirectory(root) else { throw SimilarImageScanError.rootUnavailable }
        try Task.checkCancellation()

        let discovery = try discoverImages(in: root)
        var analyzed: [AnalyzedImage] = []
        var unreadable = discovery.unreadable
        for (index, url) in discovery.urls.enumerated() {
            try Task.checkCancellation()
            if let image = analyze(url) {
                analyzed.append(image)
            } else {
                unreadable += 1
            }
            progress?(index + 1, discovery.urls.count)
        }

        let clusterResult = try cluster(analyzed)
        return SimilarImageScanResult(
            groups: clusterResult.groups,
            scannedImageCount: analyzed.count,
            skippedCloudPlaceholderCount: discovery.cloudPlaceholders,
            unreadableCount: unreadable,
            wasTruncated: discovery.truncated || clusterResult.wasTruncated,
            scannedAt: Date()
        )
    }

    static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    private func discoverImages(
        in root: URL
    ) throws -> (urls: [URL], unreadable: Int, cloudPlaceholders: Int, truncated: Bool) {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { throw SimilarImageScanError.rootUnavailable }

        var urls: [URL] = []
        var unreadable = 0
        var cloudPlaceholders = 0
        var truncated = false
        while let candidate = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard let values = try? candidate.resourceValues(forKeys: keys) else {
                unreadable += 1
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true,
                  Self.supportedExtensions.contains(candidate.pathExtension.lowercased()) else {
                continue
            }
            if values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus != .current {
                cloudPlaceholders += 1
                continue
            }
            if urls.count >= Self.maximumImages {
                truncated = true
                break
            }
            urls.append(candidate.standardizedFileURL)
        }
        return (urls, unreadable, cloudPlaceholders, truncated)
    }

    private func analyze(_ url: URL) -> AnalyzedImage? {
        guard let fingerprint = ReviewedTrashFingerprint.read(at: url),
              fingerprint.owner == UInt32(getuid()),
              fingerprint.mode & UInt32(S_IFMT) == UInt32(S_IFREG),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= 200_000, height <= 200_000,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary
              ),
              let hash = Self.differenceHash(thumbnail),
              let grayscale = Self.grayscalePixels(thumbnail, width: 64, height: 64) else {
            return nil
        }

        let metrics = Self.imageMetrics(grayscale)
        return AnalyzedImage(
            url: url,
            name: url.lastPathComponent,
            fileSize: max(0, Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)),
            width: width,
            height: height,
            modifiedAt: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            dHash: hash,
            sharpness: metrics.sharpness,
            exposure: metrics.exposure,
            face: Self.faceScore(thumbnail),
            featurePrint: Self.featurePrint(thumbnail),
            fingerprint: fingerprint
        )
    }

    private func cluster(
        _ images: [AnalyzedImage]
    ) throws -> (groups: [SimilarImageGroup], wasTruncated: Bool) {
        guard images.count >= 2 else { return ([], false) }
        var unionFind = UnionFind(count: images.count)
        let pairResult = candidatePairs(images)
        for encoded in pairResult.pairs {
            try Task.checkCancellation()
            let lhsIndex = Int(encoded >> 32)
            let rhsIndex = Int(encoded & 0xffff_ffff)
            guard images.indices.contains(lhsIndex), images.indices.contains(rhsIndex) else { continue }
            let lhs = images[lhsIndex]
            let rhs = images[rhsIndex]
            let aspectL = Double(lhs.width) / Double(lhs.height)
            let aspectR = Double(rhs.width) / Double(rhs.height)
            guard abs(log(aspectL / aspectR)) <= 0.45 else { continue }
            let hamming = Self.hammingDistance(lhs.dHash, rhs.dHash)
            if hamming <= 7 {
                unionFind.union(lhsIndex, rhsIndex)
                continue
            }
            guard hamming <= 24,
                  let leftFeature = lhs.featurePrint,
                  let rightFeature = rhs.featurePrint else { continue }
            var distance: Float = .greatestFiniteMagnitude
            guard (try? leftFeature.computeDistance(&distance, to: rightFeature)) != nil else {
                continue
            }
            if (hamming <= 18 && distance <= 0.55)
                || (hamming <= 24 && distance <= 0.35) {
                unionFind.union(lhsIndex, rhsIndex)
            }
        }

        var clusters: [Int: [AnalyzedImage]] = [:]
        for index in images.indices {
            clusters[unionFind.find(index), default: []].append(images[index])
        }
        let groups = clusters.values.compactMap(Self.makeGroup)
            .sorted {
                let leftSize = $0.items.reduce(0) { $0 + $1.fileSize }
                let rightSize = $1.items.reduce(0) { $0 + $1.fileSize }
                if leftSize != rightSize { return leftSize > rightSize }
                return $0.id < $1.id
            }
        return (groups, pairResult.wasTruncated)
    }

    private func candidatePairs(
        _ images: [AnalyzedImage]
    ) -> (pairs: Set<UInt64>, wasTruncated: Bool) {
        var pairs = Set<UInt64>()
        var wasTruncated = false
        @discardableResult
        func add(_ lhs: Int, _ rhs: Int) -> Bool {
            guard lhs != rhs else { return true }
            let low = min(lhs, rhs)
            let high = max(lhs, rhs)
            let encoded = (UInt64(low) << 32) | UInt64(high)
            guard !pairs.contains(encoded) else { return true }
            guard pairs.count < Self.maximumCandidatePairs else {
                wasTruncated = true
                return false
            }
            pairs.insert(encoded)
            return true
        }

        if images.count <= 2_000 {
            for left in images.indices {
                for right in images.indices where right > left {
                    add(left, right)
                }
            }
            return (pairs, wasTruncated)
        }

        var buckets: [UInt16: [Int]] = [:]
        for (index, image) in images.enumerated() {
            for segment in 0..<8 {
                let value = UInt16((image.dHash >> UInt64(segment * 8)) & 0xff)
                let key = UInt16(segment << 8) | value
                buckets[key, default: []].append(index)
            }
        }
        bucketLoop: for bucket in buckets.values {
            let bounded = Array(bucket.prefix(500))
            for leftOffset in bounded.indices {
                for rightOffset in bounded.indices where rightOffset > leftOffset {
                    guard add(bounded[leftOffset], bounded[rightOffset]) else {
                        break bucketLoop
                    }
                }
            }
        }

        if !wasTruncated {
            let dated = images.indices.sorted {
                (images[$0].modifiedAt ?? .distantPast) < (images[$1].modifiedAt ?? .distantPast)
            }
            dateLoop: for offset in dated.indices {
                guard let leftDate = images[dated[offset]].modifiedAt else { continue }
                for next in dated.index(after: offset)..<min(dated.count, offset + 31) {
                    guard let rightDate = images[dated[next]].modifiedAt else { continue }
                    if rightDate.timeIntervalSince(leftDate) > 10 * 60 { break }
                    guard add(dated[offset], dated[next]) else { break dateLoop }
                }
            }
        }
        return (pairs, wasTruncated)
    }

    private static func makeGroup(_ cluster: [AnalyzedImage]) -> SimilarImageGroup? {
        guard cluster.count >= 2 else { return nil }
        let maxPixels = max(1, cluster.map { Double($0.width) * Double($0.height) }.max() ?? 1)
        let items = cluster.map { image -> SimilarImageItem in
            let resolution = sqrt((Double(image.width) * Double(image.height)) / maxPixels)
            let faceWeight = image.face > 0 ? 0.12 : 0
            let overall = min(1, max(0,
                resolution * 0.38
                    + image.sharpness * 0.32
                    + image.exposure * (0.30 - faceWeight)
                    + image.face * faceWeight
            ))
            return SimilarImageItem(
                id: image.url.path,
                url: image.url,
                name: image.name,
                fileSize: image.fileSize,
                pixelWidth: image.width,
                pixelHeight: image.height,
                modifiedAt: image.modifiedAt,
                quality: SimilarImageQuality(
                    overall: overall,
                    resolution: resolution,
                    sharpness: image.sharpness,
                    exposure: image.exposure,
                    face: image.face
                ),
                fingerprint: image.fingerprint
            )
        }
        .sorted {
            if $0.quality.overall != $1.quality.overall {
                return $0.quality.overall > $1.quality.overall
            }
            let leftPixels = Double($0.pixelWidth) * Double($0.pixelHeight)
            let rightPixels = Double($1.pixelWidth) * Double($1.pixelHeight)
            if leftPixels != rightPixels {
                return leftPixels > rightPixels
            }
            return $0.fileSize > $1.fileSize
        }
        guard let recommended = items.first else { return nil }
        return SimilarImageGroup(
            id: "similar-group|\(items.map(\.id).min() ?? recommended.id)",
            items: items,
            recommendedKeepID: recommended.id
        )
    }

    private static func differenceHash(_ image: CGImage) -> UInt64? {
        guard let pixels = grayscalePixels(image, width: 9, height: 8) else { return nil }
        var hash: UInt64 = 0
        for row in 0..<8 {
            for column in 0..<8 {
                if pixels[row * 9 + column] > pixels[row * 9 + column + 1] {
                    hash |= UInt64(1) << UInt64(row * 8 + column)
                }
            }
        }
        return hash
    }

    private static func grayscalePixels(
        _ image: CGImage,
        width: Int,
        height: Int
    ) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func imageMetrics(
        _ pixels: [UInt8]
    ) -> (sharpness: Double, exposure: Double) {
        guard pixels.count == 64 * 64 else { return (0, 0) }
        let mean = pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count)
        let clipped = Double(pixels.count { $0 <= 5 || $0 >= 250 }) / Double(pixels.count)
        let centeredExposure = 1 - min(1, abs(mean - 127.5) / 127.5)
        let exposure = max(0, centeredExposure * (1 - min(0.8, clipped)))

        var laplacianSquares = 0.0
        var samples = 0
        for row in 1..<63 {
            for column in 1..<63 {
                let index = row * 64 + column
                let value = Double(pixels[index]) * 4
                    - Double(pixels[index - 1])
                    - Double(pixels[index + 1])
                    - Double(pixels[index - 64])
                    - Double(pixels[index + 64])
                laplacianSquares += value * value
                samples += 1
            }
        }
        let variance = samples > 0 ? laplacianSquares / Double(samples) : 0
        let sharpness = 1 - exp(-variance / 1_500)
        return (min(1, max(0, sharpness)), min(1, max(0, exposure)))
    }

    private static func featurePrint(_ image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first as? VNFeaturePrintObservation
    }

    private static func faceScore(_ image: CGImage) -> Double {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let faces = request.results,
              !faces.isEmpty else { return 0 }
        return faces.reduce(0.0) { current, face in
            let area = Double(face.boundingBox.width * face.boundingBox.height)
            let score = Double(face.confidence) * min(1, sqrt(area) * 3)
            return max(current, score)
        }
    }

    private static func isSafeDirectory(_ url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFDIR
            && information.st_mode & S_IWOTH == 0
    }

    private static func isProtectedSystemPath(_ path: String) -> Bool {
        ["/System", "/Library", "/private", "/usr", "/bin", "/sbin"].contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }
}

private struct UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    mutating func find(_ value: Int) -> Int {
        if parent[value] != value { parent[value] = find(parent[value]) }
        return parent[value]
    }

    mutating func union(_ lhs: Int, _ rhs: Int) {
        let leftRoot = find(lhs)
        let rightRoot = find(rhs)
        guard leftRoot != rightRoot else { return }
        if rank[leftRoot] < rank[rightRoot] {
            parent[leftRoot] = rightRoot
        } else if rank[leftRoot] > rank[rightRoot] {
            parent[rightRoot] = leftRoot
        } else {
            parent[rightRoot] = leftRoot
            rank[leftRoot] += 1
        }
    }
}
