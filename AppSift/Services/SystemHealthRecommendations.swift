import Foundation

enum HealthRecommendationPriority: Int, Comparable {
    case information = 0
    case action = 1
    case urgent = 2

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum HealthRecommendationAction: Hashable {
    case navigate(AppSection)
    case openBatterySettings
    case enableSystemAlerts
}

struct HealthRecommendation: Identifiable, Hashable {
    let id: String
    let priority: HealthRecommendationPriority
    let title: String
    let detail: String
    let evidence: String
    let systemImage: String
    let actionLabel: String?
    let action: HealthRecommendationAction?
}

struct SystemHealthRuleSnapshot {
    let activeAlerts: [SystemAlertCondition]
    let appUpdateCount: Int
    let macOSUpdateCount: Int
    let brokenStartupItemCount: Int
    let oldBackupCount: Int
    let oldBackupSize: Int64
    let corruptPreferenceCount: Int
    let legacyUserResidueCount: Int
    let hasFullDiskAccess: Bool
    let systemAlertsEnabled: Bool
}

enum SystemHealthRecommendationEngine {
    static func recommendations(
        from snapshot: SystemHealthRuleSnapshot
    ) -> [HealthRecommendation] {
        var results = snapshot.activeAlerts.map(recommendation(for:))

        let updateCount = snapshot.appUpdateCount + snapshot.macOSUpdateCount
        if updateCount > 0 {
            results.append(
                HealthRecommendation(
                    id: "available-updates",
                    priority: .action,
                    title: String(localized: "Review available updates"),
                    detail: String(
                        format: String(localized: "%lld verified update entries are available."),
                        Int64(updateCount)
                    ),
                    evidence: String(
                        format: String(localized: "%lld app updates · %lld macOS updates"),
                        Int64(snapshot.appUpdateCount),
                        Int64(snapshot.macOSUpdateCount)
                    ),
                    systemImage: "arrow.triangle.2.circlepath.circle.fill",
                    actionLabel: String(localized: "Review Updates"),
                    action: .navigate(.appUpdates)
                )
            )
        }

        if snapshot.brokenStartupItemCount > 0 {
            results.append(
                HealthRecommendation(
                    id: "broken-startup-items",
                    priority: .action,
                    title: String(localized: "Remove broken startup items"),
                    detail: String(
                        format: String(localized: "%lld startup entries point to missing executables."),
                        Int64(snapshot.brokenStartupItemCount)
                    ),
                    evidence: String(localized: "The target path was missing during the latest startup-item scan."),
                    systemImage: "power.circle.fill",
                    actionLabel: String(localized: "Review Startup Items"),
                    action: .navigate(.startupItems)
                )
            )
        }

        if snapshot.oldBackupCount > 0 {
            results.append(
                HealthRecommendation(
                    id: "old-ios-backups",
                    priority: .action,
                    title: String(localized: "Review older device backups"),
                    detail: String(
                        format: String(localized: "%lld local backups are more than six months old."),
                        Int64(snapshot.oldBackupCount)
                    ),
                    evidence: ByteCountFormatter.string(
                        fromByteCount: snapshot.oldBackupSize,
                        countStyle: .file
                    ),
                    systemImage: "iphone",
                    actionLabel: String(localized: "Review Backups"),
                    action: .navigate(.iosBackups)
                )
            )
        }

        if snapshot.corruptPreferenceCount > 0 {
            results.append(
                HealthRecommendation(
                    id: "corrupt-preferences",
                    priority: .action,
                    title: String(localized: "Review damaged preference files"),
                    detail: String(
                        format: String(localized: "%lld property lists could not be parsed."),
                        Int64(snapshot.corruptPreferenceCount)
                    ),
                    evidence: String(localized: "PropertyListSerialization rejected these files during the latest diagnostic scan."),
                    systemImage: "doc.badge.gearshape",
                    actionLabel: String(localized: "Open Diagnostics"),
                    action: .navigate(.systemResidue)
                )
            )
        }

        if snapshot.legacyUserResidueCount > 0 {
            results.append(
                HealthRecommendation(
                    id: "legacy-user-data",
                    priority: .information,
                    title: String(localized: "Inspect old user data"),
                    detail: String(
                        format: String(localized: "%lld folders do not cleanly match current local accounts."),
                        Int64(snapshot.legacyUserResidueCount)
                    ),
                    evidence: String(localized: "Account name and owner UID checks; AppSift does not delete these folders automatically."),
                    systemImage: "person.crop.circle.badge.questionmark",
                    actionLabel: String(localized: "Open Diagnostics"),
                    action: .navigate(.systemResidue)
                )
            )
        }

        if !snapshot.hasFullDiskAccess {
            results.append(
                HealthRecommendation(
                    id: "full-disk-access",
                    priority: .information,
                    title: String(localized: "Some scans are permission-limited"),
                    detail: String(localized: "Mail, browser, and some Library diagnostics may be incomplete without Full Disk Access."),
                    evidence: String(localized: "AppSift's current Full Disk Access probe did not succeed."),
                    systemImage: "lock.shield.fill",
                    actionLabel: nil,
                    action: nil
                )
            )
        }

        if !snapshot.systemAlertsEnabled {
            results.append(
                HealthRecommendation(
                    id: "system-alerts-disabled",
                    priority: .information,
                    title: String(localized: "Background system alerts are off"),
                    detail: String(localized: "Enable alerts to monitor low disk space, supported batteries, memory pressure, and older Trash items."),
                    evidence: String(localized: "System Alerts is disabled in AppSift settings."),
                    systemImage: "bell.slash.fill",
                    actionLabel: String(localized: "Enable Alerts"),
                    action: .enableSystemAlerts
                )
            )
        }

        return results.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func recommendation(
        for alert: SystemAlertCondition
    ) -> HealthRecommendation {
        let action: HealthRecommendationAction?
        let actionLabel: String?
        switch alert.kind {
        case .lowInternalDisk, .lowExternalDisk:
            action = .navigate(.spaceLens)
            actionLabel = String(localized: "Open Space Lens")
        case .staleTrash:
            action = .navigate(.cleaning(.trashBins))
            actionLabel = String(localized: "Review Trash")
        case .batteryService:
            action = .openBatterySettings
            actionLabel = String(localized: "Open Battery Settings")
        case .lowBattery, .lowDeviceBattery, .memoryPressure:
            action = nil
            actionLabel = nil
        }
        let priority: HealthRecommendationPriority = alert.severity == .critical
            ? .urgent
            : .action
        return HealthRecommendation(
            id: "alert|\(alert.id)",
            priority: priority,
            title: alert.title,
            detail: alert.detail,
            evidence: alert.evidence,
            systemImage: systemImage(for: alert.kind),
            actionLabel: actionLabel,
            action: action
        )
    }

    private static func systemImage(for kind: SystemAlertKind) -> String {
        switch kind {
        case .lowInternalDisk: return "internaldrive.fill"
        case .lowExternalDisk: return "externaldrive.fill"
        case .lowBattery: return "battery.25percent"
        case .lowDeviceBattery: return "battery.25percent"
        case .batteryService: return "wrench.and.screwdriver.fill"
        case .memoryPressure: return "memorychip.fill"
        case .staleTrash: return "trash.fill"
        }
    }
}
