import AppKit
import SwiftUI

struct SystemHealthView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var alertCenter = SystemAlertCenter.shared
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject var macOSUpdateCenter: MacOSUpdateCenter
    @ObservedObject var iosBackupCenter: IOSBackupCenter
    @ObservedObject var residueCenter: SystemResidueCenter
    let navigate: (AppSection) -> Void

    @AppStorage(SystemAlertCenter.settingsKey) private var systemAlertsEnabled = false
    @State private var confirmsHistoryClear = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                summary
                liveTelemetry
                currentAlerts
                recommendationsSection
                historySection
            }
            .padding(20)
        }
        .navigationTitle("System Health")
        .toolbar {
            Button(action: refreshAll) {
                Label("Refresh Health Checks", systemImage: "arrow.clockwise")
            }
        }
        .onAppear {
            monitor.start()
            refreshMissingChecks()
        }
        .onDisappear { monitor.stop() }
        .confirmationDialog(
            "Clear Alert History?",
            isPresented: $confirmsHistoryClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                _ = alertCenter.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears AppSift's local alert log. It does not change system data or dismiss current conditions.")
        }
    }

    private var summary: some View {
        CardSurface(padding: 18) {
            HStack(alignment: .center, spacing: 16) {
                IconTile(
                    systemName: summaryIcon,
                    tint: summaryTint,
                    size: 56,
                    corner: 14
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(summaryTitle)
                        .font(.system(size: 22, weight: .semibold))
                    Text("AppSift uses explicit conditions and evidence. It does not invent a numeric Mac health score.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let lastCheckedAt = alertCenter.lastCheckedAt {
                        Text(
                            String(
                                format: String(localized: "Last checked: %@"),
                                DateFormatter.localizedString(
                                    from: lastCheckedAt,
                                    dateStyle: .none,
                                    timeStyle: .short
                                )
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    StatusChip(
                        label: String(
                            format: String(localized: "%lld active alerts"),
                            Int64(alertCenter.activeConditions.count)
                        ),
                        systemImage: alertCenter.activeConditions.isEmpty
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill",
                        tint: alertCenter.activeConditions.isEmpty ? Tint.green : Tint.orange
                    )
                    Toggle("Background Alerts", isOn: systemAlertsBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
    }

    private var liveTelemetry: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("Live System Status", icon: "waveform.path.ecg")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 210), spacing: 10)],
                spacing: 10
            ) {
                telemetryCard(
                    title: "CPU",
                    value: "\(Int((monitor.cpuUsage * 100).rounded()))%",
                    detail: String(localized: "Current total utilization"),
                    icon: "cpu.fill",
                    tint: Tint.blue
                )
                telemetryCard(
                    title: "Memory",
                    value: "\(Int((monitor.memoryFraction * 100).rounded()))%",
                    detail: memoryDetail,
                    icon: "memorychip.fill",
                    tint: monitor.memoryFraction >= 0.93 ? Tint.orange : Tint.purple
                )
                telemetryCard(
                    title: "Network",
                    value: networkValue,
                    detail: String(localized: "Current download / upload"),
                    icon: "arrow.up.arrow.down",
                    tint: Tint.cyan
                )
                if let battery = monitor.battery {
                    telemetryCard(
                        title: "Battery",
                        value: "\(battery.percentage)%",
                        detail: batteryDetail(battery),
                        icon: "battery.75percent",
                        tint: battery.percentage <= 15 ? Tint.orange : Tint.green
                    )
                }
            }

            if !monitor.volumes.isEmpty {
                CardSurface(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Mounted Disks")
                            .font(.headline)
                        ForEach(monitor.volumes.prefix(8)) { volume in
                            HStack(spacing: 9) {
                                Image(systemName: volume.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                                    .foregroundStyle(volume.isInternal ? Tint.blue : Tint.cyan)
                                    .frame(width: 18)
                                Text(volume.name)
                                    .lineLimit(1)
                                Spacer()
                                Text(
                                    String(
                                        format: String(localized: "%@ available"),
                                        ByteCountFormatter.string(
                                            fromByteCount: volume.availableBytes,
                                            countStyle: .file
                                        )
                                    )
                                )
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !monitor.deviceBatteries.isEmpty {
                CardSurface(padding: 14) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Connected Device Batteries")
                            .font(.headline)
                        ForEach(monitor.deviceBatteries.prefix(8)) { device in
                            HStack {
                                Label(device.name, systemImage: "dot.radiowaves.left.and.right")
                                Spacer()
                                Text("\(device.percentage)%")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(device.percentage <= 10 ? Tint.orange : .secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var currentAlerts: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("Current Alerts", icon: "bell.badge.fill")
            if alertRecommendations.isEmpty {
                CardSurface(padding: 14) {
                    Label("No current disk, battery, memory, device, or Trash-age alerts.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Tint.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(alertRecommendations) { recommendation in
                    recommendationCard(recommendation)
                }
            }
        }
    }

    @ViewBuilder
    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("Rule-Based Recommendations", icon: "lightbulb.fill")
            if generalRecommendations.isEmpty {
                CardSurface(padding: 14) {
                    Label("No additional actions are suggested by the completed checks.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Tint.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(generalRecommendations) { recommendation in
                    recommendationCard(recommendation)
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionTitle("Alert History", icon: "clock.arrow.circlepath")
                Spacer()
                Button("Clear History", role: .destructive) {
                    confirmsHistoryClear = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(alertCenter.history.isEmpty)
            }
            if alertCenter.history.isEmpty {
                Text("No system alerts have been recorded on this Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(alertCenter.history.prefix(30)) { record in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: severityIcon(record.severity))
                            .foregroundStyle(severityTint(record.severity))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.title)
                                .font(.subheadline.weight(.semibold))
                            Text(record.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(record.evidence)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(record.detectedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(.bar, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func recommendationCard(_ recommendation: HealthRecommendation) -> some View {
        CardSurface(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(
                    systemName: recommendation.systemImage,
                    tint: priorityTint(recommendation.priority),
                    size: 34
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(recommendation.title)
                        .font(.headline)
                    Text(recommendation.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Label(recommendation.evidence, systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 12)
                if let label = recommendation.actionLabel,
                   let action = recommendation.action {
                    Button(label) { perform(action) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func telemetryCard(
        title: LocalizedStringKey,
        value: String,
        detail: String,
        icon: String,
        tint: Color
    ) -> some View {
        CardSurface(padding: 13) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .font(.title3)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.headline.monospacedDigit())
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
    }

    private var recommendations: [HealthRecommendation] {
        let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? .distantPast
        let oldBackups = iosBackupCenter.backups.filter {
            $0.completionState != .inProgress
                && ($0.lastBackupDate ?? $0.modificationDate ?? .distantFuture) < cutoff
        }
        let snapshot = SystemHealthRuleSnapshot(
            activeAlerts: alertCenter.activeConditions,
            appUpdateCount: appState.availableAppUpdateCount,
            macOSUpdateCount: macOSUpdateCenter.updates.count,
            brokenStartupItemCount: appState.startupItems.count {
                $0.isMissing && !$0.isInactiveRegistration
            },
            oldBackupCount: oldBackups.count,
            oldBackupSize: oldBackups.reduce(0) { $0 + $1.allocatedSize },
            corruptPreferenceCount: residueCenter.corruptPreferences.count,
            legacyUserResidueCount: residueCenter.legacyUsers.count,
            hasFullDiskAccess: appState.hasFullDiskAccess,
            systemAlertsEnabled: systemAlertsEnabled
        )
        return SystemHealthRecommendationEngine.recommendations(from: snapshot)
    }

    private var alertRecommendations: [HealthRecommendation] {
        recommendations.filter { $0.id.hasPrefix("alert|") }
    }

    private var generalRecommendations: [HealthRecommendation] {
        recommendations.filter { !$0.id.hasPrefix("alert|") }
    }

    private var summaryTitle: LocalizedStringKey {
        if alertCenter.activeConditions.contains(where: { $0.severity == .critical }) {
            return "Urgent Attention Needed"
        }
        if !alertCenter.activeConditions.isEmpty { return "Review Current Alerts" }
        if !generalRecommendations.isEmpty { return "A Few Actions Are Suggested" }
        return "No Current Issues Detected"
    }

    private var summaryIcon: String {
        if alertCenter.activeConditions.contains(where: { $0.severity == .critical }) {
            return "exclamationmark.octagon.fill"
        }
        if !alertCenter.activeConditions.isEmpty { return "exclamationmark.triangle.fill" }
        if !generalRecommendations.isEmpty { return "lightbulb.fill" }
        return "checkmark.seal.fill"
    }

    private var summaryTint: Color {
        if alertCenter.activeConditions.contains(where: { $0.severity == .critical }) {
            return Tint.red
        }
        if !alertCenter.activeConditions.isEmpty { return Tint.orange }
        if !generalRecommendations.isEmpty { return Tint.blue }
        return Tint.green
    }

    private var systemAlertsBinding: Binding<Bool> {
        Binding(
            get: { systemAlertsEnabled },
            set: { enabled in
                systemAlertsEnabled = enabled
                NotificationCenter.default.post(
                    name: .appSiftSystemAlertsChanged,
                    object: nil
                )
            }
        )
    }

    private var memoryDetail: String {
        let used = ByteCountFormatter.string(fromByteCount: monitor.memoryUsed, countStyle: .memory)
        let total = ByteCountFormatter.string(fromByteCount: monitor.memoryTotal, countStyle: .memory)
        return "\(used) / \(total)"
    }

    private var networkValue: String {
        let down = ByteCountFormatter.string(
            fromByteCount: monitor.networkDownloadBytesPerSecond,
            countStyle: .file
        )
        let up = ByteCountFormatter.string(
            fromByteCount: monitor.networkUploadBytesPerSecond,
            countStyle: .file
        )
        return "↓ \(down)/s · ↑ \(up)/s"
    }

    private func batteryDetail(_ battery: SystemBatterySnapshot) -> String {
        var details: [String] = []
        if let health = battery.healthPercentage {
            details.append(String(format: String(localized: "%lld%% estimated health"), Int64(health)))
        }
        if let cycles = battery.cycleCount {
            details.append(String(format: String(localized: "%lld cycles"), Int64(cycles)))
        }
        if battery.isCharging { details.append(String(localized: "Charging")) }
        return details.isEmpty ? String(localized: "Battery status from macOS") : details.joined(separator: " · ")
    }

    private func refreshMissingChecks() {
        alertCenter.refresh()
        if !appState.hasScannedAppUpdates { appState.scanAppUpdates() }
        if !macOSUpdateCenter.hasChecked { macOSUpdateCenter.check() }
        if !appState.hasScannedStartupItems { appState.scanStartupItems() }
        if !iosBackupCenter.hasScanned { iosBackupCenter.scan() }
        if !residueCenter.hasScanned { residueCenter.scan() }
    }

    private func refreshAll() {
        alertCenter.refresh()
        appState.scanAppUpdates(force: true)
        macOSUpdateCenter.check()
        appState.scanStartupItems(force: true)
        if !iosBackupCenter.isScanning { iosBackupCenter.scan() }
        residueCenter.scan(force: true)
    }

    private func perform(_ action: HealthRecommendationAction) {
        switch action {
        case .navigate(let section):
            navigate(section)
        case .openBatterySettings:
            let candidates = [
                "x-apple.systempreferences:com.apple.Battery-Settings.extension",
                "x-apple.systempreferences:com.apple.preference.energysaver",
            ]
            for raw in candidates {
                if let url = URL(string: raw), NSWorkspace.shared.open(url) { break }
            }
        case .enableSystemAlerts:
            systemAlertsBinding.wrappedValue = true
        }
    }

    private func priorityTint(_ priority: HealthRecommendationPriority) -> Color {
        switch priority {
        case .information: return Tint.blue
        case .action: return Tint.orange
        case .urgent: return Tint.red
        }
    }

    private func severityIcon(_ severity: SystemAlertSeverity) -> String {
        severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
    }

    private func severityTint(_ severity: SystemAlertSeverity) -> Color {
        switch severity {
        case .advisory: return Tint.blue
        case .warning: return Tint.orange
        case .critical: return Tint.red
        }
    }
}
