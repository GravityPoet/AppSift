import Foundation

actor ScanEngine {
    private let fileManager: FileManager
    private let home: String
    private let developerArtifactScanner: DeveloperArtifactScanner

    /// The scanner normally walks the current user's home directory.  Keeping
    /// the root injectable makes the cache ownership policy testable without
    /// touching a real user's Library (and is also useful for fixture scans).
    init(
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.home = homeURL.standardizedFileURL.path
        self.developerArtifactScanner = DeveloperArtifactScanner(
            fileManager: fileManager,
            homeURL: homeURL
        )
    }

    /// Live path reporter for the dashboard's scanning ticker. Throttled so
    /// a directory with thousands of entries doesn't flood the main actor.
    private var onPath: (@Sendable (String) -> Void)?
    private var lastReport = Date.distantPast

    /// `path` is an autoclosure so the String is only materialized after the
    /// throttle gate passes — a deep home-directory walk enumerates hundreds
    /// of thousands of entries and only ~12/sec are ever displayed.
    private func report(_ path: @autoclosure () -> String) {
        guard let onPath else { return }
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.1 else { return }
        lastReport = now
        onPath(path())
    }

    private struct CleanupTarget {
        let name: String
        let path: String
        let isSelected: Bool
        let minimumSize: Int64

        init(name: String, path: String, isSelected: Bool = true, minimumSize: Int64 = 1024) {
            self.name = name
            self.path = path
            self.isSelected = isSelected
            self.minimumSize = minimumSize
        }
    }

    // MARK: - Public API

    func scanCategory(
        _ category: CleaningCategory,
        onPath: (@Sendable (String) -> Void)? = nil
    ) async -> CategoryResult {
        guard !Task.isCancelled else {
            return CategoryResult(category: category, items: [], totalSize: 0)
        }
        self.onPath = onPath
        defer { self.onPath = nil }
        switch category {
        case .smartScan:
            return CategoryResult(category: category, items: [], totalSize: 0)
        case .systemJunk:
            return scanSystemJunk()
        case .userCache:
            return scanUserCache()
        case .aiApps:
            return scanAIApps()
        case .mailAttachments:
            return scanMailAttachments()
        case .trashBins:
            return scanTrash()
        case .largeFiles:
            return scanLargeFiles()
        case .purgeableSpace:
            return scanPurgeableSpace()
        case .xcodeJunk:
            return scanXcodeJunk()
        case .brewCache:
            return scanBrewCache()
        case .nodeCache:
            return scanNodeCache()
        case .dockerCache:
            return scanDockerCache()
        case .developerArtifacts:
            return scanDeveloperArtifacts()
        }
    }

    func getDiskInfo() -> DiskInfo {
        var info = DiskInfo()
        do {
            let attrs = try fileManager.attributesOfFileSystem(forPath: "/")
            if let total = attrs[.systemSize] as? Int64 {
                info.totalSpace = total
            }
            if let free = attrs[.systemFreeSize] as? Int64 {
                info.freeSpace = free
            }
            info.usedSpace = info.totalSpace - info.freeSpace

            // Use URLResourceValues for accurate purgeable space detection
            let rootURL = URL(fileURLWithPath: "/")
            let values = try rootURL.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ])
            if let importantCapacity = values.volumeAvailableCapacityForImportantUsage,
               let freeCapacity = values.volumeAvailableCapacity {
                // Purgeable = important capacity (free + purgeable) minus actual free
                let purgeable = importantCapacity - Int64(freeCapacity)
                if purgeable > 10 * 1024 * 1024 { // Only report if > 10 MB
                    info.purgeableSpace = purgeable
                }
            }
        } catch {
            Logger.shared.log("Disk info unavailable: \(error.localizedDescription)", level: .warning)
        }
        return info
    }

    // MARK: - Scanners

    private func scanSystemJunk() -> CategoryResult {
        var items: [CleanableItem] = []
        var totalSize: Int64 = 0

        let systemPaths = [
            "/Library/Caches",
            "/Library/Logs",
            "/private/var/log",
            "\(home)/Library/Logs",
            "/tmp",
            "/private/var/tmp",
        ]

        for path in systemPaths {
            let scanned = scanDirectory(path: path, category: .systemJunk, recursive: true, maxDepth: 3)
            items.append(contentsOf: scanned)
        }

        totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .systemJunk, items: items, totalSize: totalSize)
    }

    private func scanUserCache() -> CategoryResult {
        var items: [CleanableItem] = []
        // Exclude cache roots claimed by dedicated categories, macOS/iCloud,
        // or the browser privacy flow.  The generic cache scanner must never
        // turn transport databases or live browser profiles into ordinary
        // "junk" rows (and must not count a root again in another category).
        let excludedRootPaths = Self.userCacheExcludedRootPaths(home: home)

        // Dynamically enumerate ~/Library/Caches/ so every subdirectory is visible
        let cachePath = "\(home)/Library/Caches"
        let scanned = scanDirectory(
            path: cachePath,
            category: .userCache,
            recursive: false,
            maxDepth: 1,
            excluding: excludedRootPaths
        )
        items.append(contentsOf: scanned)

        // Pip has no dedicated category, so keep its global cache visible.
        // npm/yarn/pnpm are owned by Node Cache; listing them here as well
        // would make Smart Scan report the same bytes twice (npm's
        // ~/.npm/_cacache is the common example).
        let devCaches = [
            "\(home)/.cache/pip",
            "\(home)/Library/Caches/pip",
        ]

        for path in devCaches {
            if let item = makeCleanupItem(
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                category: .userCache
            ) {
                items.append(item)
            }
        }

        // NoTrace is not one of the three browsers handled by
        // BrowserPrivacyScanner. Keep its cache visible for an explicit
        // review, but never preselect it in the generic cleaner: the browser
        // may still own/open these files and there is no close-and-trash flow
        // here yet. Use a larger, hidden-file-inclusive bound because this
        // cache can legitimately contain hundreds of thousands of entries;
        // Chrome/Safari/Firefox remain owned by Browser Privacy.
        let reviewOnlyCaches = [
            (name: "NoTrace Browser cache (manual review)", path: "\(home)/Library/Caches/NoTrace Browser"),
        ]
        for target in reviewOnlyCaches {
            if let item = makeCleanupItem(
                name: target.name,
                path: target.path,
                category: .userCache,
                isSelected: false,
                maximumEntries: 1_000_000,
                includeHiddenFiles: true
            ) {
                items.append(item)
            }
        }

        let uniqueItems = deduplicatedItems(items)
        let totalSize = uniqueItems.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .userCache, items: uniqueItems, totalSize: totalSize)
    }

    /// Cache roots that are not safe to classify as generic user junk.
    ///
    /// The list is deliberately explicit rather than matching on broad words
    /// such as "cloud" or "browser".  This avoids hiding unrelated developer
    /// caches while protecting macOS transport state and roots owned by a
    /// dedicated AppSift scanner.  Browser roots are excluded from User Cache
    /// because BrowserPrivacyCenter closes supported browsers before moving
    /// their data to Trash; the generic cleaner has no equivalent lifecycle
    /// gate.
    static func userCacheExcludedRootPaths(home: String) -> Set<String> {
        let normalizedHome = normalizedPath(home)
        let roots = [
            // Dedicated AppSift categories.
            "\(normalizedHome)/Library/Caches/Homebrew",
            "\(normalizedHome)/Library/Caches/com.electron.ollama",
            "\(normalizedHome)/Library/Caches/ollama",
            "\(normalizedHome)/Library/Caches/com.apple.dt.Xcode",
            "\(normalizedHome)/Library/Caches/uv",
            "\(normalizedHome)/Library/Caches/Yarn",
            "\(normalizedHome)/Library/pnpm/store",

            // Node-owned global caches that may be surfaced from another
            // location in a future scanner.  User Cache currently only walks
            // Library/Caches plus the explicit pip paths, but keeping these in
            // the ownership policy makes cross-category de-duplication clear.
            "\(normalizedHome)/.npm",
            "\(normalizedHome)/.cache/yarn",
            "\(normalizedHome)/.cache/pnpm",

            // macOS/iCloud transport and metadata state.  These are not
            // disposable app caches even when their logical size is large.
            "\(normalizedHome)/Library/Caches/CloudKit",
            "\(normalizedHome)/Library/Caches/CloudDocs",
            "\(normalizedHome)/Library/Caches/com.apple.CloudDocs",
            "\(normalizedHome)/Library/Caches/com.apple.CloudDocs.iCloudDriveFileProvider",

            // Browser runtime roots.  Chrome's cache is nested below Google;
            // excluding the vendor root is intentional because the current
            // one-level generic scanner cannot safely split Google/Chrome
            // from sibling Google developer caches.
            "\(normalizedHome)/Library/Caches/Google",
            "\(normalizedHome)/Library/Caches/Chromium",
            "\(normalizedHome)/Library/Caches/Firefox",
            "\(normalizedHome)/Library/Caches/com.apple.Safari",
            "\(normalizedHome)/Library/Caches/NoTrace Browser",
        ]
        return Set(roots.map(normalizedPath))
    }

    /// Returns true when a path is one of the explicitly protected roots or a
    /// descendant of one.  This helper is internal so regression tests can
    /// prove the boundary without depending on the machine's live processes.
    static func isUserCachePathExcluded(_ path: String, home: String) -> Bool {
        let normalized = normalizedPath(path)
        return userCacheExcludedRootPaths(home: home).contains { root in
            normalized == root || normalized.hasPrefix(root + "/")
        }
    }

    private func scanAIApps() -> CategoryResult {
        // Deep AI model & LLM cache scanning (Ollama, LM Studio) is reserved for AppSift Pro.
        // Public Community Edition provides a baseline clean pass.
        return CategoryResult(category: .aiApps, items: [], totalSize: 0)
    }

    private func scanMailAttachments() -> CategoryResult {
        var items: [CleanableItem] = []

        let mailPaths = [
            "\(home)/Library/Mail Downloads",
            "\(home)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
        ]

        for path in mailPaths {
            let scanned = scanDirectory(path: path, category: .mailAttachments, recursive: true, maxDepth: 3)
            items.append(contentsOf: scanned)
        }

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .mailAttachments, items: items, totalSize: totalSize)
    }

    private func scanTrash() -> CategoryResult {
        var items: [CleanableItem] = []

        let trashPath = "\(home)/.Trash"
        let scanned = scanDirectory(path: trashPath, category: .trashBins, recursive: false, maxDepth: 1)
        items.append(contentsOf: scanned)

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .trashBins, items: items, totalSize: totalSize)
    }

    private func scanLargeFiles() -> CategoryResult {
        var items: [CleanableItem] = []

        // Honor the thresholds the user set in Settings → Cleaning. These keys
        // were previously surfaced in the UI but never read here, so the sliders
        // did nothing; defaults match the old hardcoded 100 MB / 12-month values.
        let defaults = UserDefaults.standard
        let thresholdMB = defaults.object(forKey: "settings.cleaning.largeFileThreshold") as? Int ?? 100
        let oldFileMonths = defaults.object(forKey: "settings.cleaning.oldFileMonths") as? Int ?? 12
        let minSize = Int64(max(1, thresholdMB)) * 1024 * 1024
        let oldCutoff = Calendar.current.date(byAdding: .month, value: -max(1, oldFileMonths), to: Date())
            ?? Date.distantPast

        // Folders the user excluded from the large-file scan (issue #121) —
        // e.g. VM images, media libraries, project assets they never want
        // surfaced. Files anywhere inside an excluded folder are skipped, and
        // the directory subtree is pruned so we don't even walk it.
        let excludedFolders = (defaults.stringArray(forKey: "settings.cleaning.largeFileExcludedFolders") ?? [])
            .map(normalizePath)
            .filter { !$0.isEmpty }

        // Honor the "Skip hidden files during scan" toggle, which was a dead
        // control until now (no scanner read it). Default true preserves the
        // previous always-skip behavior.
        let skipHidden = defaults.object(forKey: "settings.cleaning.skipHiddenFiles") as? Bool ?? true
        var enumerationOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if skipHidden { enumerationOptions.insert(.skipsHiddenFiles) }

        func isExcluded(_ path: String) -> Bool {
            let normalized = normalizePath(path)
            return excludedFolders.contains { normalized == $0 || normalized.hasPrefix($0 + "/") }
        }

        let searchPaths = [
            "\(home)/Downloads",
            "\(home)/Documents",
            "\(home)/Desktop",
        ]

        for basePath in searchPaths {
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: basePath),
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: enumerationOptions
            ) else { continue }

            // No entry cap. A 5k cap was here previously and meant any user
            // with hundreds of thousands of small files (e.g. node_modules
            // checkouts) would never see anything past entry 5k — the
            // scattered 100+ MB files were always past that bound.
            for case let fileURL as URL in enumerator {
                if Task.isCancelled { break }
                // Prune excluded subtrees: hitting the excluded directory itself
                // skips its whole contents; for files the call is a harmless no-op.
                // Skip the path normalization entirely when nothing is excluded.
                if !excludedFolders.isEmpty, isExcluded(fileURL.path) {
                    enumerator.skipDescendants()
                    continue
                }
                report(fileURL.path)
                guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                      let isFile = resourceValues.isRegularFile, isFile,
                      let fileSize = resourceValues.fileSize
                else { continue }

                let size = Int64(fileSize)
                let modDate = resourceValues.contentModificationDate

                if size > minSize || (modDate != nil && modDate! < oldCutoff && size > 10 * 1024 * 1024) {
                    items.append(CleanableItem(
                        name: fileURL.lastPathComponent,
                        path: fileURL.path,
                        size: size,
                        category: .largeFiles,
                        isSelected: false, // Don't auto-select large files
                        lastModified: modDate
                    ))
                }
            }
        }

        items.sort { $0.size > $1.size }
        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .largeFiles, items: items, totalSize: totalSize)
    }

    private func scanPurgeableSpace() -> CategoryResult {
        var items: [CleanableItem] = []
        var totalSize: Int64 = 0

        // Detect APFS purgeable space via URLResourceValues (no admin needed)
        let diskInfo = getDiskInfo()
        if diskInfo.purgeableSpace > 0 {
            // Purgeable space is reclaimed via `diskutil apfs purgePurgeable /`
            // (see CleaningEngine.purgePurgeableSpace), it is NOT a file that
            // gets unlinked. Using "/" as the path made the UI render the root
            // directory as the deletion target and triggered a bogus
            // "couldn't remove /" error after cleaning. Use an empty path so
            // the row shows no misleading filesystem location and the reveal-
            // in-Finder action stays disabled for this entry. (See issue #112.)
            items.append(CleanableItem(
                name: "APFS Purgeable Space",
                path: "",
                size: diskInfo.purgeableSpace,
                category: .purgeableSpace,
                isSelected: true,
                lastModified: nil
            ))
            totalSize = diskInfo.purgeableSpace
        }

        // Also list Time Machine local snapshots if any exist
        let snapshots = getLocalSnapshots()
        for snapshot in snapshots {
            let snapshotSize = snapshot.size > 0 ? snapshot.size : 0
            if snapshotSize > 0 {
                items.append(CleanableItem(
                    name: "TM Snapshot: \(snapshot.name)",
                    path: snapshot.name,
                    size: snapshotSize,
                    category: .purgeableSpace,
                    isSelected: false,
                    lastModified: snapshot.date
                ))
            }
        }

        return CategoryResult(category: .purgeableSpace, items: items, totalSize: totalSize)
    }

    private func scanXcodeJunk() -> CategoryResult {
        var items: [CleanableItem] = []

        let xcodePaths = [
            "\(home)/Library/Developer/Xcode/DerivedData",
            "\(home)/Library/Developer/Xcode/Archives",
            "\(home)/Library/Developer/CoreSimulator/Caches",
            "\(home)/Library/Caches/com.apple.dt.Xcode",
        ]

        for path in xcodePaths {
            if fileManager.fileExists(atPath: path) {
                let size = directorySize(path: path)
                if size > 0 {
                    items.append(CleanableItem(
                        name: URL(fileURLWithPath: path).lastPathComponent,
                        path: path,
                        size: size,
                        category: .xcodeJunk,
                        isSelected: true,
                        lastModified: nil
                    ))
                }
            }
        }

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .xcodeJunk, items: items, totalSize: totalSize)
    }

    private func scanBrewCache() -> CategoryResult {
        var items: [CleanableItem] = []

        // Default Homebrew download cache
        var brewCachePaths = [
            "\(home)/Library/Caches/Homebrew",
        ]

        // Known-good Homebrew cache roots. Any path returned by `brew --cache`
        // that is NOT inside one of these is refused - prevents an attacker
        // setting HOMEBREW_CACHE=$HOME/Documents from steering our cleanup.
        let knownBrewRoots = [
            "\(home)/Library/Caches/Homebrew",
            "/opt/homebrew/Library/Caches",
            "/usr/local/Homebrew/Library/Caches",
            "/Library/Caches/Homebrew",
        ]

        // Detect custom HOMEBREW_CACHE via `brew --cache`. Strip HOMEBREW_*
        // from the child env so an attacker can't steer the output via
        // launchctl setenv, then validate the output against knownBrewRoots.
        let brewBinPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        var detectedCustomCache = false
        for brewBin in brewBinPaths {
            guard fileManager.fileExists(atPath: brewBin) else { continue }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: brewBin)
            task.arguments = ["--cache"]
            var sanitizedEnv = ProcessInfo.processInfo.environment
            for key in Array(sanitizedEnv.keys) where key.hasPrefix("HOMEBREW_") {
                sanitizedEnv.removeValue(forKey: key)
            }
            task.environment = sanitizedEnv
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !output.isEmpty {
                    let normalized = normalizePath(output)
                    let isKnown = knownBrewRoots.contains { root in
                        normalized == root || normalized.hasPrefix(root + "/")
                    }
                    guard isKnown else {
                        Logger.shared.log("Refusing suspicious brew cache path: \(output)", level: .warning)
                        break
                    }
                    if !brewCachePaths.map(normalizePath).contains(normalized) {
                        brewCachePaths.append(output)
                    }
                    detectedCustomCache = true
                }
            } catch {
                Logger.shared.log("Failed to run \(brewBin) --cache: \(error.localizedDescription)", level: .warning)
            }
            break // Only need the first available brew binary
        }

        if !detectedCustomCache {
            Logger.shared.log("Homebrew not found at standard paths; scanning default cache location only", level: .info)
        }

        for path in brewCachePaths {
            if fileManager.fileExists(atPath: path) {
                let size = directorySize(path: path)
                if size > 0 {
                    items.append(CleanableItem(
                        name: URL(fileURLWithPath: path).lastPathComponent,
                        path: path,
                        size: size,
                        category: .brewCache,
                        isSelected: true,
                        lastModified: nil
                    ))
                }
            }
        }

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .brewCache, items: items, totalSize: totalSize)
    }

    private func scanNodeCache() -> CategoryResult {
        // Each entry is `(displayName, defaultPath, optional CLI for cache-dir
        // detection)`. The CLI invocation overrides `defaultPath` if the user
        // has set a custom location (e.g. via `npm config set cache`).
        struct ManagerCache {
            let name: String
            let defaultPath: String
            let detectionCommand: (cli: String, args: [String])?
        }

        let managers: [ManagerCache] = [
            ManagerCache(
                name: "npm cache",
                defaultPath: "\(home)/.npm",
                detectionCommand: (cli: "npm", args: ["config", "get", "cache"])
            ),
            ManagerCache(
                name: "yarn classic cache",
                defaultPath: "\(home)/Library/Caches/Yarn",
                detectionCommand: (cli: "yarn", args: ["cache", "dir"])
            ),
            // Yarn Berry / v2+ uses a per-project .yarn/cache. We don't try to
            // chase those — they're inside user projects and shouldn't be
            // touched by a system cleaner. The classic cache above remains the
            // global, safe-to-clean location.
            ManagerCache(
                name: "pnpm content-addressable store",
                defaultPath: "\(home)/Library/pnpm/store",
                detectionCommand: (cli: "pnpm", args: ["store", "path"])
            ),
            ManagerCache(
                name: "uv cache",
                defaultPath: "\(home)/Library/Caches/uv",
                detectionCommand: nil
            ),
            ManagerCache(
                name: "uv cache",
                defaultPath: "\(home)/.cache/uv",
                detectionCommand: nil
            ),
        ]

        var items: [CleanableItem] = []

        // Common $PATH locations on macOS where these CLIs land.
        let cliSearchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.volta/bin",
            "\(home)/.nvm/versions/node",
        ]

        for manager in managers {
            if Task.isCancelled { break }
            var paths: [String] = []
            paths.append(manager.defaultPath)

            if let cmd = manager.detectionCommand,
               let cliPath = locateExecutable(named: cmd.cli, searchPaths: cliSearchPaths),
               let detected = runCommandReadingStdout(executable: cliPath, args: cmd.args) {
                let normalized = detected.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty,
                   !paths.map(normalizePath).contains(normalizePath(normalized)) {
                    paths.append(normalized)
                }
            }

            for path in paths {
                if Task.isCancelled { break }
                guard fileManager.fileExists(atPath: path) else { continue }
                let size = directorySize(path: path)
                guard size > 0 else { continue }
                items.append(CleanableItem(
                    name: manager.name,
                    path: path,
                    size: size,
                    category: .nodeCache,
                    isSelected: true,
                    lastModified: nil
                ))
            }
        }

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .nodeCache, items: items, totalSize: totalSize)
    }

    private func scanDeveloperArtifacts() -> CategoryResult {
        let result = developerArtifactScanner.scan()
        let items = result.candidates.map { candidate in
            CleanableItem(
                name: candidate.name,
                path: candidate.url.path,
                size: candidate.size,
                category: .developerArtifacts,
                isSelected: candidate.isSelectedByDefault,
                lastModified: candidate.lastModified
            )
        }
        return CategoryResult(
            category: .developerArtifacts,
            items: items,
            totalSize: items.reduce(0) { $0 + $1.size }
        )
    }

    // -- Process helpers (used by scanNodeCache) --

    private func locateExecutable(named name: String, searchPaths: [String]) -> String? {
        for dir in searchPaths {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
            // For nvm: ~/.nvm/versions/node/<version>/bin/<name>
            if dir.hasSuffix("/.nvm/versions/node"),
               let versions = try? fileManager.contentsOfDirectory(atPath: dir) {
                for v in versions {
                    let nested = (dir as NSString).appendingPathComponent("\(v)/bin/\(name)")
                    if fileManager.isExecutableFile(atPath: nested) {
                        return nested
                    }
                }
            }
        }
        return nil
    }

    private func runCommandReadingStdout(executable: String, args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            Logger.shared.log("\(executable) \(args.joined(separator: " ")) failed: \(error.localizedDescription)", level: .warning)
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private func scanDockerCache() -> CategoryResult {
        var items: [CleanableItem] = []

        // Docker Desktop on macOS keeps its VM disk + caches under
        // ~/Library/Containers/com.docker.docker/Data. The caches we
        // surface here are *recoverable* — they will be regenerated by
        // Docker on next pull/build, and `docker system prune` is the
        // CLI equivalent of cleaning them.
        let dockerDataDirs = [
            // Build cache (BuildKit), per-user
            "\(home)/Library/Containers/com.docker.docker/Data/cache",
            // Vmnetd / vpnkit log + telemetry caches
            "\(home)/Library/Containers/com.docker.docker/Data/log",
            "\(home)/Library/Containers/com.docker.docker/Data/tmp",
            // Group containers caches (Docker Desktop helper apps)
            "\(home)/Library/Group Containers/group.com.docker/Caches",
            // CLI plugin download cache
            "\(home)/.docker/cli-plugins/.cache",
            // Buildx / containerd inline cache
            "\(home)/.docker/buildx/cache",
        ]

        for path in dockerDataDirs {
            if Task.isCancelled { break }
            guard fileManager.fileExists(atPath: path) else { continue }
            let size = directorySize(path: path)
            guard size > 0 else { continue }
            items.append(CleanableItem(
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                size: size,
                category: .dockerCache,
                isSelected: true,
                lastModified: nil
            ))
        }

        // If the `docker` CLI is available, surface reclaimable space
        // reported by `docker system df` as a single virtual entry.
        // We don't try to delete it directly — the user runs
        // `docker system prune` themselves, which is the safe path.
        // We just show how much they can recover.
        let dockerBinPaths = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
        for dockerBin in dockerBinPaths where fileManager.fileExists(atPath: dockerBin) {
            if let reclaimable = reclaimableDockerSpace(dockerBin: dockerBin), reclaimable > 0 {
                items.append(CleanableItem(
                    name: "Reclaimable (run `docker system prune -af`)",
                    path: dockerBin,
                    size: reclaimable,
                    category: .dockerCache,
                    isSelected: false,
                    lastModified: nil
                ))
            }
            break
        }

        let totalSize = items.reduce(0) { $0 + $1.size }
        return CategoryResult(category: .dockerCache, items: items, totalSize: totalSize)
    }

    /// Sum the reclaimable bytes reported by `docker system df --format json`.
    /// Returns nil when Docker isn't running or the command fails — callers
    /// should treat that as "no reclaimable info available", not as an error.
    private func reclaimableDockerSpace(dockerBin: String) -> Int64? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: dockerBin)
        task.arguments = ["system", "df", "--format", "{{.Reclaimable}}"]
        let stdoutPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            Logger.shared.log("docker system df failed: \(error.localizedDescription)", level: .warning)
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        // Each line looks like e.g. "1.234GB (45%)" — parse the leading number.
        var total: Int64 = 0
        for line in output.split(separator: "\n") {
            let raw = line.split(separator: " ").first.map(String.init) ?? ""
            if let bytes = parseHumanBytes(raw) {
                total += bytes
            }
        }
        return total
    }

    /// Parse Docker's compact size format ("1.23GB", "456MB", "789kB") into bytes.
    private func parseHumanBytes(_ s: String) -> Int64? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let units: [(String, Double)] = [
            ("TB", 1_000_000_000_000),
            ("GB", 1_000_000_000),
            ("MB", 1_000_000),
            ("kB", 1_000),
            ("KB", 1_000),
            ("B", 1),
        ]
        for (suffix, multiplier) in units {
            if trimmed.hasSuffix(suffix) {
                let numberPart = String(trimmed.dropLast(suffix.count))
                if let value = Double(numberPart) {
                    return Int64(value * multiplier)
                }
            }
        }
        return nil
    }
    // MARK: - Helpers

    private func scanDirectory(
        path: String,
        category: CleaningCategory,
        recursive: Bool,
        maxDepth: Int,
        excluding excludedPaths: Set<String> = []
    ) -> [CleanableItem] {
        var items: [CleanableItem] = []

        guard fileManager.fileExists(atPath: path),
              fileManager.isReadableFile(atPath: path) else { return [] }

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: path)
            for item in contents {
                guard !Task.isCancelled else { break }
                let fullPath = (path as NSString).appendingPathComponent(item)
                report(fullPath)
                let normalizedFullPath = normalizePath(fullPath)
                if excludedPaths.contains(where: { excludedPath in
                    normalizedFullPath == excludedPath ||
                    normalizedFullPath.hasPrefix(excludedPath + "/")
                }) {
                    continue
                }

                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }

                // Security: skip symlinks to prevent symlink-following attacks
                if let attrs = try? fileManager.attributesOfItem(atPath: fullPath),
                   let fileType = attrs[.type] as? FileAttributeType,
                   fileType == .typeSymbolicLink {
                    continue
                }

                if isDir.boolValue {
                    let size = directorySize(path: fullPath)
                    if size > 1024 { // Skip tiny entries
                        items.append(CleanableItem(
                            name: item,
                            path: fullPath,
                            size: size,
                            category: category,
                            isSelected: true,
                            lastModified: fileModDate(path: fullPath)
                        ))
                    }
                } else {
                    if let attrs = try? fileManager.attributesOfItem(atPath: fullPath),
                       let size = attrs[.size] as? Int64, size > 1024 {
                        items.append(CleanableItem(
                            name: item,
                            path: fullPath,
                            size: size,
                            category: category,
                            isSelected: true,
                            lastModified: attrs[.modificationDate] as? Date
                        ))
                    }
                }
            }
        } catch {
            Logger.shared.log("Cannot enumerate \(path): \(error.localizedDescription)", level: .warning)
        }

        return items
    }

    private func makeCleanupItem(
        name: String,
        path: String,
        category: CleaningCategory,
        isSelected: Bool = true,
        minimumSize: Int64 = 1024,
        maximumEntries: Int = 10_000,
        includeHiddenFiles: Bool = false
    ) -> CleanableItem? {
        report(path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              fileManager.isReadableFile(atPath: path) else { return nil }

        if isDirectory.boolValue {
            let size = directorySize(
                path: path,
                maximumEntries: maximumEntries,
                includeHiddenFiles: includeHiddenFiles
            )
            guard size > minimumSize else { return nil }
            return CleanableItem(
                name: name,
                path: path,
                size: size,
                category: category,
                isSelected: isSelected,
                lastModified: fileModDate(path: path)
            )
        }

        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64,
              size > minimumSize else { return nil }

        return CleanableItem(
            name: name,
            path: path,
            size: size,
            category: category,
            isSelected: isSelected,
            lastModified: attrs[.modificationDate] as? Date
        )
    }

    private func deduplicatedItems(_ items: [CleanableItem]) -> [CleanableItem] {
        var seenPaths: Set<String> = []
        var uniqueItems: [CleanableItem] = []

        for item in items {
            let normalizedPath = normalizePath(item.path)
            if seenPaths.insert(normalizedPath).inserted {
                uniqueItems.append(item)
            }
        }

        return uniqueItems
    }

    private func normalizePath(_ path: String) -> String {
        Self.normalizedPath(path)
    }

    private static func normalizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private func directorySize(
        path: String,
        maximumEntries: Int = 10_000,
        includeHiddenFiles: Bool = false
    ) -> Int64 {
        var totalSize: Int64 = 0

        var options: FileManager.DirectoryEnumerationOptions = []
        if !includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: options
        ) else { return 0 }

        var count = 0
        for case let fileURL as URL in enumerator {
            if Task.isCancelled { break }
            count += 1
            if count > maximumEntries { break } // Safety limit for very large directories

            report(fileURL.path)
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  let isFile = values.isRegularFile, isFile,
                  let size = values.fileSize else { continue }
            totalSize += Int64(size)
        }

        return totalSize
    }

    private func fileModDate(path: String) -> Date? {
        try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    // MARK: - Purgeable Space Helpers

    struct SnapshotInfo {
        let name: String
        let size: Int64
        let date: Date?
    }

    /// Get local Time Machine snapshots and their sizes
    private func getLocalSnapshots() -> [SnapshotInfo] {
        var snapshots: [SnapshotInfo] = []

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        task.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }

            // Parse snapshot names (format: com.apple.TimeMachine.2026-04-08-123456.local)
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd-HHmmss"

            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed.contains("TimeMachine") else { continue }

                // Extract date from snapshot name
                var snapshotDate: Date?
                let parts = trimmed.components(separatedBy: ".")
                for part in parts {
                    if let date = dateFormatter.date(from: part) {
                        snapshotDate = date
                        break
                    }
                }

                // Get snapshot size via tmutil
                let sizeBytes = getSnapshotSize(name: trimmed)

                if sizeBytes > 0 {
                    snapshots.append(SnapshotInfo(
                        name: trimmed,
                        size: sizeBytes,
                        date: snapshotDate
                    ))
                }
            }
        } catch {
            Logger.shared.log("tmutil listlocalsnapshots failed: \(error.localizedDescription)", level: .info)
        }

        return snapshots
    }

    /// Get size of a specific local snapshot via APFS snapshot listing
    private func getSnapshotSize(name: String) -> Int64 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["apfs", "listSnapshots", "/", "-plist"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let snapshots = plist["Snapshots"] as? [[String: Any]] else {
                Logger.shared.log("Could not parse APFS snapshot plist for \(name)", level: .info)
                return 0
            }

            for snapshot in snapshots {
                if let snapshotName = snapshot["SnapshotName"] as? String,
                   snapshotName == name,
                   let dataSize = snapshot["DataSize"] as? Int64 {
                    return dataSize
                }
            }

            Logger.shared.log("Snapshot \(name) not found in APFS listing", level: .info)
        } catch {
            Logger.shared.log("diskutil apfs listSnapshots failed: \(error.localizedDescription)", level: .warning)
        }

        return 0
    }

    /// Calculate total local snapshot size from disk usage difference
    private func getLocalSnapshotSize() -> Int64 {
        // The difference between "Volume Used Space" visible to the filesystem
        // and actual container usage can indicate snapshot overhead.
        // However, without root access, we can only check if tmutil reports snapshots.

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        task.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return 0 }

            let snapshotCount = output.components(separatedBy: "\n")
                .filter { $0.contains("TimeMachine") || $0.contains("com.apple") }
                .count

            if snapshotCount == 0 { return 0 }

            // Check if system reports purgeable via newer diskutil
            // On systems that support it, "Purgeable Space" appears in diskutil info
            let diskTask = Process()
            diskTask.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            diskTask.arguments = ["info", "-plist", "/"]
            let diskPipe = Pipe()
            diskTask.standardOutput = diskPipe
            diskTask.standardError = Pipe()
            try diskTask.run()
            diskTask.waitUntilExit()

            let diskData = diskPipe.fileHandleForReading.readDataToEndOfFile()
            if let plist = try? PropertyListSerialization.propertyList(from: diskData, format: nil) as? [String: Any],
               let purgeable = plist["APFSContainerFree"] as? Int64,
               let volumeFree = plist["FreeSpace"] as? Int64 {
                // Purgeable is roughly the difference (snapshots that can be freed)
                let purgeableEstimate = max(0, volumeFree - purgeable)
                if purgeableEstimate > 10 * 1024 * 1024 { // Only report if > 10 MB
                    return purgeableEstimate
                }
            }
        } catch {
            Logger.shared.log("Purgeable space detection failed: \(error.localizedDescription)", level: .warning)
        }

        return 0
    }
}
