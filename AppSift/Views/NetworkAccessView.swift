import SwiftUI

struct NetworkAccessView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var controller = NetworkAccessController.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    @State private var selectedBundleIdentifier: String?

    private var apps: [InstalledApp] {
        let sorted = appState.installedApps.sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            $0.appName.localizedCaseInsensitiveContains(query)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedApp: InstalledApp? {
        if let selectedBundleIdentifier,
           let selected = apps.first(where: { $0.bundleIdentifier == selectedBundleIdentifier }) {
            return selected
        }
        return apps.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                HStack(alignment: .top, spacing: 20) {
                    applicationList
                        .frame(maxWidth: 650)
                    detailPanel
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
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
            if selectedBundleIdentifier == nil {
                selectedBundleIdentifier = apps.first?.bundleIdentifier
            }
        }
        .onChange(of: appState.installedApps.count) { _ in
            if selectedBundleIdentifier == nil {
                selectedBundleIdentifier = apps.first?.bundleIdentifier
            }
        }
        .alert(
            "Unable to enable network monitoring",
            isPresented: Binding(
                get: { controller.actionMessage != nil },
                set: { if !$0 { controller.actionMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                controller.actionMessage = nil
            }
        } message: {
            Text(controller.actionMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Network Access")
                .font(.system(size: 36, weight: .bold, design: .rounded))
            Text("See and control which apps can access the network.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var applicationList: some View {
        CardSurface(padding: 0, accent: Tint.purple, elevation: .standard) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    sectionHeader(
                        title: "Applications",
                        subtitle: controller.extensionState.supportsLocalTrafficView
                            ? "本地签名可查看流量；拦截需要正式签名。"
                            : "Block only the bundle IDs you explicitly choose."
                    )
                    Spacer(minLength: 8)
                    Text("\(apps.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search apps", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                .padding(.horizontal, 18)
                .padding(.bottom, 12)

                Divider()

                if apps.isEmpty {
                    EmptyStateView(
                        "Applications",
                        systemImage: "square.grid.2x2",
                        description: searchText.isEmpty
                            ? "Loading installed applications…"
                            : "No matching applications."
                    )
                    .frame(minHeight: 180)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(apps) { app in
                                applicationRow(app)
                                if app.id != apps.last?.id {
                                    Divider().padding(.leading, 70)
                                }
                            }
                        }
                    }
                    .frame(minHeight: 260, maxHeight: 520)
                }
            }
        }
    }

    private func applicationRow(_ app: InstalledApp) -> some View {
        let selected = selectedApp?.id == app.id
        let appFlows = controller.flows(for: app.bundleIdentifier)
        let received = appFlows.reduce(0) { $0 &+ $1.bytesReceived }
        let sent = appFlows.reduce(0) { $0 &+ $1.bytesSent }
        let blocked = controller.isBlocked(bundleIdentifier: app.bundleIdentifier)

        return HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.appName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Text(app.bundleIdentifier)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if received > 0 || sent > 0 {
                    Text(verbatim: "↓ \(formattedBytes(received))  ↑ \(formattedBytes(sent))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Tint.cyan)
                } else {
                    Text("No traffic yet")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 6)

            if controller.extensionState.isOperational {
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            selected
                ? Tint.blue.opacity(colorScheme == .dark ? 0.18 : 0.09)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedBundleIdentifier = app.bundleIdentifier
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    private var detailPanel: some View {
        VStack(spacing: 14) {
            statusCard
            if let selectedApp {
                selectedAppCard(selectedApp)
            } else {
                explainerCard
            }
        }
    }

    private var statusCard: some View {
        CardSurface(padding: 18, accent: Tint.cyan, elevation: .standard) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    IconTile(
                        systemName: controller.extensionState.isOperational
                            ? "network"
                            : controller.extensionState.supportsLocalTrafficView
                                ? "chart.line.uptrend.xyaxis"
                                : "network.slash",
                        tint: controller.extensionState.isOperational || controller.extensionState.supportsLocalTrafficView
                            ? Tint.green
                            : Tint.orange,
                        size: 38,
                        corner: 11,
                        glow: controller.extensionState.isOperational
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(controller.extensionState.titleKey))
                            .font(.headline)
                        Text(LocalizedStringKey(
                            controller.extensionState.isOperational
                                ? "Local analysis"
                                : controller.extensionState.isLocalOnly
                                    ? "Read-only local mode"
                                    : controller.extensionState.supportsLocalTrafficView
                                        ? "Local mode available"
                                    : "Ready to review"
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let failureMessage = controller.extensionState.failureMessage {
                    Text(failureMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(LocalizedStringKey(controller.extensionState.detailKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    controller.setMonitoringEnabled(!controller.isEnabled)
                } label: {
                    Text(LocalizedStringKey(
                        controller.isEnabled
                            ? "Disable Network Monitor"
                            : controller.extensionState.supportsLocalTrafficView
                                ? "Start Local Traffic View"
                                : "Enable Network Monitor"
                    ))
                    .frame(maxWidth: .infinity)
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

    private func selectedAppCard(_ app: InstalledApp) -> some View {
        let appFlows = controller.flows(for: app.bundleIdentifier)
        let received = appFlows.reduce(0) { $0 &+ $1.bytesReceived }
        let sent = appFlows.reduce(0) { $0 &+ $1.bytesSent }
        let blocked = controller.isBlocked(bundleIdentifier: app.bundleIdentifier)

        return CardSurface(padding: 18, accent: Tint.blue, elevation: .standard) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.appName)
                            .font(.headline)
                            .lineLimit(1)
                        Text(app.bundleIdentifier)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if controller.extensionState.isOperational {
                    Toggle(
                        "Internet Access",
                        isOn: Binding(
                            get: { !blocked },
                            set: { controller.setBlocked(!$0, bundleIdentifier: app.bundleIdentifier) }
                        )
                    )
                    .toggleStyle(.switch)
                }

                if controller.extensionState.isLocalOnly {
                    Text(LocalizedStringKey("Local signing mode only reads traffic stats; it does not block network. Blocking requires Network Extension provisioning."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    metric(title: "Incoming", value: formattedBytes(received))
                    metric(title: "Outgoing", value: formattedBytes(sent))
                }

                if let lastActivity = appFlows.map(\.lastSeenAt).max() {
                    HStack(spacing: 4) {
                        Text("Last activity")
                        Text(lastActivity, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("No traffic yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                featureRow(
                    systemImage: "lock.shield",
                    title: "Local analysis",
                    description: "Only app identity and byte totals are recorded; payloads are never inspected."
                )
            }
        }
    }

    private var explainerCard: some View {
        CardSurface(padding: 18, accent: Tint.green, elevation: .standard) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Network monitoring")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                featureRow(
                    systemImage: "nosign",
                    title: "Block any app",
                    description: "Decide which apps may connect to the internet."
                )
                featureRow(
                    systemImage: "chart.line.uptrend.xyaxis",
                    title: "Inspect traffic",
                    description: "See incoming and outgoing bytes for each app."
                )
                featureRow(
                    systemImage: "lock.shield",
                    title: "Local analysis",
                    description: "Traffic analysis stays on this Mac."
                )
            }
        }
    }

    private func featureRow(
        systemImage: String,
        title: LocalizedStringKey,
        description: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Tint.blue)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metric(title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }

    private func sectionHeader(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey
    ) -> some View {
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
