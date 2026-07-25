import CryptoKit
import Darwin
import Foundation

actor DuplicateFileScanner {
    typealias ProgressHandler = @Sendable (DuplicateScanProgress) -> Void

    private struct FileIdentity: Hashable {
        let deviceID: UInt64
        let inode: UInt64
    }

    private enum ScannerError: Error {
        case shortRead
        case fileChanged
    }

    private static let sampleChunkSize = 64 * 1024
    private static let fullHashChunkSize = 1024 * 1024

    func scan(
        roots: [URL],
        ignoredPaths: Set<String> = [],
        minimumFileSize: Int64 = 1,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> DuplicateFileScanResult {
        let normalizedRoots = Self.collapsedRoots(roots)
        let normalizedIgnoredPaths = ignoredPaths.map(Self.normalizedPath)
        var statistics = DuplicateScanStatistics()
        var filesBySize: [Int64: [DuplicateFileItem]] = [:]
        var seenIdentities = Set<FileIdentity>()

        progress(.idle)

        for root in normalizedRoots {
            try Task.checkCancellation()
            guard Self.isReadableDirectory(root) else {
                statistics.inaccessibleItemCount += 1
                continue
            }

            var enumerationErrors = 0
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Self.resourceKeys,
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in
                    enumerationErrors += 1
                    return true
                }
            ) else {
                statistics.inaccessibleItemCount += 1
                continue
            }

            while let rawURL = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                statistics.examinedFileCount += 1

                if Self.isIgnored(rawURL, ignoredPaths: normalizedIgnoredPaths) {
                    statistics.ignoredItemCount += 1
                    enumerator.skipDescendants()
                    continue
                }

                if statistics.examinedFileCount == 1
                    || statistics.examinedFileCount.isMultiple(of: 200) {
                    progress(DuplicateScanProgress(
                        phase: .enumerating,
                        fraction: nil,
                        examinedFileCount: statistics.examinedFileCount,
                        candidateFileCount: statistics.candidateFileCount,
                        currentPath: rawURL.path
                    ))
                }

                guard let values = try? rawURL.resourceValues(
                    forKeys: Set(Self.resourceKeys)
                ) else {
                    statistics.inaccessibleItemCount += 1
                    continue
                }
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      values.isReadable == true,
                      let fileSize = values.fileSize,
                      Int64(fileSize) >= max(1, minimumFileSize) else {
                    continue
                }

                let allocatedSize = Int64(values.totalFileAllocatedSize ?? fileSize)
                if Self.isCloudPlaceholder(
                    path: rawURL.path,
                    isUbiquitousItem: values.isUbiquitousItem == true,
                    downloadingStatus: values.ubiquitousItemDownloadingStatus,
                    fileSize: Int64(fileSize),
                    allocatedSize: allocatedSize
                ) {
                    statistics.cloudPlaceholderCount += 1
                    continue
                }

                guard let fingerprint = Self.currentFingerprint(for: rawURL),
                      fingerprint.fileSize == Int64(fileSize) else {
                    statistics.inaccessibleItemCount += 1
                    continue
                }

                let identity = FileIdentity(
                    deviceID: fingerprint.deviceID,
                    inode: fingerprint.inode
                )
                guard seenIdentities.insert(identity).inserted else {
                    statistics.hardLinkAliasCount += 1
                    continue
                }

                let item = DuplicateFileItem(
                    url: rawURL.standardizedFileURL,
                    name: rawURL.lastPathComponent,
                    size: fingerprint.fileSize,
                    allocatedSize: fingerprint.allocatedSize,
                    createdAt: values.creationDate,
                    modifiedAt: values.contentModificationDate,
                    contentTypeIdentifier: values.contentType?.identifier,
                    fingerprint: fingerprint,
                    protectionReason: Self.protectionReason(
                        for: rawURL,
                        fingerprint: fingerprint,
                        isWritable: values.isWritable == true
                    )
                )
                filesBySize[item.size, default: []].append(item)
            }
            statistics.inaccessibleItemCount += enumerationErrors
        }

        let sizeBuckets = filesBySize
            .filter { $0.value.count > 1 }
            .sorted { lhs, rhs in lhs.key > rhs.key }
        statistics.candidateFileCount = sizeBuckets.reduce(0) {
            $0 + $1.value.count
        }

        var sampleBuckets: [[DuplicateFileItem]] = []
        var sampledCount = 0
        for (_, files) in sizeBuckets {
            var filesBySampleHash: [String: [DuplicateFileItem]] = [:]
            for file in files {
                try Task.checkCancellation()
                do {
                    let sampleHash = try await Self.sampleHashHex(for: file)
                    filesBySampleHash[sampleHash, default: []].append(file)
                } catch ScannerError.fileChanged {
                    statistics.changedFileCount += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    statistics.hashingFailureCount += 1
                }
                sampledCount += 1
                if sampledCount == 1
                    || sampledCount == statistics.candidateFileCount
                    || sampledCount.isMultiple(of: 25) {
                    progress(DuplicateScanProgress(
                        phase: .sampling,
                        fraction: Self.fraction(
                            sampledCount,
                            statistics.candidateFileCount
                        ),
                        examinedFileCount: statistics.examinedFileCount,
                        candidateFileCount: statistics.candidateFileCount,
                        currentPath: file.url.path
                    ))
                }
            }
            sampleBuckets.append(contentsOf: filesBySampleHash.values.filter {
                $0.count > 1
            })
        }

        let fullHashCandidateCount = sampleBuckets.reduce(0) { $0 + $1.count }
        var verifiedCount = 0
        var groups: [DuplicateFileGroup] = []
        for files in sampleBuckets {
            var filesByFullHash: [String: [DuplicateFileItem]] = [:]
            for file in files {
                try Task.checkCancellation()
                do {
                    let fullHash = try await Self.fullHashHex(for: file)
                    filesByFullHash[fullHash, default: []].append(file)
                } catch ScannerError.fileChanged {
                    statistics.changedFileCount += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    statistics.hashingFailureCount += 1
                }
                verifiedCount += 1
                if verifiedCount == 1
                    || verifiedCount == fullHashCandidateCount
                    || verifiedCount.isMultiple(of: 25) {
                    progress(DuplicateScanProgress(
                        phase: .verifying,
                        fraction: Self.fraction(
                            verifiedCount,
                            fullHashCandidateCount
                        ),
                        examinedFileCount: statistics.examinedFileCount,
                        candidateFileCount: statistics.candidateFileCount,
                        currentPath: file.url.path
                    ))
                }
            }

            for (hash, duplicateFiles) in filesByFullHash where duplicateFiles.count > 1 {
                let sortedFiles = duplicateFiles.sorted {
                    $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
                }
                let recommendation = Self.keeperRecommendation(for: sortedFiles)
                groups.append(DuplicateFileGroup(
                    contentHash: hash,
                    fileSize: sortedFiles[0].size,
                    files: sortedFiles,
                    suggestedKeeperID: recommendation.item.id,
                    keepReason: recommendation.reason
                ))
            }
        }

        groups.sort {
            if $0.logicalReclaimableSize == $1.logicalReclaimableSize {
                return $0.id < $1.id
            }
            return $0.logicalReclaimableSize > $1.logicalReclaimableSize
        }
        progress(DuplicateScanProgress(
            phase: .completed,
            fraction: 1,
            examinedFileCount: statistics.examinedFileCount,
            candidateFileCount: statistics.candidateFileCount,
            currentPath: ""
        ))
        return DuplicateFileScanResult(
            groups: groups,
            statistics: statistics,
            scannedAt: Date()
        )
    }

    nonisolated static func currentFingerprint(
        for url: URL
    ) -> DuplicateFileFingerprint? {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return DuplicateFileFingerprint(
            deviceID: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            fileSize: Int64(information.st_size),
            modificationSeconds: Int64(information.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            ownerUserID: UInt32(information.st_uid),
            hardLinkCount: UInt64(information.st_nlink),
            allocatedSize: max(0, Int64(information.st_blocks) * 512)
        )
    }

    nonisolated static func sampleHashHex(
        for item: DuplicateFileItem
    ) async throws -> String {
        guard currentFingerprint(for: item.url) == item.fingerprint else {
            throw ScannerError.fileChanged
        }

        let handle = try FileHandle(forReadingFrom: item.url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var size = item.size.bigEndian
        withUnsafeBytes(of: &size) { hasher.update(bufferPointer: $0) }

        let chunkSize = Int64(sampleChunkSize)
        let offsets = Set([
            Int64(0),
            max(0, item.size / 2 - chunkSize / 2),
            max(0, item.size - chunkSize),
        ]).sorted()

        for offset in offsets {
            try Task.checkCancellation()
            let requested = Int(min(chunkSize, item.size - offset))
            guard requested > 0 else { continue }
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: requested) ?? Data()
            guard data.count == requested else { throw ScannerError.shortRead }
            hasher.update(data: data)
        }

        guard currentFingerprint(for: item.url) == item.fingerprint else {
            throw ScannerError.fileChanged
        }
        return hasher.finalize().hexString
    }

    nonisolated static func fullHashHex(
        for item: DuplicateFileItem
    ) async throws -> String {
        guard currentFingerprint(for: item.url) == item.fingerprint else {
            throw ScannerError.fileChanged
        }

        let handle = try FileHandle(forReadingFrom: item.url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytesRead: Int64 = 0

        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: fullHashChunkSize) ?? Data()
            if data.isEmpty { break }
            bytesRead += Int64(data.count)
            hasher.update(data: data)
        }

        guard bytesRead == item.size else { throw ScannerError.shortRead }
        guard currentFingerprint(for: item.url) == item.fingerprint else {
            throw ScannerError.fileChanged
        }
        return hasher.finalize().hexString
    }

    nonisolated static func keeperRecommendation(
        for files: [DuplicateFileItem]
    ) -> (item: DuplicateFileItem, reason: DuplicateKeepReason) {
        precondition(!files.isEmpty)
        let sorted = files.sorted { lhs, rhs in
            let leftScore = keeperScore(lhs)
            let rightScore = keeperScore(rhs)
            if leftScore != rightScore { return leftScore > rightScore }
            let leftDate = lhs.createdAt ?? lhs.modifiedAt ?? .distantFuture
            let rightDate = rhs.createdAt ?? rhs.modifiedAt ?? .distantFuture
            if leftDate != rightDate { return leftDate < rightDate }
            let leftDepth = lhs.url.pathComponents.count
            let rightDepth = rhs.url.pathComponents.count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
        }
        let item = sorted[0]

        if item.protectionReason != nil {
            return (item, .protectedReference)
        }
        if isPreferredLocation(item.url.path) {
            return (item, .preferredLocation)
        }
        if !looksLikeCopyName(item.name),
           files.contains(where: { looksLikeCopyName($0.name) }) {
            return (item, .originalLookingName)
        }
        let oldest = files.min {
            ($0.createdAt ?? $0.modifiedAt ?? .distantFuture)
                < ($1.createdAt ?? $1.modifiedAt ?? .distantFuture)
        }
        if oldest?.id == item.id {
            return (item, .oldestCopy)
        }
        return (item, .shortestPath)
    }

    nonisolated static func isCloudPlaceholder(
        path: String,
        isUbiquitousItem: Bool,
        downloadingStatus: URLUbiquitousItemDownloadingStatus?,
        fileSize: Int64,
        allocatedSize: Int64
    ) -> Bool {
        if isUbiquitousItem {
            guard let downloadingStatus else { return true }
            return downloadingStatus != .current
                && downloadingStatus != .downloaded
        }
        return path.contains("/Library/CloudStorage/")
            && fileSize > 0
            && allocatedSize == 0
    }

    private nonisolated static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isReadableKey,
        .isWritableKey,
        .fileSizeKey,
        .totalFileAllocatedSizeKey,
        .creationDateKey,
        .contentModificationDateKey,
        .contentTypeKey,
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
    ]

    private nonisolated static func collapsedRoots(_ roots: [URL]) -> [URL] {
        let unique = Dictionary(
            roots.map {
                let url = $0.standardizedFileURL.resolvingSymlinksInPath()
                return (normalizedPath(url.path), url)
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        let ordered = unique.values.sorted {
            $0.pathComponents.count < $1.pathComponents.count
        }
        return ordered.reduce(into: []) { result, candidate in
            guard !result.contains(where: {
                isPath(candidate.path, insideOrEqualTo: $0.path)
            }) else {
                return
            }
            result.append(candidate)
        }
    }

    private nonisolated static func isReadableDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isReadableKey,
        ]) else {
            return false
        }
        return values.isDirectory == true && values.isReadable == true
    }

    private nonisolated static func isIgnored(
        _ url: URL,
        ignoredPaths: [String]
    ) -> Bool {
        let path = normalizedPath(url.path)
        return ignoredPaths.contains {
            isPath(path, insideOrEqualTo: $0)
        }
    }

    private nonisolated static func protectionReason(
        for url: URL,
        fingerprint: DuplicateFileFingerprint,
        isWritable: Bool
    ) -> DuplicateFileProtectionReason? {
        if fingerprint.hardLinkCount > 1 { return .hardLinked }
        if isSystemLocation(url.path)
            || isSystemLocation(canonicalPath(for: url)) {
            return .systemLocation
        }
        if !isWritable || fingerprint.ownerUserID != getuid() {
            return .notWritable
        }
        return nil
    }

    private nonisolated static func isSystemLocation(_ path: String) -> Bool {
        let blockedRoots = [
            "/Applications",
            "/Library",
            "/System",
            "/bin",
            "/private",
            "/sbin",
            "/usr",
        ]
        return [path, normalizedPath(path)].contains { candidate in
            blockedRoots.contains {
                candidate == $0 || candidate.hasPrefix($0 + "/")
            }
        }
    }

    private nonisolated static func canonicalPath(for url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = buffer.withUnsafeMutableBufferPointer { output in
            url.path.withCString { input in
                realpath(input, output.baseAddress)
            }
        }
        guard resolved != nil else {
            return url.standardizedFileURL.path
        }
        return String(cString: buffer)
    }

    private nonisolated static func keeperScore(_ item: DuplicateFileItem) -> Int {
        var score = 0
        if item.protectionReason != nil { score += 10_000 }
        if isPreferredLocation(item.url.path) { score += 500 }
        if !looksLikeCopyName(item.name) { score += 100 }
        if isTransientLocation(item.url.path) { score -= 500 }
        score -= min(100, item.url.pathComponents.count)
        return score
    }

    private nonisolated static func isPreferredLocation(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["Documents", "Pictures", "Movies", "Music"].contains {
            isPath(path, insideOrEqualTo: "\(home)/\($0)")
        }
    }

    private nonisolated static func isTransientLocation(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Downloads",
            "\(home)/Desktop",
            "\(home)/.Trash",
            "/tmp",
            "/private/tmp",
        ].contains {
            isPath(path, insideOrEqualTo: $0)
        }
    }

    private nonisolated static func looksLikeCopyName(_ name: String) -> Bool {
        let stem = (name as NSString)
            .deletingPathExtension
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.hasSuffix(" copy")
            || stem.hasSuffix("-copy")
            || stem.hasSuffix("_copy")
            || stem.contains("duplicate") {
            return true
        }
        return stem.range(
            of: #"\s\(\d+\)$"#,
            options: .regularExpression
        ) != nil
    }

    private nonisolated static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private nonisolated static func isPath(
        _ path: String,
        insideOrEqualTo root: String
    ) -> Bool {
        let normalized = normalizedPath(path)
        let normalizedRoot = normalizedPath(root)
        if normalizedRoot == "/" {
            return normalized.hasPrefix("/")
        }
        return normalized == normalizedRoot
            || normalized.hasPrefix(normalizedRoot + "/")
    }

    private nonisolated static func fraction(
        _ completed: Int,
        _ total: Int
    ) -> Double {
        guard total > 0 else { return 1 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
