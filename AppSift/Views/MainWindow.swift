import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var permission = PermissionCoordinator.shared
    @State private var selectedSection: AppSection? = .cleaning(.smartScan)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .frame(minWidth: 232)
                .navigationSplitViewColumnWidth(min: 232, ideal: 244, max: 320)
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    sidebarSection("Overview") {
                        navRow(section: .cleaning(.smartScan), label: "Dashboard",
                               icon: "sparkles", tint: Tint.blue,
                               badge: dashboardBadge)
                    }

                    sidebarSection("Applications") {
                        navRow(section: .apps, label: "Installed Apps",
                               icon: "square.grid.2x2.fill", tint: Tint.purple,
                               badge: appState.installedApps.isEmpty ? nil : "\(appState.installedApps.count)")
                        navRow(section: .appUpdates, label: "App Updates",
                               icon: "arrow.triangle.2.circlepath.circle.fill", tint: Tint.blue,
                               badge: appState.availableAppUpdateCount == 0
                                   ? nil
                                   : "\(appState.availableAppUpdateCount)")
                        navRow(section: .installationFiles, label: "Installation Files",
                               icon: "shippingbox.fill", tint: Tint.orange,
                               badge: nil)
                        navRow(section: .startupItems, label: "Startup Items",
                               icon: "power.circle.fill", tint: Tint.orange,
                               badge: startupItemsBadge)
                        navRow(section: .extensions, label: "Extensions",
                               icon: "puzzlepiece.extension.fill", tint: Tint.purple,
                               badge: extensionsBadge)
                        navRow(section: .appPermissions, label: "Privacy Permissions",
                               icon: "hand.raised.fill", tint: Tint.blue,
                               badge: appPermissionsBadge)
                        navRow(section: .defaultApplications, label: "Default Applications",
                               icon: "arrow.up.forward.app.fill", tint: Tint.blue,
                               badge: defaultApplicationsBadge)
                        navRow(section: .removalHistory, label: "Removal History",
                               icon: "arrow.uturn.backward.circle.fill", tint: Tint.green,
                               badge: appState.availableRestorableItemCount == 0
                                   ? nil
                                   : "\(appState.availableRestorableItemCount)")
                        navRow(section: .orphans, label: "Orphaned Files",
                               icon: "doc.questionmark.fill", tint: Tint.pink,
                               badge: appState.orphanedFiles.isEmpty ? nil : "\(appState.orphanedFiles.count)")
                    }

                    sidebarSection("Storage") {
                        navRow(section: .timeMachine, label: "Time Machine Snapshots",
                               icon: "clock.arrow.circlepath", tint: Tint.orange,
                               badge: appState.localTimeMachineSnapshots.isEmpty
                                   ? nil
                                   : "\(appState.localTimeMachineSnapshots.count)")
                    }

                    sidebarSection("Cleanup") {
                        ForEach(CleaningCategory.scannable) { category in
                            navRow(section: .cleaning(category),
                                   label: LocalizedStringKey(category.rawValue),
                                   icon: category.icon,
                                   tint: category.color,
                                   badge: sizeBadge(for: category))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 14)
            }

            healthFooter
        }
        .background(.bar)
        .navigationTitle("AppSift")
    }

    private func sidebarSection<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(title)
                .padding(.horizontal, 8)
            content()
        }
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }

    private func navRow(section: AppSection, label: LocalizedStringKey, icon: String,
                        tint: Color, badge: String?) -> some View {
        SidebarNavRow(
            label: label, icon: icon, tint: tint, badge: badge,
            isSelected: selectedSection == section
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedSection = section
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            selectedSection = section
        }
    }

    private var dashboardBadge: String? {
        appState.totalJunkSize > 0
            ? ByteCountFormatter.string(fromByteCount: appState.totalJunkSize, countStyle: .file)
            : nil
    }

    private var startupItemsBadge: String? {
        guard appState.hasScannedStartupItems else { return nil }
        let attentionCount = appState.startupItems.count {
            $0.state == .requiresApproval || $0.isMissing
        }
        return attentionCount == 0 ? nil : "\(attentionCount)"
    }

    private var extensionsBadge: String? {
        guard appState.hasScannedExtensions,
              !appState.managedExtensions.isEmpty else { return nil }
        return "\(appState.managedExtensions.count)"
    }

    private var defaultApplicationsBadge: String? {
        guard appState.hasScannedDefaultApplications,
              !appState.defaultApplications.isEmpty else { return nil }
        return "\(appState.defaultApplications.count)"
    }

    private var appPermissionsBadge: String? {
        guard appState.hasScannedAppPermissions,
              appState.highImpactAllowedAppPermissionCount > 0 else { return nil }
        return "\(appState.highImpactAllowedAppPermissionCount)"
    }

    private func sizeBadge(for category: CleaningCategory) -> String? {
        guard let size = appState.categoryResults[category]?.totalSize, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private var healthFooter: some View {
        let ok = appState.hasFullDiskAccess
        let tint = ok ? Tint.green : Tint.orange
        return HStack(spacing: 10) {
            PulsingDot(tint: tint, isPulsing: !ok)
                .fixedSize()

            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(ok ? "Ready to clean" : "Limited access"))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Explicit solid color — same vibrancy-collapse guard as the
                    // sidebar rows (#117); this title also inherited the default.
                    .foregroundStyle(colorScheme == .dark
                        ? Color.white.opacity(0.92)
                        : Color.black.opacity(0.85))
                Text(LocalizedStringKey(ok ? "Full Disk Access granted" : "Grant FDA in Settings"))
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        case .apps:
            AppListView()
        case .appUpdates:
            AppUpdatesView()
        case .installationFiles:
            InstallationFilesView()
        case .startupItems:
            StartupItemsView()
        case .extensions:
            ExtensionsView()
        case .appPermissions:
            AppPermissionsView()
        case .defaultApplications:
            DefaultApplicationsView()
        case .removalHistory:
            RemovalHistoryView()
        case .orphans:
            OrphanListView()
        case .timeMachine:
            TimeMachineSnapshotsView()
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
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
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
                .fill(Tint.orange.opacity(0.08))
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

/// Sidebar row with a springy hover highlight. Extracted to a struct so each
/// row owns its hover state; the selected row's IconTile glows via the shared
/// glow treatment in AppTheme.
private struct SidebarNavRow: View {
    let label: LocalizedStringKey
    let icon: String
    let tint: Color
    let badge: String?
    let isSelected: Bool

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            IconTile(systemName: icon, tint: tint, size: 24, glow: isSelected)
                .fixedSize()
            Text(label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                // Force an explicit, solid foreground instead of inheriting the
                // sidebar list's default. On some configs (custom accent /
                // reduced transparency, seen on M1 Max — issue #117) the
                // inherited emphasized/vibrant label style resolves transparent
                // and the row text disappears while explicitly-colored text
                // (headers, badges) stays visible. A colorScheme-driven solid
                // color sidesteps that vibrancy path entirely.
                .foregroundStyle(isSelected ? Color.white : labelColor)
            Spacer(minLength: 4)
            if let badge {
                Text(badge)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(isSelected ? Color.white.opacity(0.18) : Color.primary.opacity(0.06))
                    )
                    .contentTransition(.numericText())
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Leading anchor keeps the row from clipping against the sidebar edge.
        .scaleEffect(hovering && !reduceMotion ? 1.02 : 1, anchor: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Tint.blue : Color.primary.opacity(hovering ? 0.05 : 0))
        )
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: isSelected)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Solid, opaque label color that adapts to light/dark without routing
    /// through the sidebar's vibrant primary style (see #117).
    private var labelColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.92)
            : Color.black.opacity(0.85)
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
