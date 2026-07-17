import Foundation

enum OrphanSafetyPolicy {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    // Conservative allowlist: only volatile data directories.
    static let allowedRoots: [String] = [
        "\(home)/Library/Caches",
        "\(home)/Library/Logs",
        "\(home)/Library/Saved Application State",
        "\(home)/Library/HTTPStorages",
        "\(home)/Library/WebKit",
        "\(home)/Library/Application Support/CrashReporter",
        "/Library/Caches",
        "/Library/Logs",
    ]

    private static let blockedFragments: [String] = [
        "/Library/Preferences",
        "/Library/PreferencePanes",
        "/Library/Containers",
        "/Library/Group Containers",
        "/Library/Application Scripts",
        "/Library/LaunchAgents",
        "/Library/LaunchDaemons",
        "/Library/PrivilegedHelperTools",
        "/Library/Keychains",
        "/Library/Mail",
        "/Library/Safari",
        "/Library/Messages",
        "/Library/Calendars",
        "/Library/Accounts",
        "/Library/Mobile Documents",
        "/Library/CloudStorage",
    ]

    static func isSafeCandidate(_ url: URL) -> Bool {
        let path = normalizedPath(url)
        let lowerPath = path.lowercased()

        // Belt-and-suspenders: reject any high-risk home dotpath (defined in
        // Conditions.swift). The allowedRoots filter below would catch most
        // of these, but this early block keeps the rule obvious.
        for root in highRiskHomeDotPaths {
            if path == root || path.hasPrefix(root + "/") {
                return false
            }
        }

        // Require the match to land STRICTLY inside the allowed root, not at a
        // sibling like /tmpfoo. Trailing "/" prevents hasPrefix from matching
        // sibling directories whose names merely start with the root name.
        guard allowedRoots.contains(where: { root in
            let rootWithSlash = root.lowercased() + "/"
            return lowerPath.hasPrefix(rootWithSlash)
        }) else {
            return false
        }

        if blockedFragments.contains(where: { lowerPath.contains($0.lowercased()) }) {
            return false
        }

        let name = url.lastPathComponent.lowercased()
        if name.hasPrefix("com.apple.") || name == ".globalpreferences.plist" {
            return false
        }

        return true
    }

    private static func normalizedPath(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        return standardized.resolvingSymlinksInPath().path
    }
}

/// The only boundary allowed to remove orphan candidates from the live file
/// system. Keeping Trash access behind an injectable operation makes the
/// recovery contract testable without touching a user's files.
struct OrphanTrashService {
    enum Outcome: Equatable {
        case trashed
        case missing
        case blocked
        case permissionDenied
        case failed(String)
    }

    typealias FileExists = (String) -> Bool
    typealias TrashOperation = (URL) throws -> Void

    private let fileExists: FileExists
    private let trashOperation: TrashOperation

    init(
        fileExists: @escaping FileExists = { FileManager.default.fileExists(atPath: $0) },
        trashOperation: @escaping TrashOperation = { url in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        }
    ) {
        self.fileExists = fileExists
        self.trashOperation = trashOperation
    }

    func trash(_ url: URL) -> Outcome {
        guard OrphanSafetyPolicy.isSafeCandidate(url) else {
            return .blocked
        }

        guard fileExists(url.path) else {
            return .missing
        }

        do {
            try trashOperation(url)
            return .trashed
        } catch {
            let nsError = error as NSError
            if Self.isMissingFileError(nsError) {
                return .missing
            }
            if Self.isPermissionDeniedError(nsError) {
                return .permissionDenied
            }
            return .failed(error.localizedDescription)
        }
    }

    private static func isMissingFileError(_ error: NSError) -> Bool {
        (error.domain == NSCocoaErrorDomain && [
            NSFileNoSuchFileError,
            NSFileReadNoSuchFileError,
        ].contains(error.code)) ||
        (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }

    private static func isPermissionDeniedError(_ error: NSError) -> Bool {
        (error.domain == NSCocoaErrorDomain && [
            NSFileReadNoPermissionError,
            NSFileWriteNoPermissionError,
        ].contains(error.code)) ||
        (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code))
    }
}
