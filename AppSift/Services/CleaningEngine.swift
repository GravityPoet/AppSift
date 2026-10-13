import Foundation

actor CleaningEngine {
    // Preserve the feature key so existing recovery records remain visible.
    static let recoveryFeature = "cleanup-personal-files"
    private let fileManager: FileManager
    private let homePath: String
    private let trashService: ReviewedTrashService
    private let privilegedService: PrivilegedAppRemovalService

    init(fileManager: FileManager = .default,
         homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
         trashService: ReviewedTrashService? = nil,
         privilegedService: PrivilegedAppRemovalService? = nil) {
        self.fileManager = fileManager
        let home = homeURL.standardizedFileURL.resolvingSymlinksInPath()
        self.homePath = home.path
        let privileged = privilegedService ?? PrivilegedAppRemovalService(
            trashRoot: home.appendingPathComponent(".Trash", isDirectory: true),
            allowedSourceRoots: [home] + Self.systemCleanupRoots.map { URL(fileURLWithPath: $0) }
        )
        self.privilegedService = privileged
        self.trashService = trashService ?? ReviewedTrashService(privilegedService: privileged)
    }

    struct CleaningResult {
        // Moving files to Trash does not release their occupied disk space.
        var freedSpace: Int64 = 0
        var itemsCleaned: Int = 0
        var errors: [String] = []
        var cleanedPaths: Set<String> = []
        var trashedSpace: Int64 = 0
        var requiresAdmin: [CleanableItem] = []
    }

    func cleanItems(_ items: [CleanableItem], progressHandler: @Sendable (Double) -> Void) async -> CleaningResult {
        await clean(items, usingAdministrator: false, progressHandler: progressHandler)
    }

    func cleanWithAdminPrivileges(items: [CleanableItem]) async -> CleaningResult {
        await clean(items, usingAdministrator: true, progressHandler: { _ in })
    }

    private func clean(_ items: [CleanableItem], usingAdministrator: Bool,
                       progressHandler: @Sendable (Double) -> Void) async -> CleaningResult {
        var result = CleaningResult()
        var candidates: [ReviewedTrashCandidate] = []
        var itemsByPath: [String: CleanableItem] = [:]
        for item in items where !item.isManualAction {
            let url = URL(fileURLWithPath: item.path).standardizedFileURL
            guard let fingerprint = item.reviewedFingerprint,
                  isAllowed(item, at: url),
                  url.resolvingSymlinksInPath().path == url.path,
                  ReviewedTrashFingerprint.read(at: url) == fingerprint else {
                result.errors.append("\(item.path): " + String(localized: "Could not safely review this item. Scan again before removal."))
                continue
            }
            guard itemsByPath[url.path] == nil else { continue }
            itemsByPath[url.path] = item
            if !usingAdministrator,
               fingerprint.owner != UInt32(getuid())
                || !fileManager.isWritableFile(atPath: url.deletingLastPathComponent().path)
                || privilegedService.requiresAdministratorAccess(for: [url]) {
                result.requiresAdmin.append(item)
                continue
            }
            candidates.append(ReviewedTrashCandidate(
                id: "\(item.category.rawValue):\(item.id.uuidString)", name: item.name,
                url: url, size: item.size, fingerprint: fingerprint,
                allowedRoot: url.deletingLastPathComponent(), requiresDirectChild: true
            ))
        }

        // Move a selected parent once; moving one of its children first would
        // change the parent's reviewed fingerprint and double-count its size.
        let topLevel = candidates.filter { candidate in
            !candidates.contains { other in
                candidate.url.path.hasPrefix(other.url.path + "/")
            }
        }
        guard !topLevel.isEmpty else {
            progressHandler(1)
            return result
        }
        let outcome = await trashService.moveToTrash(
            topLevel, feature: Self.recoveryFeature, usingAdministrator: usingAdministrator,
            progressHandler: progressHandler
        )
        if !outcome.historyPersisted {
            result.errors.append(String(localized: "Recovery history could not be saved. Check each item's result before trying again."))
        }
        for entry in outcome.record?.items ?? [] {
            switch entry.status {
            case .movedToTrash:
                result.cleanedPaths.insert(entry.originalPath)
                result.itemsCleaned += 1
                result.trashedSpace += entry.size
                for path in itemsByPath.keys where path.hasPrefix(entry.originalPath + "/") {
                    result.cleanedPaths.insert(path)
                }
            case .alreadyMissing:
                result.cleanedPaths.insert(entry.originalPath)
            case .trashFailed where !usingAdministrator && entry.failure?.kind == .administratorAccessRequired:
                if let item = itemsByPath[entry.originalPath] { result.requiresAdmin.append(item) }
            default:
                let detail = entry.detail ?? String(localized: "Could not move this item to Trash. Scan again before removal.")
                let location = entry.trashPath.map { " [Trash: \($0)]" } ?? ""
                result.errors.append("\(entry.originalPath): \(detail)\(location)")
            }
        }
        // A child already moved with its parent must not be escalated later.
        result.requiresAdmin.removeAll { result.cleanedPaths.contains($0.path) }
        if outcome.record == nil {
            result.errors.append(String(localized: "The selected file batch could not be moved safely."))
        }
        progressHandler(1)
        return result
    }

    private func isAllowed(_ item: CleanableItem, at url: URL) -> Bool {
        switch item.category {
        case .largeFiles:
            return isExplicitSingleFileDeletable(resolvedPath: url.path)
                && item.reviewedFingerprint.map { $0.mode & UInt32(S_IFMT) == UInt32(S_IFREG) } == true
        case .mailAttachments:
            return ["\(homePath)/Library/Mail Downloads",
                    "\(homePath)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"]
                .contains { url.path.hasPrefix($0 + "/") }
        case .developerArtifacts:
            return DeveloperArtifactScanner.isSafeRemovalRoot(resolvedPath: url.path, expectedSize: item.size)
        case .smartScan, .trashBins, .purgeableSpace:
            return false
        default:
            return isSafeToDelete(resolvedPath: url.path)
        }
    }

    func cleanCategory(_ result: CategoryResult, progressHandler: @Sendable (Double) -> Void) async -> CleaningResult {
        await cleanItems(result.items.filter(\.isSelected), progressHandler: progressHandler)
    }

    func recoveryHistory() async -> [ReviewedTrashRecord] {
        await trashService.history(feature: Self.recoveryFeature)
    }

    func undo(_ record: ReviewedTrashRecord) async -> ReviewedTrashUndoOutcome {
        guard record.feature == Self.recoveryFeature else {
            return ReviewedTrashUndoOutcome(restoredCount: 0, failedCount: record.items.count, historyPersisted: true)
        }
        return await trashService.undo(record)
    }

    private static let systemCleanupRoots = [
        "/Library/Caches", "/Library/Logs", "/private/var/log", "/var/log",
        "/private/var/tmp", "/var/tmp", "/private/tmp", "/tmp",
        "/opt/homebrew/Library/Caches", "/usr/local/Homebrew/Library/Caches",
    ]

    /// Generic cleanup may move cache/log children, never shared Library roots
    /// or another app's settings, containers, mail store, or recovery history.
    func isSafeToDelete(resolvedPath: String) -> Bool {
        let path = (resolvedPath as NSString).standardizingPath
        guard !isProtectedRuntimePath(path, home: homePath) else { return false }
        if !path.hasPrefix(homePath + "/") {
            return Self.systemCleanupRoots.contains { path.hasPrefix($0 + "/") }
        }
        let childOnlyRoots = [
            "\(homePath)/Library/Caches", "\(homePath)/Library/Logs", "\(homePath)/.cache",
        ]
        if childOnlyRoots.contains(where: { path.hasPrefix($0 + "/") }) { return true }
        let removableRoots = [
            "\(homePath)/Library/Developer/Xcode/DerivedData",
            "\(homePath)/Library/Developer/Xcode/Archives",
            "\(homePath)/Library/Developer/CoreSimulator/Caches",
            "\(homePath)/.ollama/logs", "\(homePath)/.ollama/history",
            "\(homePath)/.lmstudio/server-logs", "\(homePath)/.lmstudio/conversations",
            "\(homePath)/.npm", "\(homePath)/Library/pnpm/store",
            "\(homePath)/Library/Containers/com.docker.docker/Data/cache",
            "\(homePath)/Library/Containers/com.docker.docker/Data/log",
            "\(homePath)/Library/Containers/com.docker.docker/Data/tmp",
            "\(homePath)/Library/Group Containers/group.com.docker/Caches",
            "\(homePath)/.docker/cli-plugins/.cache",
        ]
        return removableRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func isProtectedRuntimePath(_ path: String, home: String) -> Bool {
        let roots = [
            "\(home)/Library/Caches/CloudKit",
            "\(home)/Library/Caches/CloudDocs",
            "\(home)/Library/Caches/com.apple.CloudDocs",
            "\(home)/Library/Caches/com.apple.CloudDocs.iCloudDriveFileProvider",
            "\(home)/Library/Caches/Google",
            "\(home)/Library/Caches/Chromium",
            "\(home)/Library/Caches/Firefox",
            "\(home)/Library/Caches/com.apple.Safari",
        ]
        return roots.contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }

    func isExplicitSingleFileDeletable(resolvedPath: String) -> Bool {
        let path = (resolvedPath as NSString).standardizingPath
        return ["Downloads", "Documents", "Desktop"].contains {
            path.hasPrefix("\(homePath)/\($0)/")
        }
    }

    func purgePurgeableSpace() async -> Int64 {
        // Get current purgeable space first
        let beforeFree = getCurrentFreeSpace()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["apfs", "purgePurgeable", "/"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            let afterFree = getCurrentFreeSpace()
            let freedSpace = afterFree - beforeFree
            return max(0, freedSpace)
        } catch {
            Logger.shared.log("diskutil purge failed: \(error.localizedDescription)", level: .error)
            return 0
        }
    }

    private func getCurrentFreeSpace() -> Int64 {
        do {
            let attrs = try fileManager.attributesOfFileSystem(forPath: "/")
            return (attrs[.systemFreeSize] as? Int64) ?? 0
        } catch {
            Logger.shared.log("Cannot read filesystem attributes: \(error.localizedDescription)", level: .warning)
            return 0
        }
    }
}
