import SwiftUI
import AppKit

/// Zero-size helper that captures SwiftUI's `openWindow` action into
/// `WindowOpener.shared` when the main window appears, so the AppKit menu-bar
/// popover can reopen the window after it's been closed.
struct WindowOpenerCapture: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { WindowOpener.shared.open = { id in openWindow(id: id) } }
    }
}

/// Drop-down panel hosted in the menu-bar `NSPopover` (via `NSHostingController`)
/// with live CPU / memory / disk meters and quick actions. Kept self-contained
/// so the menu bar surface stays decoupled from the main window's `AppState`.
struct MenuBarMonitorView: View {
    @ObservedObject private var monitor = SystemMonitor.shared

    private var externalVolumes: [SystemVolumeSnapshot] {
        Array(monitor.volumes.filter { !$0.isInternal }.prefix(3))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("System Monitor")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    VStack(spacing: 10) {
                        MeterRow(title: "CPU", tint: Tint.blue,
                                 fraction: monitor.cpuUsage,
                                 detail: "\(Int((monitor.cpuUsage * 100).rounded()))%")
                        MeterRow(title: "Memory", tint: Tint.purple,
                                 fraction: monitor.memoryFraction,
                                 detail: byteDetail(monitor.memoryUsed, monitor.memoryTotal))
                        MeterRow(title: "Mac Disk", tint: Tint.green,
                                 fraction: monitor.diskFraction,
                                 detail: freeDetail(total: monitor.diskTotal, used: monitor.diskUsed))
                        InfoRow(
                            title: "Network",
                            systemImage: "arrow.up.arrow.down",
                            detail: networkDetail
                        )
                        if let battery = monitor.battery {
                            MeterRow(
                                title: "Battery",
                                tint: battery.percentage <= 15 ? Tint.orange : Tint.green,
                                fraction: Double(battery.percentage) / 100,
                                detail: batteryDetail(battery)
                            )
                        }
                    }

                    if !externalVolumes.isEmpty {
                        Divider()
                        Text("External Disks")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(externalVolumes) { volume in
                            MeterRow(
                                title: LocalizedStringKey(volume.name),
                                tint: volume.usedFraction >= 0.95 ? Tint.orange : Tint.cyan,
                                fraction: volume.usedFraction,
                                detail: ByteCountFormatter.string(
                                    fromByteCount: volume.availableBytes,
                                    countStyle: .file
                                ) + String(localized: " free")
                            )
                        }
                    }

                    if !monitor.deviceBatteries.isEmpty {
                        Divider()
                        Text("Connected Devices")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(monitor.deviceBatteries.prefix(3)) { device in
                            MeterRow(
                                title: LocalizedStringKey(device.name),
                                tint: device.percentage <= 15 ? Tint.orange : Tint.blue,
                                fraction: Double(device.percentage) / 100,
                                detail: "\(device.percentage)%"
                            )
                        }
                    }
                }
                .padding(14)
            }

            Divider()
            HStack {
                Button("Open AppSift", action: openMainWindow)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Spacer()
                Button("Quit AppSift") { NSApp.terminate(nil) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(12)
        }
        .frame(width: 300, height: 410)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private func byteDetail(_ used: Int64, _ total: Int64) -> String {
        let u = ByteCountFormatter.string(fromByteCount: used, countStyle: .memory)
        let t = ByteCountFormatter.string(fromByteCount: total, countStyle: .memory)
        return "\(u) / \(t)"
    }

    private func freeDetail(total: Int64, used: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, total - used), countStyle: .file)
            + String(localized: " free")
    }

    private var networkDetail: String {
        let down = ByteCountFormatter.string(
            fromByteCount: monitor.networkDownloadBytesPerSecond,
            countStyle: .file
        )
        let up = ByteCountFormatter.string(
            fromByteCount: monitor.networkUploadBytesPerSecond,
            countStyle: .file
        )
        return "↓ \(down)/s  ↑ \(up)/s"
    }

    private func batteryDetail(_ battery: SystemBatterySnapshot) -> String {
        var parts = ["\(battery.percentage)%"]
        if let health = battery.healthPercentage {
            parts.append(String(format: String(localized: "%lld%% health"), Int64(health)))
        }
        if battery.isCharging { parts.append(String(localized: "Charging")) }
        return parts.joined(separator: " · ")
    }

    /// Bring the app forward and surface the main window. The app stays alive
    /// after its window closes only while the monitor is enabled (see
    /// `AppDelegate.applicationShouldTerminateAfterLastWindowClosed`), so this
    /// reopens a fresh window when none is left, otherwise just focuses it.
    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Exclude the menu-bar popover's own panel; a real content window is
        // titled and can become main.
        if let existing = NSApp.windows.first(where: {
            $0.canBecomeMain && $0.styleMask.contains(.titled)
        }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            // No content window left — reopen via the captured openWindow action
            // (the popover has no working openWindow environment of its own).
            WindowOpener.shared.open?("main")
        }
    }
}

private struct InfoRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let detail: String

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(detail)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
    }
}

/// One labeled meter: title on the left, a thin tinted progress bar, and a
/// trailing numeric detail. Mirrors the restrained chrome used elsewhere.
private struct MeterRow: View {
    let title: LocalizedStringKey
    let tint: Color
    let fraction: Double
    let detail: String

    private var clamped: Double { max(0, min(1, fraction)) }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(detail)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(2, geo.size.width * clamped))
                }
            }
            .frame(height: 5)
        }
    }
}
