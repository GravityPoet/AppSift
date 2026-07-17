import Foundation
import AppKit
import Security
import os

enum AppSelfRemovalPolicy {
    static func isCurrentApplication(
        bundleIdentifier: String,
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard let currentBundleIdentifier, !currentBundleIdentifier.isEmpty else {
            return false
        }
        return bundleIdentifier == currentBundleIdentifier
    }
}

enum AppSignatureStatus: String, Hashable, Sendable {
    case developerSigned
    case locallySigned
    case adHoc
    case unsigned
    case invalid
    case unknown
}

enum AppNotarizationStatus: String, Hashable, Sendable {
    case notarized
    case notNotarized
    case unknown
}

enum AppSignatureInspectionState: String, Hashable, Sendable {
    case pending
    case inspected
}

struct AppSignatureMetadata: Hashable, Sendable {
    let status: AppSignatureStatus
    let signingIdentifier: String?
    let teamIdentifier: String?
    let developerName: String?
    /// True only when a valid Apple-anchored signature uses a Mac App Store
    /// application certificate. Receipt presence is checked separately so a
    /// copied `_MASReceipt` directory cannot claim App Store provenance.
    let isMacAppStoreSigned: Bool
    let notarizationStatus: AppNotarizationStatus
    let isSandboxed: Bool?
    let entitlementIdentifiers: [String]
    /// App Group identifiers name shared filesystem containers. They are kept
    /// separate from general association identifiers so the uninstaller can
    /// find them while still refusing to treat them as app-exclusive data.
    let sharedContainerIdentifiers: [String]

    init(
        status: AppSignatureStatus,
        signingIdentifier: String?,
        teamIdentifier: String?,
        developerName: String? = nil,
        isMacAppStoreSigned: Bool = false,
        notarizationStatus: AppNotarizationStatus = .unknown,
        isSandboxed: Bool? = nil,
        entitlementIdentifiers: [String],
        sharedContainerIdentifiers: [String] = []
    ) {
        self.status = status
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.developerName = developerName
        self.isMacAppStoreSigned = isMacAppStoreSigned
        self.notarizationStatus = notarizationStatus
        self.isSandboxed = isSandboxed
        self.entitlementIdentifiers = entitlementIdentifiers
        self.sharedContainerIdentifiers = sharedContainerIdentifiers
    }

    static let unknown = AppSignatureMetadata(
        status: .unknown,
        signingIdentifier: nil,
        teamIdentifier: nil,
        entitlementIdentifiers: []
    )
}

enum AppSizeState: String, Hashable {
    /// No trustworthy recursive size is available yet. The list can still be
    /// shown immediately while the bundle is measured in the background.
    case pending
    /// Reused from a fingerprint-matched, time-bounded on-disk cache.
    case cached
    /// Freshly calculated by recursively walking the app bundle.
    case calculated
    /// The bundle disappeared or could not be enumerated during this pass.
    case unavailable
}

enum AppSignatureInspector {
    private static let adHocCodeDirectoryFlag: UInt32 = 0x2
    private static let identifierEntitlementKeys: Set<String> = [
        "application-identifier",
        "com.apple.application-identifier",
        "com.apple.security.application-groups",
        "com.apple.developer.icloud-container-identifiers",
        "com.apple.developer.ubiquity-container-identifiers",
        "com.apple.developer.ubiquity-kvstore-identifier",
    ]

    static func inspect(at url: URL) -> AppSignatureMetadata {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            return metadata(forFailureStatus: createStatus)
        }

