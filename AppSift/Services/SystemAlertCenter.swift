import AppKit
import Darwin
import Foundation
@preconcurrency import UserNotifications

enum SystemAlertKind: String, Codable, Hashable, Sendable {
    case lowInternalDisk
    case lowExternalDisk
    case lowBattery
    case lowDeviceBattery
    case batteryService
    case memoryPressure
    case staleTrash
}

enum SystemAlertSeverity: String, Codable, Hashable, Sendable {
    case advisory
    case warning
    case critical
}

struct SystemAlertCondition: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let kind: SystemAlertKind
    let severity: SystemAlertSeverity
    let title: String
    let detail: String
    let evidence: String
    let detectedAt: Date
}

struct SystemAlertHistoryRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let conditionID: String
    let kind: SystemAlertKind
    let severity: SystemAlertSeverity
    let title: String
    let detail: String
    let evidence: String
    let detectedAt: Date
}

enum SystemAlertNotificationContract {
    static let markerKey = "AppSift.SystemAlert"
    static let notificationPrefix = "AppSift.SystemAlert."
}

struct SystemAlertTelemetrySnapshot: Sendable {
    let volumes: [SystemVolumeSnapshot]
    let battery: SystemBatterySnapshot?
    let deviceBatteries: [SystemDeviceBatterySnapshot]
    let memory: SystemMemorySnapshot?
    let trash: SystemTrashSnapshot?
    let capturedAt: Date
}

final class SystemAlertHistoryStore: @unchecked Sendable {
    static let shared = SystemAlertHistoryStore()
    private static let maximumRecords = 200
    private static let maximumBytes = 750_000

    private let fileURL: URL
    private let lock = NSLock()
    private var records: [SystemAlertHistoryRecord]

    init(
        fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AppSift", isDirectory: true)
            .appendingPathComponent("SystemAlertHistory.json")
    ) {
        self.fileURL = fileURL
        self.records = Self.load(from: fileURL)
    }

    func snapshot() -> [SystemAlertHistoryRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    @discardableResult
    func append(_ record: SystemAlertHistoryRecord) -> Bool {
        guard Self.isValid(record) else { return false }
        lock.lock()
        defer { lock.unlock() }
        let previous = records
        records.insert(record, at: 0)
        if records.count > Self.maximumRecords {
            records.removeLast(records.count - Self.maximumRecords)
        }
        guard persistLocked() else {
            records = previous
            return false
        }
        return true
    }

    @discardableResult
    func clear() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let previous = records
        records.removeAll()
        guard persistLocked() else {
            records = previous
            return false
        }
        return true
    }

    private func persistLocked() -> Bool {
        guard let data = try? JSONEncoder().encode(records),
              data.count <= Self.maximumBytes else { return false }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
            guard Self.isOwnedDirectory(directory), !Self.isSymbolicLink(fileURL) else {
                return false
            }
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            Logger.shared.log(
                "Could not persist system alert history: \(error.localizedDescription)",
                level: .warning
            )
            return false
        }
    }

    private static func load(from fileURL: URL) -> [SystemAlertHistoryRecord] {
        guard isOwnedDirectory(fileURL.deletingLastPathComponent()),
              isOwnedRegularFile(fileURL),
              let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0,
              size <= maximumBytes,
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let decoded = try? JSONDecoder().decode([SystemAlertHistoryRecord].self, from: data),
              decoded.count <= maximumRecords,
              decoded.allSatisfy(isValid) else { return [] }
        return decoded.sorted { $0.detectedAt > $1.detectedAt }
    }

    private static func isValid(_ record: SystemAlertHistoryRecord) -> Bool {
        !record.conditionID.isEmpty
            && record.conditionID.count <= 1_024
            && !record.title.isEmpty
            && record.title.count <= 512
            && record.detail.count <= 2_048
            && record.evidence.count <= 2_048
            && record.detectedAt.timeIntervalSinceReferenceDate.isFinite
    }

    private static func isOwnedDirectory(_ url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFDIR
            && information.st_uid == getuid()
            && information.st_mode & S_IWOTH == 0
    }

    private static func isOwnedRegularFile(_ url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFREG
            && information.st_uid == getuid()
            && information.st_mode & S_IWOTH == 0
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0
            && information.st_mode & S_IFMT == S_IFLNK
    }
}

@MainActor
final class SystemAlertCenter: ObservableObject {
    typealias TelemetryProvider = () -> SystemAlertTelemetrySnapshot
    typealias NotificationPoster = (SystemAlertCondition) throws -> Void

    static let shared = SystemAlertCenter()
    static let settingsKey = "settings.general.systemAlerts"

