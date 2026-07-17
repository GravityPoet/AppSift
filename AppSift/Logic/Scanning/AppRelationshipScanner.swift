import Darwin
import Foundation

struct AppRelationshipApplicationReference: Hashable, Sendable {
    let id: String
    let name: String
    let bundleIdentifier: String
    let url: URL
    let signature: AppSignatureMetadata
    let signatureInspectionState: AppSignatureInspectionState

    init(
        id: String,
        name: String,
        bundleIdentifier: String,
        url: URL,
        signature: AppSignatureMetadata,
        signatureInspectionState: AppSignatureInspectionState
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.signature = signature
        self.signatureInspectionState = signatureInspectionState
    }

    init(app: InstalledApp) {
        self.init(
            id: app.id,
            name: app.appName,
            bundleIdentifier: app.bundleIdentifier,
            url: app.path,
            signature: app.signature,
            signatureInspectionState: app.signatureInspectionState
        )
    }
}

struct AppRelationshipApplication: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let bundleIdentifier: String
    let url: URL
    let teamIdentifier: String
    let groupIdentifiers: [String]
}

enum AppRelationshipLocationKind: String, Hashable, Sendable {
    case groupContainer
    case applicationScripts
}

enum AppRelationshipLocationStatus: String, Hashable, Sendable {
    case presentDirectory
    case notFound
    case permissionDenied
    case unsafeType
    case unreadable
}

struct AppRelationshipLocation: Hashable, Sendable {
    let kind: AppRelationshipLocationKind
    let url: URL
    let status: AppRelationshipLocationStatus
}

struct AppRelationshipGroup: Identifiable, Hashable, Sendable {
    let identifier: String
    let teamIdentifier: String
    let applications: [AppRelationshipApplication]
    let locations: [AppRelationshipLocation]

    var id: String { "\(teamIdentifier)|\(identifier)" }
    var isShared: Bool { applications.count > 1 }

    func contains(applicationID: String) -> Bool {
        applications.contains { $0.id == applicationID }
    }
}

struct AppRelationshipScanResult: Hashable, Sendable {
    let groups: [AppRelationshipGroup]
    let selectedApplicationID: String?
    let scannedApplicationCount: Int
    let ignoredUnsignedApplicationCount: Int
    let invalidGroupIdentifierCount: Int
    let wasTruncated: Bool
    let wasCancelled: Bool
    let scannedAt: Date

    func groups(containing applicationID: String) -> [AppRelationshipGroup] {
        groups.filter { $0.contains(applicationID: applicationID) }
    }

    func relatedApplications(to applicationID: String) -> [AppRelationshipApplication] {
        var byID: [String: AppRelationshipApplication] = [:]
        for group in groups(containing: applicationID) {
            for application in group.applications where application.id != applicationID {
                byID[application.id] = application
            }
        }
        return byID.values.sorted(by: AppRelationshipScanner.applicationSort)
    }
}

/// Builds a read-only relationship graph from signed App Group entitlements.
/// A relationship requires all three signals: a valid developer signature,
/// the same Team ID, and an exact App Group identifier. Same-developer apps
/// alone are never treated as related.
enum AppRelationshipScanner {
    typealias SignatureProvider = @Sendable (URL) -> AppSignatureMetadata

    private struct GroupKey: Hashable {
        let teamIdentifier: String
        let groupIdentifier: String
    }

    static let defaultMaximumApplicationCount = 512
    static let defaultMaximumGroupCountPerApplication = 128
    static let defaultMaximumMembershipCount = 8_192