        let validityStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: 0),
            nil
        )
        guard validityStatus == errSecSuccess else {
            return metadata(forFailureStatus: validityStatus)
        }

        var signingInformation: CFDictionary?
        let copyStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard copyStatus == errSecSuccess,
              let information = signingInformation as? [String: Any] else {
            return .unknown
        }

        let signingIdentifier = nonEmptyString(information[kSecCodeInfoIdentifier as String])
        let teamIdentifier = nonEmptyString(information[kSecCodeInfoTeamIdentifier as String])
        let codeDirectoryFlags = (information[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let certificateSummary = certificates.first.flatMap {
            SecCertificateCopySubjectSummary($0) as String?
        }
        let status = signatureStatus(
            teamIdentifier: teamIdentifier,
            codeDirectoryFlags: codeDirectoryFlags,
            hasCertificate: !certificates.isEmpty,
            isAppleDeveloperCertificate: requirementStatus(
                "anchor apple generic",
                for: staticCode
            ) == errSecSuccess
        )
        let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any]

        // Only a valid Developer ID / App Store signature contributes extra
        // association identifiers. Ad-hoc apps can choose arbitrary
        // entitlements and must not be able to claim another app's files.
        let entitlementIdentifiers: [String]
        let sharedContainerIdentifiers: [String]
        if status == .developerSigned, let entitlements {
            entitlementIdentifiers = relatedIdentifiers(from: entitlements)
            sharedContainerIdentifiers = Self.sharedContainerIdentifiers(from: entitlements)
        } else {
            entitlementIdentifiers = []
            sharedContainerIdentifiers = []
        }
        let isMacAppStoreSigned = status == .developerSigned
            && isMacAppStoreCertificate(certificateSummary)

        return AppSignatureMetadata(
            status: status,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            developerName: developerName(
                from: certificateSummary,
                teamIdentifier: teamIdentifier
            ),
            isMacAppStoreSigned: isMacAppStoreSigned,
            // App Store distribution is reviewed and signed through a
            // different trust path; a failed Developer ID `notarized`
            // requirement must not be presented as an orange warning.
            notarizationStatus: isMacAppStoreSigned
                ? .unknown
                : notarizationStatus(for: staticCode),
            isSandboxed: entitlements.map(isSandboxed(from:)) ?? false,
            entitlementIdentifiers: entitlementIdentifiers,
            sharedContainerIdentifiers: sharedContainerIdentifiers
        )
    }

    static func signatureStatus(
        teamIdentifier: String?,
        codeDirectoryFlags: UInt32,
        hasCertificate: Bool,
        isAppleDeveloperCertificate: Bool
    ) -> AppSignatureStatus {
        if codeDirectoryFlags & adHocCodeDirectoryFlag != 0 {
            return .adHoc
        }
        if teamIdentifier != nil && isAppleDeveloperCertificate {
            return .developerSigned
        }
        if hasCertificate {
            return .locallySigned
        }
        return .unknown
    }

    static func developerName(
        from certificateSummary: String?,
        teamIdentifier: String?
    ) -> String? {
        guard var name = nonEmptyString(certificateSummary) else { return nil }
        if name == "Apple Mac OS Application Signing" {
            return nil
        }
        let prefixes = [
            "Developer ID Application: ",
            "3rd Party Mac Developer Application: ",
            "Apple Distribution: ",
            "Mac Developer: ",
            "Apple Development: ",
        ]
        if let prefix = prefixes.first(where: { name.hasPrefix($0) }) {
            name.removeFirst(prefix.count)
        }
        if let teamIdentifier {
            let suffix = " (\(teamIdentifier))"
            if name.hasSuffix(suffix) {
                name.removeLast(suffix.count)
            }
        }
        return nonEmptyString(name)
    }

    static func isMacAppStoreCertificate(_ certificateSummary: String?) -> Bool {
        guard let summary = nonEmptyString(certificateSummary) else { return false }
        return summary == "Apple Mac OS Application Signing"
            || summary.hasPrefix("3rd Party Mac Developer Application: ")
    }

    static func isSandboxed(from entitlements: [String: Any]) -> Bool {
        entitlements["com.apple.security.app-sandbox"] as? Bool == true
    }

    static func notarizationStatus(
        forRequirementStatus status: OSStatus
    ) -> AppNotarizationStatus {
        if status == errSecSuccess {
            return .notarized
        }
        if status == errSecCSReqFailed {
            return .notNotarized
        }
        return .unknown
    }

    static func relatedIdentifiers(from entitlements: [String: Any]) -> [String] {
        var identifiers: Set<String> = []

        for key in identifierEntitlementKeys {
            guard let value = entitlements[key] else { continue }
            if let string = nonEmptyString(value) {
                identifiers.insert(string)
            } else if let strings = value as? [String] {
                for string in strings {
                    if let normalized = nonEmptyString(string) {
                        identifiers.insert(normalized)
                    }
                }
            }
        }

        return identifiers.sorted()
    }

    static func sharedContainerIdentifiers(from entitlements: [String: Any]) -> [String] {
        guard let value = entitlements["com.apple.security.application-groups"] else {
            return []
        }

        var identifiers: Set<String> = []
        if let string = nonEmptyString(value) {
            identifiers.insert(string)
        } else if let strings = value as? [String] {
            for string in strings {
                if let normalized = nonEmptyString(string) {
                    identifiers.insert(normalized)
                }
            }
        }
        return identifiers.sorted()
    }

    private static func notarizationStatus(for staticCode: SecStaticCode) -> AppNotarizationStatus {
        guard let status = requirementStatus("notarized", for: staticCode) else {
            return .unknown
        }
        return notarizationStatus(forRequirementStatus: status)
    }

    private static func requirementStatus(
        _ requirementSource: String,
        for staticCode: SecStaticCode
    ) -> OSStatus? {
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirementSource as CFString,
            SecCSFlags(rawValue: 0),
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            return nil
        }

        return SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: 0),
            requirement
        )
    }

    private static func metadata(forFailureStatus status: OSStatus) -> AppSignatureMetadata {
        let signatureStatus: AppSignatureStatus
        if status == errSecCSUnsigned {
            signatureStatus = .unsigned
        } else if status == errSecCSBadObjectFormat || status == errSecCSStaticCodeNotFound {
            signatureStatus = .unknown
        } else {
            signatureStatus = .invalid
        }

        return AppSignatureMetadata(
            status: signatureStatus,
            signingIdentifier: nil,
            teamIdentifier: nil,
            entitlementIdentifiers: []
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct InstalledApp: Identifiable, Hashable {
    let id: String
    let appName: String
    let bundleIdentifier: String
    let path: URL
    let icon: NSImage
    let size: Int64
    let sizeState: AppSizeState
    let version: String?
    let buildNumber: String?
    let minimumSystemVersion: String?
    let createdAt: Date?
    let modifiedAt: Date?
    let lastUsedAt: Date?
    let signature: AppSignatureMetadata
    let signatureInspectionState: AppSignatureInspectionState

    init(
        appName: String,
        bundleIdentifier: String,
        path: URL,
        icon: NSImage,
        size: Int64,
        sizeState: AppSizeState = .calculated,
        version: String? = nil,
        buildNumber: String? = nil,
        minimumSystemVersion: String? = nil,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        lastUsedAt: Date? = nil,
        signature: AppSignatureMetadata = .unknown,
        signatureInspectionState: AppSignatureInspectionState = .inspected
    ) {
        self.id = path.standardizedFileURL.resolvingSymlinksInPath().path
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.icon = icon
        self.size = size
        self.sizeState = sizeState
        self.version = version
        self.buildNumber = buildNumber
        self.minimumSystemVersion = minimumSystemVersion
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.lastUsedAt = lastUsedAt
        self.signature = signature
        self.signatureInspectionState = signatureInspectionState
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var hasKnownSize: Bool {
        sizeState == .cached || sizeState == .calculated
    }

    var needsSizeCalculation: Bool {
        sizeState == .pending
    }

    var needsSignatureInspection: Bool {
        signatureInspectionState == .pending
    }

    var versionSummary: String? {
        switch (version, buildNumber) {
        case let (version?, build?) where version != build:
            return "\(version) (\(build))"
        case let (version?, _):
            return version
        case let (_, build?):
            return build
        default:
            return nil
        }
    }

    func replacingSize(_ size: Int64, state: AppSizeState) -> InstalledApp {
        InstalledApp(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            path: path,
            icon: icon,
            size: size,
            sizeState: state,
            version: version,
            buildNumber: buildNumber,
            minimumSystemVersion: minimumSystemVersion,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            lastUsedAt: lastUsedAt,
            signature: signature,
            signatureInspectionState: signatureInspectionState
        )
    }

    func replacingSignature(_ signature: AppSignatureMetadata) -> InstalledApp {
        InstalledApp(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            path: path,
            icon: icon,
            size: size,
            sizeState: sizeState,
            version: version,
            buildNumber: buildNumber,
            minimumSystemVersion: minimumSystemVersion,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            lastUsedAt: lastUsedAt,
            signature: signature,
            signatureInspectionState: .inspected
        )
    }

    /// Combines independent background enrichments without allowing a stale
    /// size result to erase a newer signature result (or vice versa).
    func mergingEnrichment(from update: InstalledApp) -> InstalledApp {
        guard id == update.id else { return self }
        let sizeSource = update.sizeState == .pending ? self : update
        let signatureSource = update.signatureInspectionState == .pending ? self : update

        return InstalledApp(
            appName: update.appName,
            bundleIdentifier: update.bundleIdentifier,
            path: update.path,
            icon: update.icon,
            size: sizeSource.size,
            sizeState: sizeSource.sizeState,
            version: update.version,
            buildNumber: update.buildNumber,
            minimumSystemVersion: update.minimumSystemVersion,
            createdAt: update.createdAt,
            modifiedAt: update.modifiedAt,
            lastUsedAt: update.lastUsedAt,
            signature: signatureSource.signature,
            signatureInspectionState: signatureSource.signatureInspectionState
        )
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool {
        lhs.id == rhs.id
    }
}

enum AppInstallationSource: Hashable, Sendable {
    case macAppStore
    case homebrewCask(HomebrewCaskInstallMetadata)
    case unknown
}

struct HomebrewCaskInstallMetadata: Hashable, Sendable {
    let token: String
    let version: String?
    let tap: String?
    let receiptURL: URL
    /// Homebrew zap entries are untrusted context only. AppSift never imports
    /// these paths into its removal selection.
    let extraCleanupPatternCount: Int
}

struct AppOfficialUninstaller: Hashable, Sendable {
    let name: String
    let url: URL
}

struct AppInstallationInsights: Hashable, Sendable {
    let source: AppInstallationSource
    let officialUninstaller: AppOfficialUninstaller?
    let installerPackage: InstallerPackageInsights?

    init(
        source: AppInstallationSource,
        officialUninstaller: AppOfficialUninstaller?,
        installerPackage: InstallerPackageInsights? = nil
    ) {
        self.source = source
        self.officialUninstaller = officialUninstaller
        self.installerPackage = installerPackage
    }

    var hasVerifiedInsight: Bool {
        source != .unknown || officialUninstaller != nil || installerPackage != nil
    }
}

/// Read-only installation provenance. Every positive result joins multiple
/// independent signals and remains informational: none of this metadata is
/// accepted as authorization to delete a path.
enum AppInstallationInspector {
    typealias SignatureInspection = (URL) -> AppSignatureMetadata

    static let defaultHomebrewRoots = [
        URL(fileURLWithPath: "/opt/homebrew/Caskroom", isDirectory: true),
        URL(fileURLWithPath: "/usr/local/Caskroom", isDirectory: true),
    ]

    private static let maximumReceiptBytes = 2_000_000
    private static let maximumCaskCountPerRoot = 512
    private static let maximumVersionDirectoriesPerCask = 32
    private static let maximumArtifactCount = 128
    private static let maximumCleanupPatternCount = 1_000
    private static let maximumSiblingCandidateCount = 1_024

    private struct ParsedCaskReceipt {
        let appNames: Set<String>
        let version: String?
        let tap: String?
        let extraCleanupPatternCount: Int
    }

    private struct UninstallerCandidate: Hashable {
        let url: URL
        let rank: Int
    }

    static func inspect(
        app: InstalledApp,
        fileManager: FileManager = .default,
        homebrewRoots: [URL] = defaultHomebrewRoots,
        signatureInspector: SignatureInspection = { AppSignatureInspector.inspect(at: $0) },
        shouldCancel: () -> Bool = { false }
    ) -> AppInstallationInsights {
        guard !shouldCancel() else {
            return AppInstallationInsights(source: .unknown, officialUninstaller: nil)
        }

        let homebrew = verifiedHomebrewCask(
            for: app,
            fileManager: fileManager,
            roots: homebrewRoots,
            signatureInspector: signatureInspector,
            shouldCancel: shouldCancel
        )
        let source: AppInstallationSource
        if let homebrew {
            source = .homebrewCask(homebrew)
        } else if hasVerifiedMacAppStoreReceipt(
            for: app,
            fileManager: fileManager
        ) {
            source = .macAppStore
        } else {
            source = .unknown
        }

        guard !shouldCancel() else {
            return AppInstallationInsights(source: source, officialUninstaller: nil)
        }
        let uninstaller = verifiedOfficialUninstaller(
            for: app,
            fileManager: fileManager,
            signatureInspector: signatureInspector,
            shouldCancel: shouldCancel
        )
        guard !shouldCancel() else {
            return AppInstallationInsights(
                source: source,
                officialUninstaller: uninstaller
            )
        }
        let installerPackage = PkgReceiptInspector.inspect(
            app: app,
            fileManager: fileManager,
            shouldCancel: shouldCancel
        )
        return AppInstallationInsights(
            source: source,
            officialUninstaller: uninstaller,
            installerPackage: installerPackage
        )
    }

    /// Builds Homebrew provenance for many installed apps in one bounded pass
    /// over Caskroom. This avoids the O(apps × casks) walk that would make an
    /// update scan noticeably slower on machines with large app libraries.
    static func verifiedHomebrewCasks(
        for apps: [InstalledApp],
        fileManager: FileManager = .default,
        roots: [URL] = defaultHomebrewRoots,
        signatureInspector: SignatureInspection = { AppSignatureInspector.inspect(at: $0) },
        shouldCancel: () -> Bool = { false }
    ) -> [InstalledApp.ID: HomebrewCaskInstallMetadata] {
        let appsByBundleName = Dictionary(
            grouping: apps,
            by: { $0.path.lastPathComponent }
        )
        var matches: [InstalledApp.ID: [HomebrewCaskInstallMetadata]] = [:]
        var refreshedApps: [InstalledApp.ID: InstalledApp] = [:]

        for root in roots.sorted(by: { $0.path < $1.path }) {
            guard !shouldCancel() else { return [:] }
            guard let caskDirectories = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for caskDirectory in caskDirectories
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                .prefix(maximumCaskCountPerRoot) {
                guard !shouldCancel() else { return [:] }
                let token = caskDirectory.lastPathComponent
                guard isSafeCaskToken(token),
                      let directoryValues = try? caskDirectory.resourceValues(forKeys: [
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                      ]),
                      directoryValues.isDirectory == true,
                      directoryValues.isSymbolicLink != true else { continue }

                let receiptURL = caskDirectory
                    .appendingPathComponent(".metadata", isDirectory: true)
                    .appendingPathComponent("INSTALL_RECEIPT.json", isDirectory: false)
                guard let receipt = parseCaskReceipt(
                    at: receiptURL,
                    inside: caskDirectory,
                    fileManager: fileManager
                ) else { continue }

                for appName in receipt.appNames.sorted() {
                    guard let candidateApps = appsByBundleName[appName] else { continue }
                    for originalApp in candidateApps {
                        guard !shouldCancel() else { return [:] }
                        let app: InstalledApp
                        if let refreshed = refreshedApps[originalApp.id] {
                            app = refreshed
                        } else {
                            let refreshed = originalApp.replacingSignature(
                                signatureInspector(originalApp.path)
                            )
                            refreshedApps[originalApp.id] = refreshed
                            app = refreshed
                        }
                        guard app.signature.status == .developerSigned,
                              let selectedTeamID = nonEmpty(app.signature.teamIdentifier),
                              !app.bundleIdentifier.isEmpty,
                              let installedVersion = verifiedHomebrewArtifactVersion(
                                appName: appName,
                                selectedApp: app,
                                selectedTeamID: selectedTeamID,
                                caskDirectory: caskDirectory,
                                fileManager: fileManager,
                                signatureInspector: signatureInspector,
                                shouldCancel: shouldCancel
                              ) else { continue }

                        matches[app.id, default: []].append(
                            HomebrewCaskInstallMetadata(
                                token: token,
                                version: receipt.version ?? installedVersion,
                                tap: receipt.tap,
                                receiptURL: receiptURL.standardizedFileURL,
                                extraCleanupPatternCount: receipt.extraCleanupPatternCount
                            )
                        )
                    }
                }
            }
        }

        return matches.reduce(into: [:]) { result, entry in
            // Multiple verified receipts claiming one bundle are ambiguous;
            // do not choose a package manager by path order.
            guard entry.value.count == 1, let metadata = entry.value.first else { return }
            result[entry.key] = metadata
        }
    }

    static func hasVerifiedMacAppStoreReceipt(
        for app: InstalledApp,
        fileManager: FileManager = .default
    ) -> Bool {
        guard app.signature.status == .developerSigned,
              app.signature.isMacAppStoreSigned else { return false }

        let receipt = app.path
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("_MASReceipt", isDirectory: true)
            .appendingPathComponent("receipt", isDirectory: false)
        guard fileManager.fileExists(atPath: receipt.path),
              let values = try? receipt.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maximumReceiptBytes else { return false }

        let resolvedApp = app.path.standardizedFileURL.resolvingSymlinksInPath()
        let expected = resolvedApp
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("_MASReceipt", isDirectory: true)
            .appendingPathComponent("receipt", isDirectory: false)
            .standardizedFileURL
        return receipt.standardizedFileURL.resolvingSymlinksInPath().path == expected.path
    }

    private static func verifiedHomebrewCask(
        for app: InstalledApp,
        fileManager: FileManager,
        roots: [URL],
        signatureInspector: SignatureInspection,
        shouldCancel: () -> Bool
    ) -> HomebrewCaskInstallMetadata? {
        guard app.signature.status == .developerSigned,
              let selectedTeamID = nonEmpty(app.signature.teamIdentifier),
              !app.bundleIdentifier.isEmpty else { return nil }

        var matches: [HomebrewCaskInstallMetadata] = []
        for root in roots.sorted(by: { $0.path < $1.path }) {
            guard !shouldCancel() else { return nil }
            guard let caskDirectories = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for caskDirectory in caskDirectories
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                .prefix(maximumCaskCountPerRoot) {
                guard !shouldCancel() else { return nil }
                let token = caskDirectory.lastPathComponent
                guard isSafeCaskToken(token),
                      let directoryValues = try? caskDirectory.resourceValues(forKeys: [
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                      ]),
                      directoryValues.isDirectory == true,
                      directoryValues.isSymbolicLink != true else { continue }

                let receiptURL = caskDirectory
                    .appendingPathComponent(".metadata", isDirectory: true)
                    .appendingPathComponent("INSTALL_RECEIPT.json", isDirectory: false)
                guard let receipt = parseCaskReceipt(
                    at: receiptURL,
                    inside: caskDirectory,
                    fileManager: fileManager
                ),
                receipt.appNames.contains(app.path.lastPathComponent),
                let installedVersion = verifiedHomebrewArtifactVersion(
                    appName: app.path.lastPathComponent,
                    selectedApp: app,
                    selectedTeamID: selectedTeamID,
                    caskDirectory: caskDirectory,
                    fileManager: fileManager,
                    signatureInspector: signatureInspector,
                    shouldCancel: shouldCancel
                ) else { continue }

                matches.append(
                    HomebrewCaskInstallMetadata(
                        token: token,
                        version: receipt.version ?? installedVersion,
                        tap: receipt.tap,
                        receiptURL: receiptURL.standardizedFileURL,
                        extraCleanupPatternCount: receipt.extraCleanupPatternCount
                    )
                )
                if matches.count > 1 {
                    // Conflicting local managers are not resolved by guessing.
                    return nil
                }
            }
        }
        return matches.first
    }

    private static func verifiedHomebrewArtifactVersion(
        appName: String,
        selectedApp: InstalledApp,
        selectedTeamID: String,
        caskDirectory: URL,
        fileManager: FileManager,
        signatureInspector: SignatureInspection,
        shouldCancel: () -> Bool
    ) -> String? {
        guard let children = try? fileManager.contentsOfDirectory(
            at: caskDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let selectedPath = selectedApp.path.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        for versionDirectory in children
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .prefix(maximumVersionDirectoriesPerCask) {
            guard !shouldCancel() else { return nil }
            guard let directoryValues = try? versionDirectory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
              ]),
              directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else { continue }

            let artifact = versionDirectory.appendingPathComponent(appName, isDirectory: true)
            guard fileManager.fileExists(atPath: artifact.path),
                  let artifactValues = try? artifact.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                  ]) else { continue }

            if artifactValues.isSymbolicLink == true {
                guard artifact.standardizedFileURL.resolvingSymlinksInPath().path == selectedPath else {
                    continue
                }
                return versionDirectory.lastPathComponent
            }

            guard artifactValues.isDirectory == true,
                  Bundle(url: artifact)?.bundleIdentifier == selectedApp.bundleIdentifier else {
                continue
            }
            let artifactSignature = signatureInspector(artifact)
            guard artifactSignature.status == .developerSigned,
                  artifactSignature.teamIdentifier == selectedTeamID else { continue }
            return versionDirectory.lastPathComponent
        }
        return nil
    }

    private static func parseCaskReceipt(
        at receiptURL: URL,
        inside caskDirectory: URL,
        fileManager: FileManager
    ) -> ParsedCaskReceipt? {
        guard fileManager.fileExists(atPath: receiptURL.path),
              let values = try? receiptURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maximumReceiptBytes else { return nil }

        let resolvedCaskPath = caskDirectory.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let resolvedReceiptPath = receiptURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard resolvedReceiptPath.hasPrefix(resolvedCaskPath + "/.metadata/") else {
            return nil
        }

        guard let data = try? Data(contentsOf: receiptURL, options: [.mappedIfSafe]),
              data.count <= maximumReceiptBytes,
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let rawArtifacts = document["uninstall_artifacts"] as? [Any]
            ?? document["artifacts"] as? [Any]
            ?? []
        var appNames: Set<String> = []
        var cleanupPatterns: Set<String> = []

        for rawArtifact in rawArtifacts.prefix(maximumArtifactCount) {
            guard let artifact = rawArtifact as? [String: Any] else { continue }
            if let appValue = artifact["app"] {
                for entry in arrayValues(appValue) {
                    if let name = entry as? String, isSafeAppArtifactName(name) {
                        appNames.insert(name)
                    } else if let options = entry as? [String: Any],
                              let target = options["target"] as? String,
                              isSafeAppArtifactName(target) {
                        appNames.insert(target)
                    }
                }
            }

            guard let zapValue = artifact["zap"] else { continue }
            for zapEntry in arrayValues(zapValue) {
                guard let zap = zapEntry as? [String: Any],
                      let trashValue = zap["trash"] else { continue }
                for pathValue in arrayValues(trashValue) {
                    guard cleanupPatterns.count < maximumCleanupPatternCount,
                          let path = boundedString(pathValue, maximumLength: 4_096) else {
                        continue
                    }
                    cleanupPatterns.insert(path)
                }
            }
        }

        let source = document["source"] as? [String: Any]
        return ParsedCaskReceipt(
            appNames: appNames,
            version: boundedString(source?["version"], maximumLength: 128),
            tap: boundedString(source?["tap"], maximumLength: 256),
            extraCleanupPatternCount: cleanupPatterns.count
        )
    }

    private static func verifiedOfficialUninstaller(
        for app: InstalledApp,
        fileManager: FileManager,
        signatureInspector: SignatureInspection,
        shouldCancel: () -> Bool
    ) -> AppOfficialUninstaller? {
        guard app.signature.status == .developerSigned,
              let teamID = nonEmpty(app.signature.teamIdentifier) else { return nil }

        let selectedResolvedPath = app.path.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        var candidates: Set<UninstallerCandidate> = []
        let nestedRoots = [
            "Contents/Resources",
            "Contents/SharedSupport",
            "Contents/Helpers",
        ]
        for relativePath in nestedRoots {
            guard !shouldCancel() else { return nil }
            let root = app.path.appendingPathComponent(relativePath, isDirectory: true)
            guard let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children.prefix(maximumArtifactCount)
            where isUninstallerAppName(child.lastPathComponent) {
                candidates.insert(UninstallerCandidate(url: child, rank: 0))
            }
        }

        let siblingRoot = app.path.deletingLastPathComponent()
        let selectedNameTokens = normalizedSelectedAppNameTokens(app.appName)
        if let siblings = try? fileManager.contentsOfDirectory(
            at: siblingRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            for sibling in siblings.prefix(maximumSiblingCandidateCount) {
                guard !shouldCancel() else { return nil }
                guard sibling.standardizedFileURL.path != app.path.standardizedFileURL.path,
                      isUninstallerAppName(sibling.lastPathComponent) else { continue }
                let normalizedCandidate = normalizeName(
                    sibling.deletingPathExtension().lastPathComponent
                )
                guard selectedNameTokens.contains(where: normalizedCandidate.contains) else {
                    continue
                }
                candidates.insert(UninstallerCandidate(url: sibling, rank: 1))
            }
        }

        var verified: [(candidate: UninstallerCandidate, name: String)] = []
        for candidate in candidates.sorted(by: {
            if $0.rank == $1.rank { return $0.url.path < $1.url.path }
            return $0.rank < $1.rank
        }) {
            guard !shouldCancel() else { return nil }
            guard candidate.url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                  let values = try? candidate.url.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                  ]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }

            let candidateResolved = candidate.url.standardizedFileURL.resolvingSymlinksInPath()
            if candidate.rank == 0 {
                guard candidateResolved.path.hasPrefix(selectedResolvedPath + "/") else {
                    continue
                }
            } else {
                let resolvedParent = candidate.url.deletingLastPathComponent()
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
                let selectedParent = app.path.deletingLastPathComponent()
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
                guard resolvedParent == selectedParent else { continue }
            }

            let signature = signatureInspector(candidate.url)
            guard signature.status == .developerSigned,
                  signature.teamIdentifier == teamID else { continue }
            let name = (Bundle(url: candidate.url)?
                .object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (Bundle(url: candidate.url)?
                    .object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? candidate.url.deletingPathExtension().lastPathComponent
            verified.append((candidate, name))
        }

        guard let bestRank = verified.map(\.candidate.rank).min() else { return nil }
        let preferred = verified.filter { $0.candidate.rank == bestRank }
        guard preferred.count == 1, let match = preferred.first else { return nil }
        return AppOfficialUninstaller(
            name: match.name,
            url: match.candidate.url.standardizedFileURL
        )
    }

    private static func arrayValues(_ value: Any) -> [Any] {
        value as? [Any] ?? [value]
    }

    private static func isSafeCaskToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= 128 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@+._-")
        return token.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isSafeAppArtifactName(_ value: String) -> Bool {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.count <= 512,
              name == (name as NSString).lastPathComponent,
              name != ".",
              name != ".." else { return false }
        return URL(fileURLWithPath: name).pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }

    private static func boundedString(_ value: Any?, maximumLength: Int) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else { return nil }
        return trimmed
    }

    private static func nonEmpty(_ value: String?) -> String? {
        boundedString(value, maximumLength: 1_024)
    }

    private static func normalizedSelectedAppNameTokens(_ appName: String) -> [String] {
        let withoutVersion = appName.replacingOccurrences(
            of: #"\s+\d+(?:\.\d+)*$"#,
            with: "",
            options: .regularExpression
        )
        return Set([normalizeName(appName), normalizeName(withoutVersion)])
            .filter { $0.count >= 3 }
            .sorted()
    }

    private static func normalizeName(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static func isUninstallerAppName(_ value: String) -> Bool {
        guard URL(fileURLWithPath: value).pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return false
        }
        let name = value
            .deletingPathExtension
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let tokens = [
            "uninstall",
            "desinstaller",
            "desinstalar",
            "desinstalador",
            "卸载",
            "解除安裝",
            "アンインストール",
            "إلغاء التثبيت",
        ]
        return tokens.contains(where: name.contains)
    }
}

