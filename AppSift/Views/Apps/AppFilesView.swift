import SwiftUI
import UniformTypeIdentifiers

/// View-side grouping of discovered leftovers into CleanMyMac-style buckets.
/// Purely presentational — AppState's flat `discoveredFiles` stays the source
/// of truth so the removal/selection logic is untouched.
enum LeftoverGroup: String, CaseIterable, Identifiable {
    case application = "Application"
    case caches = "Caches"
    case appSupport = "Application Support"
    case preferences = "Preferences"
    case logs = "Logs"
    case containers = "Containers"
    case launchAgents = "Launch Agents"
    case other = "Other Files"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .application: return "app.fill"
        case .caches: return "internaldrive.fill"
        case .appSupport: return "shippingbox.fill"
        case .preferences: return "gearshape.fill"
        case .logs: return "doc.text.fill"
        case .containers: return "cube.box.fill"
        case .launchAgents: return "bolt.fill"
        case .other: return "doc.fill"
        }
    }

    var tint: Color {
        switch self {
        case .application: return Tint.blue
        case .caches: return Tint.orange
        case .appSupport: return Tint.purple
        case .preferences: return Tint.cyan
        case .logs: return Tint.yellow
        case .containers: return Tint.pink
        case .launchAgents: return Tint.red
        case .other: return Tint.green
        }
    }

    static func categorize(_ url: URL) -> LeftoverGroup {
        let path = url.path
        if path.hasSuffix(".app") { return .application }
        if path.contains("/Caches/") { return .caches }
        if path.contains("/Application Support/") { return .appSupport }
        if path.contains("/Preferences/") { return .preferences }
        if path.contains("/Logs/") || path.contains("/DiagnosticReports/") { return .logs }
        if path.contains("/Containers/") || path.contains("/Group Containers/") { return .containers }
        if path.contains("/LaunchAgents/") || path.contains("/LaunchDaemons/") { return .launchAgents }
        return .other
    }
}

struct AppFilesView: View {
    private enum PendingConfirmation {
        case removal
        case reset
        case officialUninstaller(AppOfficialUninstaller)
    }

    @EnvironmentObject var appState: AppState
    let app: InstalledApp

    @State private var collapsedGroups: Set<LeftoverGroup> = []
    @State private var protectedSectionExpanded = false
    @State private var iconHovering = false
    @State private var pendingConfirmation: PendingConfirmation?
    @State private var showInstallerPackageDetails = false
    @State private var showRelationshipDetails = false
    /// Recursive stats are calculated off the main thread. A generation token
    /// prevents a late result from a previously selected app from repainting
    /// the current detail view.
    @State private var statsCache: [URL: FileTreeStats] = [:]
    @State private var statsTask: Task<[URL: FileTreeStats], Never>?
    @State private var statsGeneration = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedStats: FileTreeStats {
        aggregateStats(for: Array(appState.selectedFiles))
    }

    private var selectedResetStats: FileTreeStats {
        aggregateStats(for: Array(appState.selectedAppResetFiles))
    }

    private var allRelatedStats: FileTreeStats {
        aggregateStats(for: appState.discoveredFiles)
    }

