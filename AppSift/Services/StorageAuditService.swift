import Darwin
import Foundation

actor StorageAuditService {
    typealias ProgressHandler = @Sendable (StorageAuditProgress) -> Void

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private struct NodeSummary {
        let logicalBytes: Int64
        let allocatedBytes: Int64
        let fileCount: Int
        let directoryCount: Int
    }

    private struct Context {
        let root: URL
        let volumePath: String
        let progress: ProgressHandler
        let rootDevice: dev_t
        var examinedItemCount = 0
        var inaccessibleItemCount = 0
        var inaccessiblePaths: [String] = []
        var symbolicLinkCount = 0
        var hardLinkAliasCount = 0
        var seenFileIdentities: Set<FileIdentity> = []
        var cloudPlaceholderCount = 0
        var nestedVolumeCount = 0
        var firmlinkSkippedCount = 0
        let firmlinkRoots: Set<String>
        var topItems: [StorageAuditItem] = []
        var virtualMachineItems: [StorageAuditItem] = []

        init(
            root: URL,
            volumePath: String,
            progress: @escaping ProgressHandler,
            firmlinkRoots: Set<String>? = nil
        ) {
            self.root = root
            self.volumePath = volumePath
            self.progress = progress
            var rootInformation = stat()
            self.rootDevice = lstat(root.path, &rootInformation) == 0
                ? rootInformation.st_dev
                : 0
            let roots = firmlinkRoots
                ?? (root.path == "/" ? StorageAuditService.loadFirmlinkRoots() : [])
            self.firmlinkRoots = Set(roots.map(StorageAuditService.normalizedPath))
        }

        mutating func report(_ path: String) {
            examinedItemCount += 1
            if examinedItemCount == 1 || examinedItemCount.isMultiple(of: 250) {
                progress(StorageAuditProgress(
                    phase: .scanning,
                    volumePath: volumePath,
                    examinedItemCount: examinedItemCount,
                    currentPath: path
                ))
            }
        }

        mutating func recordInaccessible(_ path: String) {
            inaccessibleItemCount += 1
            if inaccessiblePaths.count < 512 {
                inaccessiblePaths.append(path)
            }
        }

        mutating func addTopItem(_ item: StorageAuditItem) {
            topItems.append(item)
            topItems.sort {
                if $0.allocatedBytes != $1.allocatedBytes {
                    return $0.allocatedBytes > $1.allocatedBytes
                }
                if $0.logicalBytes != $1.logicalBytes {
                    return $0.logicalBytes > $1.logicalBytes
                }
                return $0.path < $1.path
            }
            if topItems.count > 32 { topItems.removeLast() }
        }

        mutating func addVirtualMachineItem(_ item: StorageAuditItem) {
            virtualMachineItems.append(item)
            virtualMachineItems.sort { $0.allocatedBytes > $1.allocatedBytes }
            if virtualMachineItems.count > 64 { virtualMachineItems.removeLast() }
        }
    }

    private static let virtualMachineExtensions: Set<String> = [
        "utm", "qcow", "qcow2", "vmdk", "vdi", "vhd", "vhdx", "img", "iso"
    ]

    private let volumeProvider: @Sendable () -> [SystemVolumeSnapshot]
    private let processProvider: @Sendable () -> [SystemProcessMemorySnapshot]
    private let firmlinkRootsOverride: Set<String>?

    init(
        volumeProvider: @escaping @Sendable () -> [SystemVolumeSnapshot] = {
            SystemTelemetryReader.mountedVolumes(includeHidden: true)
        },
        processProvider: @escaping @Sendable () -> [SystemProcessMemorySnapshot] = {
            SystemTelemetryReader.allProcessesByMemory()
        },
        firmlinkRoots: Set<String>? = nil
    ) {
        self.volumeProvider = volumeProvider
        self.processProvider = processProvider
        self.firmlinkRootsOverride = firmlinkRoots
    }

    func scan(
        includeInternal: Bool = true,
        progress: @escaping ProgressHandler = { _ in }
    ) async -> StorageAuditReport {
        progress(StorageAuditProgress(
            phase: .discovering,
            volumePath: "",
            examinedItemCount: 0,
            currentPath: ""
        ))

        let mounted = volumeProvider()
        var targets: [SystemVolumeSnapshot] = []
        var dataPath: String?
        if includeInternal {
            let startup = mounted.first(where: { $0.path == "/" })
                ?? Self.startupVolumeSnapshot()
            let data = mounted.first(where: {
                $0.path == "/System/Volumes/Data"
                    || $0.volumeRole?.localizedCaseInsensitiveCompare("Data") == .orderedSame
            })
                ?? Self.dataVolumeSnapshot(fallback: startup)
            dataPath = data.path
            if startup.path != data.path {
                targets.append(startup)
            }
            targets.append(data)
            targets.append(contentsOf: mounted.filter {
                $0.isInternal
                    && $0.path != "/"
                    && $0.path != data.path
                    && ($0.path.hasPrefix("/System/Volumes/") || $0.path == "/Volumes/Recovery")
            })
        }
        targets.append(contentsOf: mounted.filter {
            !$0.isInternal && $0.path != "/"
        })

        var volumes: [StorageAuditVolume] = []
        var vmItems: [StorageAuditItem] = []
        for target in targets {
            if Task.isCancelled { break }
            progress(StorageAuditProgress(
                phase: .scanning,
                volumePath: target.path,
                examinedItemCount: 0,
                currentPath: target.path
            ))

            if Self.isTimeMachineVolume(target)
                || Self.isReadOnlySystemVolume(target)
                || (target.isInternal
                    && target.path != "/"
                    && target.path != dataPath
                    && (target.path.hasPrefix("/System/Volumes/") || target.path == "/Volumes/Recovery")) {
                let isTimeMachine = Self.isTimeMachineVolume(target)
                volumes.append(StorageAuditVolume(
                    path: target.path,
                    name: target.name,
                    totalBytes: target.totalBytes,
                    availableBytes: target.availableBytes,
                    isInternal: target.isInternal,
                    isRemovable: target.isRemovable,
                    isReadOnly: target.isReadOnly,
                    deviceIdentifier: target.deviceIdentifier,
                    filesystemType: target.filesystemType,
                    volumeRole: target.volumeRole,
                    containerIdentifier: target.containerIdentifier,
                    isBackupVolume: target.isBackupVolume,
                    isMetadataOnly: true,
                    status: .metadataOnly,
                    scannedItemCount: 0,
                    fileCount: 0,
                    directoryCount: 0,
                    logicalBytes: 0,
                    allocatedBytes: 0,
                    inaccessibleItemCount: 0,
                    inaccessiblePaths: [],
                    symbolicLinkCount: 0,
                    cloudPlaceholderCount: 0,
                    nestedVolumeCount: 0,
                    firmlinkSkippedCount: 0,
                    hardLinkAliasCount: 0,
                    topItems: [],
                    errorSummary: isTimeMachine
                        ? String(localized: "Time Machine volumes are shown as metadata only.")
                        : target.path == "/"
                            ? String(localized: "The read-only System volume is represented as metadata; the Data volume is scanned recursively.")
                            : String(localized: "Auxiliary internal volumes are represented as metadata to avoid double counting the APFS container.")
                ))
                continue
            }

            let result = await scanVolume(target, progress: progress)
            volumes.append(result.volume)
            vmItems.append(contentsOf: result.virtualMachineItems)
            if result.cancelled { break }
        }

        let allProcesses = processProvider().sorted { lhs, rhs in
            if lhs.residentBytes != rhs.residentBytes {
                return lhs.residentBytes > rhs.residentBytes
            }
            return lhs.pid < rhs.pid
        }
        let processes = Array(allProcesses.prefix(16))
        let memory = SystemTelemetryReader.memorySnapshot()
        let trash = SystemTelemetryReader.trashSnapshot()
        let virtualMachines = Self.makeVirtualMachineAssets(
            from: vmItems,
            processes: allProcesses
        )
        let wasCancelled = Task.isCancelled || volumes.contains { $0.status == .cancelled }
        var notes = [
            String(localized: "The mutable Data volume and each readable external volume are measured separately; read-only System and Time Machine volumes remain metadata-only."),
            String(localized: "The macOS System and Data volumes share one APFS container; their capacity figures are not added together."),
            String(localized: "Unreadable paths, symlinks, cloud placeholders, and nested volumes are counted as coverage boundaries."),
            String(localized: "Windows guest files are not entered; UTM and virtual disk files are host-side assets only."),
            String(localized: "Logical totals can include hard-link aliases or APFS clone streams; allocated totals are the physical-allocation comparison."),
        ]
        if volumes.contains(where: { $0.status == .metadataOnly }) {
            notes.append(String(localized: "Time Machine external volumes are intentionally metadata-only in this audit."))
        }
        progress(StorageAuditProgress(
            phase: wasCancelled ? .cancelled : .completed,
            volumePath: "",
            examinedItemCount: volumes.reduce(0) { $0 + $1.scannedItemCount },
            currentPath: ""
        ))
        return StorageAuditReport(
            capturedAt: Date(),
            volumes: volumes,
            processes: processes,
            memory: memory,
            trash: trash,
            virtualMachines: virtualMachines,
            coverageNotes: notes,
            wasCancelled: wasCancelled
        )
    }

    private func scanVolume(
        _ target: SystemVolumeSnapshot,
        progress: @escaping ProgressHandler
    ) async -> (volume: StorageAuditVolume, virtualMachineItems: [StorageAuditItem], cancelled: Bool) {
        let root = URL(fileURLWithPath: target.path, isDirectory: true).standardizedFileURL
        var context = Context(
            root: root,
            volumePath: target.path,
            progress: progress,
            firmlinkRoots: firmlinkRootsOverride
        )
        guard Self.isReadableDirectory(root) else {
            return (
                StorageAuditVolume(
                    path: target.path,
                    name: target.name,
                    totalBytes: target.totalBytes,
                    availableBytes: target.availableBytes,
                    isInternal: target.isInternal,
                    isRemovable: target.isRemovable,
                    isReadOnly: target.isReadOnly,
                    deviceIdentifier: target.deviceIdentifier,
                    filesystemType: target.filesystemType,
                    volumeRole: target.volumeRole,
                    containerIdentifier: target.containerIdentifier,
                    isBackupVolume: target.isBackupVolume,
                    isMetadataOnly: false,
                    status: .inaccessible,
                    scannedItemCount: 0,
                    fileCount: 0,
                    directoryCount: 0,
                    logicalBytes: 0,
                    allocatedBytes: 0,
                    inaccessibleItemCount: 1,
                    inaccessiblePaths: [target.path],
                    symbolicLinkCount: 0,
                    cloudPlaceholderCount: 0,
                    nestedVolumeCount: 0,
                    firmlinkSkippedCount: 0,
                    hardLinkAliasCount: 0,
                    topItems: [],
                    errorSummary: String(localized: "The volume could not be read.")
                ),
                [],
                false
            )
        }

        let summary: NodeSummary
        do {
            summary = try scanNode(at: root, isRoot: true, context: &context)
        } catch is CancellationError {
            let volume = StorageAuditVolume(
                path: target.path,
                name: target.name,
                totalBytes: target.totalBytes,
                availableBytes: target.availableBytes,
                isInternal: target.isInternal,
                isRemovable: target.isRemovable,
                isReadOnly: target.isReadOnly,
                deviceIdentifier: target.deviceIdentifier,
                filesystemType: target.filesystemType,
                volumeRole: target.volumeRole,
                containerIdentifier: target.containerIdentifier,
                isBackupVolume: target.isBackupVolume,
                isMetadataOnly: false,
                status: .cancelled,
                scannedItemCount: context.examinedItemCount,
                fileCount: 0,
                directoryCount: 0,
                logicalBytes: 0,
                allocatedBytes: 0,
                inaccessibleItemCount: context.inaccessibleItemCount,
                inaccessiblePaths: context.inaccessiblePaths,
                symbolicLinkCount: context.symbolicLinkCount,
                cloudPlaceholderCount: context.cloudPlaceholderCount,
                nestedVolumeCount: context.nestedVolumeCount,
                firmlinkSkippedCount: context.firmlinkSkippedCount,
                hardLinkAliasCount: context.hardLinkAliasCount,
                topItems: context.topItems,
                errorSummary: String(localized: "The scan was cancelled before finalizing.")
            )
            return (volume, context.virtualMachineItems, true)
        } catch {
            context.recordInaccessible(root.path)
            summary = NodeSummary(logicalBytes: 0, allocatedBytes: 0, fileCount: 0, directoryCount: 0)
        }

        let volume = StorageAuditVolume(
            path: target.path,
            name: target.name,
            totalBytes: target.totalBytes,
            availableBytes: target.availableBytes,
            isInternal: target.isInternal,
            isRemovable: target.isRemovable,
            isReadOnly: target.isReadOnly,
            deviceIdentifier: target.deviceIdentifier,
            filesystemType: target.filesystemType,
            volumeRole: target.volumeRole,
            containerIdentifier: target.containerIdentifier,
            isBackupVolume: target.isBackupVolume,
            isMetadataOnly: false,
            status: .scanned,
            scannedItemCount: context.examinedItemCount,
            fileCount: summary.fileCount,
            directoryCount: summary.directoryCount,
            logicalBytes: summary.logicalBytes,
            allocatedBytes: summary.allocatedBytes,
            inaccessibleItemCount: context.inaccessibleItemCount,
            inaccessiblePaths: context.inaccessiblePaths,
            symbolicLinkCount: context.symbolicLinkCount,
            cloudPlaceholderCount: context.cloudPlaceholderCount,
            nestedVolumeCount: context.nestedVolumeCount,
            firmlinkSkippedCount: context.firmlinkSkippedCount,
            hardLinkAliasCount: context.hardLinkAliasCount,
            topItems: context.topItems,
            errorSummary: context.inaccessibleItemCount > 0
                ? String(localized: "Some paths could not be read; inspect the inaccessible count and sample paths.")
                : nil
        )
        return (volume, context.virtualMachineItems, false)
    }

    private func scanNode(
        at url: URL,
        isRoot: Bool,
        context: inout Context
    ) throws -> NodeSummary {
        try Task.checkCancellation()
        if context.firmlinkRoots.contains(Self.normalizedPath(url.path)) {
            context.firmlinkSkippedCount += 1
            return NodeSummary(logicalBytes: 0, allocatedBytes: 0, fileCount: 0, directoryCount: 0)
        }
        context.report(url.path)

        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            context.recordInaccessible(url.path)
            return NodeSummary(logicalBytes: 0, allocatedBytes: 0, fileCount: 0, directoryCount: 0)
        }
        let fileType = information.st_mode & S_IFMT
        if fileType == S_IFLNK {
            context.symbolicLinkCount += 1
            return NodeSummary(logicalBytes: 0, allocatedBytes: 0, fileCount: 0, directoryCount: 0)
        }
        if information.st_dev != context.rootDevice && !isRoot {
            context.nestedVolumeCount += 1
            return NodeSummary(logicalBytes: 0, allocatedBytes: 0, fileCount: 0, directoryCount: 0)
        }

        let isDirectory = fileType == S_IFDIR
        if isDirectory {
            var logical: Int64 = 0
            var allocated: Int64 = 0
            var files = 0
            var directories = 1
            do {
                let children = try FileManager.default.contentsOfDirectory(atPath: url.path)
                    .map { url.appendingPathComponent($0, isDirectory: false) }
                for child in children {
                    try Task.checkCancellation()
                    let childSummary = try scanNode(at: child, isRoot: false, context: &context)
                    logical = Self.adding(logical, childSummary.logicalBytes)
                    allocated = Self.adding(allocated, childSummary.allocatedBytes)
                    files += childSummary.fileCount
                    directories += childSummary.directoryCount
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                context.recordInaccessible(url.path)
            }
            let summary = NodeSummary(
                logicalBytes: logical,
                allocatedBytes: allocated,
                fileCount: files,
                directoryCount: directories
            )
            let item = StorageAuditItem(
                path: url.path,
                name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                kind: "directory",
                logicalBytes: logical,
                allocatedBytes: allocated,
                fileCount: files,
                directoryCount: directories
            )
            context.addTopItem(item)
            if Self.isVirtualMachinePath(url) {
                context.addVirtualMachineItem(item)
            }
            return summary
        }

        guard fileType == S_IFREG else {
            return NodeSummary(logicalBytes: 0, allocatedBytes: 0, fileCount: 0, directoryCount: 0)
        }
        let logical = Int64(max(0, information.st_size))
        let allocated = Int64(max(0, information.st_blocks)) * 512
        let identity = FileIdentity(device: information.st_dev, inode: information.st_ino)
        let isHardLinkAlias = !context.seenFileIdentities.insert(identity).inserted
        if isHardLinkAlias { context.hardLinkAliasCount += 1 }
        let cloudPlaceholder = (information.st_flags & UInt32(SF_DATALESS)) != 0
        if cloudPlaceholder { context.cloudPlaceholderCount += 1 }
        let item = StorageAuditItem(
            path: url.path,
            name: url.lastPathComponent,
            kind: "file",
            logicalBytes: logical,
            allocatedBytes: cloudPlaceholder || isHardLinkAlias ? 0 : allocated,
            fileCount: 1,
            directoryCount: 0
        )
        context.addTopItem(item)
        if Self.isVirtualMachinePath(url) {
            context.addVirtualMachineItem(item)
        }
        return NodeSummary(
            logicalBytes: logical,
            allocatedBytes: cloudPlaceholder || isHardLinkAlias ? 0 : allocated,
            fileCount: 1,
            directoryCount: 0
        )
    }

    private static func makeVirtualMachineAssets(
        from items: [StorageAuditItem],
        processes: [SystemProcessMemorySnapshot]
    ) -> [StorageAuditVirtualMachineAsset] {
        let grouped = Dictionary(grouping: items, by: \.path)
        let candidatePaths = Set(grouped.keys)
        return grouped.values.compactMap { group in
            guard let item = group.max(by: { $0.allocatedBytes < $1.allocatedBytes }) else { return nil }
            let isNestedInUTM = candidatePaths.contains { parent in
                parent != item.path
                    && URL(fileURLWithPath: parent).pathExtension.lowercased() == "utm"
                    && item.path.hasPrefix(parent + "/")
            }
            guard !isNestedInUTM else { return nil }
            let matching = processes.filter { process in
                guard let commandLine = process.commandLine else { return false }
                return commandLine.contains(item.path)
                    || commandLine.contains(item.name)
            }
            return StorageAuditVirtualMachineAsset(
                path: item.path,
                kind: item.kind,
                logicalBytes: item.logicalBytes,
                allocatedBytes: item.allocatedBytes,
                processIDs: matching.map(\.pid),
                isRunning: !matching.isEmpty,
                guestScope: String(localized: "The guest OS was not entered; this is a host-side VM asset.")
            )
        }
        .sorted { $0.allocatedBytes > $1.allocatedBytes }
    }

    private static func isTimeMachineVolume(_ volume: SystemVolumeSnapshot) -> Bool {
        let value = (volume.name + " " + volume.path).lowercased()
        return volume.isBackupVolume
            || value.contains("time machine")
            || value.contains("timemachine")
            || value.contains("时间机器")
            || value.contains(".timemachine")
    }

    private static func isReadOnlySystemVolume(_ volume: SystemVolumeSnapshot) -> Bool {
        volume.path == "/" && volume.isReadOnly
    }

    private static func isReadableDirectory(_ url: URL) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0
            && information.st_mode & S_IFMT == S_IFDIR
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    private static func loadFirmlinkRoots() -> Set<String> {
        guard let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) else {
            return []
        }
        return Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard let first = fields.first, first.hasPrefix("/") else { return nil }
            return String(first)
        })
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func startupVolumeSnapshot() -> SystemVolumeSnapshot {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/")
        let total = attributes?[.systemSize] as? Int64 ?? 0
        let available = attributes?[.systemFreeSize] as? Int64 ?? 0
        return SystemVolumeSnapshot(
            path: "/",
            name: String(localized: "Macintosh HD"),
            totalBytes: total,
            availableBytes: available,
            isInternal: true,
            isRemovable: false,
            isReadOnly: false
        )
    }

    private static func dataVolumeSnapshot(
        fallback: SystemVolumeSnapshot
    ) -> SystemVolumeSnapshot {
        let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: "/System/Volumes/Data"
        )
        return SystemVolumeSnapshot(
            path: "/System/Volumes/Data",
            name: String(localized: "Data"),
            totalBytes: attributes?[.systemSize] as? Int64 ?? fallback.totalBytes,
            availableBytes: attributes?[.systemFreeSize] as? Int64 ?? fallback.availableBytes,
            isInternal: true,
            isRemovable: false,
            isReadOnly: false
        )
    }

    private static func isVirtualMachinePath(_ url: URL) -> Bool {
        virtualMachineExtensions.contains(url.pathExtension.lowercased())
    }

    private static func adding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }
}

@MainActor
final class StorageAuditCenter: ObservableObject {
    @Published private(set) var report: StorageAuditReport?
    @Published private(set) var isScanning = false
    @Published private(set) var progress = StorageAuditProgress.idle
    @Published var errorMessage: String?

    private let service: StorageAuditService
    private var task: Task<Void, Never>?

    init(service: StorageAuditService = StorageAuditService()) {
        self.service = service
    }

    func scan(force: Bool = false) {
        if isScanning {
            guard force else { return }
            task?.cancel()
        }
        isScanning = true
        errorMessage = nil
        progress = .idle
        let service = service
        task = Task { [weak self] in
            let result = await service.scan { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.progress = progress
                }
            }
            guard let self else { return }
            if !Task.isCancelled {
                self.report = result
            }
            self.isScanning = false
            self.task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }
}
