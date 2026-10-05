import Foundation
import SwiftUI

private struct InstalledAppComparator: SortComparator, Sendable {
    enum Field: Sendable {
        case appName
        case size
        case lastUsed
    }

    var field: Field
    var order: SortOrder = .forward

    func compare(_ lhs: InstalledApp, _ rhs: InstalledApp) -> ComparisonResult {
        let result: ComparisonResult
        switch field {
        case .appName:
            result = lhs.appName.localizedCaseInsensitiveCompare(rhs.appName)
        case .size:
            if lhs.size == rhs.size {
                result = .orderedSame
            } else {
                result = lhs.size < rhs.size ? .orderedAscending : .orderedDescending
            }
        case .lastUsed:
            return AppUsageAnalyzer.compareLastUsed(
                lhs.lastUsedAt,
                rhs.lastUsedAt,
                newestFirst: order == .reverse
            )
        }

        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

/// Search matching for the installed-app inventory lives outside the view so
/// the query semantics stay deterministic and independently testable. The
/// toolbar search field can emit mixed case, diacritics, or surrounding
/// whitespace; all of those should behave like the same user query.
enum InstalledAppSearch {
    private static let metadataMinimumQueryLength = 3

    static func normalized(_ text: String) -> String {
        text
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ app: InstalledApp, query: String) -> Bool {
        matchScore(for: app, query: query) != nil
    }

    /// Returns a lower score for a more useful visible-name match. Keeping the
    /// score separate from filtering lets the table honour an explicit size or
    /// last-used sort while still making the default name search feel relevant.
    static func matchScore(for app: InstalledApp, query: String) -> Int? {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return 0 }

        let normalizedName = normalized(app.appName)
        if normalizedName == normalizedQuery {
            return 0
        }
        if normalizedName.hasPrefix(normalizedQuery) {
            return 1
        }

        let nameTokens = normalizedName.components(
            separatedBy: CharacterSet.alphanumerics.inverted
        )
        if nameTokens.contains(where: { $0.hasPrefix(normalizedQuery) }) {
            return 2
        }
        if normalizedName.contains(normalizedQuery) {
            return 3
        }

        // One- and two-character queries are intended to narrow the visible
        // app names immediately. Searching hidden metadata that early makes a
        // query such as "m" match nearly every `com.*` bundle identifier and
        // leaves the list looking unfiltered.
        guard normalizedQuery.count >= metadataMinimumQueryLength else {
            return nil
        }

        let searchableFields = [
            app.bundleIdentifier,
            app.version,
            app.signature.developerName,
            app.signature.teamIdentifier,
        ].compactMap { $0 }

        return searchableFields.contains {
            normalized($0).contains(normalizedQuery)
        } ? 4 : nil
    }

    static func filter(_ apps: [InstalledApp], query: String) -> [InstalledApp] {
        apps.filter { matchScore(for: $0, query: query) != nil }
    }

    static func ranked(_ apps: [InstalledApp], query: String) -> [InstalledApp] {
        apps.enumerated()
            .compactMap { index, app in
                matchScore(for: app, query: query).map {
                    (index: index, score: $0, app: app)
                }
            }
            .sorted {
                if $0.score != $1.score {
                    return $0.score < $1.score
                }
                return $0.index < $1.index
            }
            .map(\.app)
    }
}

struct AppListView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var selection: InstalledApp.ID?
    @State private var usageFilter: AppUsageFilter = .all
    @Environment(\.colorScheme) private var colorScheme
    @State private var sortOrder: [InstalledAppComparator] = [
        InstalledAppComparator(field: .appName)
    ]

    private var normalizedSearchText: String {
        InstalledAppSearch.normalized(searchText)
    }

    private var filteredApps: [InstalledApp] {
        let base = InstalledAppSearch.filter(
            appState.installedApps,
            query: searchText
        )
        let usageFiltered = base.filter {
            usageFilter.matches(lastUsedAt: $0.lastUsedAt)
        }
        let sorted = usageFiltered.sorted(using: sortOrder)
        guard !normalizedSearchText.isEmpty,
              sortOrder.first?.field == .appName else {
            return sorted
        }
        return InstalledAppSearch.ranked(sorted, query: searchText)
    }

