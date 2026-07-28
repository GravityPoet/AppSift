import SwiftUI

enum ToolboxCategory: String, CaseIterable, Identifiable {
    case applications = "Applications"
    case storage = "Storage"
    case cleanup = "Cleanup"
    case maintenance = "Maintenance"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }

    var systemImage: String {
        switch self {
        case .applications: return "square.grid.2x2"
        case .storage: return "internaldrive"
        case .cleanup: return "sparkles"
        case .maintenance: return "wrench.and.screwdriver"
        }
    }
}

struct AppTool: Identifiable {
    let id: String
    let section: AppSection
    let titleKey: String
    let systemImage: String
    let tint: Color
    let category: ToolboxCategory

    var summaryKey: String {
        switch section {
        case .apps:
            return "Review installed apps and all related files."
        case .appUpdates:
            return "Check supported apps for trusted updates."
        case .installationFiles:
            return "Find old DMG, PKG, XIP, and app archives."
        case .startupItems:
            return "Review login items, agents, and broken entries."
        case .extensions:
            return "Inspect extensions and background components."
        case .appPermissions:
            return "Audit declared and granted app permissions."
        case .browserPrivacy:
            return "Clear history, downloads, cookies, and caches."
        case .defaultApplications:
            return "Review and change default handlers safely."
        case .removalHistory:
            return "Restore files moved during previous removals."
        case .orphans:
            return "Find leftovers from apps no longer installed."
        case .spaceLens:
            return "Explore disk usage with an interactive space map."
        case .duplicateFiles:
            return "Find exact copies by verified file content."
        case .similarImages:
            return "Group near-duplicate photos and keep the best."
        case .timeMachine:
            return "Review local snapshots and reclaim space carefully."
        case .iosBackups:
            return "Review local device backups by device and date."
        case .downloadsBySource:
            return "Group downloaded files by their source app."
        case .systemHealth:
            return "See evidence-based alerts and recommended actions."
        case .systemMaintenance:
            return "Run targeted DNS, Spotlight, and Mail repairs."
        case .systemResidue:
            return "Inspect old users, preferences, and document versions."
        case .cleaning(let category):
            return category.description
        case .tools:
            return "Everything you need for apps, storage, privacy, and maintenance."
        }
    }
}

enum AppToolCatalog {
    static let all: [AppTool] = {
        let applicationTools = [
            AppTool(
                id: "installed-apps",
                section: .apps,
                titleKey: "Installed Apps",
                systemImage: "square.grid.2x2.fill",
                tint: Tint.purple,
                category: .applications
            ),
            AppTool(
                id: "app-updates",
                section: .appUpdates,
                titleKey: "App Updates",
                systemImage: "arrow.triangle.2.circlepath.circle.fill",
                tint: Tint.blue,
                category: .applications
            ),
            AppTool(
                id: "installation-files",
                section: .installationFiles,
                titleKey: "Installation Files",
                systemImage: "shippingbox.fill",
                tint: Tint.orange,
                category: .applications
            ),
            AppTool(
                id: "startup-items",
                section: .startupItems,
                titleKey: "Startup Items",
                systemImage: "power.circle.fill",
                tint: Tint.orange,
                category: .applications
            ),
            AppTool(
                id: "extensions",
                section: .extensions,
                titleKey: "Extensions",
                systemImage: "puzzlepiece.extension.fill",
                tint: Tint.purple,
                category: .applications
            ),
            AppTool(
                id: "privacy-permissions",
                section: .appPermissions,
                titleKey: "Privacy Permissions",
                systemImage: "hand.raised.fill",
                tint: Tint.blue,
                category: .applications
            ),
            AppTool(
                id: "browser-privacy",
                section: .browserPrivacy,
                titleKey: "Browser Privacy",
                systemImage: "hand.raised.square.fill",
                tint: Tint.purple,
                category: .applications
            ),
            AppTool(
                id: "default-applications",
                section: .defaultApplications,
                titleKey: "Default Applications",
                systemImage: "arrow.up.forward.app.fill",
                tint: Tint.blue,
                category: .applications
            ),
            AppTool(
                id: "removal-history",
                section: .removalHistory,
                titleKey: "Removal History",
                systemImage: "arrow.uturn.backward.circle.fill",
                tint: Tint.green,
                category: .applications
            ),
            AppTool(
                id: "orphaned-files",
                section: .orphans,
                titleKey: "Orphaned Files",
                systemImage: "doc.questionmark.fill",
                tint: Tint.pink,
                category: .applications
            ),
        ]

        let storageTools = [
            AppTool(
                id: "space-lens",
                section: .spaceLens,
                titleKey: "Space Lens",
                systemImage: "square.3.layers.3d",
                tint: Tint.purple,
                category: .storage
            ),
            AppTool(
                id: "duplicate-files",
                section: .duplicateFiles,
                titleKey: "Duplicate Files",
                systemImage: "doc.on.doc.fill",
                tint: Tint.cyan,
                category: .storage
            ),
            AppTool(
                id: "similar-images",
                section: .similarImages,
                titleKey: "Similar Images",
                systemImage: "photo.stack.fill",
                tint: Tint.purple,
                category: .storage
            ),
            AppTool(
                id: "time-machine-snapshots",
                section: .timeMachine,
                titleKey: "Time Machine Snapshots",
                systemImage: "clock.arrow.circlepath",
                tint: Tint.orange,
                category: .storage
            ),
            AppTool(
                id: "ios-backups",
                section: .iosBackups,
                titleKey: "iPhone & iPad Backups",
                systemImage: "iphone",
                tint: Tint.blue,
                category: .storage
            ),
            AppTool(
                id: "downloads-by-source",
                section: .downloadsBySource,
                titleKey: "Downloads by Source",
                systemImage: "arrow.down.doc.fill",
                tint: Tint.blue,
                category: .storage
            ),
        ]

        let cleanupTools = CleaningCategory.scannable.map { category in
            AppTool(
                id: cleaningIdentifier(for: category),
                section: .cleaning(category),
                titleKey: category.rawValue,
                systemImage: category.icon,
                tint: category.color,
                category: .cleanup
            )
        }

        let maintenanceTools = [
            AppTool(
                id: "system-health",
                section: .systemHealth,
                titleKey: "System Health",
                systemImage: "waveform.path.ecg",
                tint: Tint.green,
                category: .maintenance
            ),
            AppTool(
                id: "system-maintenance",
                section: .systemMaintenance,
                titleKey: "System Maintenance",
                systemImage: "wrench.and.screwdriver.fill",
                tint: Tint.blue,
                category: .maintenance
            ),
            AppTool(
                id: "system-residue",
                section: .systemResidue,
                titleKey: "System Residue",
                systemImage: "stethoscope",
                tint: Tint.orange,
                category: .maintenance
            ),
        ]

        return applicationTools + storageTools + cleanupTools + maintenanceTools
    }()