private extension String {
    var deletingPathExtension: String {
        (self as NSString).deletingPathExtension
    }
}

struct FileTreeStats: Equatable, Sendable {
    var allocatedSize: Int64
    var fileCount: Int
    var directoryCount: Int

    static let zero = FileTreeStats(
        allocatedSize: 0,
        fileCount: 0,
        directoryCount: 0
    )

    var itemCount: Int {
        fileCount + directoryCount
    }

    mutating func add(_ other: FileTreeStats) {
        allocatedSize += other.allocatedSize
        fileCount += other.fileCount
        directoryCount += other.directoryCount
    }
}

enum FileTreeStatsCalculator {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey,
    ]

    /// Computes the recursive reclaimable size and item counts for one selected
    /// root. Hidden entries are included because moving a parent directory to
    /// Trash removes them too. FileManager does not follow symbolic links; they
    /// count as one file and cannot escape the selected tree.
    static func calculate(
        at url: URL,
        shouldCancel: @escaping () -> Bool = { false }
    ) -> FileTreeStats? {
        guard !shouldCancel() else { return nil }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              let rootValues = try? url.resourceValues(forKeys: resourceKeys) else {
            return nil
        }

        let rootIsDirectory = isDirectory.boolValue && rootValues.isSymbolicLink != true
        guard rootIsDirectory else {
            return FileTreeStats(
                allocatedSize: allocatedSize(from: rootValues),
                fileCount: 1,
                directoryCount: 0
            )
        }

        var stats = FileTreeStats(
            allocatedSize: 0,
            fileCount: 0,
            directoryCount: 1
        )

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in !shouldCancel() }
        ) else {
            return stats
        }

        for case let itemURL as URL in enumerator {
            guard !shouldCancel() else { return nil }
            guard let values = try? itemURL.resourceValues(forKeys: resourceKeys) else {
                continue
            }

            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                stats.fileCount += 1
                stats.allocatedSize += allocatedSize(from: values)
            } else if values.isDirectory == true {
                stats.directoryCount += 1
            } else {
                stats.fileCount += 1
                stats.allocatedSize += allocatedSize(from: values)
            }
        }

        return stats
    }

    private static func allocatedSize(from values: URLResourceValues) -> Int64 {
        Int64(
            values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0
        )
    }
}