    /// Discovered files bucketed for display, preserving the sorted order
    /// inside each bucket. Only non-empty groups are shown.
    private var groupedFiles: [(group: LeftoverGroup, urls: [URL])] {
        let buckets = Dictionary(grouping: appState.discoveredFiles, by: LeftoverGroup.categorize)
        return LeftoverGroup.allCases.compactMap { group in
            guard let urls = buckets[group], !urls.isEmpty else { return nil }
            return (group, urls)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !appState.isReviewingTrashedApp,
               let installationInsights,
               installationInsights.hasVerifiedInsight {
                Divider()
                installationInsightsPanel(installationInsights)
            }

            if !appState.isReviewingTrashedApp,
               appState.isScanningAppRelationships || !relationshipGroups.isEmpty {
                Divider()
                relationshipSummaryPanel
            }

            Divider()

            // Content
            if appState.isScanningAppFiles {
                scanningState
            } else if appState.discoveredFiles.isEmpty && appState.protectedAppFiles.isEmpty {
                EmptyStateView(
                    "No Related Files",
                    systemImage: "checkmark.circle",
                    description: LocalizedStringKey(
                        String(format: String(localized: "No additional files found for %@."), app.appName)
                    ),
                    tint: Tint.green
                )
            } else {
                fileGroupsList

                if !appState.discoveredFiles.isEmpty {
                    actionBar
                }
            }
        }
        .onAppear { rebuildStatsCache() }
        .onChange(of: appState.discoveredFiles) { _ in rebuildStatsCache() }
        .onChange(of: app.id) { _ in
            protectedSectionExpanded = false
            pendingConfirmation = nil
            showInstallerPackageDetails = false
            showRelationshipDetails = false
        }
        .onDisappear { cancelStatsCalculation() }
        .sheet(isPresented: $showInstallerPackageDetails) {
            if let installerPackage = installationInsights?.installerPackage {
                InstallerPackageDetailsView(insights: installerPackage)
            }
        }
        .sheet(isPresented: $showRelationshipDetails) {
            AppRelationshipDetailsView(
                appName: app.appName,
                selectedApplicationID: app.id,
                groups: relationshipGroups,
                wasIncomplete: appState.selectedAppRelationships?.wasTruncated == true
                    || appState.selectedAppRelationships?.wasCancelled == true
            )
        }
        .alert(errorAlertTitle, isPresented: Binding(
            get: {
                appState.appInstallationActionError != nil
                    || (appState.removalError != nil && !appState.removalNeedsFullDiskAccess)
            },
            set: {
                if !$0 {
                    appState.appInstallationActionError = nil
                    appState.removalError = nil
                    appState.removalNeedsFullDiskAccess = false
                }
            }
        )) {
            Button("OK", role: .cancel) {
                appState.appInstallationActionError = nil
                appState.removalError = nil
                appState.removalNeedsFullDiskAccess = false
            }
        } message: {
            Text(errorAlertMessage)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            switch pendingConfirmation {
            case .removal:
                Button("Move to Trash", role: .destructive) {
                    pendingConfirmation = nil
                    appState.removeSelectedFiles()
                }
            case .reset:
                Button("Reset App", role: .destructive) {
                    pendingConfirmation = nil
                    appState.resetSelectedApp()
                }
            case .officialUninstaller(let uninstaller):
                Button("Open Uninstaller") {
                    pendingConfirmation = nil
                    appState.openOfficialUninstaller(uninstaller, for: app)
                }
            case nil:
                EmptyView()
            }
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 48, height: 48)
                .scaleEffect(iconHovering && !reduceMotion ? 1.06 : 1)
                .animation(reduceMotion ? nil : MotionTokens.snappy, value: iconHovering)
                .onHover { iconHovering = $0 }

            VStack(alignment: .leading, spacing: 4) {
                Text(app.appName)
                    .font(.title3.bold())
                Text(app.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if let version = app.versionSummary {
                        StatusChip(
                            label: String(
                                format: String(localized: "Version %@"),
                                version
                            ),
                            systemImage: "number",
                            tint: Tint.blue
                        )
                    }
                    signatureStatusChip
                    if appState.isReviewingTrashedApp {
                        StatusChip(
                            label: String(localized: "App is in Trash"),
                            systemImage: "trash",
                            tint: Tint.purple
                        )
                    }
                    notarizationStatusChip
                    if app.signature.isSandboxed == true {
                        StatusChip(
                            label: String(localized: "Sandboxed"),
                            systemImage: "shippingbox.fill",
                            tint: Tint.blue
                        )
                        .help("Uses the macOS App Sandbox.")
                    }
                }
            }

            Spacer()

            if !appState.discoveredFiles.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(itemsCountText(count: allRelatedStats.itemCount))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    CountUpBytes(bytes: allRelatedStats.allocatedSize)
                        .font(.callout.bold())
                }
                .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9),
                           value: appState.discoveredFiles.count)
            }
        }
        .padding()
    }

    private var installationInsights: AppInstallationInsights? {
        guard appState.selectedApp?.id == app.id else { return nil }
        return appState.selectedAppInstallationInsights
    }

    private var relationshipGroups: [AppRelationshipGroup] {
        guard appState.selectedApp?.id == app.id else { return [] }
        return appState.selectedAppRelationships?.groups(containing: app.id) ?? []
    }

    private var relatedApplicationCount: Int {
        appState.selectedAppRelationships?.relatedApplications(to: app.id).count ?? 0
    }

    private var relationshipSummaryPanel: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tint.purple)
                .frame(width: 26, height: 26)
                .background(
                    Tint.purple.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 7)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("App Group Relationships")
                    .font(.system(size: 12.5, weight: .semibold))
                if appState.isScanningAppRelationships {
                    Text("Verifying signed App Group relationships…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        String(
                            format: String(localized: "%lld signed groups · %lld related apps"),
                            Int64(relationshipGroups.count),
                            Int64(relatedApplicationCount)
                        )
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if appState.isScanningAppRelationships {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Review Relationships…") {
                    showRelationshipDetails = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.025))
    }

    @ViewBuilder
    private func installationInsightsPanel(
        _ insights: AppInstallationInsights
    ) -> some View {
        VStack(spacing: 0) {
            switch insights.source {
            case .macAppStore:
                installationInsightRow(
                    title: String(localized: "Mac App Store"),
                    detail: String(
                        localized: "App Store signature and receipt are present. Purchases and subscriptions stay in your Apple Account."
                    ),
                    systemImage: "bag.fill",
                    tint: Tint.blue
                ) {
                    EmptyView()
                }

            case .homebrewCask(let metadata):
                installationInsightRow(
                    title: String(
                        format: String(localized: "Homebrew Cask · %@"),
                        metadata.token
                    ),
                    detail: homebrewInsightDetail(metadata),
                    systemImage: "shippingbox.fill",
                    tint: Tint.green
                ) {
                    Button("Show Receipt") {
                        appState.revealHomebrewReceipt(metadata, for: app)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.isVerifyingInstallationAction)
                }

            case .unknown:
                EmptyView()
            }

            if insights.source != .unknown,
               insights.installerPackage != nil {
                Divider()
                    .padding(.leading, 48)
            }

            if let installerPackage = insights.installerPackage {
                installationInsightRow(
                    title: String(
                        format: String(
                            localized: "Installer Package · %lld receipt(s)"
                        ),
                        Int64(installerPackage.receipts.count)
                    ),
                    detail: installerPackageInsightDetail(installerPackage),
                    systemImage: "shippingbox.and.arrow.backward.fill",
                    tint: Tint.orange
                ) {
                    Button("Review Details…") {
                        showInstallerPackageDetails = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if (insights.source != .unknown || insights.installerPackage != nil),
               insights.officialUninstaller != nil {
                Divider()
                    .padding(.leading, 48)
            }

            if let uninstaller = insights.officialUninstaller {
                installationInsightRow(
                    title: String(localized: "Official Uninstaller"),
                    detail: String(
                        localized: "A same-developer uninstaller is available. Apple recommends using it for bundled system components."
                    ),
                    systemImage: "wrench.and.screwdriver.fill",
                    tint: Tint.orange
                ) {
                    Button("Open Uninstaller…") {
                        pendingConfirmation = .officialUninstaller(uninstaller)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Tint.orange)
                    .controlSize(.small)
                    .disabled(appState.isVerifyingInstallationAction)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.025))
    }

    private func installationInsightRow<Accessory: View>(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)
            accessory()
                .fixedSize()
        }
        .padding(.vertical, 5)
    }

    private func homebrewInsightDetail(
        _ metadata: HomebrewCaskInstallMetadata
    ) -> String {
        if metadata.extraCleanupPatternCount > 0 {
            return String(
                format: String(
                    localized: "Homebrew lists %lld extra cleanup patterns. AppSift never imports them automatically or treats them as removal authorization."
                ),
                Int64(metadata.extraCleanupPatternCount)
            )
        }
        return String(
            localized: "AppSift will not modify Homebrew’s installed record."
        )
    }

    private func installerPackageInsightDetail(
        _ insights: InstallerPackageInsights
    ) -> String {
        let summary = String(
            format: String(
                localized: "%lld payload paths · %lld existing external components (%lld shared, %lld system-sensitive, %lld unverified). External components stay protected and are never auto-selected."
            ),
            Int64(insights.payloadPathCount),
            Int64(insights.externalComponents.count),
            Int64(insights.sharedExternalComponentCount),
            Int64(insights.systemSensitiveExternalComponentCount),
            Int64(insights.unverifiedExternalComponentCount)
        )
        guard insights.isIncomplete else { return summary }
        return summary + " " + String(
            localized: "The receipt result is incomplete; some components or ownership checks were bounded or unavailable."
        )
    }

    @ViewBuilder
    private var signatureStatusChip: some View {
        switch app.signature.status {
        case .developerSigned:
            if let identity = app.signature.developerName ?? app.signature.teamIdentifier {
                StatusChip(
                    label: String(
                        format: String(localized: "Signed · %@"),
                        identity
                    ),
                    systemImage: "checkmark.shield.fill",
                    tint: Tint.green
                )
                .help(developerSignatureHelp)
            }
        case .locallySigned:
            StatusChip(
                label: String(localized: "Local signature"),
                systemImage: "signature",
                tint: Tint.orange
            )
            .help(app.signature.developerName ?? String(localized: "Local signature"))
        case .adHoc:
            StatusChip(
                label: String(localized: "Ad hoc signature"),
                systemImage: "signature",
                tint: Tint.orange
            )
        case .unsigned:
            StatusChip(
                label: String(localized: "Unsigned"),
                systemImage: "exclamationmark.shield.fill",
                tint: Tint.orange
            )
        case .invalid:
            StatusChip(
                label: String(localized: "Invalid signature"),
                systemImage: "xmark.shield.fill",
                tint: Tint.red
            )
        case .unknown:
            EmptyView()
        }
    }

    @ViewBuilder
    private var notarizationStatusChip: some View {
        switch app.signature.notarizationStatus {
        case .notarized:
            StatusChip(
                label: String(localized: "Notarized"),
                systemImage: "checkmark.seal.fill",
                tint: Tint.green
            )
            .help("Apple notarization verified")
        case .notNotarized:
            if app.signature.status == .developerSigned || app.signature.status == .locallySigned {
                StatusChip(
                    label: String(localized: "Signed but not notarized"),
                    systemImage: "exclamationmark.seal.fill",
                    tint: Tint.orange
                )
            }
        case .unknown:
            EmptyView()
        }
    }

    private var developerSignatureHelp: String {
        guard let teamIdentifier = app.signature.teamIdentifier else {
            return String(localized: "Valid developer signature")
        }
        return String(
            format: String(localized: "Valid developer signature · Team ID %@"),
            teamIdentifier
        )
    }

    // MARK: - Scanning state

    private var scanningState: some View {
        VStack(spacing: 14) {
            Spacer()
            if reduceMotion {
                ProgressView(LocalizedStringKey("Scanning for related files..."))
            } else {
                SearchPulse()
                Text("Scanning for related files...")
                    .font(.system(size: 13, weight: .medium))
            }
            Text(checkingLocationsText(count: appState.currentAppFileSearchLocationCount))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grouped list

    private var fileGroupsList: some View {
        List {
            ForEach(groupedFiles, id: \.group) { entry in
                DisclosureGroup(isExpanded: groupExpansionBinding(entry.group)) {
                    // No .staggered() inside the lazy List — a delayed reveal
                    // would blank rows as they scroll in. The removal
                    // transition still sweeps deleted rows out.
                    ForEach(entry.urls, id: \.self) { fileURL in
                        FileRow(
                            fileURL: fileURL,
                            isSelected: fileSelectionBinding(for: fileURL),
                            fileSize: statsCache[fileURL]?.allocatedSize,
                            evidence: appState.appFileMatchEvidenceByPath[
                                fileURL.standardizedFileURL.path
                            ] ?? .legacyUnknown,
                            onRemove: { removeSingleFile(fileURL) }
                        )
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .opacity,
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                )
                        )
                    }
                } label: {
                    groupHeader(entry.group, urls: entry.urls)
                }
            }

            if !appState.protectedAppFiles.isEmpty {
                DisclosureGroup(isExpanded: $protectedSectionExpanded) {
                    ForEach(appState.protectedAppFiles) { protectedFile in
                        protectedFileRow(protectedFile)
                    }
                } label: {
                    protectedFilesHeader
                }
            }
        }
        .id(app.id)
    }

    private var protectedFilesHeader: some View {
        HStack(spacing: 10) {
            IconTile(
                systemName: "lock.shield.fill",
                tint: Tint.orange,
                size: 22,
                corner: 6
            )
            VStack(alignment: .leading, spacing: 1) {
                Text("Excluded for safety")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("Kept because ownership is shared or uncertain.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(appState.protectedAppFiles.count.formatted())
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Tint.orange)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private func protectedFileRow(_ protectedFile: ProtectedAppFile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tint.orange)
                .frame(width: 22, height: 22)
                .background(Tint.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(protectedFile.url.lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(protectedFile.url.path)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !protectedFile.relatedApplications.isEmpty {
                    Text(protectedRelationshipSummary(protectedFile))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Tint.orange)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                Text(protectionReasonTitle(protectedFile.reason))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Tint.orange)
                Text(matchedItemsText(count: protectedFile.matchedItemCount))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 3)
        .help(protectedFile.url.path)
    }

    private func protectedRelationshipSummary(
        _ protectedFile: ProtectedAppFile
    ) -> String {
        let applications = protectedFile.relatedApplications
        let visibleNames = applications.prefix(3).map(\.name).joined(separator: ", ")
        let remaining = applications.count - min(applications.count, 3)
        let names = remaining > 0
            ? visibleNames + " " + String(
                format: String(localized: "+ %lld more"),
                Int64(remaining)
            )
            : visibleNames
        if protectedFile.reason == .sharedContainer {
            return String(format: String(localized: "Shared with %@"), names)
        }
        return String(format: String(localized: "Belongs to %@"), names)
    }

    private func groupHeader(_ group: LeftoverGroup, urls: [URL]) -> some View {
        let groupStats = aggregateStats(for: urls)
        let hasCompleteStats = urls.allSatisfy { statsCache[$0] != nil }
        let allSelected = urls.allSatisfy { appState.selectedFiles.contains($0) }

        return HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { allSelected },
                set: { selected in
                    if selected {
                        appState.selectedFiles.formUnion(urls)
                    } else {
                        appState.selectedFiles.subtract(urls)
                    }
                }
            )) {
                EmptyView()
            }
            .toggleStyle(AnimatedCheckboxStyle())
            .labelsHidden()

            IconTile(systemName: group.icon, tint: group.tint, size: 22, corner: 6)
            Text(LocalizedStringKey(group.rawValue))
                .font(.system(size: 12.5, weight: .semibold))
            Spacer()
            if !hasCompleteStats {
                ProgressView()
                    .controlSize(.mini)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(fileFolderCountText(groupStats))
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: groupStats.allocatedSize, countStyle: .file))
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func groupExpansionBinding(_ group: LeftoverGroup) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(group) },
            set: { expanded in
                let change = {
                    if expanded {
                        collapsedGroups.remove(group)
                    } else {
                        collapsedGroups.insert(group)
                    }
                }
                if reduceMotion {
                    change()
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { change() }
                }
            }
        )
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack {
            Button("Select All") {
                appState.selectedFiles = Set(appState.discoveredFiles)
            }
            Button("Deselect All") {
                appState.selectedFiles.removeAll()
            }

            Spacer()

            if !appState.selectedFiles.isEmpty {
                VStack(alignment: .trailing, spacing: 1) {
                    CountUpBytes(bytes: selectedStats.allocatedSize)
                        .font(.callout.bold())
                    Text(itemsCountText(count: selectedStats.itemCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if !appState.isReviewingTrashedApp,
                   !appState.availableAppResetFiles.isEmpty {
                    Button {
                        pendingConfirmation = .reset
                    } label: {
                        Label("Reset App…", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .tint(Tint.orange)
                    .disabled(!appState.canResetSelectedApp)
                    .help("Keep the app installed and move selected user data to Trash.")
                }

                Button(role: .destructive) {
                    pendingConfirmation = .removal
                } label: {
                    Text("Review & Remove")
                }
                .buttonStyle(GlowProminentButtonStyle(tint: Tint.red, gradient: TintGradient.destructive))
                .disabled(!appState.canRemoveSelectedAppFiles)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .trailing).combined(with: .opacity)
                )
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
                   value: appState.selectedFiles.isEmpty)
        .padding()
        .background(.bar)
    }

    // MARK: - Helpers

    private var errorAlertTitle: String {
        appState.appInstallationActionError == nil
            ? String(localized: "Removal Failed")
            : String(localized: "Action Failed")
    }

    private var errorAlertMessage: String {
        appState.appInstallationActionError ?? appState.removalError ?? ""
    }

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .removal:
            return String(localized: "Move selected items to Trash?")
        case .reset:
            return String(
                format: String(localized: "Reset %@ while keeping it installed?"),
                app.appName
            )
        case .officialUninstaller:
            return String(localized: "Open official uninstaller?")
        case nil:
            return ""
        }
    }

    private var confirmationMessage: String {
        switch pendingConfirmation {
        case .removal:
            return removalConfirmationMessage
        case .reset:
            return resetConfirmationMessage
        case .officialUninstaller(let uninstaller):
            return String(
                format: String(
                    localized: "AppSift will recheck the code signature before opening %@. AppSift itself will not remove anything."
                ),
                uninstaller.name
            )
        case nil:
            return ""
        }
    }

    private func itemsCountText(count: Int) -> String {
        String(format: String(localized: "%lld items"), Int64(count))
    }

    private var removalConfirmationMessage: String {
        if appState.isReviewingTrashedApp {
            return String(
                format: String(
                    localized: "AppSift will move %lld selected leftover items (%@) to Trash and save a restore receipt. The app already in Trash stays untouched. %lld protected groups stay untouched."
                ),
                Int64(selectedStats.itemCount),
                ByteCountFormatter.string(
                    fromByteCount: selectedStats.allocatedSize,
                    countStyle: .file
                ),
                Int64(appState.protectedAppFiles.count)
            )
        }

        var message = String(
            format: String(
                localized: "AppSift will quit %@ if needed, move %lld selected items (%@) to Trash, and save a restore receipt. %lld protected groups stay untouched."
            ),
            app.appName,
            Int64(selectedStats.itemCount),
            ByteCountFormatter.string(
                fromByteCount: selectedStats.allocatedSize,
                countStyle: .file
            ),
            Int64(appState.protectedAppFiles.count)
        )

        if let uninstaller = installationInsights?.officialUninstaller {
            message += "\n\n" + String(
                format: String(
                    localized: "A same-developer uninstaller (%@) is available. Apple recommends it when an app installs bundled system components."
                ),
                uninstaller.name
            )
        }
        if case .some(.homebrewCask(let metadata)) = installationInsights?.source {
            message += "\n\n" + String(
                format: String(
                    localized: "Homebrew still records %@ as installed. Removing it here does not update Homebrew’s installed record."
                ),
                metadata.token
            )
        }
        if appState.selectedFilesRequireAdministratorAccess {
            message += "\n\n" + String(
                localized: "Some selected items are owned by macOS or a system installer. AppSift will request administrator authorization once, stop matching background services, move the reviewed batch to Trash, and roll it back if verification fails."
            )
        }
        return message
    }

    private var resetConfirmationMessage: String {
        String(
            format: String(
                localized: "AppSift will quit %@, keep its application bundle installed, and move %lld selected user-data items (%@) to Trash. This can sign you out and remove settings, local databases, or app-managed documents. Shared data, system components, and %lld protected groups stay untouched. Restore from Removal History if needed."
            ),
            app.appName,
            Int64(selectedResetStats.itemCount),
            ByteCountFormatter.string(
                fromByteCount: selectedResetStats.allocatedSize,
                countStyle: .file
            ),
            Int64(appState.protectedAppFiles.count)
        )
    }

    private func checkingLocationsText(count: Int) -> String {
        String(format: String(localized: "Checking %lld locations..."), Int64(count))
    }

    private func matchedItemsText(count: Int) -> String {
        String(format: String(localized: "%lld matched items"), Int64(count))
    }

    private func protectionReasonTitle(_ reason: AppFileProtectionReason) -> String {
        switch reason {
        case .foreignApplication:
            return String(localized: "Another application")
        case .sharedContainer:
            return String(localized: "Shared app group")
        case .sharedIdentity:
            return String(localized: "Shared app data")
        case .foreignPrivateData:
            return String(localized: "Foreign app data")
        case .ambiguousName:
            return String(localized: "Ambiguous name match")
        }
    }

    private func fileFolderCountText(_ stats: FileTreeStats) -> String {
        if stats.directoryCount == 0 {
            return String(format: String(localized: "%lld files"), Int64(stats.fileCount))
        }
        if stats.fileCount == 0 {
            return String(format: String(localized: "%lld folders"), Int64(stats.directoryCount))
        }
        return String(
            format: String(localized: "%lld files · %lld folders"),
            Int64(stats.fileCount),
            Int64(stats.directoryCount)
        )
    }

    private func fileSelectionBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { appState.selectedFiles.contains(url) },
            set: { selected in
                if selected {
                    appState.selectedFiles.insert(url)
                } else {
                    appState.selectedFiles.remove(url)
                }
            }
        )
    }

    private func aggregateStats(for urls: [URL]) -> FileTreeStats {
        urls.reduce(into: .zero) { total, url in
            if let stats = statsCache[url] {
                total.add(stats)
            } else {
                // Preserve a truthful lower bound while the recursive count is
                // still loading: every selected root is at least one item.
                total.fileCount += 1
            }
        }
    }

    private func rebuildStatsCache() {
        statsTask?.cancel()
        let generation = UUID()
        statsGeneration = generation

        let currentURLs = Set(appState.discoveredFiles)
        statsCache = statsCache.filter { currentURLs.contains($0.key) }
        let urlsToCalculate = appState.discoveredFiles.filter { statsCache[$0] == nil }
        guard !urlsToCalculate.isEmpty else {
            statsTask = nil
            return
        }

        let task = Task.detached(priority: .utility) {
            var result: [URL: FileTreeStats] = [:]
            for url in urlsToCalculate {
                guard !Task.isCancelled else { break }
                if let stats = FileTreeStatsCalculator.calculate(
                    at: url,
                    shouldCancel: { Task.isCancelled }
                ) {
                    result[url] = stats
                }
            }
            return result
        }
        statsTask = task

        Task { @MainActor in
            let calculated = await task.value
            guard statsGeneration == generation, !task.isCancelled else { return }
            statsCache.merge(calculated) { _, fresh in fresh }
            statsTask = nil
        }
    }

    private func cancelStatsCalculation() {
        statsGeneration = UUID()
        statsTask?.cancel()
        statsTask = nil
    }

    private func removeSingleFile(_ url: URL) {
        appState.selectedFiles = [url]
        appState.removeSelectedFiles()
    }
}

