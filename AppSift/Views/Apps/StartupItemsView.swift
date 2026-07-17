import SwiftUI

private enum StartupItemFilter: String, CaseIterable, Identifiable {
    case all
    case enabled
    case disabled
    case requiresApproval
    case missing

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .enabled: return "Enabled"
        case .disabled: return "Disabled"
        case .requiresApproval: return "Needs Approval"
        case .missing: return "Missing"
        }
    }

    func includes(_ item: StartupItem) -> Bool {
        switch self {
        case .all: return true
        case .enabled: return item.state == .enabled && !item.isMissing
        case .disabled: return item.state == .disabled && !item.isMissing
        case .requiresApproval: return item.state == .requiresApproval && !item.isMissing
        case .missing: return item.isMissing
        }
    }
}

private enum StartupItemConfirmation: Identifiable {
    case control(StartupItem, StartupItemControlAction)
    case undo(StartupItemControlRecord)
    case clearHistory

    var id: String {
        switch self {
        case let .control(item, action):
            return "control|\(item.id)|\(action.rawValue)"
        case let .undo(record):
            return "undo|\(record.id.uuidString)"
        case .clearHistory:
            return "clear-history"
        }
    }
}

struct StartupItemsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var filter: StartupItemFilter = .all
    @State private var pendingConfirmation: StartupItemConfirmation?
    @State private var showsAllHistory = false

    private var filteredItems: [StartupItem] {
        appState.startupItems.filter { item in
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

    private var visibleControlHistory: [StartupItemControlRecord] {
        showsAllHistory
            ? appState.startupItemControlHistory
            : Array(appState.startupItemControlHistory.prefix(5))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if appState.isScanningStartupItems && !appState.hasScannedStartupItems {
                    ProgressView(LocalizedStringKey("Reading macOS startup records..."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !appState.hasScannedStartupItems {
                    EmptyStateView(
                        "Startup Items",
                        systemImage: "power.circle",
                        description: "Review login items, background tasks, launch agents, and system daemons with their local evidence.",
                        action: { appState.scanStartupItems() },
                        actionLabel: "Scan Startup Items",
                        tint: Tint.orange
                    )
                } else if appState.startupItems.isEmpty
                    && appState.startupItemControlHistory.isEmpty {
                    EmptyStateView(
                        "No Startup Items Found",
                        systemImage: "checkmark.circle",
                        description: "AppSift did not find any startup records in the macOS registry or launchd folders.",
                        action: { appState.scanStartupItems(force: true) },
                        actionLabel: "Scan Again",
                        tint: Tint.green
                    )
                } else {
                    results
                }
            }
        }
        .navigationTitle("Startup Items")
        .searchable(text: $searchText, prompt: "Search startup items")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    appState.scanStartupItems(force: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(appState.isScanningStartupItems)

                Button {
                    appState.openLoginItemsSettings()
                } label: {
                    Label("Open Login Items", systemImage: "gear")
                }
            }
        }
        .onAppear {
            appState.scanStartupItems()
        }
        .alert(item: $pendingConfirmation) { confirmation in
            confirmationAlert(confirmation)
        }
        .alert("Startup Item Action Failed", isPresented: Binding(
            get: { appState.startupItemActionError != nil },
            set: { if !$0 { appState.startupItemActionError = nil } }
        )) {
            Button("OK", role: .cancel) {
                appState.startupItemActionError = nil
            }
        } message: {
            Text(appState.startupItemActionError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(systemName: "power.circle.fill", tint: Tint.orange, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("Startup Items")
                    .font(.title2.weight(.semibold))
                Text("Modern and system startup items stay read-only. Current-user legacy LaunchAgents can be safely controlled with undo history.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            if appState.isScanningStartupItems {
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

                if let message = appState.startupItemActionMessage {
                    actionNotice(message)
                }

                if !appState.startupBackgroundTaskDataAvailable
                    || appState.startupBackgroundTaskDataTruncated {
                    incompleteRegistryNotice
                }

                if !appState.startupItems.isEmpty {
                    Picker("Filter", selection: $filter) {
                        ForEach(StartupItemFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    if filteredItems.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text("No Matching Startup Items")
                                .font(.headline)
                            Text("Try another search or status filter.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    } else {
                        ForEach(StartupItemKind.allCases, id: \.self) { kind in
                            let items = filteredItems.filter { $0.kind == kind }
                            if !items.isEmpty {
                                startupGroup(kind: kind, items: items)
                            }
                        }
                    }
                }

                if !appState.startupItemControlHistory.isEmpty {
                    controlHistory
                }
            }
            .padding(20)
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            StatusChip(
                label: String(format: String(localized: "%lld total"), Int64(appState.startupItems.count)),
                systemImage: "list.bullet",
                tint: Tint.blue
            )
            StatusChip(
                label: String(format: String(localized: "%lld enabled"), count(state: .enabled)),
                systemImage: "checkmark.circle.fill",
                tint: Tint.green
            )
            StatusChip(
                label: String(format: String(localized: "%lld disabled"), count(state: .disabled)),
                systemImage: "pause.circle.fill",
                tint: .secondary
            )
            if controllableCount > 0 {
                StatusChip(
                    label: String(
                        format: String(localized: "%lld safely controllable"),
                        controllableCount
                    ),
                    systemImage: "arrow.uturn.backward.circle.fill",
                    tint: Tint.blue
                )
            }
            if count(state: .requiresApproval) > 0 {
                StatusChip(
                    label: String(format: String(localized: "%lld need approval"), count(state: .requiresApproval)),
                    systemImage: "exclamationmark.triangle.fill",
                    tint: Tint.orange
                )
            }
            if missingCount > 0 {
                StatusChip(
                    label: String(format: String(localized: "%lld missing"), missingCount),
                    systemImage: "questionmark.folder.fill",
                    tint: Tint.red
                )
            }
            Spacer()
        }
    }

    private var incompleteRegistryNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tint.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("macOS background registry was unavailable or incomplete")
                    .font(.subheadline.weight(.semibold))
                Text("LaunchAgent and LaunchDaemon property lists are still shown. Refresh to retry the full system registry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Tint.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Tint.orange.opacity(0.18), lineWidth: 0.5)
        )
    }

    private func actionNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Tint.green)
            Text(message)
                .font(.subheadline)
            Spacer(minLength: 12)
            Button {
                appState.startupItemActionMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(Tint.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Tint.green.opacity(0.16), lineWidth: 0.5)
        )
    }

    private var controlHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Tint.blue)
                Text("Change History")
                    .font(.headline)
                Text("\(appState.startupItemControlHistory.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(role: .destructive) {
                    pendingConfirmation = .clearHistory
                } label: {
                    Label("Clear History", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(appState.activeStartupItemActionID != nil)
            }

            Text("History is stored only on this Mac. Clearing it does not change any LaunchAgent state.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(visibleControlHistory) { record in
                StartupItemControlHistoryRow(
                    record: record,
                    isWorking: appState.activeStartupItemActionID == record.id.uuidString,
                    isUndoable: appState.isStartupItemControlUndoable(record),
                    actionsDisabled: appState.activeStartupItemActionID != nil
                        || appState.isScanningStartupItems,
                    undo: {
                        pendingConfirmation = .undo(record)
                    }
                )
            }


            if appState.startupItemControlHistory.count > 5 {
                Button {
                    showsAllHistory.toggle()
                } label: {
                    if showsAllHistory {
                        Label("Show Less", systemImage: "chevron.up")
                    } else {
                        Label("Show All History", systemImage: "chevron.down")
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func confirmationAlert(
        _ confirmation: StartupItemConfirmation
    ) -> Alert {
        switch confirmation {
        case let .control(item, action):
            let title = action == .disable
                ? String(localized: "Safely Disable LaunchAgent?")
                : String(localized: "Enable LaunchAgent?")
            let format = action == .disable
                ? String(localized: "Disable %@ and unload it from the current user session? The plist will not be deleted, and this change can be undone.")
                : String(localized: "Enable %@ and load it for the current user session? The plist will be revalidated first, and this change can be undone.")
            return Alert(
                title: Text(title),
                message: Text(String(format: format, item.name)),
                primaryButton: .default(Text(action.buttonTitle)) {
                    appState.controlStartupItem(item, action: action)
                },
                secondaryButton: .cancel()
            )
        case let .undo(record):
            let format = record.originalDisabled
                ? String(localized: "Undo this change and restore %@ to its previous disabled state? AppSift will revalidate the plist first.")
                : String(localized: "Undo this change and restore %@ to its previous enabled state? AppSift will revalidate the plist first.")
            return Alert(
                title: Text("Undo Startup Item Change?"),
                message: Text(String(format: format, record.itemName)),
                primaryButton: .default(Text("Undo")) {
                    appState.undoStartupItemControl(record)
                },
                secondaryButton: .cancel()
            )
        case .clearHistory:
            return Alert(
                title: Text("Clear Startup Item History?"),
                message: Text("This deletes only AppSift's local history. It does not enable, disable, load, unload, or delete any LaunchAgent."),
                primaryButton: .destructive(Text("Clear History")) {
                    appState.clearStartupItemControlHistory()
                    showsAllHistory = false
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func startupGroup(kind: StartupItemKind, items: [StartupItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: kind.icon)
                    .foregroundStyle(kind.tint)
                Text(kind.title)
                    .font(.headline)
                Text("\(items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            ForEach(items) { item in
                let controlAction = appState.isStartupItemControllable(item)
                    ? preferredControlAction(for: item)
                    : nil
                StartupItemRow(
                    item: item,
                    controlAction: controlAction,
                    isWorking: appState.activeStartupItemActionID == item.id,
                    actionsDisabled: appState.activeStartupItemActionID != nil
                        || appState.isScanningStartupItems,
                    reveal: {
                        appState.revealStartupItem(item)
                    },
                    control: { action in
                        pendingConfirmation = .control(item, action)
                    }
                )
            }
        }
    }

    private func preferredControlAction(
        for item: StartupItem
    ) -> StartupItemControlAction {
        item.state == .disabled ? .enable : .disable
    }

    private func searchableText(for item: StartupItem) -> String {
        [
            item.name,
            item.developerName,
            item.teamIdentifier,
            item.displayIdentifier,
            item.itemURL?.path,
            item.executableURL?.path,
            item.associatedBundleIdentifiers.joined(separator: " "),
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private func count(state: StartupItemState) -> Int64 {
        Int64(appState.startupItems.count { $0.state == state && !$0.isMissing })
    }

    private var missingCount: Int64 {
        Int64(appState.startupItems.count(where: \.isMissing))
    }

    private var controllableCount: Int64 {
        Int64(appState.startupItems.count(where: appState.isStartupItemControllable))
    }
}

private struct StartupItemRow: View {
    let item: StartupItem
    let controlAction: StartupItemControlAction?
    let isWorking: Bool
    let actionsDisabled: Bool
    let reveal: () -> Void
    let control: (StartupItemControlAction) -> Void

    var body: some View {
        CardSurface(padding: 12, elevation: .flat) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(systemName: item.kind.icon, tint: item.kind.tint, size: 30)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        StartupStateChip(item: item)
                        StatusChip(
                            label: item.scope.title,
                            systemImage: item.scope == .user ? "person.fill" : "desktopcomputer",
                            tint: .secondary
                        )
                    }

                    if let developer = item.developerName {
                        Text(developer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(item.displayIdentifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if let path = item.revealURL?.path {
                        Text(path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
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
                        if item.isLegacy {
                            Text("Legacy")
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
                    if let controlAction {
                        Button {
                            control(controlAction)
                        } label: {
                            if isWorking {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(controlAction.progressTitle)
                                }
                            } else {
                                Label(
                                    controlAction.buttonTitle,
                                    systemImage: controlAction.icon
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(actionsDisabled)
                    }

                    if item.revealURL != nil && !item.isMissing {
                        Button(action: reveal) {
                            Label("Reveal", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(actionsDisabled)
                    }
                }
            }
        }
    }
}

private struct StartupItemControlHistoryRow: View {
    let record: StartupItemControlRecord
    let isWorking: Bool
    let isUndoable: Bool
    let actionsDisabled: Bool
    let undo: () -> Void

    var body: some View {
        CardSurface(padding: 12, elevation: .flat) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(
                    systemName: record.action == .disable
                        ? "pause.circle.fill"
                        : "play.circle.fill",
                    tint: record.action == .disable ? .secondary : Tint.green,
                    size: 30
                )

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(record.itemName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        StatusChip(
                            label: record.restoredAt == nil
                                ? record.action.historyTitle
                                : String(localized: "Restored"),
                            systemImage: record.restoredAt == nil
                                ? record.action.icon
                                : "arrow.uturn.backward",
                            tint: record.restoredAt == nil
                                ? record.action.tint
                                : Tint.green
                        )
                    }

                    Text(record.serviceIdentifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Text(record.itemPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Text(
                        String(
                            format: String(localized: "Previous state: %@"),
                            record.previousStateDescription
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Text(record.changedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 12)

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else if isUndoable {
                    Button(action: undo) {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(actionsDisabled)
                } else if record.restoredAt == nil {
                    Text("Undo newer change first")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }
}

private struct StartupStateChip: View {
    let item: StartupItem

    var body: some View {
        if item.isMissing {
            StatusChip(label: String(localized: "Missing"), systemImage: "questionmark", tint: Tint.red)
        } else {
            StatusChip(label: item.state.title, systemImage: item.state.icon, tint: item.state.tint)
        }
    }
}

private extension StartupItemControlAction {
    var buttonTitle: String {
        switch self {
        case .disable: return String(localized: "Safe Disable")
        case .enable: return String(localized: "Enable")
        }
    }

    var progressTitle: String {
        switch self {
        case .disable: return String(localized: "Disabling...")
        case .enable: return String(localized: "Enabling...")
        }
    }

    var historyTitle: String {
        switch self {
        case .disable: return String(localized: "Disabled")
        case .enable: return String(localized: "Enabled")
        }
    }

    var icon: String {
        switch self {
        case .disable: return "pause.fill"
        case .enable: return "play.fill"
        }
    }

    var tint: Color {
        switch self {
        case .disable: return .secondary
        case .enable: return Tint.green
        }
    }
}

private extension StartupItemControlRecord {
    var previousStateDescription: String {
        switch (originalDisabled, originalLoaded) {
        case (false, true):
            return String(localized: "Enabled and loaded")
        case (false, false):
            return String(localized: "Enabled but not loaded")
        case (true, false):
            return String(localized: "Disabled and unloaded")
        case (true, true):
            return String(localized: "Disabled but still loaded")
        }
    }
}

private extension StartupItemKind {
    var title: LocalizedStringKey {
        switch self {
        case .loginItem: return "Login Items"
        case .backgroundItem: return "Background Items"
        case .launchAgent: return "Launch Agents"
        case .launchDaemon: return "System Daemons"
        }
    }

    var icon: String {
        switch self {
        case .loginItem: return "person.crop.circle.badge.checkmark"
        case .backgroundItem: return "gearshape.2.fill"
        case .launchAgent: return "bolt.horizontal.circle.fill"
        case .launchDaemon: return "server.rack"
        }
    }

    var tint: Color {
        switch self {
        case .loginItem: return Tint.blue
        case .backgroundItem: return Tint.purple
        case .launchAgent: return Tint.orange
        case .launchDaemon: return Tint.red
        }
    }
}

private extension StartupItemState {
    var title: String {
        switch self {
        case .enabled: return String(localized: "Enabled")
        case .disabled: return String(localized: "Disabled")
        case .requiresApproval: return String(localized: "Needs Approval")
        case .unknown: return String(localized: "Unknown")
        }
    }

    var icon: String {
        switch self {
        case .enabled: return "checkmark"
        case .disabled: return "pause.fill"
        case .requiresApproval: return "exclamationmark"
        case .unknown: return "questionmark"
        }
    }

    var tint: Color {
        switch self {
        case .enabled: return Tint.green
        case .disabled: return .secondary
        case .requiresApproval: return Tint.orange
        case .unknown: return Tint.blue
        }
    }
}

private extension StartupItemScope {
    var title: String {
        switch self {
        case .user: return String(localized: "User")
        case .system: return String(localized: "System")
        }
    }
}

private extension StartupItemEvidence {
    var title: LocalizedStringKey {
        switch self {
        case .backgroundTaskManagement: return "macOS Registry"
        case .launchdPropertyList: return "launchd Plist"
        case .appleAttribution: return "Apple Attribution"
        }
    }
}
