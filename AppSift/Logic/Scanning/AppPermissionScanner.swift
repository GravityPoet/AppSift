import Darwin
import Foundation
import SQLite3

enum AppPermissionDatabaseScope: String, Codable, Hashable, Sendable {
    case user
    case system
}

enum AppPermissionDatabaseStatus: String, Codable, Hashable, Sendable {
    case available
    case notFound
    case permissionDenied
    case unsupportedSchema
    case readFailed
}

struct AppPermissionDatabaseSource: Codable, Hashable, Sendable {
    let scope: AppPermissionDatabaseScope
    let path: String
    let status: AppPermissionDatabaseStatus
    let rowCount: Int
    let sqliteResultCode: Int32?
}

enum AppPermissionDecision: String, Codable, Hashable, Sendable {
    case allowed
    case denied
    case limited
    case unknown

    init(authorizationValue: Int64) {
        switch authorizationValue {
        case 0: self = .denied
        case 2: self = .allowed
        case 3: self = .limited
        default: self = .unknown
        }
    }
}

enum AppPermissionCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case systemControl
    case mediaAndSensors
    case personalData
    case filesAndFolders
    case other
}

/// A future-compatible TCC service identifier. Known services receive a
/// localized title and a fixed `tccutil` mapping; unknown identifiers remain
/// visible as local evidence but never become executable arguments.
struct AppPermissionService: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let accessibility = Self(rawValue: "kTCCServiceAccessibility")
    static let addressBook = Self(rawValue: "kTCCServiceAddressBook")
    static let appData = Self(rawValue: "kTCCServiceSystemPolicyAppData")
    static let appManagement = Self(rawValue: "kTCCServiceSystemPolicyAppBundles")
    static let appleEvents = Self(rawValue: "kTCCServiceAppleEvents")
    static let audioCapture = Self(rawValue: "kTCCServiceAudioCapture")
    static let bluetooth = Self(rawValue: "kTCCServiceBluetoothAlways")
    static let calendar = Self(rawValue: "kTCCServiceCalendar")
    static let camera = Self(rawValue: "kTCCServiceCamera")
    static let contactsFull = Self(rawValue: "kTCCServiceContactsFull")
    static let contactsLimited = Self(rawValue: "kTCCServiceContactsLimited")
    static let desktop = Self(rawValue: "kTCCServiceSystemPolicyDesktopFolder")
    static let developerTool = Self(rawValue: "kTCCServiceDeveloperTool")
    static let documents = Self(rawValue: "kTCCServiceSystemPolicyDocumentsFolder")
    static let downloads = Self(rawValue: "kTCCServiceSystemPolicyDownloadsFolder")
    static let endpointSecurity = Self(rawValue: "kTCCServiceEndpointSecurityClient")
    static let fileProviderDomain = Self(rawValue: "kTCCServiceFileProviderDomain")
    static let focusStatus = Self(rawValue: "kTCCServiceFocusStatus")
    static let fullDiskAccess = Self(rawValue: "kTCCServiceSystemPolicyAllFiles")
    static let gameCenterFriends = Self(rawValue: "kTCCServiceGameCenterFriends")
    static let homeKit = Self(rawValue: "kTCCServiceWillow")
    static let inputMonitoring = Self(rawValue: "kTCCServiceListenEvent")
    static let location = Self(rawValue: "kTCCServiceLocation")
    static let mediaLibrary = Self(rawValue: "kTCCServiceMediaLibrary")
    static let microphone = Self(rawValue: "kTCCServiceMicrophone")
    static let motion = Self(rawValue: "kTCCServiceMotion")
    static let networkVolumes = Self(rawValue: "kTCCServiceSystemPolicyNetworkVolumes")
    static let passkeys = Self(rawValue: "kTCCServiceWebBrowserPublicKeyCredential")
    static let photos = Self(rawValue: "kTCCServicePhotos")
    static let photosAdd = Self(rawValue: "kTCCServicePhotosAdd")
    static let postEvent = Self(rawValue: "kTCCServicePostEvent")
    static let reminders = Self(rawValue: "kTCCServiceReminders")
    static let removableVolumes = Self(rawValue: "kTCCServiceSystemPolicyRemovableVolumes")
    static let remoteDesktop = Self(rawValue: "kTCCServiceRemoteDesktop")
    static let screenRecording = Self(rawValue: "kTCCServiceScreenCapture")
    static let siri = Self(rawValue: "kTCCServiceSiri")
    static let speechRecognition = Self(rawValue: "kTCCServiceSpeechRecognition")
    static let systemAdministration = Self(rawValue: "kTCCServiceSystemPolicySysAdminFiles")
    static let userTracking = Self(rawValue: "kTCCServiceUserTracking")
    static let virtualMachineNetworking = Self(rawValue: "kTCCServiceVirtualMachineNetworking")

    var displayNameKey: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .addressBook, .contactsFull, .contactsLimited: return "Contacts"
        case .appData: return "Other Apps' Data"
        case .appManagement: return "App Management"
        case .appleEvents: return "Automation"
        case .audioCapture: return "System Audio Recording"
        case .bluetooth: return "Bluetooth"
        case .calendar: return "Calendar"
        case .camera: return "Camera"
        case .desktop: return "Desktop Folder"
        case .developerTool: return "Developer Tools"
        case .documents: return "Documents Folder"
        case .downloads: return "Downloads Folder"
        case .endpointSecurity: return "Endpoint Security"
        case .fileProviderDomain: return "File Provider Data"
        case .focusStatus: return "Focus Status"
        case .fullDiskAccess: return "Full Disk Access"
        case .gameCenterFriends: return "Game Center Friends"
        case .homeKit: return "Home Data"
        case .inputMonitoring: return "Input Monitoring"
        case .location: return "Location"
        case .mediaLibrary: return "Media Library"
        case .microphone: return "Microphone"
        case .motion: return "Motion & Fitness"
        case .networkVolumes: return "Network Volumes"
        case .passkeys: return "Passkeys"
        case .photos: return "Photos"
        case .photosAdd: return "Add to Photos"
        case .postEvent: return "Keyboard Control"
        case .reminders: return "Reminders"
        case .removableVolumes: return "Removable Volumes"
        case .remoteDesktop: return "Remote Desktop"
        case .screenRecording: return "Screen & System Audio Recording"
        case .siri: return "Siri"
        case .speechRecognition: return "Speech Recognition"
        case .systemAdministration: return "System Administration Files"
        case .userTracking: return "Tracking"
        case .virtualMachineNetworking: return "Virtual Machine Networking"
        default:
            return rawValue.replacingOccurrences(of: "kTCCService", with: "")
        }
    }

    var category: AppPermissionCategory {
        switch self {
        case .accessibility, .appManagement, .appleEvents, .developerTool,
             .endpointSecurity, .fullDiskAccess, .inputMonitoring, .postEvent,
             .remoteDesktop, .virtualMachineNetworking:
            return .systemControl
        case .audioCapture, .bluetooth, .camera, .microphone, .motion,
             .screenRecording, .speechRecognition:
            return .mediaAndSensors
        case .addressBook, .calendar, .contactsFull, .contactsLimited,
             .focusStatus, .gameCenterFriends, .homeKit, .location,
             .mediaLibrary, .passkeys, .photos, .photosAdd, .reminders,
             .siri, .userTracking:
            return .personalData
        case .appData, .desktop, .documents, .downloads, .fileProviderDomain,
             .networkVolumes, .removableVolumes, .systemAdministration:
            return .filesAndFolders
        default:
            return .other
        }
    }

    var isHighImpact: Bool {
        switch self {
        case .accessibility, .appData, .appManagement, .appleEvents,
             .audioCapture, .camera, .endpointSecurity, .fullDiskAccess,
             .inputMonitoring, .microphone, .postEvent, .remoteDesktop,
             .screenRecording, .systemAdministration:
            return true
        default:
            return false
        }
    }

    /// Only service names documented by Apple for `tccutil reset` are
    /// executable. Unknown TCC rows stay read-only.
    var resetServiceName: String? {
        guard rawValue.hasPrefix("kTCCService") else { return nil }
        let value = String(rawValue.dropFirst("kTCCService".count))
        return Self.resetServiceAllowlist.contains(value) ? value : nil
    }

    var systemSettingsAnchor: String? {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .addressBook, .contactsFull, .contactsLimited: return "Privacy_Contacts"
        case .appData, .appManagement: return "Privacy_AppBundles"
        case .appleEvents: return "Privacy_Automation"
        case .audioCapture: return "Privacy_AudioCapture"
        case .bluetooth: return "Privacy_Bluetooth"
        case .calendar: return "Privacy_Calendars"
        case .camera: return "Privacy_Camera"
        case .desktop, .documents, .downloads, .fileProviderDomain,
             .networkVolumes, .removableVolumes: return "Privacy_FilesAndFolders"
        case .developerTool: return "Privacy_DevTools"
        case .fullDiskAccess: return "Privacy_AllFiles"
        case .inputMonitoring, .postEvent: return "Privacy_ListenEvent"
        case .location: return "Privacy_LocationServices"
        case .mediaLibrary: return "Privacy_MediaLibrary"
        case .microphone: return "Privacy_Microphone"
        case .motion: return "Privacy_Motion"
        case .photos, .photosAdd: return "Privacy_Photos"
        case .reminders: return "Privacy_Reminders"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .speechRecognition: return "Privacy_SpeechRecognition"
        default: return nil
        }
    }

    private static let resetServiceAllowlist: Set<String> = [
        "Accessibility", "AddressBook", "AppleEvents", "AudioCapture",
        "BluetoothAlways", "Calendar", "Camera", "DeveloperTool",
        "EnergyKitGuidance", "ExternalCameraMedia", "FileProviderDomain",
        "FileProviderPresence", "FocusStatus", "GameCenterFriends", "HomeKit",
        "ListenEvent", "MediaLibrary", "Microphone", "Motion", "Photos",
        "PhotosAdd", "PostEvent", "Reminders", "RemoteDesktop", "ScreenCapture",
        "Siri", "SpeechRecognition", "SystemPolicyAllFiles",
        "SystemPolicyAppBundles", "SystemPolicyAppData",
        "SystemPolicyDesktopFolder", "SystemPolicyDocumentsFolder",
        "SystemPolicyDownloadsFolder", "SystemPolicyNetworkVolumes",
        "SystemPolicyRemovableVolumes", "SystemPolicySysAdminFiles",
        "UserTracking", "VirtualMachineNetworking", "VoiceBanking",
        "WebBrowserPublicKeyCredential",
    ]
}