    static func scan(
        applications: [AppRelationshipApplicationReference],
        selectedApplicationID: String? = nil,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        maximumApplicationCount: Int = defaultMaximumApplicationCount,
        maximumGroupCountPerApplication: Int = defaultMaximumGroupCountPerApplication,
        maximumMembershipCount: Int = defaultMaximumMembershipCount,
        signatureProvider: @escaping SignatureProvider = {
            AppSignatureInspector.inspect(at: $0)
        },
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> AppRelationshipScanResult {
        let applicationLimit = min(max(maximumApplicationCount, 1), 2_048)
        let groupLimit = min(max(maximumGroupCountPerApplication, 1), 512)
        let membershipLimit = min(max(maximumMembershipCount, 1), 32_768)
        let orderedApplications = prioritizedUniqueApplications(
            applications,
            selectedApplicationID: selectedApplicationID
        )
        let boundedApplications = Array(orderedApplications.prefix(applicationLimit))

        var groupedApplications: [GroupKey: [AppRelationshipApplication]] = [:]
        var scannedApplicationCount = 0
        var ignoredUnsignedApplicationCount = 0
        var invalidGroupIdentifierCount = 0
        var membershipCount = 0
        var wasTruncated = orderedApplications.count > boundedApplications.count
        var wasCancelled = false

        applicationLoop: for reference in boundedApplications {
            guard !shouldCancel() else {
                wasCancelled = true
                break
            }
            scannedApplicationCount += 1

            let signature = reference.signatureInspectionState == .pending
                ? signatureProvider(reference.url)
                : reference.signature
            guard signature.status == .developerSigned,
                  let teamIdentifier = normalizedTeamIdentifier(signature.teamIdentifier) else {
                ignoredUnsignedApplicationCount += 1
                continue
            }

            let declaredGroups = orderedUnique(signature.sharedContainerIdentifiers)
            if declaredGroups.count > groupLimit {
                wasTruncated = true
            }

            var validGroups: [String] = []
            for identifier in declaredGroups.prefix(groupLimit) {
                guard isValidGroupIdentifier(identifier, teamIdentifier: teamIdentifier) else {
                    invalidGroupIdentifierCount += 1
                    continue
                }
                validGroups.append(identifier)
            }
            guard !validGroups.isEmpty else { continue }

            let application = AppRelationshipApplication(
                id: reference.id,
                name: reference.name,
                bundleIdentifier: reference.bundleIdentifier,
                url: reference.url.standardizedFileURL,
                teamIdentifier: teamIdentifier,
                groupIdentifiers: validGroups
            )
            for identifier in validGroups {
                guard !shouldCancel() else {
                    wasCancelled = true
                    break applicationLoop
                }
                guard membershipCount < membershipLimit else {
                    wasTruncated = true
                    break applicationLoop
                }
                let key = GroupKey(
                    teamIdentifier: teamIdentifier,
                    groupIdentifier: identifier
                )
                groupedApplications[key, default: []].append(application)
                membershipCount += 1
            }
        }

        let libraryURL = homeURL.standardizedFileURL
            .appendingPathComponent("Library", isDirectory: true)
        let groups = groupedApplications.map { key, applications in
            AppRelationshipGroup(
                identifier: key.groupIdentifier,
                teamIdentifier: key.teamIdentifier,
                applications: applications.sorted(by: applicationSort),
                locations: locations(
                    for: key.groupIdentifier,
                    libraryURL: libraryURL
                )
            )
        }
        .sorted {
            if $0.identifier == $1.identifier {
                return $0.teamIdentifier < $1.teamIdentifier
            }
            return $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending
        }

        return AppRelationshipScanResult(
            groups: groups,
            selectedApplicationID: selectedApplicationID,
            scannedApplicationCount: scannedApplicationCount,
            ignoredUnsignedApplicationCount: ignoredUnsignedApplicationCount,
            invalidGroupIdentifierCount: invalidGroupIdentifierCount,
            wasTruncated: wasTruncated,
            wasCancelled: wasCancelled,
            scannedAt: Date()
        )
    }

    static func isValidGroupIdentifier(
        _ identifier: String,
        teamIdentifier: String
    ) -> Bool {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == identifier,
              !identifier.isEmpty,
              identifier.utf8.count <= 255,
              identifier.hasPrefix("group.") || identifier.hasPrefix(teamIdentifier + "."),
              identifier.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (
                      CharacterSet.alphanumerics.contains(scalar)
                          || scalar == "-" || scalar == "." || scalar == "_"
                  )
              }) else {
            return false
        }
        return !identifier.hasSuffix(".") && !identifier.contains("..")
    }

    static func locationStatus(at url: URL) -> AppRelationshipLocationStatus {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &metadata)
        }
        if result == 0 {
            return (metadata.st_mode & S_IFMT) == S_IFDIR
                ? .presentDirectory
                : .unsafeType
        }

        switch errno {
        case ENOENT, ENOTDIR:
            return .notFound
        case EACCES, EPERM:
            return .permissionDenied
        default:
            return .unreadable
        }
    }

    static func applicationSort(
        _ lhs: AppRelationshipApplication,
        _ rhs: AppRelationshipApplication
    ) -> Bool {
        if lhs.name == rhs.name { return lhs.url.path < rhs.url.path }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func locations(
        for identifier: String,
        libraryURL: URL
    ) -> [AppRelationshipLocation] {
        let candidates: [(AppRelationshipLocationKind, URL)] = [
            (
                .groupContainer,
                libraryURL
                    .appendingPathComponent("Group Containers", isDirectory: true)
                    .appendingPathComponent(identifier, isDirectory: true)
            ),
            (
                .applicationScripts,
                libraryURL
                    .appendingPathComponent("Application Scripts", isDirectory: true)
                    .appendingPathComponent(identifier, isDirectory: true)
            ),
        ]
        return candidates.map { kind, url in
            AppRelationshipLocation(
                kind: kind,
                url: url,
                status: locationStatus(at: url)
            )
        }
    }

    private static func prioritizedUniqueApplications(
        _ applications: [AppRelationshipApplicationReference],
        selectedApplicationID: String?
    ) -> [AppRelationshipApplicationReference] {
        var byID: [String: AppRelationshipApplicationReference] = [:]
        for application in applications where byID[application.id] == nil {
            byID[application.id] = application
        }
        return byID.values.sorted { lhs, rhs in
            if let selectedApplicationID {
                if lhs.id == selectedApplicationID { return true }
                if rhs.id == selectedApplicationID { return false }
            }
            if lhs.name == rhs.name { return lhs.url.path < rhs.url.path }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func normalizedTeamIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 64,
              trimmed.unicodeScalars.allSatisfy({
                  $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-")
              }) else {
            return nil
        }
        return trimmed
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
