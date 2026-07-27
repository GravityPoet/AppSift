import SwiftUI

enum SidebarPrimaryDestination: String, CaseIterable, Identifiable {
    case dashboard
    case installedApps
    case spaceLens
    case tools

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .dashboard: return "Dashboard"
        case .installedApps: return "Installed Apps"
        case .spaceLens: return "Space Lens"
        case .tools: return "Tools"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "sparkles"
        case .installedApps: return "square.grid.2x2"
        case .spaceLens: return "square.3.layers.3d"
        case .tools: return "wrench.and.screwdriver"
        }
    }

    var section: AppSection {
        switch self {
        case .dashboard: return .cleaning(.smartScan)
        case .installedApps: return .apps
        case .spaceLens: return .spaceLens
        case .tools: return .tools
        }
    }

    static func selection(for section: AppSection?) -> SidebarPrimaryDestination? {
        switch section {
        case .cleaning(.smartScan):
            return .dashboard
        case .apps:
            return .installedApps
        case .spaceLens:
            return .spaceLens
        case nil:
            return nil
        default:
            return .tools
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var permission = PermissionCoordinator.shared
    @State private var selectedSection: AppSection? = .cleaning(.smartScan)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    init(initialSection: AppSection = .cleaning(.smartScan)) {
        _selectedSection = State(initialValue: initialSection)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .frame(minWidth: 210)
                .navigationSplitViewColumnWidth(min: 210, ideal: 224, max: 300)
        } detail: {
            detailContainer
        }
        .frame(minWidth: 980, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.checkFullDiskAccess()
            appState.refreshRemovalHistory()
            permission.refreshStatus()
        }
        .onChange(of: appState.pendingExternalApp) { app in
            // A right-clicked app arrived via Finder Services — surface the
            // Installed Apps view so its related-files scan is visible.
            guard app != nil else { return }
            selectedSection = .apps
            appState.pendingExternalApp = nil
        }
        .onAppear {
            // Covers a request that landed before MainWindow mounted (cold
            // launch, or while onboarding was still showing) — onChange alone
            // fires only on subsequent changes and would miss it.
            if appState.pendingExternalApp != nil {
                selectedSection = .apps
                appState.pendingExternalApp = nil
            }
        }
        .onChange(of: appState.cleanErrorIsFDAFixable) { isFDAFixable in
            // Auto-route FDA-fixable clean errors straight into the rich
            // sheet — skip the generic alert entirely so the user gets
            // 1-tap remediation instead of "Check the log for details".
            guard isFDAFixable else { return }
            let pending = appState.pendingPermissionRetryItems
            appState.cleanError = nil
            appState.cleanErrorIsFDAFixable = false
            appState.requestFullDiskAccessAndRetry(
                items: pending,
                context: .cleanup(failedCount: pending.count)
            )
        }
        .onChange(of: appState.removalNeedsFullDiskAccess) { needs in
            // Keep the uninstall retry observer at the window root. A partial
            // removal can move the app bundle successfully and make its detail
            // view disappear before permission-denied leftovers are retried.
            guard needs else { return }
            appState.requestFullDiskAccessAndRetryAppRemoval()
        }
        .alert("Couldn't clean everything", isPresented: Binding(
            get: { appState.cleanError != nil && !appState.cleanErrorIsFDAFixable },
            set: { if !$0 { appState.cleanError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.cleanError = nil }
        } message: {
            Text(appState.cleanError ?? "")
        }
        .sheet(isPresented: Binding(
            get: { permission.isRequesting },
            set: { if !$0 { permission.dismiss(callRetry: false) } }
        )) {
            PermissionSheet()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: sidebarSelection) {
                Section("Overview") {
                    ForEach(SidebarPrimaryDestination.allCases) { destination in
                        sidebarRow(destination)
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Feature navigation")
            .accessibilityIdentifier("main.sidebar")

            Divider()
            healthFooter
        }
        .background(.bar)
        .navigationTitle("AppSift")
    }

    private var sidebarSelection: Binding<SidebarPrimaryDestination?> {
        Binding(
            get: {
                SidebarPrimaryDestination.selection(for: selectedSection)
            },
            set: { destination in
                guard let destination else { return }
                navigate(to: destination.section)
            }
        )
    }

    private func sidebarRow(_ destination: SidebarPrimaryDestination) -> some View {
        let isSelected = SidebarPrimaryDestination.selection(
            for: selectedSection
        ) == destination
        let selectedText = Color(
            nsColor: .alternateSelectedControlTextColor
        )
        return HStack(spacing: 8) {
            Image(systemName: destination.systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(
                    isSelected ? selectedText : Color.accentColor
                )
                .frame(width: 18)
            Text(destination.label)
                .foregroundStyle(
                    isSelected
                        ? selectedText
                        : Color(nsColor: .labelColor)
                )
                .lineLimit(1)
            Spacer(minLength: 6)
            if let badge = sidebarBadge(for: destination) {
                Text(badge)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(
                        isSelected
                            ? selectedText.opacity(0.86)
                            : Color(nsColor: .secondaryLabelColor)
                    )
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(destination.label))
        .accessibilityValue(
            Text(verbatim: sidebarBadge(for: destination) ?? "")
        )
        .accessibilityIdentifier("main.sidebar.item.\(destination.rawValue)")
        .tag(destination)
    }

    private func navigate(to section: AppSection) {
        if section == .cleaning(.smartScan) {
            appState.showDashboardOverview()
        }
        selectedSection = section
    }

    private func sidebarBadge(
        for destination: SidebarPrimaryDestination
    ) -> String? {
        guard destination == .installedApps,
              !appState.installedApps.isEmpty else {
            return nil
        }
        return "\(appState.installedApps.count)"
    }

    private var healthFooter: some View {
        let ok = appState.hasFullDiskAccess
        let tint = ok ? Tint.green : Tint.orange
        return HStack(spacing: 6) {
            Button {
                navigate(to: .systemHealth)
            } label: {
                HStack(spacing: 8) {
                    PulsingDot(tint: tint, isPulsing: !ok)
                        .fixedSize()
                    Text(LocalizedStringKey(ok ? "Ready to clean" : "Limited access"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("main.health.status")
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("System Health")
            .accessibilityValue(
                Text(LocalizedStringKey(ok ? "Ready to clean" : "Limited access"))
            )

            if !ok {
                Button("Fix") {
                    permission.requestAccess(context: .general) {
                        appState.checkFullDiskAccess()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Fix permission")
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContainer: some View {
        VStack(spacing: 0) {
            if !appState.hasFullDiskAccess && !appState.fdaBannerDismissed {
                fdaToast
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity)
                    )
            }
            if let candidate = appState.pendingTrashAppReviews.first {
                trashAppReviewBanner(candidate)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity)
                    )
            }
            detailView
                .id(selectedSection)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8),
                   value: appState.fdaBannerDismissed)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8),
                   value: appState.hasFullDiskAccess)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8),
                   value: appState.pendingTrashAppReviews.count)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main content")
        .accessibilityIdentifier("main.detail")
        .background(
            // Quiet ambient gradient under every section. Static layers,
            // opacities kept low enough to stay clean in light mode.
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [Tint.blue.opacity(0.05), .clear],
                    startPoint: .topLeading, endPoint: .center
                )
                RadialGradient(
                    colors: [Tint.purple.opacity(0.03), .clear],
                    center: .topTrailing, startRadius: 0, endRadius: 600
                )
            }
            .ignoresSafeArea()
        )
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .tools:
            ToolboxView(navigate: navigate)
        case .systemHealth:
            SystemHealthView(
                macOSUpdateCenter: appState.macOSUpdateCenter,
                iosBackupCenter: appState.iosBackupCenter,
                residueCenter: appState.systemResidueCenter
            ) { section in
                selectedSection = section
            }
        case .apps:
            AppListView()
        case .appUpdates:
            AppUpdatesView()
        case .installationFiles:
            InstallationFilesView()
        case .spaceLens:
            SpaceLensView()
        case .duplicateFiles:
            DuplicateFilesView()
        case .similarImages:
            SimilarImagesView(center: appState.similarImageCenter)
        case .startupItems:
            StartupItemsView()
        case .extensions:
            ExtensionsView()
        case .appPermissions:
            AppPermissionsView()
        case .browserPrivacy:
            BrowserPrivacyView(center: appState.browserPrivacyCenter)
        case .defaultApplications:
            DefaultApplicationsView()
        case .removalHistory:
            RemovalHistoryView()
        case .orphans:
            OrphanListView()
        case .timeMachine:
            TimeMachineSnapshotsView()
        case .iosBackups:
            IOSBackupsView(center: appState.iosBackupCenter)
        case .downloadsBySource:
            DownloadsBySourceView(center: appState.downloadSourceCenter)
        case .systemMaintenance:
            SystemMaintenanceView(center: appState.systemMaintenanceCenter)
        case .systemResidue:
            SystemResidueView(center: appState.systemResidueCenter)
        case .cleaning(let category):
            if category == .smartScan {
                DashboardView { section in
                    selectedSection = section
                }
            } else {
                CategoryDetailView(category: category)
            }
        case nil:
            EmptyStateView("AppSift", systemImage: "sparkles",
                           description: "Select a category from the sidebar to get started.")
        }
    }

    @ViewBuilder
    private var pulsingLockIcon: some View {
        pulsingLockIconView()
    }

    // Quiet FDA bar — single tinted surface, no gradient or glow.
    private var fdaToast: some View {
        HStack(spacing: 12) {
            IconTile(systemName: "lock.shield.fill", tint: Tint.orange, size: 32, corner: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text("Full Disk Access required")
                    .font(.system(size: 13, weight: .semibold))
                Text("1-tap setup. We'll auto-retry what failed.")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button("Set up") {
                permission.requestAccess(context: .general) {
                    appState.checkFullDiskAccess()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Button {
                appState.fdaBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color(red: 0.18, green: 0.13, blue: 0.08)
                        : Color(red: 1.00, green: 0.97, blue: 0.93)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Tint.orange.opacity(0.22), lineWidth: 0.5)
        )
    }

    private func trashAppReviewBanner(_ candidate: TrashAppCandidate) -> some View {
        HStack(spacing: 12) {
            IconTile(systemName: "trash.circle.fill", tint: Tint.purple, size: 32, corner: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(
                    appState.pendingTrashAppReviews.count == 1
                        ? "App moved to Trash"
                        : "Apps moved to Trash"
                ))
                .font(.system(size: 13, weight: .semibold))

                Text(trashReviewDescription(candidate))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button("Review Leftovers") {
                appState.reviewNextTrashApp()
            }
            .buttonStyle(.borderedProminent)
            .tint(Tint.purple)
            .controlSize(.regular)

            Button {
                appState.dismissTrashAppReviews()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Tint.purple.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Tint.purple.opacity(0.22), lineWidth: 0.5)
        )
    }

    private func trashReviewDescription(_ candidate: TrashAppCandidate) -> String {
        let additionalCount = appState.pendingTrashAppReviews.count - 1
        if additionalCount == 0 {
            return String(
                format: String(localized: "%@ was moved to Trash. Review its leftover files?"),
                candidate.appName
            )
        }
        return String(
            format: String(localized: "%@ and %lld more apps were moved to Trash. Review leftover files?"),
            candidate.appName,
            Int64(additionalCount)
        )
    }
}

@ViewBuilder
private func pulsingLockIconView() -> some View {
    let base = Image(systemName: "lock.shield.fill")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.white)
    if #available(macOS 14.0, *) {
        base.symbolEffect(.pulse.byLayer, options: .repeating)
    } else {
        base
    }
}

/// Small reusable status dot with optional pulse. Used in the sidebar health
/// footer and other "system status" surfaces.
private struct PulsingDot: View {
    let tint: Color
    var isPulsing: Bool = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isPulsing && !reduceMotion {
                Circle()
                    .stroke(tint.opacity(pulse ? 0.0 : 0.6), lineWidth: 2)
                    .frame(width: 18, height: 18)
                    .scaleEffect(pulse ? 1.6 : 0.8)
            } else {
                Circle()
                    .fill(tint.opacity(0.20))
                    .frame(width: 16, height: 16)
            }
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .shadow(color: tint.opacity(0.6), radius: 3)
        }
        .frame(width: 18, height: 18)
        .onAppear { syncPulse() }
        // The FDA status can flip while the window stays open — onAppear
        // alone latches the first value and never starts/stops the loop.
        .onChange(of: isPulsing) { _ in syncPulse() }
    }

    private func syncPulse() {
        guard isPulsing, !reduceMotion else {
            pulse = false
            return
        }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}