struct AppSizeCacheFingerprint: Codable, Equatable {
    let modificationDate: TimeInterval?
    let version: String?
    let buildNumber: String?

    init(app: InstalledApp) {
        modificationDate = app.modifiedAt?.timeIntervalSinceReferenceDate
        version = app.version
        buildNumber = app.buildNumber
    }
}

struct AppSizeCacheEntry: Codable, Equatable {
    let fingerprint: AppSizeCacheFingerprint
    let size: Int64
    let cachedAt: TimeInterval
}

/// Small, non-authoritative cache for expensive recursive app-bundle sizes.
/// Security metadata is deliberately excluded: signatures and entitlements
/// are revalidated on every discovery pass and can never be restored from a
/// writable cache file.
/// `entries` is the only mutable shared state and every access is serialized
/// by `lock`; cache-file writes use atomic replacement and are non-authoritative.
final class AppSizeCacheStore: @unchecked Sendable {
    private static let maximumCacheBytes = 4_000_000
    private static let maximumEntryCount = 5_000
    private static let defaultMaximumAge: TimeInterval = 7 * 24 * 60 * 60
    private static let logger = os.Logger(
        subsystem: ProductIdentity.bundleIdentifier,
        category: "app-size-cache"
    )

    private let cacheURL: URL
    private let maximumAge: TimeInterval
    private let lock = NSLock()
    private var entries: [String: AppSizeCacheEntry]

