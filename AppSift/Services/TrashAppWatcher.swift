import Combine
import Darwin
import Foundation

struct TrashAppCandidate: Hashable, Identifiable, Sendable {
    let path: String
    let appName: String
    let bundleIdentifier: String

    var id: String { path }

    var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    init(url: URL, appName: String, bundleIdentifier: String) {
        self.path = url.standardizedFileURL.path
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
    }
}

struct TrashRootIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

enum TrashAppDirectoryScanError: Error, Equatable {
    case rootUnavailable
    case unsafeRoot
    case rootChanged
}

struct TrashAppDirectorySnapshot: Equatable, Sendable {
    let rootIdentity: TrashRootIdentity
    let candidates: [TrashAppCandidate]
}

private enum TrashAppMetadataReader {
    private static let maximumInfoPlistByteCount = 1_048_576

    static func candidate(at appURL: URL) -> TrashAppCandidate? {
        let infoURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let info = readInfoDictionary(at: infoURL),
              nonEmptyString(info["CFBundlePackageType"]) == "APPL" else {
            return nil
        }

        let fallbackName = appURL.deletingPathExtension().lastPathComponent
        let bundleIdentifier = nonEmptyString(info["CFBundleIdentifier"]) ?? fallbackName
        guard !AppSelfRemovalPolicy.isCurrentApplication(
            bundleIdentifier: bundleIdentifier
        ),
        !AppInfoFetcher.isProtectedBundleIdentifier(bundleIdentifier) else {
            return nil
        }
        let appName = nonEmptyString(info["CFBundleDisplayName"])
            ?? nonEmptyString(info["CFBundleName"])
            ?? fallbackName
        return TrashAppCandidate(
            url: appURL,
            appName: appName,
            bundleIdentifier: bundleIdentifier
        )
    }

    private static func readInfoDictionary(at url: URL) -> [String: Any]? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= maximumInfoPlistByteCount else {
            return nil
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let bufferCount = buffer.count
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bufferCount)
            }
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard data.count + bytesRead <= maximumInfoPlistByteCount else {
                return nil
            }
            data.append(contentsOf: buffer.prefix(bytesRead))
        }

        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else {
            return nil
        }
        return propertyList as? [String: Any]
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Performs a fresh, shallow inspection of one Trash directory. Directory
/// events are deliberately not trusted to identify a path: every event causes
/// this scanner to rebuild a top-level snapshot and re-validate the boundary.
struct TrashAppDirectoryScanner {
    typealias CandidateLoader = (URL) -> TrashAppCandidate?

    let rootURL: URL
    private let candidateLoader: CandidateLoader

    init(
        rootURL: URL,
        candidateLoader: @escaping CandidateLoader = { url in
            TrashAppMetadataReader.candidate(at: url)
        }
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.candidateLoader = candidateLoader
    }

    func scan(
        expectedRootIdentity: TrashRootIdentity? = nil
    ) -> Result<TrashAppDirectorySnapshot, TrashAppDirectoryScanError> {
        guard rootURL.resolvingSymlinksInPath().standardizedFileURL.path == rootURL.path,
              let identityBefore = directoryIdentity(at: rootURL) else {
            return .failure(.unsafeRoot)
        }
        if let expectedRootIdentity, expectedRootIdentity != identityBefore {
            return .failure(.rootChanged)
        }

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isPackageKey,
                    .isSymbolicLinkKey,
                ],
                options: []
            )
        } catch {
            return .failure(.rootUnavailable)
        }

        var candidates: [TrashAppCandidate] = []
        var seenPaths: Set<String> = []
        for candidateURL in contents {
            let standardized = candidateURL.standardizedFileURL
            guard standardized.deletingLastPathComponent().path == rootURL.path,
                  standardized.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                  let values = try? standardized.resourceValues(forKeys: [
                      .isDirectoryKey,
                      .isPackageKey,
                      .isSymbolicLinkKey,
                  ]),
                  values.isSymbolicLink != true,
                  values.isDirectory == true,
                  standardized.resolvingSymlinksInPath().standardizedFileURL.path == standardized.path,
                  let candidateIdentityBefore = directoryIdentity(at: standardized),
                  let candidate = candidateLoader(standardized),
                  candidate.path == standardized.path,
                  directoryIdentity(at: standardized) == candidateIdentityBefore,
                  standardized.resolvingSymlinksInPath().standardizedFileURL.path == standardized.path,
                  seenPaths.insert(candidate.path).inserted else {
                continue
            }
            candidates.append(candidate)
        }

        guard let identityAfter = directoryIdentity(at: rootURL),
              identityAfter == identityBefore else {
            return .failure(.rootChanged)
        }

        return .success(
            TrashAppDirectorySnapshot(
                rootIdentity: identityAfter,
                candidates: candidates.sorted {
                    $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
                }
            )
        )
    }

    private func directoryIdentity(at url: URL) -> TrashRootIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        return TrashRootIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
    }
}

