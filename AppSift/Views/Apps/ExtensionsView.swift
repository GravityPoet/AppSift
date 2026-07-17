import SwiftUI

private enum ManagedExtensionFilter: String, CaseIterable, Identifiable {
    case all
    case enabled
    case disabled
    case needsReview

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .enabled: return "Enabled"
        case .disabled: return "Disabled"
        case .needsReview: return "Needs Review"
        }
    }

    func includes(_ item: ManagedExtension) -> Bool {
        switch self {
        case .all:
            return true
        case .enabled:
            return item.state == .enabled
        case .disabled:
            return item.state == .disabled
        case .needsReview:
            return item.state == .needsApproval
                || item.state == .superseded
                || item.kind == .kernelExtension
                || item.kind == .legacyPlugin
        }
    }
}

struct ExtensionsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var filter: ManagedExtensionFilter = .all

    private var filteredItems: [ManagedExtension] {
        appState.managedExtensions.filter { item in
            guard filter.includes(item) else { return false }
            guard !searchText.isEmpty else { return true }
            let query = searchText.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            return searchableText(for: item).folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ).contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if appState.isScanningExtensions && !appState.hasScannedExtensions {
                    ProgressView(LocalizedStringKey("Reading extension registries and browser manifests..."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !appState.hasScannedExtensions {
                    EmptyStateView(
                        "Extensions",
                        systemImage: "puzzlepiece.extension.fill",
                        description: "Inspect third-party app, system, browser, Finder, Share, widget, screen saver, Quick Look, preference pane, and legacy extensions with local evidence.",
                        action: { appState.scanExtensions() },
                        actionLabel: "Scan Extensions",
                        tint: Tint.purple
                    )
                } else if appState.managedExtensions.isEmpty {
                    EmptyStateView(
                        "No Third-Party Extensions Found",
                        systemImage: "checkmark.shield.fill",
                        description: "AppSift did not find third-party extensions in macOS registries, supported browser profiles, or extension folders.",
                        action: { appState.scanExtensions(force: true) },
                        actionLabel: "Scan Again",
                        tint: Tint.green
                    )
                } else {
                    results
                }
            }
        }
        .navigationTitle("Extensions")
        .searchable(text: $searchText, prompt: "Search extensions")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    appState.scanExtensions(force: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(appState.isScanningExtensions)

                Button {
                    appState.openExtensionsSettings()
                } label: {
                    Label("Open Extensions Settings", systemImage: "gear")
                }
            }
        }
        .onAppear {
            appState.scanExtensions()
        }
        .onChange(of: appState.hasFullDiskAccess) { granted in
            guard granted,
                  appState.hasScannedExtensions,
                  appState.incompleteExtensionSources.contains(.browserExtensions) else {
                return
            }
            appState.scanExtensions(force: true)
        }
        .alert("Extension Action Failed", isPresented: Binding(
            get: { appState.extensionActionError != nil },
            set: { if !$0 { appState.extensionActionError = nil } }
        )) {
            Button("OK", role: .cancel) {
                appState.extensionActionError = nil
            }
        } message: {
            Text(appState.extensionActionError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(
                systemName: "puzzlepiece.extension.fill",
                tint: Tint.purple,
                size: 34
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("Extensions")
                    .font(.title2.weight(.semibold))
                Text("One evidence-backed inventory for macOS and browser extensions. AppSift routes changes to the owning browser or System Settings instead of deleting protected components.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            if appState.isScanningExtensions {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                summary
                privacyNotice

                if !appState.incompleteExtensionSources.isEmpty {
                    incompleteNotice
                }

                Picker("Filter", selection: $filter) {
                    ForEach(ManagedExtensionFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                if filteredItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("No Matching Extensions")
                            .font(.headline)
                        Text("Try another search or status filter.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else {
                    ForEach(ManagedExtensionKind.allCases, id: \.self) { kind in
                        let items = filteredItems.filter { $0.kind == kind }
                        if !items.isEmpty {
                            extensionGroup(kind: kind, items: items)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            StatusChip(
                label: String(
                    format: String(localized: "%lld total"),
                    Int64(appState.managedExtensions.count)
                ),
                systemImage: "list.bullet",
                tint: Tint.blue
            )
            StatusChip(
                label: String(
                    format: String(localized: "%lld enabled"),
                    count(state: .enabled)
                ),
                systemImage: "checkmark.circle.fill",
                tint: Tint.green
            )
            StatusChip(
                label: String(
                    format: String(localized: "%lld disabled"),
                    count(state: .disabled)
                ),
                systemImage: "pause.circle.fill",
                tint: .secondary
            )
            StatusChip(
                label: String(
                    format: String(localized: "%lld need review"),
                    Int64(appState.managedExtensions.count {
                        ManagedExtensionFilter.needsReview.includes($0)
                    })
                ),
                systemImage: "exclamationmark.triangle.fill",
                tint: Tint.orange
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var privacyNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(Tint.blue)
                .padding(.top, 1)
            Text("AppSift only reads extension metadata and local registry/state fields needed for this inventory. Browsing history, cookies, open tabs, saved passwords, account content, and page content are not collected or displayed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Tint.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Tint.blue.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var incompleteNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tint.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Some Extension Sources Were Incomplete")
                    .font(.caption.weight(.semibold))
                Text("One or more registries, browser profiles, or extension folders could not be read completely. AppSift shows verified results without guessing about missing items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(incompleteSourceSummary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Tint.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Tint.orange.opacity(0.2), lineWidth: 0.5)
        )
    }

    private func extensionGroup(
        kind: ManagedExtensionKind,
        items: [ManagedExtension]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: kind.icon)
                    .foregroundStyle(kind.tint)
                Text(kind.title)
                    .font(.headline)
                Text(items.count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ForEach(items) { item in
                ManagedExtensionRow(
                    item: item,
                    manage: { appState.manageExtension(item) },
                    reveal: { appState.revealExtension(item) }
                )
            }
        }
    }

    private func searchableText(for item: ManagedExtension) -> String {
        [
            item.name,
            item.identifier,
            item.version,
            item.owner?.name,
            item.owner?.bundleIdentifier,
            item.developerName,
            item.teamIdentifier,
            item.profileName,
            item.url?.path,
            item.kind.rawValue,
            item.state.rawValue,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private func count(state: ManagedExtensionState) -> Int64 {
        Int64(appState.managedExtensions.count { $0.state == state })
    }

    private var incompleteSourceSummary: String {
        appState.incompleteExtensionSources
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.title)
            .joined(separator: " · ")
    }
}

private struct ManagedExtensionRow: View {
    let item: ManagedExtension
    let manage: () -> Void
    let reveal: () -> Void

    var body: some View {
        CardSurface(padding: 12, elevation: .flat) {
            HStack(alignment: .top, spacing: 12) {
                extensionIcon

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        StatusChip(
                            label: item.state.title,
                            systemImage: item.state.icon,
                            tint: item.state.tint
                        )
                        StatusChip(
                            label: item.scope.title,
                            systemImage: item.scope.icon,
                            tint: .secondary
                        )
                    }

                    if let owner = item.owner {
                        HStack(spacing: 5) {
                            Text(owner.name)
                            if let profile = item.profileName {
                                Text("·")
                                Text(profileDisplayName(profile))
                                    .monospaced()
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    } else if let profile = item.profileName {
                        Text(profileDisplayName(profile))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(item.identifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    HStack(spacing: 6) {
                        if let version = item.version {
                            Text(String(format: String(localized: "Version %@"), version))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                        }
                        if let count = item.permissionCount {
                            Text(
                                String(
                                    format: String(localized: "%lld declared permissions"),
                                    Int64(count)
                                )
                            )
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Tint.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Tint.orange.opacity(0.08), in: Capsule())
                        }
                        ForEach(
                            item.evidence.sorted { $0.rawValue < $1.rawValue },
                            id: \.self
                        ) { evidence in
                            Text(evidence.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                        }
                    }

                    if let developer = item.developerName {
                        Text(developer)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else if let teamIdentifier = item.teamIdentifier {
                        Text(teamIdentifier)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }

                    if let path = item.url?.path {
                        Text(path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 7) {
                    Button(action: manage) {
                        Label(item.management.buttonTitle, systemImage: item.management.icon)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(item.kind.tint)

                    if item.url != nil, item.management != .reveal {
                        Button(action: reveal) {
                            Label("Reveal", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var extensionIcon: some View {
        let iconURL = item.url ?? item.owner?.url
        if let iconURL,
           FileManager.default.fileExists(atPath: iconURL.path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: iconURL.path))
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .padding(3)
                .background(item.kind.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        } else {
            IconTile(systemName: item.kind.icon, tint: item.kind.tint, size: 30)
        }
    }

    private func profileDisplayName(_ value: String) -> String {
        switch value {
        case "Network": return String(localized: "Network")
        case "Driver": return String(localized: "Driver")
        case "Endpoint Security": return String(localized: "Endpoint Security")
        case "Camera": return String(localized: "Camera")
        case "System": return String(localized: "System")
        default: return value
        }
    }
}

private extension ManagedExtensionKind {
    var title: LocalizedStringKey {
        switch self {
        case .appExtension: return "App Extensions"
        case .browserExtension: return "Browser Extensions"
        case .finderExtension: return "Finder Extensions"
        case .shareExtension: return "Share Extensions"
        case .widget: return "Widgets"
        case .systemExtension: return "System Extensions"
        case .preferencePane: return "Preference Panes"
        case .screenSaver: return "Screen Savers"
        case .quickLook: return "Quick Look Extensions"
        case .legacyPlugin: return "Legacy Internet Plug-ins"
        case .kernelExtension: return "Kernel Extensions"
        }
    }

    var icon: String {
        switch self {
        case .appExtension: return "puzzlepiece.extension.fill"
        case .browserExtension: return "globe"
        case .finderExtension: return "folder.badge.gearshape"
        case .shareExtension: return "square.and.arrow.up.fill"
        case .widget: return "rectangle.3.group.fill"
        case .systemExtension: return "gearshape.2.fill"
        case .preferencePane: return "switch.2"
        case .screenSaver: return "display"
        case .quickLook: return "eye.fill"
        case .legacyPlugin: return "shippingbox.fill"
        case .kernelExtension: return "cpu.fill"
        }
    }

    var tint: Color {
        switch self {
        case .appExtension: return Tint.purple
        case .browserExtension: return Tint.blue
        case .finderExtension: return Tint.cyan
        case .shareExtension: return Tint.green
        case .widget: return Tint.purple
        case .systemExtension: return Tint.orange
        case .preferencePane: return Tint.cyan
        case .screenSaver: return Tint.pink
        case .quickLook: return Tint.blue
        case .legacyPlugin: return .secondary
        case .kernelExtension: return Tint.red
        }
    }
}

private extension ManagedExtensionState {
    var title: String {
        switch self {
        case .enabled: return String(localized: "Enabled")
        case .disabled: return String(localized: "Disabled")
        case .needsApproval: return String(localized: "Needs Approval")
        case .systemDefault: return String(localized: "System Default")
        case .installed: return String(localized: "Installed")
        case .superseded: return String(localized: "Superseded")
        case .unknown: return String(localized: "Unknown")
        }
    }

    var icon: String {
        switch self {
        case .enabled: return "checkmark.circle.fill"
        case .disabled: return "pause.circle.fill"
        case .needsApproval: return "exclamationmark.triangle.fill"
        case .systemDefault: return "gearshape.fill"
        case .installed: return "checkmark.seal.fill"
        case .superseded: return "arrow.triangle.2.circlepath"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .enabled: return Tint.green
        case .disabled: return .secondary
        case .needsApproval: return Tint.orange
        case .systemDefault: return Tint.blue
        case .installed: return Tint.green
        case .superseded: return Tint.orange
        case .unknown: return .secondary
        }
    }
}

private extension ManagedExtensionScope {
    var title: String {
        switch self {
        case .user: return String(localized: "User")
        case .system: return String(localized: "System")
        case .embedded: return String(localized: "Embedded")
        }
    }

    var icon: String {
        switch self {
        case .user: return "person.fill"
        case .system: return "desktopcomputer"
        case .embedded: return "app.badge"
        }
    }
}

private extension ManagedExtensionEvidence {
    var title: String {
        switch self {
        case .pluginKitRegistry: return String(localized: "PlugInKit")
        case .systemExtensionRegistry: return String(localized: "System registry")
        case .browserManifest: return String(localized: "Browser manifest")
        case .browserProfileRegistry: return String(localized: "Browser profile registry")
        case .browserPreference: return String(localized: "Local enabled state")
        case .filesystemBundle: return String(localized: "Bundle on disk")
        case .codeSignature: return String(localized: "Verified signature")
        case .ownerCodeSignature: return String(localized: "Verified owner signature")
        case .containingApplication: return String(localized: "Containing app")
        }
    }
}

private extension ManagedExtensionScanSource {
    var title: String {
        switch self {
        case .appExtensions: return String(localized: "App extensions")
        case .systemExtensions: return String(localized: "System extensions")
        case .browserExtensions: return String(localized: "Browser extensions")
        case .legacyBundles: return String(localized: "Legacy bundles")
        }
    }
}

private extension ManagedExtensionManagement {
    var buttonTitle: String {
        switch self {
        case .systemSettings: return String(localized: "Open Settings")
        case .browser: return String(localized: "Open Browser")
        case .reveal: return String(localized: "Reveal")
        }
    }

    var icon: String {
        switch self {
        case .systemSettings: return "gear"
        case .browser: return "globe"
        case .reveal: return "folder"
        }
    }
}
