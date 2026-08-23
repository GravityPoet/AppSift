import Darwin
import Foundation

/// A small, evidence-backed inventory of development artifacts that can be
/// recreated from a manifest or a package index.
///
/// This scanner intentionally does not walk the user's home directory.  Cargo
/// uses one exact global registry path, while project build outputs and the
/// subtitle environment are discovered only below a short allow-list of
/// project roots.  The result is an inventory only; callers must still ask the
/// user before selecting a project artifact for removal.
enum DeveloperArtifactKind: String, Codable, Hashable, Sendable {
    case cargoRegistry
    case rustTarget
    case subalignerVirtualEnvironment
}

enum DeveloperArtifactEvidence: String, Codable, Hashable, Sendable {
    case cargoRegistryPath
    case cargoManifest
    case rustTargetDirectory
    case subalignerEnvironmentName
    case pythonEnvironmentMarker
    case pythonExecutable
}

struct DeveloperArtifactCandidate: Identifiable, Codable, Hashable, Sendable {
    var id: String { url.standardizedFileURL.path }

    let url: URL
    let name: String
    let kind: DeveloperArtifactKind
    let size: Int64
    let projectRoot: URL?
    let evidence: Set<DeveloperArtifactEvidence>
    let lastModified: Date?
    let foreignOwnerCount: Int
    let wasTruncated: Bool

    /// Development outputs are never auto-selected.  A UI may offer an
    /// explicit, reviewed selection after showing this evidence to the user.
    var isSelectedByDefault: Bool { false }

    /// A truncated walk or a foreign-owned descendant makes the whole
    /// directory unsafe to hand to a bulk cleaner.  The UI can still show the
    /// candidate as an estimate and ask the user to inspect it manually.
    var isRemovalEligible: Bool {
        !wasTruncated && foreignOwnerCount == 0
    }

    var explanation: String {
        switch kind {
        case .cargoRegistry:
            return "Cargo registry downloads can be fetched again by Cargo."
        case .rustTarget:
            return "Rust build output can be recreated with Cargo."
        case .subalignerVirtualEnvironment:
            return "The subtitle alignment environment can be recreated from its setup script."
        }
    }
}

struct DeveloperArtifactScanResult: Sendable {
    let candidates: [DeveloperArtifactCandidate]
    let scannedRoots: [URL]
    let inaccessibleRootCount: Int
    let wasTruncated: Bool
    let scannedAt: Date

    var totalSize: Int64 {
        candidates.reduce(0) { $0 + $1.size }
    }
}

/// Finds only known, rebuildable developer artifacts.
///
/// The scanner is deliberately synchronous so it can be called from the
/// existing `ScanEngine` actor without introducing another actor hop.  It is
/// also fully injectable for fixture-based tests: pass `projectRoots: []` or
/// `virtualEnvironmentURLs: []` to disable the corresponding defaults.
struct DeveloperArtifactScanner {
    private struct Measurement {
        var logicalBytes: Int64 = 0
        var foreignOwnerCount = 0
        var wasTruncated = false
        var latestModificationDate: Date?
    }

    private static let defaultProjectRootNames = [
        "Tools",
        "Projects",
        "Developer",
        "Development",
        "Workspaces",
        "workspace",
        "Documents/Projects",
        "Documents/Developer",
    ]

    private static let defaultSubalignerRelativePath =
        "Tools/AI-tools/subtitle-local-workflow/.venv-subaligner"

    /// A target under a project root is cheap to discover, but an accidental
    /// recursive home walk is not.  This depth covers e.g.
    /// `~/Tools/AI-tools/FinalSub/src-tauri/target` while staying bounded.
    private let maximumProjectDepth: Int
    private let maximumEntriesPerCandidate: Int
    private let fileManager: FileManager
    private let homeURL: URL
    private let projectRoots: [URL]
    private let cargoRegistryURL: URL
    private let virtualEnvironmentURLs: [URL]
    private let currentUserID: uid_t