    static func search(
        _ query: String,
        localize: (String) -> String
    ) -> [AppTool] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }

        return all.filter { tool in
            [
                localize(tool.titleKey),
                tool.titleKey,
                localize(tool.category.rawValue),
                tool.category.rawValue,
            ].contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private static func cleaningIdentifier(for category: CleaningCategory) -> String {
        switch category {
        case .systemJunk: return "cleanup-system-junk"
        case .userCache: return "cleanup-user-cache"
        case .aiApps: return "cleanup-ai-apps"
        case .mailAttachments: return "cleanup-mail-files"
        case .trashBins: return "cleanup-trash-bins"
        case .largeFiles: return "cleanup-large-old-files"
        case .xcodeJunk: return "cleanup-xcode-junk"
        case .brewCache: return "cleanup-brew-cache"
        case .nodeCache: return "cleanup-node-cache"
        case .dockerCache: return "cleanup-docker-cache"
        case .smartScan, .purgeableSpace:
            preconditionFailure("Non-cleanable category cannot enter the tool catalog")
        }
    }
}

enum ToolboxFavorites {
    static let storageKey = "AppSift.Toolbox.FavoritesV1"

    static func decode(_ rawValue: String, validIDs: Set<String>) -> Set<String> {
        Set(
            rawValue
                .split(separator: ",")
                .map(String.init)
                .filter(validIDs.contains)
        )
    }

    static func encode(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: ",")
    }
}