struct AppPermissionRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let scope: AppPermissionDatabaseScope
    let service: AppPermissionService
    let clientIdentifier: String
    let clientType: Int32
    let decision: AppPermissionDecision
    let authorizationValue: Int64
    let authorizationReason: Int64?
    let indirectObjectIdentifier: String?
    let lastModified: Date?

    init(
        scope: AppPermissionDatabaseScope,
        service: AppPermissionService,
        clientIdentifier: String,
        clientType: Int32,
        decision: AppPermissionDecision,
        authorizationValue: Int64,
        authorizationReason: Int64?,
        indirectObjectIdentifier: String?,
        lastModified: Date?
    ) {
        self.scope = scope
        self.service = service
        self.clientIdentifier = clientIdentifier
        self.clientType = clientType
        self.decision = decision
        self.authorizationValue = authorizationValue
        self.authorizationReason = authorizationReason
        self.indirectObjectIdentifier = indirectObjectIdentifier
        self.lastModified = lastModified
        self.id = [
            scope.rawValue,
            service.rawValue,
            String(clientType),
            clientIdentifier,
            indirectObjectIdentifier ?? "",
        ].joined(separator: "|")
    }
}

struct AppPermissionDeclaration: Identifiable, Codable, Hashable, Sendable {
    let service: AppPermissionService
    let propertyListKey: String
    let purpose: String