    init(
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        projectRoots: [URL]? = nil,
        cargoRegistryURL: URL? = nil,
        virtualEnvironmentURLs: [URL]? = nil,
        currentUserID: uid_t = getuid(),
        maximumProjectDepth: Int = 6,
        maximumEntriesPerCandidate: Int = 250_000
    ) {
        self.fileManager = fileManager
        self.homeURL = homeURL.standardizedFileURL
        self.currentUserID = currentUserID
        self.maximumProjectDepth = max(1, maximumProjectDepth)
        self.maximumEntriesPerCandidate = max(1, maximumEntriesPerCandidate)

        let defaultRoots = Self.defaultProjectRoots(
            homeURL: self.homeURL,
            fileManager: self.fileManager
        )
        self.projectRoots = Self.uniqueURLs(projectRoots ?? defaultRoots)
        self.cargoRegistryURL = (cargoRegistryURL
            ?? self.homeURL.appendingPathComponent(".cargo/registry", isDirectory: true))
            .standardizedFileURL

        let defaultEnvironment = [
            self.homeURL.appendingPathComponent(
                Self.defaultSubalignerRelativePath,
                isDirectory: true
            ),
        ]
        self.virtualEnvironmentURLs = Self.uniqueURLs(
            virtualEnvironmentURLs ?? defaultEnvironment
        )
    }

    /// Existing default roots are intentionally returned only when they exist;
    /// this keeps the scan list explainable and avoids probing arbitrary home
    /// directories.
    static func defaultProjectRoots(
        homeURL: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        return defaultProjectRootNames.compactMap { relativePath in
            let root = homeURL.appendingPathComponent(relativePath, isDirectory: true)
            guard fileManager.fileExists(atPath: root.path) else { return nil }
            return root.standardizedFileURL
        }
    }

    /// Revalidate one previously displayed candidate immediately before a
    /// caller removes it. This is intentionally a static, internal API so a
    /// cleaner can perform a TOCTOU check without retaining a scanner or
    /// walking arbitrary home-directory paths.
    ///
    /// The candidate must still have the same kind, evidence, logical size,
    /// and safe ownership state. A changed file tree, a symlink, a foreign
    /// owner, or a truncated measurement rejects the removal root.
    static func isSafeRemovalRoot(
        _ candidate: DeveloperArtifactCandidate,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        currentUserID: uid_t = getuid(),
        maximumEntriesPerCandidate: Int = 250_000
    ) -> Bool {
        guard candidate.isRemovalEligible else { return false }

        let scanner = DeveloperArtifactScanner(
            homeURL: homeURL,
            projectRoots: [],
            cargoRegistryURL: candidate.kind == .cargoRegistry
                ? candidate.url
                : nil,
            virtualEnvironmentURLs: [],
            currentUserID: currentUserID,
            maximumEntriesPerCandidate: maximumEntriesPerCandidate
        )

        // Cargo registry is a single well-known global path. Do not let a
        // forged candidate of kind cargoRegistry widen the removal root.
        if candidate.kind == .cargoRegistry {
            let expected = scanner.homeURL
                .appendingPathComponent(".cargo/registry", isDirectory: true)
                .standardizedFileURL
            guard candidate.url.standardizedFileURL == expected else {
                return false
            }
        } else {
            // Rust targets and virtual environments are only discoverable
            // below the bounded project roots. Re-check that boundary here;
            // the path-only adapter is intentionally not allowed to turn an
            // arbitrary `~/.../target` or `.venv-subaligner` into a deletion
            // root merely because it has a manifest/marker beside it.
            guard let projectRoot = candidate.projectRoot,
                  candidate.url.deletingLastPathComponent().standardizedFileURL
                    == projectRoot.standardizedFileURL,
                  scanner.isKnownProjectArtifactRoot(projectRoot) else {
                return false
            }
        }

        let current: DeveloperArtifactCandidate?
        switch candidate.kind {
        case .cargoRegistry:
            current = scanner.makeCargoRegistryCandidate(at: candidate.url)
        case .rustTarget:
            current = scanner.makeRustTargetCandidate(at: candidate.url)
        case .subalignerVirtualEnvironment:
            current = scanner.makeSubalignerCandidate(
                at: candidate.url,
                projectRoot: candidate.projectRoot
            )
        }

        guard let current,
              current.url.standardizedFileURL == candidate.url.standardizedFileURL,
              current.kind == candidate.kind,
              current.projectRoot?.standardizedFileURL
                == candidate.projectRoot?.standardizedFileURL,
              current.evidence == candidate.evidence,
              current.size == candidate.size,
              current.foreignOwnerCount == 0,
              !current.wasTruncated else {
            return false
        }
        return true
    }