private struct InstallerPackageDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    let insights: InstallerPackageInsights

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    evidenceNotice
                    receiptsSection
                    componentsSection
                }
                .padding(20)
            }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 500, idealHeight: 620)
    }

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(
                systemName: "shippingbox.and.arrow.backward.fill",
                tint: Tint.orange,
                size: 34
            )
            VStack(alignment: .leading, spacing: 3) {
                Text("Installer Package Evidence")
                    .font(.title3.weight(.semibold))
                Text(
                    String(
                        format: String(localized: "%lld receipt(s) · %lld payload paths"),
                        Int64(insights.receipts.count),
                        Int64(insights.payloadPathCount)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var evidenceNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tint.orange)
                .frame(width: 28, height: 28)
                .background(Tint.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                Text("Read-only receipt evidence")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("AppSift never selects these external components for removal. Shared, sensitive, or uncertain ownership remains protected.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private var receiptsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Receipts", count: insights.receipts.count)
            VStack(spacing: 0) {
                ForEach(Array(insights.receipts.enumerated()), id: \.element.identifier) { index, receipt in
                    if index > 0 { Divider().padding(.leading, 36) }
                    HStack(spacing: 10) {
                        Image(systemName: "doc.badge.gearshape.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Tint.blue)
                            .frame(width: 26, height: 26)
                            .background(Tint.blue.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: receipt.identifier)
                                .font(.system(size: 12.5, weight: .semibold))
                                .textSelection(.enabled)
                            Text(receiptDetail(receipt))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                }
            }
            .padding(.horizontal, 12)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var componentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("External Components", count: insights.externalComponents.count)
            if insights.externalComponents.isEmpty {
                Text("No external components from this receipt are currently present.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(insights.externalComponents.enumerated()), id: \.element.id) { index, component in
                        if index > 0 { Divider().padding(.leading, 38) }
                        componentRow(component)
                    }
                }
                .padding(.horizontal, 12)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            }
            if insights.isIncomplete {
                Label(
                    "Some components or ownership checks could not be completed within the safety bounds.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(Tint.orange)
            }
        }
    }

    private func componentRow(_ component: InstallerPackageExternalComponent) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: component.url.path))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(component.url.lastPathComponent)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    ownershipChip(component.ownership)
                    if component.isSystemSensitive {
                        StatusChip(
                            label: String(localized: "System-sensitive"),
                            systemImage: "exclamationmark.shield.fill",
                            tint: Tint.red
                        )
                    }
                }
                Text(component.url.path)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(
                        String(
                            format: String(localized: "%lld payload items"),
                            Int64(component.payloadPathCount)
                        )
                    )
                    if !component.otherOwnerIdentifiers.isEmpty {
                        Text(
                            String(
                                format: String(localized: "Also owned by %@"),
                                component.otherOwnerIdentifiers.joined(separator: ", ")
                            )
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([component.url])
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.vertical, 7)
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(component.url.path, forType: .string)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([component.url])
            }
        }
    }

    @ViewBuilder
    private func ownershipChip(_ ownership: InstallerPackageComponentOwnership) -> some View {
        switch ownership {
        case .receiptOnly:
            StatusChip(
                label: String(localized: "Receipt only"),
                systemImage: "checkmark.seal.fill",
                tint: Tint.blue
            )
        case .shared:
            StatusChip(
                label: String(localized: "Shared receipt"),
                systemImage: "person.2.fill",
                tint: Tint.orange
            )
        case .unverified:
            StatusChip(
                label: String(localized: "Ownership unverified"),
                systemImage: "questionmark.circle.fill",
                tint: .secondary
            )
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
            Spacer()
            Text(count.formatted())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func receiptDetail(_ receipt: InstallerPackageReceiptMetadata) -> String {
        let location = String(
            format: String(localized: "Install location: %@"),
            receipt.installLocation
        )
        guard let version = receipt.version else { return location }
        return String(format: String(localized: "Version %@"), version) + " · " + location
    }
}

// MARK: - Removal history

struct RemovalHistoryView: View {
    private enum PendingDeletion {
        case record(UUID)
        case all
    }

    @EnvironmentObject private var appState: AppState
    @State private var pendingExportRecord: AppRemovalRecord?
    @State private var pendingDeletion: PendingDeletion?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if appState.removalHistory.isEmpty {
                EmptyStateView(
                    "No Removal History",
                    systemImage: "arrow.uturn.backward.circle",
                    description: "Apps reset or removed with AppSift will appear here with their original and Trash locations.",
                    tint: Tint.green
                )
            } else {
                historyList
            }
        }
        .onAppear { appState.refreshRemovalHistory() }
        .alert("History Action Failed", isPresented: Binding(
            get: { appState.removalHistoryError != nil },
            set: { if !$0 { appState.removalHistoryError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.removalHistoryError = nil }
        } message: {
            Text(appState.removalHistoryError ?? "")
        }
        .confirmationDialog(
            "Export path report?",
            isPresented: Binding(
                get: { pendingExportRecord != nil },
                set: { if !$0 { pendingExportRecord = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Export") {
                guard let record = pendingExportRecord else { return }
                pendingExportRecord = nil
                exportReport(record)
            }
            Button("Cancel", role: .cancel) { pendingExportRecord = nil }
        } message: {
            Text("The report contains exact local file paths, outcomes, safety exclusions, and an integrity hash. AppSift saves it only where you choose.")
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            switch pendingDeletion {
            case .record:
                Button("Delete Report", role: .destructive) {
                    performPendingDeletion()
                }
            case .all:
                Button("Clear History", role: .destructive) {
                    performPendingDeletion()
                }
            case nil:
                EmptyView()
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("This deletes only local reports. Items in Trash are not changed, and restore shortcuts will be lost.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            IconTile(
                systemName: "arrow.uturn.backward.circle.fill",
                tint: Tint.green,
                size: 42,
                corner: 11
            )

            VStack(alignment: .leading, spacing: 3) {
                Text("Removal History")
                    .font(.title3.bold())
                Text("App files and reset data move to Trash first. AppSift restores them to their original locations when macOS permits and never overwrites existing files.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(historyCountText(appState.removalHistory.count))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(availableCountText(appState.availableRestorableItemCount))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(appState.availableRestorableItemCount > 0 ? Tint.green : .secondary)
                    .monospacedDigit()
            }

            Menu {
                Button("Clear History", role: .destructive) {
                    pendingDeletion = .all
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Clear History")
            .disabled(!appState.restoringRemovalItemIDs.isEmpty)
        }
        .padding()
    }

    private var historyList: some View {
        List {
            ForEach(appState.removalHistory) { record in
                Section {
                    ForEach(record.items) { item in
                        historyItemRow(item, recordID: record.id)
                    }
                    ForEach(record.protectedItems, id: \.self) { item in
                        protectedHistoryRow(item)
                    }
                } header: {
                    recordHeader(record)
                }
            }
        }
        .listStyle(.inset)
    }

    private func recordHeader(_ record: AppRemovalRecord) -> some View {
        let available = availableItems(in: record)
        let isRestoring = record.items.contains {
            appState.restoringRemovalItemIDs.contains($0.id)
        }

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.appName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Label(
                            operationTitle(record.operation),
                            systemImage: operationIcon(record.operation)
                        )
                        .foregroundStyle(operationTint(record.operation))
                        Text("·")
                        Text(record.removedAt.formatted(date: .abbreviated, time: .shortened))
                        if let sensitivity = record.searchSensitivity {
                            Text("·")
                            Text(sensitivityText(sensitivity))
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if !available.isEmpty {
                    Button("Restore All") {
                        appState.restoreAllAvailableItems(recordID: record.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRestoring)
                }

                Menu {
                    Button {
                        pendingExportRecord = record
                    } label: {
                        Label("Export Report…", systemImage: "square.and.arrow.up")
                    }

                    Divider()

                    Button("Delete Report", role: .destructive) {
                        pendingDeletion = .record(record.id)
                    }
                    .disabled(isRestoring)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            HStack(spacing: 5) {
                if record.movedItemCount > 0 {
                    auditBadge(
                        movedCountText(record.movedItemCount),
                        systemImage: "trash.fill",
                        tint: Tint.blue
                    )
                }
                if record.protectedMatchCount > 0 {
                    auditBadge(
                        protectedCountText(record.protectedMatchCount),
                        systemImage: "lock.shield.fill",
                        tint: Tint.orange
                    )
                }
                if record.failedItemCount > 0 {
                    auditBadge(
                        failedCountText(record.failedItemCount),
                        systemImage: "exclamationmark.triangle.fill",
                        tint: Tint.red
                    )
                }
                if record.missingItemCount > 0 {
                    auditBadge(
                        missingCountText(record.missingItemCount),
                        systemImage: "minus.circle.fill",
                        tint: .secondary
                    )
                }
                if record.restoredItemCount > 0 {
                    auditBadge(
                        restoredCountText(record.restoredItemCount),
                        systemImage: "arrow.uturn.backward.circle.fill",
                        tint: Tint.green
                    )
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func historyItemRow(
        _ item: AppRemovalHistoryItem,
        recordID: UUID
    ) -> some View {
        let originalURL = URL(fileURLWithPath: item.originalPath)
        let trashURL = item.trashPath.map { URL(fileURLWithPath: $0) }
        let existsInTrash = item.trashPath.map {
            FileManager.default.fileExists(atPath: $0)
        } ?? false
        let isRestoring = appState.restoringRemovalItemIDs.contains(item.id)
        let tint = historyItemTint(item)

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(systemName: originalURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
                    ? "app.fill"
                    : "doc.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(
                        tint.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 7)
                    )

                Text(originalURL.lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 8)
                historyItemActions(
                    item,
                    recordID: recordID,
                    trashURL: trashURL,
                    existsInTrash: existsInTrash,
                    isRestoring: isRestoring
                )
            }

            Text(item.originalPath)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 36)

            Label(appFileEvidenceTitle(item.evidence), systemImage: "checkmark.seal")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(item.evidence == .legacyUnknown ? .secondary : Tint.blue)
                .lineLimit(1)
                .padding(.leading, 36)

            if let failure = item.failure {
                Label(failure.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Tint.red)
                    .lineLimit(2)
                    .padding(.leading, 36)
            }
        }
        .padding(.vertical, 3)
        .help(item.originalPath)
    }

    private func availableItems(in record: AppRemovalRecord) -> [AppRemovalHistoryItem] {
        record.items.filter {
            guard $0.outcome == .movedToTrash,
                  $0.restoredAt == nil,
                  let trashPath = $0.trashPath else { return false }
            return FileManager.default.fileExists(atPath: trashPath)
        }
    }

    @ViewBuilder
    private func historyItemActions(
        _ item: AppRemovalHistoryItem,
        recordID: UUID,
        trashURL: URL?,
        existsInTrash: Bool,
        isRestoring: Bool
    ) -> some View {
        if isRestoring {
            ProgressView()
                .controlSize(.small)
        } else if let restoredAt = item.restoredAt {
            VStack(alignment: .trailing, spacing: 1) {
                Text("Restored")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Tint.green)
                Text(restoredAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        } else {
            switch item.outcome {
            case .movedToTrash:
                if existsInTrash, let trashURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([trashURL])
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Trash")

                    Button("Restore") {
                        appState.restoreRemovalItem(recordID: recordID, itemID: item.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    outcomeLabel("No longer in Trash", tint: .secondary)
                }
            case .alreadyMissing:
                outcomeLabel("Already absent", tint: .secondary)
            case .failed:
                outcomeLabel("Not moved", tint: Tint.red)
            }
        }
    }

    private func protectedHistoryRow(_ item: AppRemovalProtectedItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tint.orange)
                    .frame(width: 26, height: 26)
                    .background(Tint.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))

                Text((item.path as NSString).lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("Not touched")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Tint.orange)
            }

            Text(item.path)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 36)

            HStack(spacing: 8) {
                Text(historyProtectionReasonTitle(item.reason))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Tint.orange)

                Spacer(minLength: 8)

                Text(matchedItemsText(item.matchedItemCount))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.leading, 36)
        }
        .padding(.vertical, 3)
        .help(item.path)
    }

    private func auditBadge(
        _ text: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
    }

    private func outcomeLabel(_ title: LocalizedStringKey, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
    }

    private func historyItemTint(_ item: AppRemovalHistoryItem) -> Color {
        if item.restoredAt != nil { return Tint.green }
        switch item.outcome {
        case .movedToTrash: return Tint.blue
        case .alreadyMissing: return .secondary
        case .failed: return Tint.red
        }
    }

    private func exportReport(_ record: AppRemovalRecord) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.prompt = String(localized: "Export")
        panel.message = String(localized: "Choose where to save this local path report.")
        let safeName = record.appName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let name = safeName.isEmpty ? "App" : safeName
        panel.nameFieldStringValue = "AppSift-\(name)-\(record.operation.rawValue)-\(record.id.uuidString.prefix(8)).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try AppRemovalReportExporter.write(record, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            appState.removalHistoryError = error.localizedDescription
        }
    }

    private var deletionTitle: LocalizedStringKey {
        switch pendingDeletion {
        case .record: return "Delete this removal report?"
        case .all: return "Clear removal history?"
        case nil: return "Clear removal history?"
        }
    }

    private func performPendingDeletion() {
        let deletion = pendingDeletion
        pendingDeletion = nil
        switch deletion {
        case .record(let recordID):
            appState.deleteRemovalRecord(recordID)
        case .all:
            appState.clearRemovalHistory()
        case nil:
            break
        }
    }

    private func historyCountText(_ count: Int) -> String {
        String(format: String(localized: "%lld removal records"), Int64(count))
    }

    private func availableCountText(_ count: Int) -> String {
        String(format: String(localized: "%lld items available to restore"), Int64(count))
    }

    private func operationTitle(_ operation: AppRemovalOperation) -> String {
        switch operation {
        case .uninstall: return String(localized: "Uninstall")
        case .reset: return String(localized: "App Reset")
        case .relatedFiles: return String(localized: "Related Files")
        case .legacyRemoval: return String(localized: "Removal")
        }
    }

    private func operationIcon(_ operation: AppRemovalOperation) -> String {
        switch operation {
        case .uninstall: return "trash.fill"
        case .reset: return "arrow.counterclockwise"
        case .relatedFiles: return "doc.badge.minus"
        case .legacyRemoval: return "clock.arrow.circlepath"
        }
    }

    private func operationTint(_ operation: AppRemovalOperation) -> Color {
        switch operation {
        case .uninstall: return Tint.red
        case .reset: return Tint.orange
        case .relatedFiles: return Tint.blue
        case .legacyRemoval: return .secondary
        }
    }

    private func sensitivityText(_ sensitivity: SearchSensitivity) -> String {
        let title: String
        switch sensitivity {
        case .strict: title = String(localized: "Strict")
        case .enhanced: title = String(localized: "Enhanced")
        case .deep: title = String(localized: "Deep")
        }
        return String(format: String(localized: "Sensitivity: %@"), title)
    }

    private func movedCountText(_ count: Int) -> String {
        String(format: String(localized: "%lld moved"), Int64(count))
    }

    private func protectedCountText(_ count: Int) -> String {
        String(format: String(localized: "%lld protected"), Int64(count))
    }

    private func failedCountText(_ count: Int) -> String {
        String(format: String(localized: "%lld failed"), Int64(count))
    }

    private func missingCountText(_ count: Int) -> String {
        String(format: String(localized: "%lld missing"), Int64(count))
    }

    private func restoredCountText(_ count: Int) -> String {
        String(format: String(localized: "%lld restored"), Int64(count))
    }

    private func matchedItemsText(_ count: Int) -> String {
        String(format: String(localized: "%lld matched items"), Int64(count))
    }
}

private func appFileEvidenceTitle(_ evidence: AppFileMatchEvidence) -> String {
    switch evidence {
    case .selectedApplication:
        return String(localized: "Application bundle")
    case .exactBundleIdentifier, .structuredBundleIdentifier,
         .bundleIdentifierSuffix, .baseBundleIdentifier:
        return String(localized: "Bundle identifier match")
    case .exactAppName, .exactBundlePathName, .versionStrippedName:
        return String(localized: "Exact app name match")
    case .verifiedEntitlement:
        return String(localized: "Verified entitlement match")
    case .containerMetadata:
        return String(localized: "Verified container ownership")
    case .appSpecificRule:
        return String(localized: "App-specific rule")
    case .legacyUnknown:
        return String(localized: "Legacy record")
    }
}

private func historyProtectionReasonTitle(_ reason: AppFileProtectionReason) -> String {
    switch reason {
    case .foreignApplication: return String(localized: "Another application")
    case .sharedContainer: return String(localized: "Shared app group")
    case .sharedIdentity: return String(localized: "Shared app data")
    case .foreignPrivateData: return String(localized: "Foreign app data")
    case .ambiguousName: return String(localized: "Ambiguous name match")
    }
}

private struct AppRelationshipDetailsView: View {
    let appName: String
    let selectedApplicationID: String
    let groups: [AppRelationshipGroup]
    let wasIncomplete: Bool

    @Environment(\.dismiss) private var dismiss

    private var orderedGroups: [AppRelationshipGroup] {
        groups.sorted { lhs, rhs in
            if lhs.isShared != rhs.isShared { return lhs.isShared }
            return lhs.identifier.localizedStandardCompare(rhs.identifier) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(
                    systemName: "link",
                    tint: Tint.purple,
                    size: 34,
                    corner: 9
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text("App Group Relationships")
                        .font(.title3.bold())
                    Text(
                        String(
                            format: String(localized: "%@ declares these signed App Groups."),
                            appName
                        )
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
            .padding(18)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    evidenceExplanation

                    if wasIncomplete {
                        Label(
                            "Relationship scan is incomplete because a bounded limit or cancellation was reached.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(Tint.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Tint.orange.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                    }

                    ForEach(orderedGroups) { group in
                        relationshipGroupCard(group)
                    }
                }
                .padding(18)
            }

            Divider()

            HStack {
                Text(
                    "Singleton declarations may belong to an embedded extension or an app that is no longer installed; AppSift still keeps their containers protected."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 20)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 720, height: 580)
    }

    private var evidenceExplanation: some View {
        Label {
            Text(
                "Signed entitlements prove which apps declare access to an App Group. They do not prove recent use."
            )
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(Tint.green)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Tint.green.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private func relationshipGroupCard(_ group: AppRelationshipGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.identifier)
                        .font(.system(.body, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                    Text(
                        String(
                            format: String(localized: "Team ID %@"),
                            group.teamIdentifier
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
                Spacer()
                Text(groupStatusText(group))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(group.isShared ? Tint.purple : Color.gray)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (group.isShared ? Tint.purple : Color.gray).opacity(0.1),
                        in: Capsule()
                    )
            }

            VStack(spacing: 0) {
                ForEach(group.applications) { application in
                    if application.id != group.applications.first?.id { Divider() }
                    HStack(spacing: 9) {
                        Image(systemName: "app.fill")
                            .foregroundStyle(
                                application.id == selectedApplicationID
                                    ? Tint.blue
                                    : Tint.purple
                            )
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(application.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                if application.id == selectedApplicationID {
                                    Text("Selected")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(Tint.blue)
                                }
                            }
                            Text(application.bundleIdentifier)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Text(application.url.path)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 260, alignment: .trailing)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 7)
                }
            }

            Divider()

            VStack(spacing: 7) {
                ForEach(group.locations, id: \.kind) { location in
                    HStack(spacing: 8) {
                        Image(systemName: locationStatusIcon(location.status))
                            .foregroundStyle(locationStatusTint(location.status))
                            .frame(width: 18)
                        Text(locationKindTitle(location.kind))
                            .font(.caption.weight(.medium))
                            .frame(width: 112, alignment: .leading)
                        Text(location.url.path)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Text(locationStatusTitle(location.status))
                            .font(.caption)
                            .foregroundStyle(locationStatusTint(location.status))
                    }
                }
            }
        }
        .padding(14)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func groupStatusText(_ group: AppRelationshipGroup) -> String {
        guard group.isShared else {
            return String(localized: "Declared by this app only")
        }
        return String(
            format: String(localized: "Shared by %lld apps"),
            Int64(group.applications.count)
        )
    }

    private func locationKindTitle(_ kind: AppRelationshipLocationKind) -> String {
        switch kind {
        case .groupContainer: return String(localized: "Group Container")
        case .applicationScripts: return String(localized: "Application Scripts")
        }
    }

    private func locationStatusTitle(_ status: AppRelationshipLocationStatus) -> String {
        switch status {
        case .presentDirectory: return String(localized: "Directory present")
        case .notFound: return String(localized: "Not found")
        case .permissionDenied: return String(localized: "Permission denied")
        case .unsafeType: return String(localized: "Unsafe path type")
        case .unreadable: return String(localized: "Could not inspect")
        }
    }

    private func locationStatusIcon(_ status: AppRelationshipLocationStatus) -> String {
        switch status {
        case .presentDirectory: return "checkmark.circle.fill"
        case .notFound: return "minus.circle"
        case .permissionDenied: return "lock.fill"
        case .unsafeType: return "exclamationmark.triangle.fill"
        case .unreadable: return "questionmark.circle.fill"
        }
    }

    private func locationStatusTint(_ status: AppRelationshipLocationStatus) -> Color {
        switch status {
        case .presentDirectory: return Tint.green
        case .notFound: return Color.gray
        case .permissionDenied, .unreadable: return Tint.orange
        case .unsafeType: return Tint.red
        }
    }
}

/// Magnifier over expanding sonar rings — the "actively searching" beat for
/// the related-files scan. Only built when Reduce Motion is off.
private struct SearchPulse: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .stroke(Tint.blue.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 44, height: 44)
                    .scaleEffect(pulse ? 1.8 : 1.0)
                    .opacity(pulse ? 0 : 0.7)
                    .animation(
                        .easeOut(duration: 1.4)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * 0.7),
                        value: pulse
                    )
            }
            Circle()
                .fill(Tint.blue.opacity(0.12))
                .frame(width: 44, height: 44)
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Tint.blue)
        }
        .frame(width: 56, height: 56)
        .onAppear { pulse = true }
    }
}

// MARK: - File Row with hover-to-reveal actions

struct FileRow: View {
    let fileURL: URL
    @Binding var isSelected: Bool
    let fileSize: Int64?
    let evidence: AppFileMatchEvidence
    let onRemove: () -> Void

    @State private var isHovering = false
    @State private var showConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Toggle(isOn: $isSelected) {
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                    .resizable()
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(fileURL.lastPathComponent)
                        .lineLimit(1)
                    Text(fileURL.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(appFileEvidenceTitle(evidence))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Tint.blue)
                        .lineLimit(1)
                }

                Spacer()

                // Buttons stay in the layout permanently and fade with
                // hover, so the trailing size badge never jumps sideways.
                Button {
                    NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
                .opacity(isHovering ? 1 : 0)
                .scaleEffect(reduceMotion ? 1 : (isHovering ? 1 : 0.8))
                .allowsHitTesting(isHovering)

                Button {
                    showConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Remove this file")
                .opacity(isHovering ? 1 : 0)
                .scaleEffect(reduceMotion ? 1 : (isHovering ? 1 : 0.8))
                .allowsHitTesting(isHovering)

                if let size = fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(AnimatedCheckboxStyle())
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .scaleEffect(isHovering && !reduceMotion ? 1.01 : 1)
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: isHovering)
        .onHover { isHovering = $0 }
        .alert(
            Text(
                String(format: String(localized: "Remove %@?"), fileURL.lastPathComponent)
            ),
            isPresented: $showConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { onRemove() }
        } message: {
            Text("AppSift moves this file to Trash and saves a restore receipt. App files are never permanently deleted by the uninstall flow.")
        }
    }
}