    @Published private(set) var activeConditions: [SystemAlertCondition] = []
    @Published private(set) var history: [SystemAlertHistoryRecord]
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var isRunning = false

    private static let refreshInterval: TimeInterval = 15 * 60
    private static let notificationCooldown: TimeInterval = 12 * 60 * 60
    private let historyStore: SystemAlertHistoryStore
    private let telemetryProvider: TelemetryProvider
    private let notificationPoster: NotificationPoster
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    init(
        historyStore: SystemAlertHistoryStore = .shared,
        telemetryProvider: TelemetryProvider? = nil,
        notificationPoster: NotificationPoster? = nil
    ) {
        self.historyStore = historyStore
        self.history = historyStore.snapshot()
        self.telemetryProvider = telemetryProvider ?? {
            SystemAlertTelemetrySnapshot(
                volumes: SystemTelemetryReader.mountedVolumes(),
                battery: SystemTelemetryReader.internalBattery(),
                deviceBatteries: SystemTelemetryReader.connectedDeviceBatteries(),
                memory: SystemTelemetryReader.memorySnapshot(),
                trash: SystemTelemetryReader.trashSnapshot(),
                capturedAt: Date()
            )
        }
        self.notificationPoster = notificationPoster ?? Self.deliverNotification
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refresh()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspaceObservers.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                }
            )
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()
        isRunning = false
    }

    func refresh() {
        let snapshot = telemetryProvider()
        let now = snapshot.capturedAt
        let conditions = Self.evaluate(
            volumes: snapshot.volumes,
            battery: snapshot.battery,
            deviceBatteries: snapshot.deviceBatteries,
            memory: snapshot.memory,
            trash: snapshot.trash,
            now: now
        )
        activeConditions = conditions
        lastCheckedAt = now

        for condition in conditions where isRunning && shouldNotify(condition, now: now) {
            let record = SystemAlertHistoryRecord(
                id: UUID(),
                conditionID: condition.id,
                kind: condition.kind,
                severity: condition.severity,
                title: condition.title,
                detail: condition.detail,
                evidence: condition.evidence,
                detectedAt: condition.detectedAt
            )
            if historyStore.append(record) {
                history = historyStore.snapshot()
                postNotification(condition)
            }
        }
    }

    @discardableResult
    func clearHistory() -> Bool {
        let result = historyStore.clear()
        if result { history = [] }
        return result
    }

    nonisolated static func evaluate(
        volumes: [SystemVolumeSnapshot],
        battery: SystemBatterySnapshot?,
        deviceBatteries: [SystemDeviceBatterySnapshot],
        memory: SystemMemorySnapshot? = nil,
        trash: SystemTrashSnapshot? = nil,
        now: Date = Date()
    ) -> [SystemAlertCondition] {
        var conditions: [SystemAlertCondition] = []
        for volume in volumes where !volume.isReadOnly && volume.totalBytes >= 2_000_000_000 {
            let fraction = Double(volume.availableBytes) / Double(volume.totalBytes)
            let absoluteFloor: Int64 = volume.isInternal ? 15_000_000_000 : 10_000_000_000
            let lowerBound: Int64 = volume.isInternal ? 5_000_000_000 : 2_000_000_000
            let threshold = min(
                absoluteFloor,
                max(lowerBound, Int64(Double(volume.totalBytes) * (volume.isInternal ? 0.08 : 0.05)))
            )
            guard volume.availableBytes <= threshold else { continue }
            let severity: SystemAlertSeverity = volume.availableBytes <= 2_000_000_000
                || fraction <= 0.01 ? .critical : .warning
            let available = ByteCountFormatter.string(
                fromByteCount: volume.availableBytes,
                countStyle: .file
            )
            let percent = Int((fraction * 100).rounded())
            let kind: SystemAlertKind = volume.isInternal ? .lowInternalDisk : .lowExternalDisk
            conditions.append(
                SystemAlertCondition(
                    id: "\(kind.rawValue)|\(volume.path)",
                    kind: kind,
                    severity: severity,
                    title: volume.isInternal
                        ? String(localized: "Mac storage is running low")
                        : String(localized: "External disk storage is running low"),
                    detail: String(
                        format: String(localized: "%@ has %@ available."),
                        volume.name,
                        available
                    ),
                    evidence: String(
                        format: String(localized: "%lld%% free on %@"),
                        Int64(percent),
                        volume.path
                    ),
                    detectedAt: now
                )
            )
        }

        if let battery {
            if let condition = battery.condition,
               !condition.localizedCaseInsensitiveContains("normal"),
               !condition.localizedCaseInsensitiveContains("good") {
                conditions.append(
                    SystemAlertCondition(
                        id: SystemAlertKind.batteryService.rawValue,
                        kind: .batteryService,
                        severity: .warning,
                        title: String(localized: "Battery may need service"),
                        detail: condition,
                        evidence: battery.healthPercentage.map {
                            String(format: String(localized: "%lld%% estimated health"), Int64($0))
                        } ?? String(localized: "Battery condition reported by macOS"),
                        detectedAt: now
                    )
                )
            } else if battery.percentage <= 10,
                      !battery.isCharging,
                      !battery.isConnectedToPower {
                conditions.append(
                    SystemAlertCondition(
                        id: SystemAlertKind.lowBattery.rawValue,
                        kind: .lowBattery,
                        severity: battery.percentage <= 5 ? .critical : .advisory,
                        title: String(localized: "Mac battery is low"),
                        detail: String(
                            format: String(localized: "%lld%% battery remaining."),
                            Int64(battery.percentage)
                        ),
                        evidence: String(localized: "Not charging"),
                        detectedAt: now
                    )
                )
            }
        }

        for device in deviceBatteries where device.percentage <= 10 && device.isCharging != true {
            conditions.append(
                SystemAlertCondition(
                    id: "\(SystemAlertKind.lowDeviceBattery.rawValue)|\(device.id)",
                    kind: .lowDeviceBattery,
                    severity: .advisory,
                    title: String(localized: "Bluetooth device battery is low"),
                    detail: String(
                        format: String(localized: "%@ has %lld%% battery remaining."),
                        device.name,
                        Int64(device.percentage)
                    ),
                    evidence: String(localized: "Battery level reported by the connected device"),
                    detectedAt: now
                )
            )
        }

        if let memory,
           memory.usedFraction >= 0.93,
           memory.swapUsedBytes >= 512_000_000 {
            let usedPercent = Int((memory.usedFraction * 100).rounded())
            conditions.append(
                SystemAlertCondition(
                    id: SystemAlertKind.memoryPressure.rawValue,
                    kind: .memoryPressure,
                    severity: memory.usedFraction >= 0.98 && memory.swapUsedBytes >= 4_000_000_000
                        ? .critical
                        : .warning,
                    title: String(localized: "Memory pressure is high"),
                    detail: String(
                        format: String(localized: "%lld%% pressure-relevant memory is in use."),
                        Int64(usedPercent)
                    ),
                    evidence: String(
                        format: String(localized: "%@ swap currently in use"),
                        ByteCountFormatter.string(
                            fromByteCount: memory.swapUsedBytes,
                            countStyle: .memory
                        )
                    ),
                    detectedAt: now
                )
            )
        }

        if let trash,
           trash.oldItemCount >= 10
            || trash.oldestModificationDate.map({
                now.timeIntervalSince($0) >= 90 * 24 * 60 * 60
            }) == true {
            conditions.append(
                SystemAlertCondition(
                    id: SystemAlertKind.staleTrash.rawValue,
                    kind: .staleTrash,
                    severity: .advisory,
                    title: String(localized: "Trash contains older items"),
                    detail: String(
                        format: String(localized: "%lld items have been in the Trash for at least 30 days."),
                        Int64(trash.oldItemCount)
                    ),
                    evidence: trash.oldestModificationDate.map {
                        String(
                            format: String(localized: "Oldest item date: %@"),
                            DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none)
                        )
                    } ?? String(localized: "Trash age metadata reported by macOS"),
                    detectedAt: now
                )
            )
        }
        return conditions.sorted {
            if $0.severity != $1.severity { return $0.severity.sortOrder > $1.severity.sortOrder }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func shouldNotify(_ condition: SystemAlertCondition, now: Date) -> Bool {
        guard let latest = history.first(where: { $0.conditionID == condition.id }) else {
            return true
        }
        return now.timeIntervalSince(latest.detectedAt) >= Self.notificationCooldown
    }

    private func postNotification(_ condition: SystemAlertCondition) {
        do {
            try notificationPoster(condition)
        } catch {
            Logger.shared.log(
                "Could not post system alert: \(error.localizedDescription)",
                level: .warning
            )
        }
    }

    private static func deliverNotification(_ condition: SystemAlertCondition) {
        let content = UNMutableNotificationContent()
        content.title = condition.title
        content.body = condition.detail
        content.sound = .default
        content.userInfo = [SystemAlertNotificationContract.markerKey: true]
        let identifier = SystemAlertNotificationContract.notificationPrefix
            + stableIdentifier(condition.id)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        ) { error in
            if let error {
                Logger.shared.log(
                    "Could not post system alert: \(error.localizedDescription)",
                    level: .warning
                )
            }
        }
    }

    private static func stableIdentifier(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private extension SystemAlertSeverity {
    var sortOrder: Int {
        switch self {
        case .advisory: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }
}