    /// Path-only adapter used by the generic cleaning engine. The displayed
    /// candidate is re-derived from the current filesystem before a removal;
    /// callers cannot manufacture a target path that merely looks like a
    /// Cargo/Rust/Python artifact.
    static func isSafeRemovalRoot(
        resolvedPath: String,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        currentUserID: uid_t = getuid(),
        expectedSize: Int64? = nil
    ) -> Bool {
        let normalizedPath = URL(fileURLWithPath: resolvedPath)
            .standardizedFileURL
            .path
        let scanner = DeveloperArtifactScanner(
            homeURL: homeURL,
            currentUserID: currentUserID
        )
        guard let candidate = scanner.scan().candidates.first(where: {
            $0.url.standardizedFileURL.path == normalizedPath
        }) else {
            return false
        }
        guard expectedSize == nil || candidate.size == expectedSize else {
            return false
        }
        return isSafeRemovalRoot(
            candidate,
            homeURL: homeURL,
            currentUserID: currentUserID
        )
    }

    func scan() -> DeveloperArtifactScanResult {
        var candidates: [DeveloperArtifactCandidate] = []
        var scannedRoots: [URL] = []
        var inaccessibleRootCount = 0

        scannedRoots.append(cargoRegistryURL)
        if let cargoCandidate = makeCargoRegistryCandidate(at: cargoRegistryURL) {
            candidates.append(cargoCandidate)
        } else if fileManager.fileExists(atPath: cargoRegistryURL.path) {
            inaccessibleRootCount += 1
        }

        for root in projectRoots {
            guard isSafeDirectory(root), isWithinHome(root) else {
                inaccessibleRootCount += 1
                continue
            }
            scannedRoots.append(root)
            discoverProjectArtifacts(
                below: root,
                candidates: &candidates,
                inaccessibleRootCount: &inaccessibleRootCount
            )
        }

        // The known path covers the repository used by the subtitle workflow;
        // discovery below project roots also supports a relocated checkout.
        for environmentURL in virtualEnvironmentURLs {
            guard !candidates.contains(where: { $0.url.standardizedFileURL == environmentURL }) else {
                continue
            }
            guard isWithinHome(environmentURL) else {
                inaccessibleRootCount += 1
                continue
            }
            if let candidate = makeSubalignerCandidate(
                at: environmentURL,
                projectRoot: environmentURL.deletingLastPathComponent()
            ) {
                candidates.append(candidate)
            } else if fileManager.fileExists(atPath: environmentURL.path) {
                inaccessibleRootCount += 1
            }
        }

        // A path can be found once by explicit configuration and once while
        // walking a project root.  Keep the larger measurement only once.
        var unique: [DeveloperArtifactCandidate] = []
        var seenPaths = Set<String>()
        for candidate in candidates.sorted(by: { $0.size > $1.size }) {
            let path = candidate.url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { continue }
            unique.append(candidate)
        }

        return DeveloperArtifactScanResult(
            candidates: unique,
            scannedRoots: Self.uniqueURLs(scannedRoots),
            inaccessibleRootCount: inaccessibleRootCount,
            wasTruncated: unique.contains(where: \.wasTruncated),
            scannedAt: Date()
        )
    }

    private func discoverProjectArtifacts(
        below root: URL,
        candidates: inout [DeveloperArtifactCandidate],
        inaccessibleRootCount: inout Int
    ) {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            inaccessibleRootCount += 1
            return
        }