    var body: some View {
        HSplitView {
            // Cap the left pane's maxWidth so dragging the splitter cannot
            // push it past half the window and break the layout (#60).
            appTable
                .frame(minWidth: 420, idealWidth: 480, maxWidth: 600)

            fileDetail
                .frame(minWidth: 300)
        }
        .searchable(text: $searchText, prompt: "Search apps")
        .navigationTitle(installedAppsTitle)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    appState.loadInstalledApps(forceSizeRefresh: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                if appState.isCalculatingAppSizes {
                    ProgressView(value: appState.appSizeCalculationProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 72)
                        .help("Calculating app sizes...")
                }

            }
        }
    }

    private var installedAppsTitle: String {
        String(format: String(localized: "Installed Apps (%lld)"), Int64(appState.installedApps.count))
    }

    // MARK: - App Table (left side)

    private var appTable: some View {
        Group {
            if appState.isLoadingApps && appState.installedApps.isEmpty {
                VStack(spacing: 12) {
                    ProgressView(LocalizedStringKey("Loading installed apps..."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.installedApps.isEmpty {
                EmptyStateView(
                    "No Apps Found",
                    systemImage: "square.grid.2x2",
                    description: "Could not find any installed applications.",
                    action: { appState.loadInstalledApps() },
                    actionLabel: "Retry"
                )
            } else {
                VStack(spacing: 0) {
                    usageFilterBar
                    Divider()
                    Table(filteredApps, selection: $selection, sortOrder: $sortOrder) {
                        TableColumn(
                            "Application",
                            sortUsing: InstalledAppComparator(field: .appName)
                        ) { app in
                            HStack(spacing: 10) {
                                HoverScaleIcon(icon: app.icon)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 5) {
                                        Text(app.appName)
                                            .foregroundStyle(appLabelColor)
                                        signatureWarning(for: app)
                                    }
                                    if let modifiedAt = app.modifiedAt {
                                        Text(modifiedAt, style: .date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .width(min: 180, ideal: 260)

                        TableColumn(
                            "Last Opened",
                            sortUsing: InstalledAppComparator(field: .lastUsed)
                        ) { app in
                            usageSummary(for: app)
                        }
                        .width(min: 105, ideal: 125, max: 160)

                        TableColumn(
                            "Size",
                            sortUsing: InstalledAppComparator(field: .size)
                        ) { app in
                            switch app.sizeState {
                            case .cached, .calculated:
                                Text(app.formattedSize)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            case .pending:
                                HStack(spacing: 5) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("Calculating...")
                                }
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .help("Calculating app size...")
                            case .unavailable:
                                Text("—")
                                    .foregroundStyle(.tertiary)
                                    .help("App size unavailable")
                            }
                        }
                        .width(min: 70, ideal: 90, max: 110)
                    }
                    .overlay {
                        if filteredApps.isEmpty && !normalizedSearchText.isEmpty {
                            EmptyStateView(
                                "No Matching Apps",
                                systemImage: "magnifyingglass",
                                description: "Try a different search.",
                                tint: Tint.purple
                            )
                            .background(Color(nsColor: .controlBackgroundColor))
                        }
                    }
                    .onChange(of: selection) { newValue in
                        guard let id = newValue,
                              let app = appState.installedApps.first(where: { $0.id == id })
                        else { return }
                        // Skip when the selection was just synced from an external
                        // (Finder Services) hand-off that already scanned this app,
                        // so we don't fire a redundant second scan.
                        guard appState.selectedApp?.id != app.id else { return }
                        appState.selectedApp = app
                        appState.scanForAppFiles(app)
                    }
                    .onChange(of: appState.selectedApp) { app in
                        // Reflect an externally-driven selection (Finder Services)
                        // in the table highlight.
                        if selection != app?.id { selection = app?.id }
                    }
                    .onAppear {
                        // Sync the highlight when this view mounts already pointed
                        // at an externally-selected app.
                        if selection != appState.selectedApp?.id {
                            selection = appState.selectedApp?.id
                        }
                    }
                }
            }
        }
    }

    private var usageFilterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Tint.blue)
            Text("Usage Evidence")
                .font(.system(size: 12.5, weight: .semibold))
            Text(usageSummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Picker("Usage Filter", selection: $usageFilter) {
                ForEach(AppUsageFilter.allCases) { filter in
                    Text(usageFilterLabel(filter)).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .labelsHidden()
            .help("Filter by the last reliable app-open evidence")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.58))
    }

    private var usageSummaryText: String {
        let unused = appState.installedApps.filter {
            AppUsageFilter.unused90.matches(lastUsedAt: $0.lastUsedAt)
        }.count
        let unknown = appState.installedApps.filter {
            AppUsageFilter.unknown.matches(lastUsedAt: $0.lastUsedAt)
        }.count
        return String(
            format: String(localized: "%lld unused · %lld no reliable record"),
            Int64(unused),
            Int64(unknown)
        )
    }

    private func usageFilterLabel(_ filter: AppUsageFilter) -> String {
        switch filter {
        case .all: return String(localized: "All Apps")
        case .unused30: return String(localized: "Unused 30+ Days")
        case .unused90: return String(localized: "Unused 90+ Days")
        case .unused180: return String(localized: "Unused 180+ Days")
        case .unknown: return String(localized: "No Usage Record")
        }
    }

    @ViewBuilder
    private func usageSummary(for app: InstalledApp) -> some View {
        let status = AppUsageAnalyzer.status(
            lastUsedAt: app.lastUsedAt,
            thresholdDays: usageFilter.thresholdDays ?? 90
        )
        VStack(alignment: .leading, spacing: 1) {
            switch status {
            case .recentlyUsed:
                if let lastUsedAt = app.lastUsedAt {
                    Text(lastUsedAt, style: .relative)
                        .foregroundStyle(.secondary)
                        .help(lastUsedAt.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("No reliable record")
                        .foregroundStyle(.tertiary)
                }
                Text("Recently Used")
                    .font(.caption2)
                    .foregroundStyle(Tint.green)
            case .unused:
                if let lastUsedAt = app.lastUsedAt {
                    Text(lastUsedAt, style: .relative)
                        .foregroundStyle(.secondary)
                        .help(lastUsedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Text("Unused")
                    .font(.caption2)
                    .foregroundStyle(Tint.orange)
            case .unknown:
                Text("No reliable record")
                    .foregroundStyle(.tertiary)
                    .help("Spotlight has no reliable last-opened date for this app")
                Text("Usage Unknown")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    private var appLabelColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.92)
            : Color.black.opacity(0.85)
    }

    @ViewBuilder
    private func signatureWarning(for app: InstalledApp) -> some View {
        switch app.signature.status {
        case .invalid:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(Tint.red)
                .help("Invalid signature")
        case .unsigned:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(Tint.orange)
                .help("Unsigned")
        case .adHoc:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(Tint.orange)
                .help("Ad hoc signature")
        case .locallySigned:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(Tint.orange)
                .help("Local signature")
        case .developerSigned:
            if app.signature.notarizationStatus == .notNotarized {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Tint.orange)
                    .help("Signed but not notarized")
            }
        case .unknown:
            EmptyView()
        }
    }

    // MARK: - File Detail (right side)

    @ViewBuilder
    private var fileDetail: some View {
        if let app = appState.selectedApp {
            AppFilesView(app: app)
        } else {
            EmptyStateView(
                "Select an App",
                systemImage: "cursorarrow.click.2",
                description: "Select an app from the list to see all its related files across your system.",
                tint: Tint.purple
            )
        }
    }
}

/// App icon that scales up slightly on hover inside a Table cell.
private struct HoverScaleIcon: View {
    let icon: NSImage

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: 32, height: 32)
            .scaleEffect(hovering && !reduceMotion ? 1.06 : 1)
            .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
            .onHover { hovering = $0 }
    }
}
