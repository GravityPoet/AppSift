import SwiftUI

private enum AppUpdateFilter: String, CaseIterable, Identifiable {
    case all
    case available
    case current
    case issues

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .available: return "Updates"
        case .current: return "Up to Date"
        case .issues: return "Needs Review"
        }
    }

    func includes(_ item: AppUpdateItem) -> Bool {
        switch self {
        case .all: return true
        case .available: return item.status == .updateAvailable
        case .current: return item.status == .upToDate
        case .issues: return item.status == .couldNotCheck
        }
    }
}

struct AppUpdatesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var filter: AppUpdateFilter = .all
    @State private var pendingHomebrewUpdate: AppUpdateItem?

    private var filteredItems: [AppUpdateItem] {
        appState.appUpdates.filter { item in
            guard filter.includes(item) else { return false }
            guard !searchText.isEmpty else { return true }
            let query = searchText.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            let haystack = [
                item.appName,
                item.bundleIdentifier,
                item.currentVersion,
                item.availableVersion,
                item.source.searchText,
            ]
            .compactMap { $0 }
            .joined(separator: " ")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            return haystack.contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if appState.isScanningAppUpdates && !appState.hasScannedAppUpdates {
                checkingState
            } else if !appState.hasScannedAppUpdates {
                firstCheckState
            } else {
                results
            }
        }
        .navigationTitle("App Updates")
        .searchable(text: $searchText, prompt: "Search update results")
        .toolbar {
            ToolbarItemGroup {
                if appState.isScanningAppUpdates {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    appState.scanAppUpdates(force: true)
                } label: {
                    Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(appState.isScanningAppUpdates || appState.installedApps.isEmpty)
            }
        }
        .confirmationDialog(
            "Update with Homebrew?",
            isPresented: Binding(
                get: { pendingHomebrewUpdate != nil },
                set: { if !$0 { pendingHomebrewUpdate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Update with Homebrew") {
                if let item = pendingHomebrewUpdate {
                    appState.performAppUpdate(item)
                }
                pendingHomebrewUpdate = nil
            }
            Button("Cancel", role: .cancel) {
                pendingHomebrewUpdate = nil
            }
        } message: {
            Text("AppSift will re-verify the Cask receipt, then run Homebrew's official targeted upgrade command. Homebrew may replace the app bundle and its managed files.")
        }
        .alert("App Update", isPresented: Binding(
            get: { presentedError != nil },
            set: { if !$0 { clearPresentedError() } }
        )) {
            Button("OK", role: .cancel) {
                clearPresentedError()
            }
        } message: {
            Text(presentedError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(
                systemName: "arrow.triangle.2.circlepath.circle.fill",
                tint: Tint.blue,
                size: 34
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("App Updates")
                    .font(.title2.weight(.semibold))
                Text("Verified local ownership chooses the update source; no Nektony database is used.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("A check contacts Apple or each verified vendor feed. Homebrew checks use local metadata; Electron sources come from the signed app bundle.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 16)
            if let date = appState.lastAppUpdateScanDate {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Last checked")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(date, style: .relative)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var checkingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Checking verified update sources...")
                .font(.headline)
            Text("AppSift is matching local signatures and receipts before contacting any source.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var firstCheckState: some View {
        EmptyStateView(
            "Check App Updates",
            systemImage: "arrow.triangle.2.circlepath",
            description: "Check App Store, Homebrew, Sparkle, and signed Electron updater sources backed by evidence on this Mac.",
            action: { appState.scanAppUpdates() },
            actionLabel: "Check for Updates",
            tint: Tint.blue
        )
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                summary

                if let message = appState.appUpdateActionMessage {
                    successNotice(message)
                }

                sourceNotice

                Picker("Filter", selection: $filter) {
                    ForEach(AppUpdateFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                if filteredItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 28))
                            .foregroundStyle(Tint.green)
                        Text("No Matching Update Results")
                            .font(.headline)
                        Text("Try another search or result filter.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else {
                    ForEach(filteredItems) { item in
                        AppUpdateRow(
                            item: item,
                            icon: appState.installedApps.first(where: { $0.id == item.id })?.icon,
                            isPerformingAction: appState.activeAppUpdateActionID == item.id,
                            action: { requestUpdate(item) },
                            openReleaseNotes: { appState.openAppUpdateReleaseNotes(item) }
                        )
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
                    format: String(localized: "%lld updates"),
                    Int64(appState.availableAppUpdateCount)
                ),
                systemImage: "arrow.down.circle.fill",
                tint: appState.availableAppUpdateCount > 0 ? Tint.blue : Tint.green
            )
            StatusChip(
                label: String(
                    format: String(localized: "%lld current"),
                    count(status: .upToDate)
                ),
                systemImage: "checkmark.circle.fill",
                tint: Tint.green
            )
            if count(status: .couldNotCheck) > 0 {
                StatusChip(
                    label: String(
                        format: String(localized: "%lld need review"),
                        count(status: .couldNotCheck)
                    ),
                    systemImage: "exclamationmark.triangle.fill",
                    tint: Tint.orange
                )
            }
            StatusChip(
                label: String(
                    format: String(localized: "%lld unsupported"),
                    Int64(appState.appUpdateUnsupportedAppCount)
                ),
                systemImage: "questionmark.circle",
                tint: Color.secondary
            )
            Spacer()
        }
    }

    private var sourceNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(Tint.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("Evidence first")
                    .font(.subheadline.weight(.semibold))
                Text("App Store, Homebrew, Sparkle, and Electron sources are tied to local evidence and re-verified before any external action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Tint.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Tint.green.opacity(0.16), lineWidth: 0.5)
        )
    }

    private func successNotice(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Tint.green)
            Text(message)
                .font(.subheadline)
            Spacer()
            Button {
                appState.appUpdateActionMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(12)
        .background(Tint.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var presentedError: String? {
        appState.appUpdateActionError ?? appState.appUpdateScanError
    }

    private func clearPresentedError() {
        appState.appUpdateActionError = nil
        appState.appUpdateScanError = nil
    }

    private func requestUpdate(_ item: AppUpdateItem) {
        if case .homebrewCask = item.source {
            pendingHomebrewUpdate = item
        } else {
            appState.performAppUpdate(item)
        }
    }

    private func count(status: AppUpdateStatus) -> Int64 {
        Int64(appState.appUpdates.count { $0.status == status })
    }
}

private struct AppUpdateRow: View {
    let item: AppUpdateItem
    let icon: NSImage?
    let isPerformingAction: Bool
    let action: () -> Void
    let openReleaseNotes: () -> Void

    var body: some View {
        CardSurface(padding: 14, elevation: .flat) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                    } else {
                        Image(systemName: "app.fill")
                            .resizable()
                            .scaledToFit()
                            .padding(5)
                            .foregroundStyle(Tint.blue)
                    }
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Text(item.appName)
                            .font(.system(size: 13, weight: .semibold))
                        AppUpdateStatusChip(status: item.status)
                        StatusChip(
                            label: item.source.title,
                            systemImage: item.source.icon,
                            tint: item.source.tint
                        )
                    }

                    versionLine

                    if let failure = item.failureReason {
                        Text(failure.message)
                            .font(.caption)
                            .foregroundStyle(Tint.orange)
                    }

                    HStack(spacing: 6) {
                        ForEach(item.evidence.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { evidence in
                            Text(evidence.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                        }
                    }
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 7) {
                    if item.status == .updateAvailable {
                        Button(action: action) {
                            if isPerformingAction {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label(item.source.actionTitle, systemImage: item.source.actionIcon)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isPerformingAction)
                    }
                    if item.releaseNotesURL != nil,
                       !item.source.primaryActionOpensReleasePage {
                        Button("Release Notes", action: openReleaseNotes)
                            .buttonStyle(.link)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var versionLine: some View {
        HStack(spacing: 6) {
            Text(item.currentVersion ?? item.currentBuild ?? String(localized: "Unknown"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let available = item.availableVersion {
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(available)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Tint.blue)
            }
        }
    }
}

private struct AppUpdateStatusChip: View {
    let status: AppUpdateStatus

    var body: some View {
        StatusChip(label: status.title, systemImage: status.icon, tint: status.tint)
    }
}

private extension AppUpdateStatus {
    var title: String {
        switch self {
        case .updateAvailable: return String(localized: "Update Available")
        case .upToDate: return String(localized: "Up to Date")
        case .couldNotCheck: return String(localized: "Needs Review")
        }
    }

    var icon: String {
        switch self {
        case .updateAvailable: return "arrow.down"
        case .upToDate: return "checkmark"
        case .couldNotCheck: return "exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .updateAvailable: return Tint.blue
        case .upToDate: return Tint.green
        case .couldNotCheck: return Tint.orange
        }
    }
}

private extension AppUpdateSource {
    var title: String {
        switch self {
        case .macAppStore: return String(localized: "Mac App Store")
        case .homebrewCask(let token, _): return "Homebrew · \(token)"
        case .sparkle: return "Sparkle"
        case .electronUpdater(let provider, _):
            switch provider {
            case .generic(let baseURL): return "Electron · \(baseURL.host ?? "HTTPS")"
            case .github: return "Electron · GitHub"
            }
        }
    }

    var searchText: String {
        switch self {
        case .macAppStore: return "Mac App Store Apple"
        case .homebrewCask(let token, _): return "Homebrew Cask \(token)"
        case .sparkle(let url): return "Sparkle \(url?.host ?? "")"
        case .electronUpdater(let provider, let channel):
            switch provider {
            case .generic(let baseURL): return "Electron Squirrel \(channel) \(baseURL.host ?? "")"
            case .github(let owner, let repo): return "Electron Squirrel GitHub \(owner) \(repo) \(channel)"
            }
        }
    }

    var icon: String {
        switch self {
        case .macAppStore: return "apple.logo"
        case .homebrewCask: return "shippingbox.fill"
        case .sparkle: return "sparkles"
        case .electronUpdater(let provider, _):
            switch provider {
            case .generic: return "bolt.horizontal.circle.fill"
            case .github: return "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    var tint: Color {
        switch self {
        case .macAppStore: return Tint.blue
        case .homebrewCask: return Tint.orange
        case .sparkle: return Tint.purple
        case .electronUpdater: return Tint.blue
        }
    }

    var actionTitle: String {
        switch self {
        case .macAppStore: return String(localized: "Open App Store")
        case .homebrewCask: return String(localized: "Update")
        case .sparkle: return String(localized: "Review Update")
        case .electronUpdater(let provider, _):
            switch provider {
            case .generic: return String(localized: "Open App…")
            case .github: return String(localized: "Open Release…")
            }
        }
    }

    var actionIcon: String {
        switch self {
        case .macAppStore: return "arrow.up.forward.app"
        case .homebrewCask: return "terminal"
        case .sparkle: return "sparkles"
        case .electronUpdater(let provider, _):
            switch provider {
            case .generic: return "arrow.up.forward.app"
            case .github: return "safari"
            }
        }
    }

    var primaryActionOpensReleasePage: Bool {
        guard case .electronUpdater(let provider, _) = self else {
            return false
        }
        if case .github = provider { return true }
        return false
    }
}

private extension AppUpdateEvidence {
    var title: LocalizedStringKey {
        switch self {
        case .developerSignature: return "Developer Signature"
        case .macAppStoreReceipt: return "App Store Receipt"
        case .spotlightProductIdentifier: return "Spotlight Product ID"
        case .appStoreLookupBundleMatch: return "Apple Bundle Match"
        case .homebrewReceipt: return "Cask Receipt"
        case .homebrewCaskroomArtifact: return "Caskroom Artifact"
        case .homebrewOutdatedCommand: return "brew outdated"
        case .sparkleHTTPSFeed: return "HTTPS Appcast"
        case .sparkleAppcast: return "Sparkle Version"
        case .electronUpdaterConfiguration: return "Signed Updater Config"
        case .squirrelFramework: return "Squirrel Framework"
        case .electronUpdateMetadata: return "Electron Version"
        case .githubReleaseIdentity: return "GitHub Release"
        }
    }
}

private extension AppUpdateFailureReason {
    var message: LocalizedStringKey {
        switch self {
        case .missingProductIdentifier:
            return "The App Store receipt is valid, but Spotlight did not provide a product ID."
        case .missingLocalVersion:
            return "The local app does not expose a version that can be compared safely."
        case .sourceUnavailable:
            return "The verified update manager is not currently available."
        case .networkUnavailable:
            return "The verified update source could not be reached."
        case .invalidResponse:
            return "The update source returned data AppSift could not validate."
        case .identityMismatch:
            return "The remote bundle identity did not match the installed app."
        case .insecureFeed:
            return "The app's update feed is not a public HTTPS address, so AppSift did not contact it."
        case .commandFailed:
            return "Homebrew could not complete the targeted outdated check."
        case .sourceChanged:
            return "The app or update source changed after the scan."
        case .stagedRollout:
            return "This release is being rolled out gradually, so the app must decide whether this Mac is eligible."
        case .incompatibleSystem:
            return "This release requires a newer macOS system version."
        }
    }
}
