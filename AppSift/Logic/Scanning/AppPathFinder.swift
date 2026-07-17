//
//  AppPathFinder.swift
//  AppSift
//
//  Heuristic file discovery engine that locates all filesystem artifacts
//  belonging to a given macOS application. Uses multi-level matching
//  against bundle identifiers, app names, and verified entitlements
//  with configurable sensitivity.
//

import Foundation
import AppKit

enum SearchSensitivity: String, CaseIterable, Identifiable, Codable, Sendable {
    static let defaultsKey = "settings.general.searchSensitivity"

    case strict = "Strict"
    case enhanced = "Enhanced"
    case deep = "Deep"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .strict: return "Exact bundle ID and name matches only. Safest option."
        case .enhanced: return "Includes delimiter-anchored bundle families and version-stripped exact names."
        case .deep: return "Also includes identifiers from verified developer entitlements."
        }
    }

    var pathFinderSensitivity: AppPathFinder.Sensitivity {
        switch self {
        case .strict: return .strict
        case .enhanced: return .enhanced
        case .deep: return .deep
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> SearchSensitivity {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let sensitivity = SearchSensitivity(rawValue: rawValue) else {
            return .enhanced
        }
        return sensitivity
    }
}

/// Machine-readable provenance for why one filesystem item entered an app
/// uninstall scan. These values are persisted in local removal receipts and
/// exported reports; keep raw values stable for backward compatibility.
enum AppFileMatchEvidence: String, Codable, CaseIterable, Hashable, Sendable {
    case selectedApplication
    case appSpecificRule
    case exactBundleIdentifier
    case structuredBundleIdentifier
    case exactAppName
    case exactBundlePathName
    case bundleIdentifierSuffix
    case baseBundleIdentifier
    case versionStrippedName
    case verifiedEntitlement
    case containerMetadata
    case legacyUnknown

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .legacyUnknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

final class AppPathFinder: Sendable {

    // MARK: - Types

    struct AppInfo: Sendable {
        let appName: String
        let bundleIdentifier: String
        let path: URL
        let entitlements: [String]?

        init(
            appName: String,
            bundleIdentifier: String,
            path: URL,
            entitlements: [String]?
        ) {
            self.appName = appName
            self.bundleIdentifier = bundleIdentifier
            self.path = path
            self.entitlements = entitlements
        }

        init(installedApp app: InstalledApp) {
            let hasVerifiedDeveloperSignature = app.signature.status == .developerSigned
            self.init(
                appName: app.appName,
                bundleIdentifier: app.bundleIdentifier,
                path: app.path,
                entitlements: hasVerifiedDeveloperSignature && !app.signature.entitlementIdentifiers.isEmpty
                    ? app.signature.entitlementIdentifiers
                    : nil
            )
        }
    }

    enum Sensitivity: Sendable {
        case strict    // Exact bundle ID + exact name match only
        case enhanced  // + structured bundle families and stripped version
        case deep      // + verified entitlement identifiers
    }

    struct SearchRoot: Equatable, Sendable {
        let path: String
        let maxDepth: Int
        let isLibraryRootSearch: Bool
    }

    /// One scan's mutable accumulator. Every access is serialized by `lock`,
    /// and no collection is reused by another scan invocation.
    private final class PathCollection: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: Set<URL>

        init(initialURLs: Set<URL>) {
            self.urls = initialURLs
        }

        func contains(_ url: URL) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return urls.contains(url)
        }

        func formUnion<S: Sequence>(_ newURLs: S) where S.Element == URL {
            lock.lock()
            urls.formUnion(newURLs)
            lock.unlock()
        }

        func snapshot() -> Set<URL> {
            lock.lock()
            defer { lock.unlock() }
            return urls
        }
    }

    // MARK: - Properties

    private let appInfo: AppInfo
    private let sensitivity: Sensitivity
    private let searchRoots: [SearchRoot]
    private let workQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "\(ProductIdentity.bundleIdentifier).pathfinder.work"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = min(6, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        return queue
    }()

    // Pre-computed cached identifiers (computed once in init, used in hot loop)
    private let bundleIdentifier: String
    private let bundleLastTwo: String
    private let appName: String
    private let pathComponentName: String
    private let baseBundleID: String?
    private let strippedAppName: String?
    private let entitlementIdentifiers: [String]

    // MARK: - Initialization

    init(
        appInfo: AppInfo,
        searchPaths: [String],
        sensitivity: Sensitivity = .enhanced
    ) {
        self.appInfo = appInfo
        self.sensitivity = sensitivity
        self.searchRoots = Self.makeSearchPlan(paths: searchPaths)

        self.bundleIdentifier = Self.canonicalArtifactName(appInfo.bundleIdentifier)
        self.bundleLastTwo = Self.canonicalArtifactName(
            appInfo.bundleIdentifier
                .split(separator: ".")
                .suffix(2)
                .joined(separator: ".")
        )
        self.appName = Self.canonicalArtifactName(appInfo.appName)
        self.pathComponentName = Self.canonicalArtifactName(
            appInfo.path.deletingPathExtension().lastPathComponent
        )
        self.baseBundleID = appInfo.bundleIdentifier.baseBundleIdentifier
            .map(Self.canonicalArtifactName)

        let stripped = Self.canonicalArtifactName(appInfo.appName.strippingTrailingVersion())
        self.strippedAppName = (stripped != self.appName && !stripped.isEmpty) ? stripped : nil

        self.entitlementIdentifiers = appInfo.entitlements?.compactMap { entitlement in
            let n = Self.canonicalArtifactName(entitlement)
            return n.isEmpty ? nil : n
        } ?? []
    }

    // MARK: - Public API

    /// Find all files related to this app synchronously.
    func findPaths() -> Set<URL> {
        let collection = PathCollection(initialURLs: [appInfo.path])

        for root in searchRoots {
            processLocation(
                root.path,
                currentDepth: 0,
                maxDepth: root.maxDepth,
                isLibraryRootSearch: root.isLibraryRootSearch,
                shouldCancel: { false },
                collection: collection
            )
        }

        var result = collection.snapshot()
        result.formUnion(discoverContainers())
        applyConditions(to: &result)

        return filterSubpaths(result)
    }

    /// Find all files related to this app with parallel location processing.
    func findPathsAsync(
        completion: @escaping @MainActor @Sendable (Set<URL>) -> Void
    ) {
        let collection = PathCollection(initialURLs: [appInfo.path])

        let operations = searchRoots.map { root in
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak operation] in
                guard let self, let operation, !operation.isCancelled else { return }
                self.processLocation(
                    root.path,
                    currentDepth: 0,
                    maxDepth: root.maxDepth,
                    isLibraryRootSearch: root.isLibraryRootSearch,
                    shouldCancel: { operation.isCancelled },
                    collection: collection
                )
            }
            return operation
        }
        workQueue.addOperations(operations, waitUntilFinished: false)

        workQueue.addBarrierBlock { [weak self] in
            guard let self else { return }
            var collectedURLs = collection.snapshot()
            collectedURLs.formUnion(self.discoverContainers())
            self.applyConditions(to: &collectedURLs)
            let result = self.filterSubpaths(collectedURLs)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func cancel() {
        workQueue.cancelAllOperations()
    }

    var searchLocationCount: Int {
        searchRoots.count
    }

    static func searchLocationCount(for paths: [String]) -> Int {
        makeSearchPlan(paths: paths).count
    }

    // MARK: - Location Processing

    private func processLocation(
        _ location: String,
        currentDepth: Int,
        maxDepth: Int,
        isLibraryRootSearch: Bool,
        shouldCancel: () -> Bool,
        collection: PathCollection
    ) {
        guard !shouldCancel() else { return }
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: location, isDirectory: true),
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        ) else {
            return
        }

        var localResults: [URL] = []
        var subdirs: [URL] = []

        for itemURL in contents {
            guard !shouldCancel() else { return }
            guard let values = try? itemURL.resourceValues(forKeys: resourceKeys) else { continue }
            let isSymbolicLink = values.isSymbolicLink == true
            let isDirectory = values.isDirectory == true && !isSymbolicLink
            let item = itemURL.lastPathComponent
            let matchingName = isDirectory
                ? item
                : (item as NSString).deletingPathExtension
            let normalizedName = matchingName.normalizedForMatching()

            // The selected bundle is inserted explicitly before scanning.
            // No other `.app` bundle may be inferred from a similar display
            // name, and package contents must never be traversed as leftovers.
            if itemURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                continue
            }

            if shouldSkipItem(normalizedName, at: itemURL, collection: collection) { continue }

            if matchEvidence(candidateName: matchingName, normalizedName: normalizedName) != nil {
                // Never escalate a matching child to its parent directory.
                // A filename match inside another app's vendor folder does
                // not prove that the selected app owns the whole folder.
                localResults.append(itemURL)
            }

            // Recurse into subdirectories up to maxDepth
            // Never follow directory symlinks. Matching the link itself is
            // safe; recursively scanning its target would escape the planned
            // search root and duplicate or overreach unrelated trees.
            if isDirectory && currentDepth < maxDepth {
                if isLibraryRootSearch && currentDepth == 0 {
                    if !skipDeepSearch.contains(itemURL.lastPathComponent) {
                        subdirs.append(itemURL)
                    }
                } else {
                    subdirs.append(itemURL)
                }
            }
        }

        guard !shouldCancel() else { return }
        collection.formUnion(localResults)

        for subdir in subdirs {
            guard !shouldCancel() else { return }
            processLocation(
                subdir.path,
                currentDepth: currentDepth + 1,
                maxDepth: maxDepth,
                isLibraryRootSearch: isLibraryRootSearch,
                shouldCancel: shouldCancel,
                collection: collection
            )
        }
    }

    // MARK: - Matching Engine

    // Minimum token length required for a name-based match to pass. Prevents
    // a malicious app named "s-s-h" (normalized "ssh", 3 chars) from
    // short-name-bombing home dotfiles like ~/.ssh into the uninstall list.
    private static let minMatchTokenLength = 5

    /// Anchored check for whether `self.bundleIdentifier` belongs to the
    /// family identified by `conditionBundleID`. Accepts exact equality,
    /// ".child" extension, or "parent." suffix - rejects a bundle ID that
    /// merely contains the condition string as a substring. This prevents
    /// `com.evil.jetbrainsapp` from hijacking the `jetbrains` rule.
    private func bundleIDMatchesCondition(_ conditionBundleID: String) -> Bool {
        let condition = Self.canonicalArtifactName(conditionBundleID)
        guard !condition.isEmpty else { return false }
        if bundleIdentifier == condition { return true }
        if bundleIdentifier.hasPrefix(condition + ".") { return true }
        if bundleIdentifier.hasSuffix("." + condition) { return true }
        return false
    }

    /// Identity matcher for one filesystem basename. Generic substring
    /// matching is intentionally forbidden: a project cache named
    /// "my-chatgpt-client" is not evidence that the ChatGPT app owns it.
    private func matchEvidence(
        candidateName: String,
        normalizedName: String
    ) -> AppFileMatchEvidence? {
        let candidate = Self.canonicalArtifactName(candidateName)

        // Per-app condition overrides take priority. Anchor the bundle ID
        // check (see bundleIDMatchesCondition above).
        for condition in appConditions {
            guard bundleIDMatchesCondition(condition.bundleID) else { continue }
            if condition.excludeTerms.contains(where: { normalizedName.contains($0) }) {
                return nil
            }
            if condition.includeTerms.contains(where: { normalizedName.contains($0) }) {
                return .appSpecificRule
            }
        }

        // Level 1: full bundle identity, exact in Strict mode and a
        // delimiter-anchored child identifier in broader modes.
        let minLen = AppPathFinder.minMatchTokenLength
        if bundleIdentifier.count >= minLen {
            if candidate == bundleIdentifier { return .exactBundleIdentifier }
            if structuredIdentifier(candidate, matches: bundleIdentifier) {
                return .structuredBundleIdentifier
            }
        }

        // Level 2: display name and bundle path name are exact only. This is
        // the boundary that keeps ChatGPT Atlas/Cloak/Swift separate from a
        // selected app named ChatGPT.
        if appName.count >= minLen, candidate == appName { return .exactAppName }
        if pathComponentName.count >= minLen, candidate == pathComponentName {
            return .exactBundlePathName
        }

        // Enhanced mode: additional structured identifiers. Prefixes still
        // require a real separator (`.`, `-`, `_`, or whitespace).
        if sensitivity != .strict {
            if bundleLastTwo.count >= minLen,
               structuredIdentifier(candidate, matches: bundleLastTwo) {
                return .bundleIdentifierSuffix
            }

            if let base = baseBundleID,
               base.count >= minLen,
               structuredIdentifier(candidate, matches: base) {
                return .baseBundleIdentifier
            }

            if let stripped = strippedAppName,
               stripped.count >= minLen,
               candidate == stripped { return .versionStrippedName }
        }

        // Deep mode may use only entitlement identifiers from a freshly
        // validated developer signature. Team ID/company name alone proves a
        // publisher, not exclusive ownership of a file or another app.
        if sensitivity == .deep {
            for entitlement in entitlementIdentifiers where entitlement.count >= minLen {
                if structuredIdentifier(candidate, matches: entitlement) {
                    return .verifiedEntitlement
                }
            }
        }

        return nil
    }

    /// Returns the same evidence used by the scanner without reading file
    /// contents. This lets the UI and removal history explain each candidate
    /// while keeping the existing bounded scan API and test injection surface.
    func evidence(for url: URL) -> AppFileMatchEvidence {
        let standardizedURL = url.standardizedFileURL
        if standardizedURL.path == appInfo.path.standardizedFileURL.path {
            return .selectedApplication
        }

        for condition in appConditions where bundleIDMatchesCondition(condition.bundleID) {
            if condition.forceIncludePaths?.contains(where: {
                $0.standardizedFileURL.path == standardizedURL.path
            }) == true {
                return .appSpecificRule
            }
        }

        if isMetadataOwnedContainer(standardizedURL) {
            return .containerMetadata
        }

        let isDirectory = (try? standardizedURL.resourceValues(
            forKeys: [.isDirectoryKey]
        ).isDirectory) == true
        let item = standardizedURL.lastPathComponent
        let matchingName = isDirectory
            ? item
            : (item as NSString).deletingPathExtension
        return matchEvidence(
            candidateName: matchingName,
            normalizedName: matchingName.normalizedForMatching()
        ) ?? .legacyUnknown
    }

    private func isMetadataOwnedContainer(_ url: URL) -> Bool {
        let containerRoot = FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("Containers", isDirectory: true)
        guard url.deletingLastPathComponent().standardizedFileURL.path
                == containerRoot?.standardizedFileURL.path,
              url.lastPathComponent.count == 36,
              url.lastPathComponent.contains("-") else {
            return false
        }

        let metadataURL = url.appendingPathComponent(
            ".com.apple.containermanagerd.metadata.plist"
        )
        guard let metadata = NSDictionary(contentsOf: metadataURL),
              let identifier = metadata["MCMMetadataIdentifier"] as? String else {
            return false
        }
        return identifier == appInfo.bundleIdentifier
    }

    private func structuredIdentifier(_ candidate: String, matches identifier: String) -> Bool {
        if candidate == identifier { return true }
        guard sensitivity != .strict,
              candidate.hasPrefix(identifier),
              candidate.count > identifier.count else { return false }

        let boundary = candidate.index(candidate.startIndex, offsetBy: identifier.count)
        return Self.identifierSeparators.contains(candidate[boundary])
    }

    private static let identifierSeparators: Set<Character> = [".", "-", "_", " ", "\t"]

    private static func canonicalArtifactName(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Skip Logic

    private func shouldSkipItem(
        _ normalizedName: String,
        at url: URL,
        collection: PathCollection
    ) -> Bool {
        if collection.contains(url) { return true }

        for skip in skipConditions {
            for path in skip.skipPaths {
                if url.path.hasPrefix(path) { return true }
            }
            if skip.skipPrefixes.contains(where: { normalizedName.hasPrefix($0) }) {
                if !skip.allowPrefixes.contains(where: { normalizedName.hasPrefix($0) }) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Container Discovery

    /// Discovers sandboxed app containers that belong to this app by checking
    /// both UUID-named containers (via metadata plist) and name-matched containers.
    private func discoverContainers() -> [URL] {
        var containers: [URL] = []

        guard let containersPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Containers") else { return containers }

        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: containersPath, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return containers }

        for dir in dirs {
            let dirName = dir.lastPathComponent

            // UUID-named containers: read the metadata plist for the owning bundle ID
            if dirName.count == 36 && dirName.contains("-") {
                let metaPlist = dir.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
                if let meta = NSDictionary(contentsOf: metaPlist),
                   let bundleID = meta["MCMMetadataIdentifier"] as? String,
                   bundleID == appInfo.bundleIdentifier {
                    containers.append(dir)
                }
            }

            // Named containers matching the bundle ID directly. Require the
            // bundle ID itself to be at least 5 chars to avoid picking up a
            // container owned by an app with a degenerate bundle identifier.
            if bundleIdentifier.count >= 5,
               Self.canonicalArtifactName(dirName) == bundleIdentifier {
                containers.append(dir)
            }
        }

        return containers
    }

    // MARK: - Condition Application

    /// Applies per-app force-include and force-exclude path overrides after
    /// the main scan has completed.
    private func applyConditions(to collection: inout Set<URL>) {
        for condition in appConditions {
            guard bundleIDMatchesCondition(condition.bundleID) else { continue }
            if let paths = condition.forceIncludePaths {
                for path in paths {
                    if FileManager.default.fileExists(atPath: path.path) {
                        collection.insert(path)
                    }
                }
            }
            if let paths = condition.forceExcludePaths {
                for path in paths {
                    collection.remove(path)
                }
            }
        }
    }

    // MARK: - Helpers

    /// User-authored content is not an uninstall artifact. Keeping these
    /// privacy-protected roots outside the search plan also prevents a scan
    /// from waiting on macOS TCC when the current build has no matching file
    /// access grant.
    private static let protectedUserContentRoots: Set<String> = Set(
        ["\(home)/Desktop", "\(home)/Documents"].map { path in
            URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }
    )

    /// Builds a minimal set of non-overlapping roots while preserving the
    /// effective depth of the old search. In particular, one depth-2
    /// Application Support root replaces hundreds of per-vendor roots.
    static func makeSearchPlan(paths: [String]) -> [SearchRoot] {
        let normalizedPaths = Set(paths.map { path in
            URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        })
        .filter { path in
            let isProtectedUserContent = protectedUserContentRoots.contains { protectedRoot in
                path == protectedRoot || path.hasPrefix(protectedRoot + "/")
            }
            let isHighRiskHomeDotPath = highRiskHomeDotPaths.contains { blocked in
                path == blocked || path.hasPrefix(blocked + "/")
            }
            return !isProtectedUserContent && !isHighRiskHomeDotPath
        }

        let candidates = normalizedPaths.map { path in
            SearchRoot(
                path: path,
                maxDepth: maximumDepth(for: path),
                isLibraryRootSearch: isLibraryDirectory(path)
            )
        }
        .sorted {
            let leftCount = URL(fileURLWithPath: $0.path).pathComponents.count
            let rightCount = URL(fileURLWithPath: $1.path).pathComponents.count
            if leftCount == rightCount { return $0.path < $1.path }
            return leftCount < rightCount
        }

        var plan: [SearchRoot] = []
        for candidate in candidates {
            if plan.contains(where: { rootSubsumes($0, child: candidate) }) {
                continue
            }
            plan.append(candidate)
        }
        return plan
    }

    private static func maximumDepth(for path: String) -> Int {
        if isLibraryDirectory(path) { return 2 }
        if path.hasSuffix("/Library/Application Support") { return 2 }
        return 1
    }

    private static func isLibraryDirectory(_ location: String) -> Bool {
        location == "\(home)/Library" || location == "/Library"
    }

    private static func rootSubsumes(_ parent: SearchRoot, child: SearchRoot) -> Bool {
        guard child.path.hasPrefix(parent.path + "/") else { return false }

        let parentComponents = URL(fileURLWithPath: parent.path).pathComponents
        let childComponents = URL(fileURLWithPath: child.path).pathComponents
        let relativeComponents = Array(childComponents.dropFirst(parentComponents.count))
        guard !relativeComponents.isEmpty else { return true }

        // Library-root recursion intentionally excludes sensitive and
        // irrelevant system subtrees. An explicit root under one of those
        // exclusions must not be incorrectly treated as covered.
        if parent.isLibraryRootSearch,
           let first = relativeComponents.first,
           skipDeepSearch.contains(first) {
            return false
        }

        return relativeComponents.count + child.maxDepth <= parent.maxDepth
    }

    /// Removes child paths when a parent is already in the set, and discards
    /// results that consist solely of a Trash item.
    private func filterSubpaths(_ urls: Set<URL>) -> Set<URL> {
        let sorted = urls.map { $0.standardizedFileURL }.sorted { $0.path < $1.path }
        var filtered: [URL] = []

        for url in sorted {
            // Remove any existing entries that are children of this URL
            filtered.removeAll { $0.path.hasPrefix(url.path + "/") }

            // Only add if this URL is not a child of an existing entry
            if !filtered.contains(where: { url.path.hasPrefix($0.path + "/") }) {
                filtered.append(url)
            }
        }

        // A single result pointing into the Trash is not meaningful
        if filtered.count == 1, let first = filtered.first, first.path.contains(".Trash") {
            return []
        }

        return Set(filtered)
    }
}