struct ToolboxView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var alertCenter = SystemAlertCenter.shared
    @AppStorage private var favoriteIDsRaw: String
    @State private var searchText = ""
    @Environment(\.colorScheme) private var colorScheme

    let navigate: (AppSection) -> Void

    private static let favoriteStorageKey: String = {
        guard ProcessInfo.processInfo.environment[
            "APPSIFT_UITEST_EPHEMERAL_TOOLBOX_FAVORITES"
        ] == "YES" else {
            return ToolboxFavorites.storageKey
        }
        let key = "\(ToolboxFavorites.storageKey).UITest"
        UserDefaults.standard.removeObject(forKey: key)
        return key
    }()

    private let grid = [
        GridItem(.adaptive(minimum: 210, maximum: 330), spacing: 16, alignment: .top)
    ]

    init(navigate: @escaping (AppSection) -> Void) {
        self.navigate = navigate
        _favoriteIDsRaw = AppStorage(
            wrappedValue: "",
            ToolboxView.favoriteStorageKey
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                toolboxHeader

                if hasSearchQuery {
                    searchResults
                } else {
                    catalogSections
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityIdentifier("toolbox.content")
        .navigationTitle("Tools")
    }

    private var toolboxHeader: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tools")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .tracking(0.2)
                Text("Everything you need for apps, storage, privacy, and maintenance.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search tools", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityLabel("Search tools")
                    .accessibilityIdentifier("toolbox.search")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear Search")
                }
            }
            .padding(.horizontal, 13)
            .frame(width: 250, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppBrand.card(for: colorScheme))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        AppBrand.cardBorder(for: colorScheme),
                        lineWidth: 0.75
                    )
            }
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if matchingTools.isEmpty {
            CardSurface(padding: 28, accent: Tint.purple, elevation: .standard) {
                VStack(spacing: 10) {
                    IconTile(
                        systemName: "magnifyingglass",
                        tint: Tint.purple,
                        size: 44,
                        corner: 13,
                        glow: true
                    )
                    Text("No tools found")
                        .font(.title3.weight(.semibold))
                    Text("Try a different search.")
                        .foregroundStyle(.secondary)
                    Button("Clear Search") {
                        searchText = ""
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, minHeight: 250)
            }
        } else {
            toolGrid(matchingTools)
        }
    }

    @ViewBuilder
    private var catalogSections: some View {
        if !favoriteTools.isEmpty {
            toolSection(
                title: "Favorites",
                systemImage: "star.fill",
                tools: favoriteTools
            )
        }

        ForEach(ToolboxCategory.allCases) { category in
            let tools = tools(in: category)
            if !tools.isEmpty {
                toolSection(
                    title: category.title,
                    systemImage: category.systemImage,
                    tools: tools
                )
            }
        }
    }

    private func toolSection(
        title: LocalizedStringKey,
        systemImage: String,
        tools: [AppTool]
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tint.cyan)
                Text(title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text("\(tools.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.07))
                    )
                Spacer()
            }
            .padding(.horizontal, 2)
            toolGrid(tools)
        }
    }

    private func toolGrid(_ tools: [AppTool]) -> some View {
        LazyVGrid(columns: grid, alignment: .leading, spacing: 12) {
            ForEach(tools) { tool in
                ToolboxToolCard(
                    tool: tool,
                    badge: badge(for: tool.section),
                    isFavorite: favoriteIDs.contains(tool.id),
                    open: { navigate(tool.section) },
                    toggleFavorite: { toggleFavorite(tool.id) }
                )
            }
        }
    }

    private var validToolIDs: Set<String> {
        Set(AppToolCatalog.all.map(\.id))
    }

    private var favoriteIDs: Set<String> {
        ToolboxFavorites.decode(
            favoriteIDsRaw,
            validIDs: validToolIDs
        )
    }

    private var favoriteTools: [AppTool] {
        AppToolCatalog.all.filter { favoriteIDs.contains($0.id) }
    }

    private var matchingTools: [AppTool] {
        AppToolCatalog.search(searchText) { key in
            Bundle.main.localizedString(
                forKey: key,
                value: key,
                table: nil
            )
        }
    }

    private var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func tools(in category: ToolboxCategory) -> [AppTool] {
        AppToolCatalog.all.filter {
            $0.category == category && !favoriteIDs.contains($0.id)
        }
    }

    private func toggleFavorite(_ id: String) {
        var updated = favoriteIDs
        if updated.contains(id) {
            updated.remove(id)
        } else {
            updated.insert(id)
        }
        favoriteIDsRaw = ToolboxFavorites.encode(updated)
    }

    private func badge(for section: AppSection) -> String? {
        switch section {
        case .apps:
            return appState.installedApps.isEmpty
                ? nil
                : "\(appState.installedApps.count)"
        case .appUpdates:
            return appState.availableUpdateCount == 0
                ? nil
                : "\(appState.availableUpdateCount)"
        case .startupItems:
            guard appState.hasScannedStartupItems else { return nil }
            let count = appState.startupItems.count(where: \.requiresUserAttention)
            return count == 0 ? nil : "\(count)"
        case .extensions:
            guard appState.hasScannedExtensions,
                  !appState.managedExtensions.isEmpty else {
                return nil
            }
            return "\(appState.managedExtensions.count)"
        case .appPermissions:
            guard appState.hasScannedAppPermissions,
                  appState.highImpactAllowedAppPermissionCount > 0 else {
                return nil
            }
            return "\(appState.highImpactAllowedAppPermissionCount)"
        case .browserPrivacy:
            return appState.browserPrivacyCenter.groups.isEmpty
                ? nil
                : "\(appState.browserPrivacyCenter.groups.count)"
        case .defaultApplications:
            guard appState.hasScannedDefaultApplications,
                  !appState.defaultApplications.isEmpty else {
                return nil
            }
            return "\(appState.defaultApplications.count)"
        case .removalHistory:
            return appState.availableRestorableItemCount == 0
                ? nil
                : "\(appState.availableRestorableItemCount)"
        case .orphans:
            return appState.orphanedFiles.isEmpty
                ? nil
                : "\(appState.orphanedFiles.count)"
        case .spaceLens:
            return appState.spaceLensResult.map {
                ByteCountFormatter.string(
                    fromByteCount: $0.root.allocatedSize,
                    countStyle: .file
                )
            }
        case .duplicateFiles:
            return appState.duplicateFileCount == 0
                ? nil
                : "\(appState.duplicateFileCount)"
        case .similarImages:
            return appState.similarImageCenter.groups.isEmpty
                ? nil
                : "\(appState.similarImageCenter.groups.count)"
        case .timeMachine:
            return appState.localTimeMachineSnapshots.isEmpty
                ? nil
                : "\(appState.localTimeMachineSnapshots.count)"
        case .iosBackups:
            return appState.iosBackupCenter.backups.isEmpty
                ? nil
                : "\(appState.iosBackupCenter.backups.count)"
        case .downloadsBySource:
            return appState.downloadSourceCenter.items.isEmpty
                ? nil
                : "\(appState.downloadSourceCenter.items.count)"
        case .systemHealth:
            return alertCenter.activeConditions.isEmpty
                ? nil
                : "\(alertCenter.activeConditions.count)"
        case .systemResidue:
            guard appState.systemResidueCenter.hasScanned else { return nil }
            let count = appState.systemResidueCenter.legacyUsers.count
                + appState.systemResidueCenter.corruptPreferences.count
                + appState.systemResidueCenter.documentVersions.count
            return count == 0 ? nil : "\(count)"
        case .cleaning(let category):
            guard let size = appState.categoryResults[category]?.totalSize,
                  size > 0 else {
                return nil
            }
            return ByteCountFormatter.string(
                fromByteCount: size,
                countStyle: .file
            )
        case .tools, .installationFiles, .systemMaintenance:
            return nil
        }
    }
}