    var id: String { "\(service.rawValue)|\(propertyListKey)" }
}

struct AppPermissionApplicationReference: Hashable, Sendable {
    let name: String
    let bundleIdentifier: String
    let url: URL
    let version: String?

    init(app: InstalledApp) {
        name = app.appName
        bundleIdentifier = app.bundleIdentifier
        url = app.path.standardizedFileURL
        version = app.versionSummary
    }

    init(name: String, bundleIdentifier: String, url: URL, version: String? = nil) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.url = url.standardizedFileURL
        self.version = version
    }
}

struct AppPermissionClient: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let clientIdentifier: String
    let clientType: Int32
    let bundleIdentifier: String?
    let applicationURL: URL?
    let version: String?
    let isInstalled: Bool
    let records: [AppPermissionRecord]
    let declarations: [AppPermissionDeclaration]

    var allowedCount: Int { records.count { $0.decision == .allowed } }
    var deniedCount: Int { records.count { $0.decision == .denied } }
    var highImpactAllowedCount: Int {
        records.count { $0.decision == .allowed && $0.service.isHighImpact }
    }
    var isStale: Bool { !isInstalled && !records.isEmpty }
    var hasObservedDecision: Bool { !records.isEmpty }
}

struct AppPermissionScanResult: Sendable {
    let clients: [AppPermissionClient]
    let sources: [AppPermissionDatabaseSource]
    let scannedAt: Date
    let wasTruncated: Bool
    let wasCancelled: Bool

