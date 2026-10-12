import SwiftUI

struct NetworkAccessView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var controller = NetworkAccessController.shared
    @Environment(\.colorScheme) private var colorScheme

    private var apps: [InstalledApp] {
        appState.installedApps.sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                statusCard
                appAccessCard
                flowCard
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle("Network Access")
        .accessibilityIdentifier("network-access.view")
        .task {
            if appState.installedApps.isEmpty, !appState.isLoadingApps {
                appState.loadInstalledApps()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Network Access")
                .font(.system(size: 36, weight: .bold, design: .rounded))
            Text("See and control which apps can access the network.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var statusCard: some View {
        CardSurface(padding: 20, accent: Tint.cyan, elevation: .standard) {
            HStack(spacing: 16) {
                IconTile(
                    systemName: controller.extensionState.isOperational
                        ? "network"
                        : "network.slash",
                    tint: controller.extensionState.isOperational ? Tint.green : Tint.orange,
                    size: 48,
                    corner: 14,
                    glow: controller.extensionState.isOperational
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.extensionState.title)
                        .font(.headline)
                    Text(controller.extensionState.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button {
                    controller.setMonitoringEnabled(!controller.isEnabled)
                } label: {
                    Text(controller.isEnabled ? "Disable Network Monitor" : "Enable Network Monitor")
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.isEnabled ? Tint.orange : Tint.blue)
                .disabled({
                    if case .activating = controller.extensionState { return true }
                    return false
                }())
                .accessibilityIdentifier("network-access.enable")
            }
        }
    }

    private var appAccessCard: some View {
        CardSurface(padding: 0, accent: Tint.purple, elevation: .standard) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(
                    title: "Applications",
                    subtitle: "Block only the bundle IDs you explicitly choose."
                )

                if apps.isEmpty {
                    EmptyStateView(
                        "Applications",
                        systemImage: "square.grid.2x2",
                        description: "Loading installed applications…"
                    )
                    .frame(minHeight: 180)
                } else {
                    ForEach(apps) { app in
                        appRow(app)
                        if app.id != apps.last?.id {
                            Divider().padding(.leading, 72)
                        }
                    }
                }
            }
        }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        let appFlows = controller.flows(for: app.bundleIdentifier)
        let received = appFlows.reduce(0) { $0 &+ $1.bytesReceived }
        let sent = appFlows.reduce(0) { $0 &+ $1.bytesSent }
        let blocked = controller.isBlocked(bundleIdentifier: app.bundleIdentifier)

        return HStack(spacing: 14) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.appName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(app.bundleIdentifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if received > 0 || sent > 0 {
                    Text(verbatim: "↓ " + formattedBytes(received) + "  ↑ " + formattedBytes(sent))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Tint.cyan)
                }
            }

            Spacer(minLength: 8)

            if blocked {
                Text("Blocked")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Tint.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Tint.orange.opacity(0.12), in: Capsule())
            }

            Toggle(
                "Block",
                isOn: Binding(
                    get: { blocked },
                    set: { controller.setBlocked($0, bundleIdentifier: app.bundleIdentifier) }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .help(blocked ? "Allow network access" : "Block network access")
            .accessibilityLabel(blocked ? "Allow network access" : "Block network access")
            .accessibilityIdentifier("network-access.block.\(app.bundleIdentifier)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var flowCard: some View {
        CardSurface(padding: 0, accent: Tint.blue, elevation: .standard) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    sectionHeader(
                        title: "Recent Traffic",
                        subtitle: "Only metadata and byte totals are retained."
                    )
                    Spacer()
                    Button("Clear") {
                        controller.clearFlows()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(controller.flows.isEmpty)
                }
                .padding(20)

                if controller.flows.isEmpty {
                    Text("No network flows recorded yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ForEach(controller.flows.prefix(30)) { flow in
                        flowRow(flow)
                        if flow.id != controller.flows.prefix(30).last?.id {
                            Divider().padding(.leading, 72)
                        }
                    }
                }
            }
        }
    }

    private func flowRow(_ flow: AppSiftNetworkFlowRecord) -> some View {
        let appName = apps.first(where: { $0.bundleIdentifier == flow.bundleIdentifier })?.appName
            ?? flow.bundleIdentifier
        return HStack(spacing: 14) {
            Image(systemName: flow.isBlocked ? "nosign" : "arrow.up.right.circle")
                .font(.title3)
                .foregroundStyle(flow.isBlocked ? Tint.orange : Tint.blue)
                .frame(width: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(appName)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(flow.remoteEndpoint ?? "Unknown endpoint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(verbatim: "↓ " + formattedBytes(flow.bytesReceived) + "  ↑ " + formattedBytes(flow.bytesSent))
                    .font(.caption.monospacedDigit())
                Text(flow.lastSeenAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 16, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(min(bytes, UInt64(Int64.max))),
            countStyle: .file
        )
    }
}