private struct ToolboxToolCard: View {
    let tool: AppTool
    let badge: String?
    let isFavorite: Bool
    let open: () -> Void
    let toggleFavorite: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CardSurface(
            padding: 0,
            accent: tool.tint,
            elevation: hovering ? .raised : .standard
        ) {
            ZStack(alignment: .topTrailing) {
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 0) {
                        IconTile(
                            systemName: tool.systemImage,
                            tint: tool.tint,
                            size: 44,
                            corner: 13,
                            glow: true
                        )
                        .padding(.bottom, 14)

                        Text(LocalizedStringKey(tool.titleKey))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        Text(LocalizedStringKey(tool.summaryKey))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .padding(.top, 5)

                        Spacer(minLength: 12)

                        HStack(spacing: 8) {
                            if let badge {
                                Text(badge)
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(tool.tint)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }

                            Spacer()

                            HStack(spacing: 5) {
                                Text("Open")
                                    .font(.system(size: 11.5, weight: .semibold))
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 178, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey(tool.titleKey)))
                .accessibilityValue(Text(verbatim: badge ?? ""))
                .accessibilityIdentifier("toolbox.tool.\(tool.id)")

                Button(action: toggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(
                            isFavorite ? Color.yellow : Color.secondary
                        )
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(
                                    Color.white.opacity(
                                        colorScheme == .dark ? 0.08 : 0.52
                                    )
                                )
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(11)
                .accessibilityLabel(
                    Text(isFavorite ? "Remove from Favorites" : "Add to Favorites")
                )
                .accessibilityIdentifier("toolbox.favorite.\(tool.id)")
                .help(
                    Text(isFavorite ? "Remove from Favorites" : "Add to Favorites")
                )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    tool.tint.opacity(hovering ? 0.42 : 0),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .scaleEffect(reduceMotion ? 1 : (hovering ? 1.012 : 1))
        .offset(y: hovering && !reduceMotion ? -2 : 0)
        .animation(
            reduceMotion ? nil : MotionTokens.snappy,
            value: hovering
        )
        .contentShape(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .onHover { hovering = $0 }
    }
}