    var recordCount: Int { clients.reduce(0) { $0 + $1.records.count } }
    var allowedCount: Int { clients.reduce(0) { $0 + $1.allowedCount } }
    var deniedCount: Int { clients.reduce(0) { $0 + $1.deniedCount } }
    var highImpactAllowedCount: Int {
        clients.reduce(0) { $0 + $1.highImpactAllowedCount }
    }
    var staleClientCount: Int { clients.count { $0.isStale } }
    var hasReadableDatabase: Bool {
        sources.contains { $0.status == .available }
    }
}

enum AppPermissionScanner {
    struct DatabaseLocation: Hashable, Sendable {
        let scope: AppPermissionDatabaseScope
        let url: URL
    }

    private struct ClientKey: Hashable {
        let identifier: String
        let type: Int32

        var id: String { "\(type)|\(identifier)" }
    }

    private struct DatabaseReadResult {
        let records: [AppPermissionRecord]
        let source: AppPermissionDatabaseSource
        let wasTruncated: Bool
        let wasCancelled: Bool
    }

    static var defaultDatabaseLocations: [DatabaseLocation] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            DatabaseLocation(
                scope: .user,
                url: home
                    .appendingPathComponent("Library/Application Support/com.apple.TCC")
                    .appendingPathComponent("TCC.db")
            ),
            DatabaseLocation(
                scope: .system,
                url: URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")
            ),
        ]
    }

    static func scan(
        applications: [AppPermissionApplicationReference],
        databaseLocations: [DatabaseLocation] = defaultDatabaseLocations,
        maximumRowsPerDatabase: Int = 50_000
    ) -> AppPermissionScanResult {
        let boundedMaximum = min(max(1, maximumRowsPerDatabase), 100_000)
        var records: [AppPermissionRecord] = []
        var sources: [AppPermissionDatabaseSource] = []
        var wasTruncated = false
        var wasCancelled = false

        for location in databaseLocations {
            if Task.isCancelled {
                wasCancelled = true
                break
            }
            let result = readDatabase(
                location,
                maximumRows: boundedMaximum
            )
            records.append(contentsOf: result.records)
            sources.append(result.source)
            wasTruncated = wasTruncated || result.wasTruncated
            wasCancelled = wasCancelled || result.wasCancelled
        }

        return AppPermissionScanResult(
            clients: buildClients(records: records, applications: applications),
            sources: sources,
            scannedAt: Date(),
            wasTruncated: wasTruncated,
            wasCancelled: wasCancelled
        )
    }

    static func declarations(
        for application: AppPermissionApplicationReference
    ) -> [AppPermissionDeclaration] {
        let plistURL = application.url
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let values = try? plistURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
        ]),
        values.isRegularFile == true,
        let size = values.fileSize,
        size > 0,
        size <= 4_194_304,
        let data = try? Data(contentsOf: plistURL, options: .mappedIfSafe),
        let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ),
        let dictionary = propertyList as? [String: Any] else {
            return []
        }

        return declarationKeys.compactMap { propertyListKey, service in
            guard let rawPurpose = dictionary[propertyListKey] as? String,
                  let purpose = normalizedPurpose(rawPurpose) else {
                return nil
            }
            return AppPermissionDeclaration(
                service: service,
                propertyListKey: propertyListKey,
                purpose: purpose
            )
        }
        .sorted {
            if $0.service.rawValue != $1.service.rawValue {
                return $0.service.rawValue < $1.service.rawValue
            }
            return $0.propertyListKey < $1.propertyListKey
        }
    }

    private static func readDatabase(
        _ location: DatabaseLocation,
        maximumRows: Int
    ) -> DatabaseReadResult {
        // `SQLITE_OPEN_NOFOLLOW` rejects a symlink in any path component.
        // macOS temporary paths commonly begin with `/var` (a symlink to
        // `/private/var`), so resolve only the parent directory and preserve
        // the final component for the `lstat` + NOFOLLOW boundary below.
        let sourceURL = location.url.standardizedFileURL
        let standardizedURL = resolvingParentSymlinks(of: sourceURL)
        var information = stat()
        guard lstat(standardizedURL.path, &information) == 0 else {
            let status: AppPermissionDatabaseStatus = errno == ENOENT
                ? .notFound
                : (errno == EACCES || errno == EPERM ? .permissionDenied : .readFailed)
            return unavailableResult(location, status: status, code: nil)
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            return unavailableResult(location, status: .readFailed, code: nil)
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW
        let openResult = sqlite3_open_v2(
            standardizedURL.path,
            &database,
            flags,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            let status: AppPermissionDatabaseStatus = [
                SQLITE_AUTH,
                SQLITE_PERM,
                SQLITE_CANTOPEN,
            ].contains(openResult) ? .permissionDenied : .readFailed
            return unavailableResult(location, status: status, code: openResult)
        }
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 500)
        guard sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK,
              let columns = accessTableColumns(database),
              ["service", "client", "client_type", "auth_value"]
                .allSatisfy(columns.contains) else {
            return unavailableResult(
                location,
                status: .unsupportedSchema,
                code: sqlite3_errcode(database)
            )
        }

        let authorizationReason = columns.contains("auth_reason")
            ? "auth_reason"
            : "NULL AS auth_reason"
        let indirectObject = columns.contains("indirect_object_identifier")
            ? "indirect_object_identifier"
            : "NULL AS indirect_object_identifier"
        let lastModified = columns.contains("last_modified")
            ? "last_modified"
            : "NULL AS last_modified"
        let order = columns.contains("last_modified")
            ? " ORDER BY last_modified DESC"
            : ""
        let sql = """
        SELECT service, client, client_type, auth_value,
               \(authorizationReason), \(indirectObject), \(lastModified)
        FROM access\(order)
        LIMIT ?
        """

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            return unavailableResult(
                location,
                status: .readFailed,
                code: prepareResult
            )
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(maximumRows + 1))

        var records: [AppPermissionRecord] = []
        records.reserveCapacity(min(maximumRows, 2_000))
        var cancelled = false
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            if Task.isCancelled {
                cancelled = true
                break
            }
            if let record = record(from: statement, scope: location.scope) {
                records.append(record)
            }
            if records.count > maximumRows { break }
            stepResult = sqlite3_step(statement)
        }

        guard cancelled || records.count > maximumRows || stepResult == SQLITE_DONE else {
            return DatabaseReadResult(
                records: [],
                source: AppPermissionDatabaseSource(
                    scope: location.scope,
                    path: standardizedURL.path,
                    status: .readFailed,
                    rowCount: 0,
                    sqliteResultCode: stepResult
                ),
                wasTruncated: false,
                wasCancelled: false
            )
        }

        let truncated = records.count > maximumRows
        if truncated { records.removeLast(records.count - maximumRows) }
        return DatabaseReadResult(
            records: records,
            source: AppPermissionDatabaseSource(
                scope: location.scope,
                path: standardizedURL.path,
                status: .available,
                rowCount: records.count,
                sqliteResultCode: nil
            ),
            wasTruncated: truncated,
            wasCancelled: cancelled
        )
    }

    private static func unavailableResult(
        _ location: DatabaseLocation,
        status: AppPermissionDatabaseStatus,
        code: Int32?
    ) -> DatabaseReadResult {
        DatabaseReadResult(
            records: [],
            source: AppPermissionDatabaseSource(
                scope: location.scope,
                path: location.url.standardizedFileURL.path,
                status: status,
                rowCount: 0,
                sqliteResultCode: code
            ),
            wasTruncated: false,
            wasCancelled: false
        )
    }

    private static func resolvingParentSymlinks(of sourceURL: URL) -> URL {
        let parent = sourceURL.deletingLastPathComponent()
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = parent.path.withCString { path in
            buffer.withUnsafeMutableBufferPointer { storage in
                realpath(path, storage.baseAddress) != nil
            }
        }
        guard resolved else { return sourceURL }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            .appendingPathComponent(sourceURL.lastPathComponent)
    }

    private static func accessTableColumns(_ database: OpaquePointer) -> Set<String>? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(access)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let value = textColumn(statement, index: 1), !value.isEmpty {
                columns.insert(value)
            }
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? columns : nil
    }

    private static func record(
        from statement: OpaquePointer,
        scope: AppPermissionDatabaseScope
    ) -> AppPermissionRecord? {
        guard let rawService = textColumn(statement, index: 0),
              let client = textColumn(statement, index: 1),
              !rawService.isEmpty,
              rawService.count <= 256,
              !client.isEmpty,
              client.count <= 4_096 else {
            return nil
        }
        let clientType = sqlite3_column_int(statement, 2)
        let authorizationValue = sqlite3_column_int64(statement, 3)
        let authorizationReason = sqlite3_column_type(statement, 4) == SQLITE_NULL
            ? nil
            : sqlite3_column_int64(statement, 4)
        let indirectObject: String? = {
            guard let value = textColumn(statement, index: 5),
                  value != "UNUSED",
                  value.count <= 4_096 else { return nil }
            return value
        }()
        let lastModified: Date? = {
            guard sqlite3_column_type(statement, 6) != SQLITE_NULL else { return nil }
            let seconds = sqlite3_column_int64(statement, 6)
            guard seconds > 946_684_800,
                  seconds < Int64(Date().timeIntervalSince1970) + 31_536_000 else {
                return nil
            }
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }()

        return AppPermissionRecord(
            scope: scope,
            service: AppPermissionService(rawValue: rawService),
            clientIdentifier: client,
            clientType: clientType,
            decision: AppPermissionDecision(authorizationValue: authorizationValue),
            authorizationValue: authorizationValue,
            authorizationReason: authorizationReason,
            indirectObjectIdentifier: indirectObject,
            lastModified: lastModified
        )
    }

    private static func textColumn(
        _ statement: OpaquePointer,
        index: Int32
    ) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(validatingUTF8: UnsafeRawPointer(pointer)
            .assumingMemoryBound(to: CChar.self))
    }

    private static func buildClients(
        records: [AppPermissionRecord],
        applications: [AppPermissionApplicationReference]
    ) -> [AppPermissionClient] {
        var applicationsByBundleIdentifier: [String: AppPermissionApplicationReference] = [:]
        for application in applications.sorted(by: applicationPreference) {
            guard !application.bundleIdentifier.isEmpty,
                  applicationsByBundleIdentifier[application.bundleIdentifier] == nil else {
                continue
            }
            applicationsByBundleIdentifier[application.bundleIdentifier] = application
        }

        let declarationsByBundleIdentifier = Dictionary(
            uniqueKeysWithValues: applicationsByBundleIdentifier.map { key, application in
                (key, declarations(for: application))
            }
        )
        let recordsByClient = Dictionary(grouping: records) {
            ClientKey(identifier: $0.clientIdentifier, type: $0.clientType)
        }
        var clients: [AppPermissionClient] = recordsByClient.map { key, records in
            let application = matchedApplication(
                for: key,
                applicationsByBundleIdentifier: applicationsByBundleIdentifier
            )
            let bundleIdentifier = key.type == 0
                ? key.identifier
                : application?.bundleIdentifier
            let name = application?.name ?? fallbackClientName(for: key)
            return AppPermissionClient(
                id: key.id,
                name: name,
                clientIdentifier: key.identifier,
                clientType: key.type,
                bundleIdentifier: bundleIdentifier,
                applicationURL: application?.url,
                version: application?.version,
                isInstalled: application != nil,
                records: records.sorted(by: recordPreference),
                declarations: bundleIdentifier.flatMap {
                    declarationsByBundleIdentifier[$0]
                } ?? []
            )
        }

        let existingBundleIdentifiers = Set(
            clients.compactMap { $0.clientType == 0 ? $0.bundleIdentifier : nil }
        )
        for (bundleIdentifier, application) in applicationsByBundleIdentifier
        where !existingBundleIdentifiers.contains(bundleIdentifier) {
            let declarations = declarationsByBundleIdentifier[bundleIdentifier] ?? []
            guard !declarations.isEmpty else { continue }
            clients.append(AppPermissionClient(
                id: "0|\(bundleIdentifier)",
                name: application.name,
                clientIdentifier: bundleIdentifier,
                clientType: 0,
                bundleIdentifier: bundleIdentifier,
                applicationURL: application.url,
                version: application.version,
                isInstalled: true,
                records: [],
                declarations: declarations
            ))
        }

        return clients.sorted { lhs, rhs in
            if lhs.hasObservedDecision != rhs.hasObservedDecision {
                return lhs.hasObservedDecision
            }
            if lhs.highImpactAllowedCount != rhs.highImpactAllowedCount {
                return lhs.highImpactAllowedCount > rhs.highImpactAllowedCount
            }
            if lhs.allowedCount != rhs.allowedCount {
                return lhs.allowedCount > rhs.allowedCount
            }
            if lhs.isInstalled != rhs.isInstalled {
                return lhs.isInstalled
            }
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    private static func matchedApplication(
        for key: ClientKey,
        applicationsByBundleIdentifier: [String: AppPermissionApplicationReference]
    ) -> AppPermissionApplicationReference? {
        if key.type == 0 {
            return applicationsByBundleIdentifier[key.identifier]
        }
        guard key.type == 1, key.identifier.hasPrefix("/") else { return nil }
        return applicationsByBundleIdentifier.values
            .filter {
                key.identifier == $0.url.path
                    || key.identifier.hasPrefix($0.url.path + "/")
            }
            .max { $0.url.path.count < $1.url.path.count }
    }

    private static func fallbackClientName(for key: ClientKey) -> String {
        if key.type == 1, key.identifier.hasPrefix("/") {
            let name = URL(fileURLWithPath: key.identifier)
                .deletingPathExtension()
                .lastPathComponent
            return name.isEmpty ? key.identifier : name
        }
        let component = key.identifier.split(separator: ".").last.map(String.init)
        return component?.isEmpty == false ? component! : key.identifier
    }

    private static func applicationPreference(
        _ lhs: AppPermissionApplicationReference,
        _ rhs: AppPermissionApplicationReference
    ) -> Bool {
        func rank(_ path: String) -> Int {
            if path.hasPrefix("/Applications/") { return 0 }
            if path.contains("/Applications/") { return 1 }
            if path.hasPrefix("/System/Applications/") { return 2 }
            return 3
        }
        let lhsRank = rank(lhs.url.path)
        let rhsRank = rank(rhs.url.path)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.url.path < rhs.url.path
    }

    private static func recordPreference(
        _ lhs: AppPermissionRecord,
        _ rhs: AppPermissionRecord
    ) -> Bool {
        if lhs.service.category != rhs.service.category {
            return lhs.service.category.rawValue < rhs.service.category.rawValue
        }
        if lhs.service.rawValue != rhs.service.rawValue {
            return lhs.service.rawValue < rhs.service.rawValue
        }
        if lhs.decision != rhs.decision {
            return lhs.decision.rawValue < rhs.decision.rawValue
        }
        return lhs.id < rhs.id
    }

    private static func normalizedPurpose(_ rawValue: String) -> String? {
        let value = rawValue
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !value.isEmpty else { return nil }
        return String(value.prefix(512))
    }

    private static let declarationKeys: [String: AppPermissionService] = [
        "NSAppBundlesUsageDescription": .appManagement,
        "NSAppDataUsageDescription": .appData,
        "NSAppleEventsUsageDescription": .appleEvents,
        "NSAppleMusicUsageDescription": .mediaLibrary,
        "NSAudioCaptureUsageDescription": .audioCapture,
        "NSBluetoothAlwaysUsageDescription": .bluetooth,
        "NSCalendarsFullAccessUsageDescription": .calendar,
        "NSCalendarsUsageDescription": .calendar,
        "NSCalendarsWriteOnlyAccessUsageDescription": .calendar,
        "NSCameraUsageDescription": .camera,
        "NSContactsUsageDescription": .addressBook,
        "NSDesktopFolderUsageDescription": .desktop,
        "NSDocumentsFolderUsageDescription": .documents,
        "NSDownloadsFolderUsageDescription": .downloads,
        "NSFileProviderDomainUsageDescription": .fileProviderDomain,
        "NSFocusStatusUsageDescription": .focusStatus,
        "NSGKFriendListUsageDescription": .gameCenterFriends,
        "NSHomeKitUsageDescription": .homeKit,
        "NSLocationUsageDescription": .location,
        "NSLocationWhenInUseUsageDescription": .location,
        "NSMicrophoneUsageDescription": .microphone,
        "NSMotionUsageDescription": .motion,
        "NSNetworkVolumesUsageDescription": .networkVolumes,
        "NSPhotoLibraryAddUsageDescription": .photosAdd,
        "NSPhotoLibraryUsageDescription": .photos,
        "NSRemindersFullAccessUsageDescription": .reminders,
        "NSRemindersUsageDescription": .reminders,
        "NSRemovableVolumesUsageDescription": .removableVolumes,
        "NSSiriUsageDescription": .siri,
        "NSSpeechRecognitionUsageDescription": .speechRecognition,
        "NSSystemAdministrationUsageDescription": .systemAdministration,
        "NSUserTrackingUsageDescription": .userTracking,
    ]
}