    init(
        cacheURL: URL = AppSizeCacheStore.defaultCacheURL,
        maximumAge: TimeInterval = AppSizeCacheStore.defaultMaximumAge
    ) {
        self.cacheURL = cacheURL
        self.maximumAge = maximumAge
        self.entries = Self.loadEntries(from: cacheURL)
    }

    func cachedSize(for app: InstalledApp, now: Date = Date()) -> Int64? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[app.id],
              entry.size >= 0,
              entry.fingerprint == AppSizeCacheFingerprint(app: app) else {
            return nil
        }

        let age = now.timeIntervalSinceReferenceDate - entry.cachedAt
        guard age >= 0, age <= maximumAge else { return nil }
        return entry.size
    }

    func record(size: Int64, for app: InstalledApp, now: Date = Date()) {
        guard size >= 0 else { return }
        let entry = AppSizeCacheEntry(
            fingerprint: AppSizeCacheFingerprint(app: app),
            size: size,
            cachedAt: now.timeIntervalSinceReferenceDate
        )

        lock.lock()
        entries[app.id] = entry
        trimIfNeeded()
        lock.unlock()
    }

    func prune(keeping appIDs: Set<String>) {
        lock.lock()
        entries = entries.filter { appIDs.contains($0.key) }
        lock.unlock()
    }

    func persist() {
        lock.lock()
        let snapshot = entries
        lock.unlock()

        guard let data = try? JSONEncoder().encode(snapshot),
              data.count <= Self.maximumCacheBytes else { return }

        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            Self.logger.warning("Could not persist app-size cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func trimIfNeeded() {
        guard entries.count > Self.maximumEntryCount else { return }
        entries = Dictionary(
            uniqueKeysWithValues: entries
                .sorted { $0.value.cachedAt > $1.value.cachedAt }
                .prefix(Self.maximumEntryCount)
                .map { ($0.key, $0.value) }
        )
    }

    private static func loadEntries(from url: URL) -> [String: AppSizeCacheEntry] {
        guard let data = try? Data(contentsOf: url),
              data.count <= maximumCacheBytes,
              let decoded = try? JSONDecoder().decode([String: AppSizeCacheEntry].self, from: data) else {
            return [:]
        }

        let valid = decoded.filter { !$0.key.isEmpty && $0.value.size >= 0 }
        guard valid.count > maximumEntryCount else { return valid }
        return Dictionary(
            uniqueKeysWithValues: valid
                .sorted { $0.value.cachedAt > $1.value.cachedAt }
                .prefix(maximumEntryCount)
                .map { ($0.key, $0.value) }
        )
    }

    private static var defaultCacheURL: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ProductIdentity.bundleIdentifier
        return root
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("installed-app-sizes.json", isDirectory: false)
    }
}

