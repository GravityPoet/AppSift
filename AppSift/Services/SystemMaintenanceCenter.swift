import AppKit
import Darwin
import Foundation

enum SpotlightIndexState: String, Hashable, Sendable {
    case enabled
    case disabled
    case unavailable
    case unknown
}

struct SpotlightVolume: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let isInternal: Bool
    let isReadOnly: Bool
    let indexState: SpotlightIndexState
    let statusDetail: String
}

struct MailIndexFile: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let size: Int64
    let modifiedAt: Date?
    let fingerprint: ReviewedTrashFingerprint
    let allowedRoot: URL

    var candidate: ReviewedTrashCandidate {
        ReviewedTrashCandidate(
            id: id,
            name: url.lastPathComponent,
            url: url,
            size: size,
            fingerprint: fingerprint,
            allowedRoot: allowedRoot,
            requiresDirectChild: true
        )
    }
}

struct MailIndexStatus: Hashable, Sendable {
    let mailDataURL: URL?
    let files: [MailIndexFile]
    let permissionDenied: Bool

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
}

struct SystemMaintenanceSnapshot: Sendable {
    let spotlightVolumes: [SpotlightVolume]
    let mailIndex: MailIndexStatus
}

actor SystemMaintenanceService {
    typealias AuthorizedCommandRunner = @Sendable (String) async throws -> Void
    typealias SpotlightVolumeProvider = @Sendable () -> [SpotlightVolume]

    enum ServiceError: LocalizedError {
        case authorizationCancelled
        case authorizationFailed(String)
        case volumeChanged
        case readOnlyVolume
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .authorizationCancelled:
                return String(localized: "Administrator authorization was cancelled. No maintenance command was run.")
            case .authorizationFailed(let detail):
                return detail.isEmpty
                    ? String(localized: "Administrator authorization failed. No maintenance command was run.")
                    : detail
            case .volumeChanged:
                return String(localized: "The selected disk is no longer mounted or changed. Refresh and try again.")
            case .readOnlyVolume:
                return String(localized: "Spotlight cannot be rebuilt on a read-only disk.")
            case .commandFailed(let detail):
                return detail
            }
        }
    }

    private static let maximumCommandOutputBytes = 1_000_000
    private let currentUserID: uid_t
    private let homeURL: URL
    private let spotlightVolumeProvider: SpotlightVolumeProvider?
    private let authorizedCommandRunner: AuthorizedCommandRunner?

    init(
        currentUserID: uid_t = getuid(),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        spotlightVolumeProvider: SpotlightVolumeProvider? = nil,
        authorizedCommandRunner: AuthorizedCommandRunner? = nil
    ) {
        self.currentUserID = currentUserID
        self.homeURL = homeURL.standardizedFileURL
        self.spotlightVolumeProvider = spotlightVolumeProvider
        self.authorizedCommandRunner = authorizedCommandRunner
    }

    func scan() -> SystemMaintenanceSnapshot {
        SystemMaintenanceSnapshot(
            spotlightVolumes: spotlightVolumeProvider?() ?? Self.currentSpotlightVolumes(),
            mailIndex: scanMailIndex()
        )
    }

    func flushDNSCache() async throws {
        let command = "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder"
        try await runAuthorizedCommand(command)
    }

    func rebuildSpotlight(volumeID: String) async throws {
        guard !volumeID.contains("\0"), !volumeID.contains("\n"), !volumeID.contains("\r") else {
            throw ServiceError.volumeChanged
        }
        let freshVolumes = spotlightVolumeProvider?() ?? Self.currentSpotlightVolumes()
        guard let selected = freshVolumes.first(where: { $0.id == volumeID }) else {
            throw ServiceError.volumeChanged
        }
        guard !selected.isReadOnly else { throw ServiceError.readOnlyVolume }

        let command = "/usr/bin/mdutil -E \(Self.shellQuote(selected.url.path))"
        try await runAuthorizedCommand(command)
    }

    private func scanMailIndex() -> MailIndexStatus {
        let mailRoot = homeURL.appendingPathComponent("Library/Mail", isDirectory: true)
        guard Self.isOwnedDirectory(mailRoot, owner: currentUserID) else {
            return MailIndexStatus(
                mailDataURL: nil,
                files: [],
                permissionDenied: FileManager.default.fileExists(atPath: mailRoot.path)
            )
        }

        let versionDirectories: [URL]
        do {
            versionDirectories = try FileManager.default.contentsOfDirectory(
                at: mailRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                guard url.lastPathComponent.range(of: #"^V\d+$"#, options: .regularExpression) != nil,
                      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                    return false
                }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
            .sorted { Self.mailVersion($0) > Self.mailVersion($1) }
        } catch {
            return MailIndexStatus(mailDataURL: nil, files: [], permissionDenied: true)
        }

        guard let mailData = versionDirectories
            .map({ $0.appendingPathComponent("MailData", isDirectory: true) })
            .first(where: { Self.isOwnedDirectory($0, owner: currentUserID) }) else {
            return MailIndexStatus(mailDataURL: nil, files: [], permissionDenied: false)
        }

        let allowedNames: Set<String> = [
            "Envelope Index",
            "Envelope Index-shm",
            "Envelope Index-wal",
        ]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: mailData,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            return MailIndexStatus(mailDataURL: mailData, files: [], permissionDenied: true)
        }

        let files = urls.compactMap { url -> MailIndexFile? in
            guard allowedNames.contains(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fingerprint = ReviewedTrashFingerprint.read(at: url),
                  fingerprint.owner == UInt32(currentUserID) else {
                return nil
            }
            return MailIndexFile(
                id: url.standardizedFileURL.path,
                url: url.standardizedFileURL,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate,
                fingerprint: fingerprint,
                allowedRoot: mailData.standardizedFileURL
            )
        }
        .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }

        return MailIndexStatus(mailDataURL: mailData, files: files, permissionDenied: false)
    }

    private static func currentSpotlightVolumes() -> [SpotlightVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsBrowsableKey,
            .volumeIsInternalKey,
            .volumeIsReadOnlyKey,
        ]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        var seen: Set<String> = []
        return mounted.compactMap { rawURL -> SpotlightVolume? in
            let url = rawURL.standardizedFileURL.resolvingSymlinksInPath()
            let path = url.path
            guard path == "/" || path.hasPrefix("/Volumes/"),
                  path != "/Volumes",
                  !path.contains("\0"),
                  seen.insert(path).inserted,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false else {
                return nil
            }

            let result = runProcess(
                executable: "/usr/bin/mdutil",
                arguments: ["-s", path]
            )
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = detail.lowercased()
            let state: SpotlightIndexState
            if lowercased.contains("indexing enabled") {
                state = .enabled
            } else if lowercased.contains("indexing disabled")
                        || lowercased.contains("search and indexing disabled") {
                state = .disabled
            } else if result.status != 0 {
                state = .unavailable
            } else {
                state = .unknown
            }
            return SpotlightVolume(
                id: path,
                url: url,
                name: values.volumeName ?? (path == "/" ? String(localized: "Macintosh HD") : url.lastPathComponent),
                isInternal: values.volumeIsInternal ?? (path == "/"),
                isReadOnly: values.volumeIsReadOnly ?? false,
                indexState: state,
                statusDetail: detail
            )
        }
        .sorted {
            if $0.isInternal != $1.isInternal { return $0.isInternal }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func runAuthorizedCommand(_ command: String) async throws {
        guard command.utf8.count <= 4_096 else {
            throw ServiceError.commandFailed(String(localized: "The maintenance command exceeded the safety limit."))
        }
        if let authorizedCommandRunner {
            try await authorizedCommandRunner(command)
            return
        }
        let source = "do shell script \(Self.appleScriptLiteral(command)) with administrator privileges"
        let result: (errorNumber: Int?, detail: String?) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let script = NSAppleScript(source: source)
                var errorInfo: NSDictionary?
                script?.executeAndReturnError(&errorInfo)
                continuation.resume(returning: (
                    errorInfo?[NSAppleScript.errorNumber] as? Int,
                    errorInfo?[NSAppleScript.errorMessage] as? String
                ))
            }
        }
        if result.errorNumber == -128 { throw ServiceError.authorizationCancelled }
        if result.errorNumber != nil {
            throw ServiceError.authorizationFailed(result.detail ?? "")
        }
    }

    private static func runProcess(executable: String, arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let bounded = Data((output + error).prefix(maximumCommandOutputBytes))
        return (process.terminationStatus, String(data: bounded, encoding: .utf8) ?? "")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func mailVersion(_ url: URL) -> Int {
        Int(url.lastPathComponent.dropFirst()) ?? 0
    }

    private static func isOwnedDirectory(_ url: URL, owner: uid_t) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0
            && information.st_mode & S_IFMT == S_IFDIR
            && information.st_uid == owner
            && information.st_mode & S_IWOTH == 0
    }
}

