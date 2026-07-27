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
    @AppStorage(ToolboxFavorites.storageKey) private var favoriteIDsRaw = ""
    @State private var searchText = ""

    let navigate: (AppSection) -> Void

    private let grid = [
        GridItem(.adaptive(minimum: 250, maximum: 380), spacing: 12, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if hasSearchQuery {
                    searchResults
                } else {
                    catalogSections
                }
            }
            .padding(20)
        }
        .accessibilityIdentifier("toolbox.content")
        .navigationTitle("Tools")
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text("Search tools")
        )
    }

    @ViewBuilder
    private var searchResults: some View {
        if matchingTools.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.secondary)
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
            .frame(maxWidth: .infinity, minHeight: 320)
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
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 2)
            toolGrid(tools)
        }
    }

    private func toolGrid(_ tools: [AppTool]) -> some View {
        LazyVGrid(columns: grid, alignment: .leading, spacing: 12) {
            ForEach(tools) { tool in
                ToolboxToolRow(
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

private struct ToolboxToolRow: View {
    let tool: AppTool
    let badge: String?
    let isFavorite: Bool
    let open: () -> Void
    let toggleFavorite: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 10) {
                    IconTile(
                        systemName: tool.systemImage,
                        tint: tool.tint,
                        size: 32,
                        corner: 8
                    )
                    .fixedSize()

                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(tool.titleKey))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(tool.category.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let badge {
                        Text(badge)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 10)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text(LocalizedStringKey(tool.titleKey)))
            .accessibilityValue(Text(verbatim: badge ?? ""))
            .accessibilityIdentifier("toolbox.tool.\(tool.id)")

            Button(action: toggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isFavorite ? Color.accentColor : .secondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 5)
            .accessibilityLabel(
                Text(isFavorite ? "Remove from Favorites" : "Add to Favorites")
            )
            .accessibilityIdentifier("toolbox.favorite.\(tool.id)")
            .help(
                Text(isFavorite ? "Remove from Favorites" : "Add to Favorites")
            )
        }
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.04 : 0))
                .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
    }
}