final class AppInfoFetcher: Sendable {
    static let shared = AppInfoFetcher()
    private let sizeCache = AppSizeCacheStore()

    private static let protectedBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.finder", "com.apple.AppStore",
        "com.apple.systempreferences", "com.apple.Terminal",
        "com.apple.ActivityMonitor", "com.apple.dt.Xcode",
        "com.apple.mail", "com.apple.iCal", "com.apple.AddressBook",
        "com.apple.Preview", "com.apple.TextEdit", "com.apple.calculator",
        "com.apple.MobileSMS", "com.apple.FaceTime", "com.apple.Music",
        "com.apple.TV", "com.apple.Podcasts", "com.apple.News",
        "com.apple.Maps", "com.apple.Photos", "com.apple.Notes",
        "com.apple.reminders", "com.apple.Stocks", "com.apple.Home",
        "com.apple.weather", "com.apple.clock", "com.apple.Passwords",
    ]

    static func isProtectedBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        protectedBundleIDs.contains(bundleIdentifier)
    }

    private init() {}

    /// Compatibility API used by the CLI: returns a fully sized list. The UI
    /// uses `discoverInstalledApps` and progressively fills only cache misses
    /// so the first useful frame does not wait on every bundle tree.
    func fetchInstalledApps() -> [InstalledApp] {
        var apps = discoverInstalledApps()
        for index in apps.indices {
            if let inspected = inspectSignature(for: apps[index]) {
                apps[index] = inspected
            }
            guard apps[index].needsSizeCalculation else { continue }
            if let calculated = calculateSize(for: apps[index]) {
                apps[index] = calculated
            } else {
                apps[index] = apps[index].replacingSize(0, state: .unavailable)
            }
        }
        sizeCache.prune(keeping: Set(apps.map(\.id)))
        sizeCache.persist()
        return apps
    }

    func discoverInstalledApps(
        useSizeCache: Bool = true,
        shouldCancel: @escaping () -> Bool = { false }
    ) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        var seenBundleIDs: Set<String> = []

        // `/Users/Shared` is where game launchers (Riot Client, some Blizzard
        // and Epic helpers) drop their `.app` bundles instead of /Applications,
        // so it has to be scanned for those to show up in the uninstaller
        // (issue #123). It can also hold multi-gigabyte game data trees, so it
        // is depth-bounded — the launcher bundles live within the first few
        // levels (e.g. /Users/Shared/Riot Games/Riot Client.app at depth 2);
        // the bound is kept generous (6) so a vendor that nests one or two
        // directories deeper is still found, while the multi-gigabyte asset
        // trees below that are not walked.
        let searchRoots: [(path: String, maxDepth: Int)] = [
            ("/Applications", 8),
            ("\(home)/Applications", 8),
            ("/System/Applications", 8),
            ("/Users/Shared", 6),
        ]

        for (searchPath, maxDepth) in searchRoots {
            guard !shouldCancel() else { return [] }
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: searchPath),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard !shouldCancel() else { return [] }
                guard url.pathExtension == "app" else {
                    // Stop descending once past the depth bound so a deep data
                    // tree (e.g. a game's assets) doesn't get fully walked.
                    if enumerator.level >= maxDepth {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                // Skip subdirectories inside .app bundles
                enumerator.skipDescendants()

                // Skip system/protected apps
                if url.path.hasPrefix("/System") { continue }

                guard let app = loadAppInfo(from: url, useSizeCache: useSizeCache),
                      !seenBundleIDs.contains(app.bundleIdentifier),
                      !AppSelfRemovalPolicy.isCurrentApplication(
                        bundleIdentifier: app.bundleIdentifier
                      ),
                      !Self.isProtectedBundleIdentifier(app.bundleIdentifier) else { continue }

                seenBundleIDs.insert(app.bundleIdentifier)
                apps.append(app)
            }
        }

        return apps.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    /// Build an `InstalledApp` from a single bundle URL. Used by the Finder
    /// Services handler ("Uninstall with AppSift") to resolve a right-clicked
    /// .app into the uninstaller without re-scanning every app. Enforces the
    /// same protections as the full scan: no /System apps, and no protected
    /// Apple bundle IDs (Safari, Mail, Xcode, App Store, …) — so a right-click
    /// can never route a system app into the uninstaller.
    func fetchApp(at url: URL) -> InstalledApp? {
        guard var app = discoverApp(at: url) else { return nil }
        app = inspectSignature(for: app) ?? app
        return calculateSize(for: app) ?? app
    }

    /// Fast single-app variant used by Finder Services. It resolves identity
    /// and any valid cached size without walking or validating the bundle.
    func discoverApp(at url: URL, useSizeCache: Bool = true) -> InstalledApp? {
        guard url.pathExtension == "app", !url.path.hasPrefix("/System") else { return nil }
        guard let app = loadAppInfo(from: url, useSizeCache: useSizeCache),
              !AppSelfRemovalPolicy.isCurrentApplication(
                bundleIdentifier: app.bundleIdentifier
              ),
              !Self.isProtectedBundleIdentifier(app.bundleIdentifier) else { return nil }
        return app
    }

    func calculateSize(
        for app: InstalledApp,
        shouldCancel: @escaping () -> Bool = { false }
    ) -> InstalledApp? {
        guard !shouldCancel() else { return nil }
        if !app.needsSizeCalculation { return app }
        guard let stats = FileTreeStatsCalculator.calculate(
            at: app.path,
            shouldCancel: shouldCancel
        ) else { return nil }

        sizeCache.record(size: stats.allocatedSize, for: app)
        return app.replacingSize(stats.allocatedSize, state: .calculated)
    }

    func inspectSignature(
        for app: InstalledApp,
        shouldCancel: @escaping () -> Bool = { false }
    ) -> InstalledApp? {
        guard !shouldCancel() else { return nil }
        if !app.needsSignatureInspection { return app }
        let signature = AppSignatureInspector.inspect(at: app.path)
        guard !shouldCancel() else { return nil }
        return app.replacingSignature(signature)
    }

    func persistSizeCache(keeping apps: [InstalledApp]) {
        sizeCache.prune(keeping: Set(apps.map(\.id)))
        sizeCache.persist()
    }

    private func loadAppInfo(from url: URL, useSizeCache: Bool) -> InstalledApp? {
        guard let bundle = Bundle(url: url) else { return nil }

        let bundleID = bundle.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)

        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let version = Self.nonEmptyBundleString(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString"))
        let buildNumber = Self.nonEmptyBundleString(bundle.object(forInfoDictionaryKey: "CFBundleVersion"))
        let minimumSystemVersion = Self.nonEmptyBundleString(bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion"))
        let lastUsedAt = AppUsageMetadataReader.lastUsedDate(at: url)
        let unresolved = InstalledApp(
            appName: appName,
            bundleIdentifier: bundleID,
            path: url,
            icon: icon,
            size: 0,
            sizeState: .pending,
            version: version,
            buildNumber: buildNumber,
            minimumSystemVersion: minimumSystemVersion,
            createdAt: values?.creationDate,
            modifiedAt: values?.contentModificationDate,
            lastUsedAt: lastUsedAt,
            signature: .unknown,
            signatureInspectionState: .pending
        )

        guard useSizeCache,
              let cachedSize = sizeCache.cachedSize(for: unresolved) else {
            return unresolved
        }
        return unresolved.replacingSize(cachedSize, state: .cached)
    }

    private static func nonEmptyBundleString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

}