@MainActor
final class SystemMaintenanceCenter: ObservableObject {
    typealias MailRunningProvider = () -> Bool
    typealias MailTerminationHandler = () async -> Bool
    typealias MailReopenHandler = () -> Void

    static let mailIndexFeature = "mail-index-repair"

    @Published private(set) var spotlightVolumes: [SpotlightVolume] = []
    @Published var selectedSpotlightVolumeID: String?
    @Published private(set) var mailIndex = MailIndexStatus(
        mailDataURL: nil,
        files: [],
        permissionDenied: false
    )
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRunningDNS = false
    @Published private(set) var isRunningSpotlight = false
    @Published private(set) var isRepairingMail = false
    @Published private(set) var history: [ReviewedTrashRecord]
    @Published var actionMessage: String?
    @Published var errorMessage: String?

    private let service: SystemMaintenanceService
    private let trashService: ReviewedTrashService
    private let mailRunningProvider: MailRunningProvider
    private let mailTerminationHandler: MailTerminationHandler?
    private let mailReopenHandler: MailReopenHandler?

    init(
        service: SystemMaintenanceService = SystemMaintenanceService(),
        trashService: ReviewedTrashService = ReviewedTrashService(),
        historyStore: ReviewedTrashHistoryStore = .shared,
        mailRunningProvider: MailRunningProvider? = nil,
        mailTerminationHandler: MailTerminationHandler? = nil,
        mailReopenHandler: MailReopenHandler? = nil
    ) {
        self.service = service
        self.trashService = trashService
        self.mailRunningProvider = mailRunningProvider ?? {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.mail"
            ).isEmpty
        }
        self.mailTerminationHandler = mailTerminationHandler
        self.mailReopenHandler = mailReopenHandler
        self.history = historyStore.snapshot(feature: Self.mailIndexFeature)
    }

    var isMailRunning: Bool {
        mailRunningProvider()
    }

    var latestUndoableMailRecord: ReviewedTrashRecord? {
        history.first { record in
            record.items.contains { item in
                item.status == .movedToTrash
                    && item.restoredAt == nil
                    && item.trashPath.map(FileManager.default.fileExists(atPath:)) == true
            }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await service.scan()
            spotlightVolumes = snapshot.spotlightVolumes
            mailIndex = snapshot.mailIndex
            if selectedSpotlightVolumeID.flatMap({ id in
                snapshot.spotlightVolumes.first(where: { $0.id == id })
            }) == nil {
                selectedSpotlightVolumeID = snapshot.spotlightVolumes.first?.id
            }
            isRefreshing = false
        }
    }

    func flushDNSCache() {
        guard !isRunningDNS else { return }
        isRunningDNS = true
        errorMessage = nil
        actionMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await service.flushDNSCache()
                actionMessage = String(localized: "The DNS cache was refreshed successfully.")
            } catch {
                errorMessage = error.localizedDescription
            }
            isRunningDNS = false
        }
    }

    func rebuildSelectedSpotlightIndex() {
        guard !isRunningSpotlight, let selectedSpotlightVolumeID else { return }
        isRunningSpotlight = true
        errorMessage = nil
        actionMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await service.rebuildSpotlight(volumeID: selectedSpotlightVolumeID)
                actionMessage = String(localized: "Spotlight accepted the rebuild request. Search results may be incomplete until indexing finishes.")
                let snapshot = await service.scan()
                spotlightVolumes = snapshot.spotlightVolumes
                mailIndex = snapshot.mailIndex
            } catch {
                errorMessage = error.localizedDescription
            }
            isRunningSpotlight = false
        }
    }

    func repairMailIndex() {
        guard !isRepairingMail, !mailIndex.files.isEmpty else { return }
        isRepairingMail = true
        errorMessage = nil
        actionMessage = nil
        let shouldReopenMail = isMailRunning
        Task { [weak self] in
            guard let self else { return }
            if shouldReopenMail {
                guard await requestMailTermination() else {
                    errorMessage = String(localized: "Mail did not quit. No index files were changed.")
                    isRepairingMail = false
                    return
                }
            }

            let freshSnapshot = await service.scan()
            let freshByID = Dictionary(uniqueKeysWithValues: freshSnapshot.mailIndex.files.map { ($0.id, $0) })
            let candidates = mailIndex.files.compactMap { freshByID[$0.id]?.candidate }
            guard candidates.count == mailIndex.files.count else {
                errorMessage = String(localized: "Mail index files changed. Refresh and try again.")
                isRepairingMail = false
                reopenMailIfNeeded(shouldReopenMail)
                return
            }
            guard !isMailRunning else {
                errorMessage = String(localized: "Mail reopened before the repair began. No index files were changed.")
                isRepairingMail = false
                return
            }

            let outcome = await trashService.moveToTrash(candidates, feature: Self.mailIndexFeature)
            history = await trashService.history(feature: Self.mailIndexFeature)
            let refreshed = await service.scan()
            spotlightVolumes = refreshed.spotlightVolumes
            mailIndex = refreshed.mailIndex
            isRepairingMail = false
            if outcome.movedCount > 0 {
                actionMessage = String(localized: "Mail index files were moved to the Trash. Mail will rebuild its index when reopened.")
            }
            if !outcome.historyPersisted {
                errorMessage = String(localized: "The Mail index repair was rolled back because recovery history could not be saved.")
            } else if outcome.failedCount > 0 {
                errorMessage = String(localized: "Some Mail index files could not be moved safely.")
            }
            reopenMailIfNeeded(shouldReopenMail && outcome.movedCount > 0)
        }
    }

    func undoMailRepair(_ record: ReviewedTrashRecord) {
        guard !isRepairingMail, record.feature == Self.mailIndexFeature else { return }
        isRepairingMail = true
        errorMessage = nil
        actionMessage = nil
        let shouldReopenMail = isMailRunning
        Task { [weak self] in
            guard let self else { return }
            if shouldReopenMail, !(await requestMailTermination()) {
                errorMessage = String(localized: "Mail did not quit. No index files were restored.")
                isRepairingMail = false
                return
            }
            guard !isMailRunning else {
                errorMessage = String(localized: "Mail reopened before the restore began. No index files were restored.")
                isRepairingMail = false
                return
            }
            let outcome = await trashService.undo(record)
            history = await trashService.history(feature: Self.mailIndexFeature)
            let refreshed = await service.scan()
            spotlightVolumes = refreshed.spotlightVolumes
            mailIndex = refreshed.mailIndex
            isRepairingMail = false
            if outcome.restoredCount > 0 {
                actionMessage = String(localized: "Mail index files were restored from the Trash.")
            }
            if outcome.failedCount > 0 || !outcome.historyPersisted {
                errorMessage = String(localized: "AppSift could not safely restore every Mail index file.")
            }
            reopenMailIfNeeded(shouldReopenMail && outcome.restoredCount > 0)
        }
    }

    private func requestMailTermination() async -> Bool {
        if let mailTerminationHandler {
            return await mailTerminationHandler()
        }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail")
        guard !applications.isEmpty else { return true }
        applications.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(7)
        while Date() < deadline {
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    private func reopenMailIfNeeded(_ shouldReopen: Bool) {
        guard shouldReopen else { return }
        if let mailReopenHandler {
            mailReopenHandler()
            return
        }
        guard
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