/// Pure transition logic kept separate from DispatchSource so duplicate,
/// removal, re-addition, and suppression semantics are deterministic in tests.
struct TrashAppSnapshotDetector {
    private var previousPaths: Set<String>?

    mutating func observe(
        _ candidates: [TrashAppCandidate],
        suppressedPaths: Set<String> = []
    ) -> [TrashAppCandidate] {
        let byPath = Dictionary(
            candidates.map { ($0.path, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        let currentPaths = Set(byPath.keys)
        defer { previousPaths = currentPaths }

        guard let previousPaths else {
            return []
        }

        return currentPaths
            .subtracting(previousPaths)
            .subtracting(suppressedPaths)
            .compactMap { byPath[$0] }
            .sorted {
                $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
            }
    }

    mutating func reset() {
        previousPaths = nil
    }
}

@MainActor
final class TrashAppWatcher: ObservableObject {
    enum Status: Equatable {
        case stopped
        case watching
        case retrying
    }

    static let shared = TrashAppWatcher()
    static let settingsKey = "settings.general.trashAppWatcher"
    static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL
    }

    @Published private(set) var status: Status = .stopped

    private let scanner: TrashAppDirectoryScanner
    private let debounceInterval: TimeInterval
    private let retryInterval: TimeInterval
    private var detector = TrashAppSnapshotDetector()
    private var source: DispatchSourceFileSystemObject?
    private var rootIdentity: TrashRootIdentity?
    private var detectionHandler: (([TrashAppCandidate]) -> Void)?
    private var suppressedUntil: [String: Date] = [:]
    private var debounceWorkItem: DispatchWorkItem?
    private var retryWorkItem: DispatchWorkItem?
    private var wantsToRun = false

    convenience init() {
        self.init(rootURL: Self.defaultRootURL)
    }

    init(
        rootURL: URL,
        debounceInterval: TimeInterval = 0.6,
        retryInterval: TimeInterval = 2,
        candidateLoader: TrashAppDirectoryScanner.CandidateLoader? = nil
    ) {
        if let candidateLoader {
            self.scanner = TrashAppDirectoryScanner(
                rootURL: rootURL,
                candidateLoader: candidateLoader
            )
        } else {
            self.scanner = TrashAppDirectoryScanner(rootURL: rootURL)
        }
        self.debounceInterval = debounceInterval
        self.retryInterval = retryInterval
    }

    func start(onDetection: @escaping ([TrashAppCandidate]) -> Void) {
        detectionHandler = onDetection
        wantsToRun = true
        guard source == nil else { return }
        armWatcher()
    }

    func stop() {
        wantsToRun = false
        detectionHandler = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        retryWorkItem?.cancel()
        retryWorkItem = nil
        teardownSource()
        detector.reset()
        rootIdentity = nil
        suppressedUntil.removeAll()
        status = .stopped
    }

    /// Prevents AppSift's own recoverable uninstall from creating a second,
    /// redundant review prompt when its destination appears in this Trash.
    func suppress(_ trashURLs: [URL], for duration: TimeInterval = 30) {
        let rootPath = scanner.rootURL.standardizedFileURL.path
        let deadline = Date().addingTimeInterval(duration)
        for url in trashURLs {
            let standardized = url.standardizedFileURL
            guard standardized.deletingLastPathComponent().path == rootPath,
                  standardized.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                continue
            }
            suppressedUntil[standardized.path] = deadline
        }
    }

    /// Deterministic hook used by tests. Production calls arrive through the
    /// directory DispatchSource and use the same rescan path.
    func scanNowForTesting() {
        performRescan()
    }

    private func armWatcher() {
        guard wantsToRun, source == nil else { return }
        retryWorkItem?.cancel()
        retryWorkItem = nil

        let baseline: TrashAppDirectorySnapshot
        switch scanner.scan() {
        case .success(let snapshot):
            baseline = snapshot
        case .failure:
            status = .retrying
            scheduleRetry()
            return
        }

        let descriptor = open(scanner.rootURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            status = .retrying
            scheduleRetry()
            return
        }

        detector.reset()
        _ = detector.observe(baseline.candidates)
        rootIdentity = baseline.rootIdentity

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link, .revoke],
            queue: .main
        )
        newSource.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleSourceEvent()
            }
        }
        newSource.setCancelHandler {
            close(descriptor)
        }
        source = newSource
        status = .watching
        newSource.resume()

        // Close the small arm-time race: anything added after the baseline but
        // before the source resumed is found by this immediate second snapshot.
        scheduleRescan(after: 0.05)
    }

    private func handleSourceEvent() {
        guard let source else { return }
        let terminalEvents: DispatchSource.FileSystemEvent = [.rename, .delete, .revoke]
        if !source.data.intersection(terminalEvents).isEmpty {
            teardownSource()
            detector.reset()
            rootIdentity = nil
            status = .retrying
            scheduleRetry()
            return
        }
        scheduleRescan(after: debounceInterval)
    }

    private func scheduleRescan(after delay: TimeInterval) {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.performRescan()
            }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func performRescan() {
        debounceWorkItem = nil
        guard wantsToRun,
              source != nil,
              let rootIdentity else {
            return
        }

        let snapshot: TrashAppDirectorySnapshot
        switch scanner.scan(expectedRootIdentity: rootIdentity) {
        case .success(let value):
            snapshot = value
        case .failure:
            teardownSource()
            detector.reset()
            self.rootIdentity = nil
            status = .retrying
            scheduleRetry()
            return
        }

        let now = Date()
        suppressedUntil = suppressedUntil.filter { $0.value > now }
        let detections = detector.observe(
            snapshot.candidates,
            suppressedPaths: Set(suppressedUntil.keys)
        )
        guard !detections.isEmpty else { return }
        detectionHandler?(detections)
    }

    private func scheduleRetry() {
        guard wantsToRun else { return }
        retryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.wantsToRun else { return }
                self.retryWorkItem = nil
                self.armWatcher()
            }
        }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval, execute: workItem)
    }

    private func teardownSource() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        source?.cancel()
        source = nil
    }
}

enum TrashAppNotificationContract {
    static let categoryIdentifier = "AppSift.TrashAppReview"
    static let reviewActionIdentifier = "AppSift.ReviewTrashAppLeftovers"
    static let notificationIdentifier = "AppSift.TrashAppWatcher.Latest"
    static let pathsUserInfoKey = "trashAppPaths"
}

@MainActor
enum TrashAppRequestBuffer {
    static var detectedCandidates: [TrashAppCandidate] = []
    static var reviewPaths: [String] = []

    static func mergeDetected(_ candidates: [TrashAppCandidate]) {
        var byPath = Dictionary(
            detectedCandidates.map { ($0.path, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        for candidate in candidates {
            byPath[candidate.path] = candidate
        }
        detectedCandidates = byPath.values.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }
}

extension Notification.Name {
    static let appSiftTrashAppWatcherChanged = Notification.Name(
        "AppSift.TrashAppWatcherChanged"
    )
    static let appSiftTrashAppsDetected = Notification.Name(
        "AppSift.TrashAppsDetected"
    )
    static let appSiftReviewTrashApps = Notification.Name(
        "AppSift.ReviewTrashApps"
    )
}
