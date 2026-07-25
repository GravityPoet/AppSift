import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

actor SpaceLensScanner {
    typealias ProgressHandler = @Sendable (SpaceLensScanProgress) -> Void

    private struct FileIdentity: Hashable {
        let deviceID: UInt64
        let inode: UInt64
    }

    private struct CloneIdentity: Hashable {
        let deviceID: UInt64
        let contentIdentifier: Int64
    }

    private final class ScanContext {
        let rootURL: URL
        let currentUserID: uid_t
        let progress: ProgressHandler
        var statistics = SpaceLensScanStatistics()
        var seenFileIdentities = Set<FileIdentity>()
        var seenDirectoryIdentities = Set<FileIdentity>()
        var seenCloneIdentities = Set<CloneIdentity>()
        var scannedAllocatedBytes: Int64 = 0

        init(
            rootURL: URL,
            currentUserID: uid_t,
            progress: @escaping ProgressHandler
        ) {
            self.rootURL = rootURL
            self.currentUserID = currentUserID
            self.progress = progress
        }

        func report(_ url: URL, force: Bool = false) {
            guard force
                    || statistics.examinedItemCount == 1
                    || statistics.examinedItemCount.isMultiple(of: 250) else {
                return
            }
            progress(SpaceLensScanProgress(
                phase: .scanning,
                examinedItemCount: statistics.examinedItemCount,
                fileCount: statistics.fileCount,
                directoryCount: statistics.directoryCount,
                allocatedBytes: scannedAllocatedBytes,
                currentPath: url.path
            ))
        }
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .isReadableKey,
        .isWritableKey,
        .isVolumeKey,
        .fileSizeKey,
        .totalFileAllocatedSizeKey,
        .contentModificationDateKey,
        .contentTypeKey,
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .fileContentIdentifierKey,
        .mayShareFileContentKey,
    ]

    func scan(
        root requestedRoot: URL,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> SpaceLensScanResult {
        try Task.checkCancellation()
        guard let root = Self.canonicalExistingURL(requestedRoot),
              Self.isDirectory(root) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        let context = ScanContext(
            rootURL: root,
            currentUserID: getuid(),
            progress: progress
        )
        progress(.idle)
        guard let rootNode = try Self.scanNode(
            at: root,
            isRoot: true,
            context: context
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        progress(SpaceLensScanProgress(
            phase: .finalizing,
            examinedItemCount: context.statistics.examinedItemCount,
            fileCount: context.statistics.fileCount,
            directoryCount: context.statistics.directoryCount,
            allocatedBytes: rootNode.allocatedSize,
            currentPath: root.path
        ))
        try Task.checkCancellation()

        let result = SpaceLensScanResult(
            root: rootNode,
            statistics: context.statistics,
            volumeInfo: Self.volumeInfo(for: root),
            scannedAt: Date()
        )
        progress(SpaceLensScanProgress(
            phase: .completed,
            examinedItemCount: context.statistics.examinedItemCount,
            fileCount: context.statistics.fileCount,
            directoryCount: context.statistics.directoryCount,
            allocatedBytes: rootNode.allocatedSize,
            currentPath: root.path
        ))
        return result
    }

    nonisolated static func verificationToken(for url: URL) -> String? {
        guard let canonicalURL = canonicalExistingURL(url) else { return nil }
        return try? inspectNode(at: canonicalURL).token
    }

    nonisolated static func currentFingerprint(
        for url: URL
    ) -> SpaceLensFingerprint? {
        fingerprint(for: url)
    }

    nonisolated static func canonicalExistingURL(_ url: URL) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return nil }
        let canonicalPath = String(cString: buffer)
        let canonicalURL = URL(fileURLWithPath: canonicalPath)
        return URL(
            fileURLWithPath: canonicalPath,
            isDirectory: isDirectory(canonicalURL)
        )
    }

    nonisolated static func pathContainsSymbolicLink(
        _ url: URL,
        stoppingAt stopURL: URL? = nil
    ) -> Bool {
        let stopPath = stopURL?.path
        var current = url

        while current.path != "/" && current.path != stopPath {
            var information = stat()
            if lstat(current.path, &information) != 0 {
                return true
            }
            if information.st_mode & S_IFMT == S_IFLNK {
                return true
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }
        return false
    }

    private nonisolated static func scanNode(
        at url: URL,
        isRoot: Bool,
        context: ScanContext
    ) throws -> SpaceLensNode? {
        try Task.checkCancellation()
        context.statistics.examinedItemCount += 1
        context.report(url)

        var lstatInformation = stat()
        guard lstat(url.path, &lstatInformation) == 0 else {
            context.statistics.inaccessibleItemCount += 1
            return nil
        }
        guard lstatInformation.st_mode & S_IFMT != S_IFLNK else {
            context.statistics.symbolicLinkCount += 1
            return nil
        }

        guard let values = try? url.resourceValues(forKeys: resourceKeys),
              let fingerprint = fingerprint(
                for: url,
                statInformation: lstatInformation,
                resourceValues: values
              ) else {
            context.statistics.inaccessibleItemCount += 1
            return nil
        }
        guard values.isVolume != true || isRoot else {
            context.statistics.nestedVolumeCount += 1
            return nil
        }

        if values.isDirectory == true {
            let identity = FileIdentity(
                deviceID: fingerprint.deviceID,
                inode: fingerprint.inode
            )
            guard context.seenDirectoryIdentities.insert(identity).inserted else {
                context.statistics.hardLinkAliasCount += 1
                return nil
            }
            context.statistics.directoryCount += 1
            context.scannedAllocatedBytes = adding(
                context.scannedAllocatedBytes,
                fingerprint.allocatedSize
            )

            var children: [SpaceLensNode] = []
            var directoryWasReadable = values.isReadable == true
            if directoryWasReadable {
                do {
                    let childURLs = try FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: Array(resourceKeys),
                        options: []
                    )
                    children.reserveCapacity(childURLs.count)
                    for childURL in childURLs {
                        try Task.checkCancellation()
                        if let child = try scanNode(
                            at: childURL,
                            isRoot: false,
                            context: context
                        ) {
                            children.append(child)
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    directoryWasReadable = false
                    context.statistics.inaccessibleItemCount += 1
                }
            } else {
                context.statistics.inaccessibleItemCount += 1
            }

            children.sort {
                if $0.allocatedSize != $1.allocatedSize {
                    return $0.allocatedSize > $1.allocatedSize
                }
                if $0.logicalSize != $1.logicalSize {
                    return $0.logicalSize > $1.logicalSize
                }
                return $0.name.localizedStandardCompare($1.name)
                    == .orderedAscending
            }

            let childLogicalSize = children.reduce(Int64(0)) {
                adding($0, $1.logicalSize)
            }
            let childAllocatedSize = children.reduce(Int64(0)) {
                adding($0, $1.allocatedSize)
            }
            let ownProtection = protectionReason(
                for: url,
                isRoot: isRoot,
                isDirectory: true,
                isReadable: directoryWasReadable,
                isWritable: values.isWritable == true,
                isCloudPlaceholder: false,
                fingerprint: fingerprint,
                currentUserID: context.currentUserID
            )
            let protectedDescendantCount = children.reduce(0) {
                $0 + ($1.protectionReason == nil ? 0 : 1)
                    + $1.protectedDescendantCount
            }
            let kind: SpaceLensNodeKind = values.isPackage == true
                ? .package
                : .directory
            let token = verificationToken(
                fingerprint: fingerprint,
                kind: kind,
                children: children.map { ($0.name, $0.verificationToken) }
            )
            return SpaceLensNode(
                url: url,
                name: displayName(for: url),
                kind: kind,
                logicalSize: childLogicalSize,
                allocatedSize: adding(
                    fingerprint.allocatedSize,
                    childAllocatedSize
                ),
                ownAllocatedSize: fingerprint.allocatedSize,
                fileCount: children.reduce(0) { $0 + $1.fileCount },
                directoryCount: 1 + children.reduce(0) {
                    $0 + $1.directoryCount
                },
                modifiedAt: values.contentModificationDate,
                contentTypeIdentifier: values.contentType?.identifier,
                fingerprint: fingerprint,
                verificationToken: token,
                protectionReason: ownProtection,
                protectedDescendantCount: protectedDescendantCount,
                isCloneAlias: false,
                isCloudPlaceholder: false,
                children: children
            )
        }

        guard values.isRegularFile == true else {
            return nil
        }
        context.statistics.fileCount += 1
        let identity = FileIdentity(
            deviceID: fingerprint.deviceID,
            inode: fingerprint.inode
        )
        let isHardLinkAlias = !context.seenFileIdentities
            .insert(identity).inserted
        if isHardLinkAlias {
            context.statistics.hardLinkAliasCount += 1
        }

        let cloudPlaceholder = isCloudPlaceholder(
            path: url.path,
            isUbiquitousItem: values.isUbiquitousItem == true,
            downloadingStatus: values.ubiquitousItemDownloadingStatus,
            logicalSize: fingerprint.logicalSize,
            allocatedSize: fingerprint.allocatedSize
        )
        if cloudPlaceholder {
            context.statistics.cloudPlaceholderCount += 1
        }

        var isCloneAlias = false
        if values.mayShareFileContent == true {
            context.statistics.cloneCandidateCount += 1
            if let contentIdentifier = values.fileContentIdentifier,
               contentIdentifier != 0 {
                let cloneIdentity = CloneIdentity(
                    deviceID: fingerprint.deviceID,
                    contentIdentifier: contentIdentifier
                )
                isCloneAlias = !context.seenCloneIdentities
                    .insert(cloneIdentity).inserted
                if isCloneAlias {
                    context.statistics.cloneAliasCount += 1
                }
            }
        }

        let countedAllocatedSize = cloudPlaceholder
            || isHardLinkAlias
            || isCloneAlias
            ? 0
            : fingerprint.allocatedSize
        context.scannedAllocatedBytes = adding(
            context.scannedAllocatedBytes,
            countedAllocatedSize
        )
        let ownProtection = protectionReason(
            for: url,
            isRoot: false,
            isDirectory: false,
            isReadable: values.isReadable == true,
            isWritable: values.isWritable == true,
            isCloudPlaceholder: cloudPlaceholder,
            fingerprint: fingerprint,
            currentUserID: context.currentUserID
        )
        let token = verificationToken(
            fingerprint: fingerprint,
            kind: .file,
            children: []
        )
        return SpaceLensNode(
            url: url,
            name: displayName(for: url),
            kind: .file,
            logicalSize: fingerprint.logicalSize,
            allocatedSize: countedAllocatedSize,
            ownAllocatedSize: countedAllocatedSize,
            fileCount: 1,
            directoryCount: 0,
            modifiedAt: values.contentModificationDate,
            contentTypeIdentifier: values.contentType?.identifier,
            fingerprint: fingerprint,
            verificationToken: token,
            protectionReason: ownProtection,
            protectedDescendantCount: 0,
            isCloneAlias: isCloneAlias,
            isCloudPlaceholder: cloudPlaceholder,
            children: []
        )
    }

    private struct InspectedNode {
        let name: String
        let token: String
    }

    private nonisolated static func inspectNode(
        at url: URL
    ) throws -> InspectedNode {
        try Task.checkCancellation()
        var information = stat()
        guard lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT != S_IFLNK,
              let values = try? url.resourceValues(forKeys: resourceKeys),
              let fingerprint = fingerprint(
                for: url,
                statInformation: information,
                resourceValues: values
              ) else {
            throw CocoaError(.fileReadNoPermission)
        }

        if values.isDirectory == true {
            let kind: SpaceLensNodeKind = values.isPackage == true
                ? .package
                : .directory
            let childURLs = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: []
            )
            var children: [InspectedNode] = []
            children.reserveCapacity(childURLs.count)
            for childURL in childURLs {
                children.append(try inspectNode(
                    at: childURL
                ))
            }
            return InspectedNode(
                name: url.lastPathComponent,
                token: verificationToken(
                    fingerprint: fingerprint,
                    kind: kind,
                    children: children.map { ($0.name, $0.token) }
                )
            )
        }

        guard values.isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return InspectedNode(
            name: url.lastPathComponent,
            token: verificationToken(
                fingerprint: fingerprint,
                kind: .file,
                children: []
            )
        )
    }

    private nonisolated static func fingerprint(
        for url: URL,
        statInformation: stat? = nil,
        resourceValues: URLResourceValues? = nil
    ) -> SpaceLensFingerprint? {
        var localInformation = stat()
        let information: stat
        if let statInformation {
            information = statInformation
        } else {
            guard lstat(url.path, &localInformation) == 0,
                  localInformation.st_mode & S_IFMT != S_IFLNK else {
                return nil
            }
            information = localInformation
        }

        let values = resourceValues ?? (try? url.resourceValues(
            forKeys: resourceKeys
        ))
        let rawAllocatedSize = values?.totalFileAllocatedSize
            .map(Int64.init)
            ?? max(0, Int64(information.st_blocks) * 512)
        return SpaceLensFingerprint(
            deviceID: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            logicalSize: max(0, Int64(information.st_size)),
            allocatedSize: max(0, rawAllocatedSize),
            modificationSeconds: Int64(information.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            ownerUserID: information.st_uid,
            hardLinkCount: UInt64(information.st_nlink),
            mode: UInt16(information.st_mode & 0o7777)
        )
    }

    private nonisolated static func verificationToken(
        fingerprint: SpaceLensFingerprint,
        kind: SpaceLensNodeKind,
        children: [(name: String, token: String)]
    ) -> String {
        var hasher = SHA256()
        update(&hasher, with: kind.rawValue)
        update(&hasher, with: "\(fingerprint.deviceID)")
        update(&hasher, with: "\(fingerprint.inode)")
        update(&hasher, with: "\(fingerprint.logicalSize)")
        update(&hasher, with: "\(fingerprint.allocatedSize)")
        update(&hasher, with: "\(fingerprint.modificationSeconds)")
        update(&hasher, with: "\(fingerprint.modificationNanoseconds)")
        update(&hasher, with: "\(fingerprint.ownerUserID)")
        update(&hasher, with: "\(fingerprint.hardLinkCount)")
        update(&hasher, with: "\(fingerprint.mode)")
        for child in children.sorted(by: { $0.name < $1.name }) {
            update(&hasher, with: child.name)
            update(&hasher, with: child.token)
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private nonisolated static func update(
        _ hasher: inout SHA256,
        with string: String
    ) {
        hasher.update(data: Data(string.utf8))
        hasher.update(data: Data([0]))
    }

    private nonisolated static func protectionReason(
        for url: URL,
        isRoot: Bool,
        isDirectory: Bool,
        isReadable: Bool,
        isWritable: Bool,
        isCloudPlaceholder: Bool,
        fingerprint: SpaceLensFingerprint,
        currentUserID: uid_t
    ) -> SpaceLensProtectionReason? {
        if isRoot {
            return .scanRoot
        }
        let canonicalPath = canonicalExistingURL(url)?.path
            ?? url.standardizedFileURL.path
        if isSystemLocation(canonicalPath) {
            return .systemLocation
        }
        if isAppManagedLibrary(url, canonicalPath: canonicalPath) {
            return .appManagedLibrary
        }
        if !isReadable {
            return .inaccessible
        }
        if fingerprint.ownerUserID != currentUserID {
            return .differentOwner
        }
        if !isWritable {
            return .notWritable
        }
        if !isDirectory && fingerprint.hardLinkCount > 1 {
            return .hardLinked
        }
        if isCloudPlaceholder {
            return .cloudPlaceholder
        }
        return nil
    }

    private nonisolated static func isSystemLocation(_ path: String) -> Bool {
        let protectedRoots = [
            "/System",
            "/Library",
            "/Applications",
            "/bin",
            "/sbin",
            "/usr",
            "/private",
            "/var",
            "/etc",
            "/opt",
            "/Users/Shared",
        ]
        if path == "/" || path == "/Users" || path == "/Volumes" {
            return true
        }
        if protectedRoots.contains(where: {
            path == $0 || path.hasPrefix($0 + "/")
        }) {
            return true
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.path
        if path == home || path == home + "/Library"
            || path.hasPrefix(home + "/Library/") {
            return true
        }
        return false
    }

    private nonisolated static func isAppManagedLibrary(
        _ url: URL,
        canonicalPath: String
    ) -> Bool {
        let protectedExtensions: Set<String> = [
            "app",
            "appex",
            "bundle",
            "framework",
            "photoslibrary",
            "photolibrary",
            "musiclibrary",
            "imovielibrary",
            "fcpbundle",
            "logicx",
            "band",
        ]
        if protectedExtensions.contains(
            url.pathExtension.lowercased()
        ) {
            return true
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.path
        let protectedUserPaths = [
            home + "/Pictures/Photos Library.photoslibrary",
            home + "/Movies/TV",
            home + "/Music/Music",
        ]
        return protectedUserPaths.contains {
            canonicalPath == $0 || canonicalPath.hasPrefix($0 + "/")
        }
    }

    private nonisolated static func isCloudPlaceholder(
        path: String,
        isUbiquitousItem: Bool,
        downloadingStatus: URLUbiquitousItemDownloadingStatus?,
        logicalSize: Int64,
        allocatedSize: Int64
    ) -> Bool {
        if isUbiquitousItem,
           downloadingStatus != .current {
            return true
        }
        return logicalSize > 0
            && allocatedSize == 0
            && (path.contains("/Library/CloudStorage/")
                || path.contains("/Mobile Documents/"))
    }

    private nonisolated static func volumeInfo(
        for root: URL
    ) -> SpaceLensVolumeInfo {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeNameKey,
            .isVolumeKey,
        ]
        let values = try? root.resourceValues(forKeys: keys)
        return SpaceLensVolumeInfo(
            totalCapacity: values?.volumeTotalCapacity.map(Int64.init),
            availableCapacity: values?.volumeAvailableCapacity.map(Int64.init),
            importantUsageAvailableCapacity:
                values?.volumeAvailableCapacityForImportantUsage,
            volumeName: values?.volumeName,
            isVolumeRoot: values?.isVolume == true
        )
    }

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private nonisolated static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    private nonisolated static func adding(
        _ lhs: Int64,
        _ rhs: Int64
    ) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }
}