        for case let url as URL in enumerator {
            let depth = relativeDepth(of: url, below: root)
            if depth > maximumProjectDepth {
                enumerator.skipDescendants()
                continue
            }

            guard let info = fileInfo(at: url) else {
                enumerator.skipDescendants()
                continue
            }
            if info.isSymbolicLink {
                // Never follow a symlink while looking for a removal root.
                enumerator.skipDescendants()
                continue
            }
            guard info.isDirectory else { continue }
            guard info.ownerID == currentUserID else {
                enumerator.skipDescendants()
                continue
            }

            if url.lastPathComponent == "target" {
                if let candidate = makeRustTargetCandidate(at: url) {
                    candidates.append(candidate)
                }
                // A target can contain nested crates and another target.  It
                // is one removal unit, so do not enumerate its descendants.
                enumerator.skipDescendants()
                continue
            }

            if url.lastPathComponent == ".venv-subaligner" {
                if let candidate = makeSubalignerCandidate(
                    at: url,
                    projectRoot: url.deletingLastPathComponent()
                ) {
                    candidates.append(candidate)
                }
                enumerator.skipDescendants()
            }
        }
    }

    private func makeCargoRegistryCandidate(
        at url: URL
    ) -> DeveloperArtifactCandidate? {
        guard isWithinHome(url),
              isSafeDirectory(url),
              let measurement = measureDirectory(url) else {
            return nil
        }
        guard measurement.logicalBytes > 0 else { return nil }

        return DeveloperArtifactCandidate(
            url: url,
            name: "Cargo registry",
            kind: .cargoRegistry,
            size: measurement.logicalBytes,
            projectRoot: nil,
            evidence: [.cargoRegistryPath],
            lastModified: measurement.latestModificationDate,
            foreignOwnerCount: measurement.foreignOwnerCount,
            wasTruncated: measurement.wasTruncated
        )
    }

    private func makeRustTargetCandidate(
        at url: URL
    ) -> DeveloperArtifactCandidate? {
        guard isWithinHome(url),
              isSafeDirectory(url),
              let parent = safeDirectoryParent(of: url),
              let manifest = regularFileIfOwned(
                parent.appendingPathComponent("Cargo.toml")
              ),
              manifest else {
            return nil
        }
        guard let measurement = measureDirectory(url),
              measurement.logicalBytes > 0 else {
            return nil
        }

        let projectName = parent.lastPathComponent
        return DeveloperArtifactCandidate(
            url: url,
            name: "\(projectName) target",
            kind: .rustTarget,
            size: measurement.logicalBytes,
            projectRoot: parent,
            evidence: [.cargoManifest, .rustTargetDirectory],
            lastModified: measurement.latestModificationDate,
            foreignOwnerCount: measurement.foreignOwnerCount,
            wasTruncated: measurement.wasTruncated
        )
    }

    private func makeSubalignerCandidate(
        at url: URL,
        projectRoot: URL?
    ) -> DeveloperArtifactCandidate? {
        guard url.lastPathComponent == ".venv-subaligner",
              isWithinHome(url),
              isSafeDirectory(url),
              regularFileIfOwned(
                url.appendingPathComponent("pyvenv.cfg")
              ) == true,
              safeDirectory(
                url.appendingPathComponent("bin", isDirectory: true)
              ) == true,
              executableMarker(
                url.appendingPathComponent("bin/python")
              ) == true else {
            return nil
        }
        guard let measurement = measureDirectory(url),
              measurement.logicalBytes > 0 else {
            return nil
        }

        let rootName = projectRoot?.lastPathComponent ?? "subtitle workflow"
        return DeveloperArtifactCandidate(
            url: url,
            name: "\(rootName) .venv-subaligner",
            kind: .subalignerVirtualEnvironment,
            size: measurement.logicalBytes,
            projectRoot: projectRoot,
            evidence: [
                .subalignerEnvironmentName,
                .pythonEnvironmentMarker,
                .pythonExecutable,
            ],
            lastModified: measurement.latestModificationDate,
            foreignOwnerCount: measurement.foreignOwnerCount,
            wasTruncated: measurement.wasTruncated
        )
    }

    private func measureDirectory(_ root: URL) -> Measurement? {
        guard let rootInfo = fileInfo(at: root),
              rootInfo.isDirectory,
              !rootInfo.isSymbolicLink,
              rootInfo.ownerID == currentUserID else {
            return nil
        }

        var measurement = Measurement()
        measurement.latestModificationDate = modificationDate(of: root)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return nil
        }

        var entryCount = 0
        for case let url as URL in enumerator {
            entryCount += 1
            if entryCount > maximumEntriesPerCandidate {
                measurement.wasTruncated = true
                break
            }

            guard let info = fileInfo(at: url) else {
                enumerator.skipDescendants()
                continue
            }
            if info.isSymbolicLink {
                // Symlinks are not part of the estimate and are never
                // followed.  A venv's `bin/python` symlink is accepted as a
                // marker, but still contributes no bytes here.
                enumerator.skipDescendants()
                continue
            }
            if info.ownerID != currentUserID {
                measurement.foreignOwnerCount += 1
            }
            if info.isRegularFile {
                measurement.logicalBytes = adding(
                    measurement.logicalBytes,
                    Int64(max(0, info.size))
                )
            }
            if let date = modificationDate(of: url),
               date > (measurement.latestModificationDate ?? .distantPast) {
                measurement.latestModificationDate = date
            }
        }
        return measurement
    }

    private func isWithinHome(_ url: URL) -> Bool {
        Self.isDescendant(url.standardizedFileURL, of: homeURL)
    }

    private func isKnownProjectArtifactRoot(_ url: URL) -> Bool {
        guard isSafeDirectory(url) else { return false }
        return Self.defaultProjectRoots(
            homeURL: homeURL,
            fileManager: fileManager
        ).contains { root in
            Self.isDescendant(url.standardizedFileURL, of: root.standardizedFileURL)
        }
    }

    private func isSafeDirectory(_ url: URL) -> Bool {
        guard isWithinHome(url),
              let info = fileInfo(at: url),
              info.isDirectory,
              !info.isSymbolicLink,
              info.ownerID == currentUserID else {
            return false
        }
        return !Self.pathContainsSymbolicLink(url, stoppingAt: homeURL)
    }

    private func safeDirectory(_ url: URL) -> Bool? {
        isSafeDirectory(url) ? true : nil
    }

    private func safeDirectoryParent(of url: URL) -> URL? {
        let parent = url.deletingLastPathComponent()
        return isSafeDirectory(parent) ? parent : nil
    }

    private func regularFileIfOwned(_ url: URL) -> Bool? {
        guard isWithinHome(url),
              let info = fileInfo(at: url),
              info.isRegularFile,
              !info.isSymbolicLink,
              info.ownerID == currentUserID else {
            return nil
        }
        return true
    }

    private func executableMarker(_ url: URL) -> Bool? {
        guard isWithinHome(url), let info = fileInfo(at: url) else { return nil }
        // uv/venv commonly makes bin/python a symlink to a managed interpreter;
        // it is safe as a marker because the candidate root itself is checked
        // for symlinks and the walker never follows it.
        guard info.isRegularFile || info.isSymbolicLink else { return nil }
        return true
    }

    private func relativeDepth(of url: URL, below root: URL) -> Int {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else {
            return maximumProjectDepth + 1
        }
        return components.count - rootComponents.count
    }

    private func fileInfo(at url: URL) -> (
        isDirectory: Bool,
        isRegularFile: Bool,
        isSymbolicLink: Bool,
        ownerID: uid_t,
        size: off_t
    )? {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return nil }
        let type = information.st_mode & S_IFMT
        return (
            type == S_IFDIR,
            type == S_IFREG,
            type == S_IFLNK,
            information.st_uid,
            information.st_size
        )
    }

    private func modificationDate(of url: URL) -> Date? {
        try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private static func pathContainsSymbolicLink(
        _ url: URL,
        stoppingAt stopURL: URL
    ) -> Bool {
        let stopPath = stopURL.standardizedFileURL.path
        var current = url.standardizedFileURL
        while true {
            var information = stat()
            if lstat(current.path, &information) != 0 {
                return true
            }
            if information.st_mode & S_IFMT == S_IFLNK {
                return true
            }
            if current.path == stopPath || current.path == "/" {
                return false
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return false }
            current = parent
        }
    }

    private static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            return seen.insert(standardized.path).inserted ? standardized : nil
        }
    }

    private func adding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }
}
