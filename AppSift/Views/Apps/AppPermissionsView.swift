import AppKit
import SwiftUI

private enum AppPermissionFilter: String, CaseIterable, Identifiable {
    case all
    case allowed
    case denied
    case highImpact
    case stale
    case declared

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .allowed: return "Allowed"
        case .denied: return "Denied"
        case .highImpact: return "High Impact"
        case .stale: return "Stale"
        case .declared: return "Declared"
        }
    }

    func includes(_ client: AppPermissionClient) -> Bool {
        switch self {
        case .all:
            return true
        case .allowed:
            return client.allowedCount > 0
        case .denied:
            return client.deniedCount > 0
        case .highImpact:
            return client.highImpactAllowedCount > 0
        case .stale:
            return client.isStale
        case .declared:
            return !client.declarations.isEmpty
        }
    }
}

private struct PendingAppPermissionReset: Identifiable {
    let client: AppPermissionClient
    let service: AppPermissionService

    var id: String { "\(client.id)|\(service.rawValue)" }
}

struct AppPermissionsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var filter: AppPermissionFilter = .all
    @State private var selectedClientID: String?
    @State private var pendingReset: PendingAppPermissionReset?

    private var filteredClients: [AppPermissionClient] {
        appState.appPermissionClients.filter { client in
            guard filter.includes(client) else { return false }
            guard !searchText.isEmpty else { return true }
            let query = searchText.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            let haystack = [
                client.name,
                client.clientIdentifier,
                client.bundleIdentifier ?? "",
                client.applicationURL?.path ?? "",
                client.records.map { $0.service.displayNameKey }.joined(separator: " "),
                client.declarations.map { $0.purpose }.joined(separator: " "),
            ]
            .joined(separator: " ")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            return haystack.contains(query)
        }
    }

    private var selectedClient: AppPermissionClient? {
        guard let selectedClientID else { return filteredClients.first }
        return filteredClients.first { $0.id == selectedClientID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if appState.isScanningAppPermissions && !appState.hasScannedAppPermissions {
                    ProgressView(
                        LocalizedStringKey("Reading local privacy permission evidence...")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !appState.hasScannedAppPermissions {
                    EmptyStateView(
                        "Privacy Permissions",
                        systemImage: "hand.raised.fill",
                        description: "Audit local macOS privacy decisions and app usage declarations without sending an inventory off this Mac.",
                        action: { appState.scanAppPermissions() },
                        actionLabel: "Scan Privacy Permissions",
                        tint: Tint.blue
                    )
                } else if appState.appPermissionClients.isEmpty {
                    emptyResult
                } else {
                    results
                }
            }
        }
        .navigationTitle("Privacy Permissions")
        .searchable(text: $searchText, prompt: "Search apps or permissions")
        .toolbar {
            ToolbarItemGroup {
                if appState.isScanningAppPermissions {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    appState.scanAppPermissions(force: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(
                    appState.isScanningAppPermissions
                        || appState.activeAppPermissionActionID != nil
                )
            }
        }
        .onAppear {
            appState.scanAppPermissions()
            reconcileSelection()
        }
        .onChange(of: appState.appPermissionClients) { _ in
            reconcileSelection()
        }
        .onChange(of: filter) { _ in
            reconcileSelection()
        }
        .onChange(of: searchText) { _ in
            reconcileSelection()
        }
        .confirmationDialog(
            "Reset Privacy Decision?",
            isPresented: Binding(
                get: { pendingReset != nil },
                set: { if !$0 { pendingReset = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingReset {
                Button("Reset Decision", role: .destructive) {
                    appState.resetAppPermission(
                        client: pendingReset.client,
                        service: pendingReset.service
                    )
                    self.pendingReset = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingReset = nil
            }
        } message: {
            if let pendingReset {
                Text(
                    String(
                        format: String(
                            localized: "AppSift will ask macOS to forget %@'s saved %@ decision using tccutil. It does not grant or deny access. The app may ask again next time."
                        ),
                        pendingReset.client.name,
                        localizedName(pendingReset.service)
                    )
                )
            }
        }
        .alert("Privacy Permission Action Failed", isPresented: Binding(
            get: { appState.appPermissionActionError != nil },
            set: { if !$0 { appState.appPermissionActionError = nil } }
        )) {
            Button("OK", role: .cancel) {
                appState.appPermissionActionError = nil
            }
        } message: {
            Text(appState.appPermissionActionError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(systemName: "hand.raised.fill", tint: Tint.blue, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("Privacy Permissions")
                    .font(.title2.weight(.semibold))
                Text("See what macOS has allowed or denied, what apps declare they may request, and safely reset remembered decisions.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("AppSift reads TCC evidence in read-only mode and never edits its database directly.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 16)
            if let date = appState.lastAppPermissionScanDate {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Last scanned")
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

    private var emptyResult: some View {
        VStack(spacing: 16) {
            EmptyStateView(
                "No Permission Evidence Found",
                systemImage: "checkmark.shield.fill",
                description: "No readable macOS privacy decisions or app usage declarations were found.",
                action: { appState.scanAppPermissions(force: true) },
                actionLabel: "Scan Again",
                tint: Tint.green
            )
            if !hasReadableDatabase {
                Button("Open Full Disk Access Settings") {
                    appState.openAppPermissionSettings(for: .fullDiskAccess)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            summary
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            sourceNotice
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            HSplitView {
                clientList
                    .frame(minWidth: 260, idealWidth: 310, maxWidth: 380)

                Group {
                    if let selectedClient {
                        clientDetail(selectedClient)
                    } else {
                        noMatchingClients
                    }
                }
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            StatusChip(
                label: String(
                    format: String(localized: "%lld apps"),
                    Int64(appState.appPermissionClients.count)
                ),
                systemImage: "app.fill",
                tint: Tint.blue
            )
            StatusChip(
                label: String(
                    format: String(localized: "%lld allowed"),
                    Int64(appState.appPermissionClients.reduce(0) { $0 + $1.allowedCount })
                ),
                systemImage: "checkmark.circle.fill",
                tint: Tint.green
            )
            StatusChip(
                label: String(
                    format: String(localized: "%lld high impact"),
                    Int64(appState.highImpactAllowedAppPermissionCount)
                ),
                systemImage: "exclamationmark.shield.fill",
                tint: Tint.orange
            )
            StatusChip(
                label: String(
                    format: String(localized: "%lld stale"),
                    Int64(appState.appPermissionClients.count { $0.isStale })
                ),
                systemImage: "questionmark.app.fill",
                tint: .secondary
            )
            Spacer(minLength: 0)
        }
    }

    private var sourceNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: hasReadableDatabase
                ? "checkmark.shield.fill"
                : "exclamationmark.triangle.fill")
                .foregroundStyle(hasReadableDatabase ? Tint.green : Tint.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(hasReadableDatabase
                    ? "Local evidence only"
                    : "Permission inventory is incomplete")
                    .font(.caption.weight(.semibold))
                Text(sourceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(sourceStatusSummary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if !hasReadableDatabase {
                Button("Open Settings") {
                    appState.openAppPermissionSettings(for: .fullDiskAccess)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            (hasReadableDatabase ? Tint.green : Tint.orange).opacity(0.07),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    (hasReadableDatabase ? Tint.green : Tint.orange).opacity(0.18),
                    lineWidth: 0.5
                )
        )
    }

    private var clientList: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $filter) {
                ForEach(AppPermissionFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .padding(12)

            Divider()

            if filteredClients.isEmpty {
                noMatchingClients
            } else {
                List {
                    ForEach(filteredClients) { client in
                        Button {
                            selectedClientID = client.id
                        } label: {
                            clientRow(client)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            selectedClientID == client.id
                                ? Tint.blue.opacity(0.12)
                                : Color.clear
                        )
                        .accessibilityLabel(client.name)
                        .accessibilityValue(clientAccessibilityValue(client))
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func clientRow(_ client: AppPermissionClient) -> some View {
        HStack(spacing: 10) {
            clientIcon(client, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(client.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(client.bundleIdentifier ?? client.clientIdentifier)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    if client.allowedCount > 0 {
                        Text(String(
                            format: String(localized: "%lld allowed"),
                            Int64(client.allowedCount)
                        ))
                        .foregroundStyle(Tint.green)
                    }
                    if client.deniedCount > 0 {
                        Text(String(
                            format: String(localized: "%lld denied"),
                            Int64(client.deniedCount)
                        ))
                        .foregroundStyle(Tint.red)
                    }
                    if client.isStale {
                        Text("Stale")
                            .foregroundStyle(Tint.orange)
                    }
                }
                .font(.caption2.weight(.medium))
            }
            Spacer(minLength: 4)
            if client.highImpactAllowedCount > 0 {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(Tint.orange)
                    .help("High-impact permission allowed")
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private func clientDetail(_ client: AppPermissionClient) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                clientIdentity(client)

                if let message = appState.appPermissionActionMessage {
                    successNotice(message)
                }

                if client.isStale {
                    staleNotice
                }

                if !client.records.isEmpty {
                    ForEach(AppPermissionCategory.allCases, id: \.self) { category in
                        let records = client.records.filter { $0.service.category == category }
                        if !records.isEmpty {
                            permissionGroup(category, records: records, client: client)
                        }
                    }
                }

                declarationSection(client)
            }
            .padding(20)
        }
    }

    private func clientIdentity(_ client: AppPermissionClient) -> some View {
        CardSurface(elevation: .flat) {
            HStack(alignment: .top, spacing: 14) {
                clientIcon(client, size: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text(client.name)
                        .font(.title3.weight(.semibold))
                    Text(client.bundleIdentifier ?? client.clientIdentifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let path = client.applicationURL?.path {
                        Text(path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 6) {
                        StatusChip(
                            label: client.isInstalled
                                ? String(localized: "Installed")
                                : String(localized: "Not installed"),
                            systemImage: client.isInstalled
                                ? "checkmark.circle.fill"
                                : "questionmark.circle.fill",
                            tint: client.isInstalled ? Tint.green : Tint.orange
                        )
                        if let version = client.version {
                            StatusChip(label: version, systemImage: "number", tint: .secondary)
                        }
                    }
                }
                Spacer(minLength: 10)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(String(
                        format: String(localized: "%lld observed decisions"),
                        Int64(client.records.count)
                    ))
                    Text(String(
                        format: String(localized: "%lld declared purposes"),
                        Int64(client.declarations.count)
                    ))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func permissionGroup(
        _ category: AppPermissionCategory,
        records: [AppPermissionRecord],
        client: AppPermissionClient
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(category.title, systemImage: category.icon)
                .font(.headline)
                .foregroundStyle(category.tint)
            CardSurface(padding: 0, elevation: .flat) {
                VStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        permissionRow(record, client: client)
                            .padding(12)
                        if index < records.count - 1 {
                            Divider()
                                .padding(.leading, 44)
                        }
                    }
                }
            }
        }
    }

    private func permissionRow(
        _ record: AppPermissionRecord,
        client: AppPermissionClient
    ) -> some View {
        let actionID = "\(client.id)|\(record.service.rawValue)"
        let isActing = appState.activeAppPermissionActionID == actionID
        let declaration = client.declarations.first {
            $0.service == record.service
        }

        return HStack(alignment: .top, spacing: 11) {
            IconTile(
                systemName: record.service.icon,
                tint: record.decision.tint,
                size: 32
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(localizedName(record.service))
                        .font(.system(size: 13, weight: .semibold))
                    StatusChip(
                        label: record.decision.title,
                        systemImage: record.decision.icon,
                        tint: record.decision.tint
                    )
                    if record.service.isHighImpact {
                        StatusChip(
                            label: String(localized: "High Impact"),
                            systemImage: "exclamationmark.shield.fill",
                            tint: Tint.orange
                        )
                    }
                }
                Text(String(
                    format: String(localized: "%@ database evidence"),
                    record.scope.title
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                if let purpose = declaration?.purpose {
                    Text(purpose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let target = record.indirectObjectIdentifier {
                    Text(String(
                        format: String(localized: "Target: %@"),
                        target
                    ))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                }
                if let date = record.lastModified {
                    Text(String(
                        format: String(localized: "Changed: %@"),
                        date.formatted(date: .abbreviated, time: .shortened)
                    ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 7) {
                Button("Open Settings") {
                    appState.openAppPermissionSettings(for: record.service)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if appState.canResetAppPermission(
                    client: client,
                    service: record.service
                ) || isActing {
                    Button("Reset Decision") {
                        pendingReset = PendingAppPermissionReset(
                            client: client,
                            service: record.service
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isActing)
                }
                if isActing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private func declarationSection(_ client: AppPermissionClient) -> some View {
        let declarationOnly = client.declarations.filter { declaration in
            !client.records.contains { $0.service == declaration.service }
        }
        if !declarationOnly.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Declared Request Reasons", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(Tint.purple)
                Text("A usage description shows what an app says it may request. It is not proof that access was granted or used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CardSurface(padding: 0, elevation: .flat) {
                    VStack(spacing: 0) {
                        ForEach(Array(declarationOnly.enumerated()), id: \.element.id) { index, item in
                            HStack(alignment: .top, spacing: 10) {
                                IconTile(
                                    systemName: item.service.icon,
                                    tint: Tint.purple,
                                    size: 30
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(localizedName(item.service))
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(item.purpose)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(item.propertyListKey)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .textSelection(.enabled)
                                }
                                Spacer(minLength: 8)
                                StatusChip(
                                    label: String(localized: "Declared only"),
                                    systemImage: "doc.text",
                                    tint: Tint.purple
                                )
                            }
                            .padding(12)
                            if index < declarationOnly.count - 1 {
                                Divider()
                                    .padding(.leading, 42)
                            }
                        }
                    }
                }
            }
        }
    }

    private var staleNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.app.fill")
                .foregroundStyle(Tint.orange)
            Text("This client still has a privacy record, but AppSift could not match it to an installed app. Review the identifier before resetting anything.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Tint.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private func successNotice(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Tint.green)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                appState.appPermissionActionMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Tint.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private var noMatchingClients: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No Matching Apps")
                .font(.headline)
            Text("Try another search or permission filter.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    @ViewBuilder
    private func clientIcon(_ client: AppPermissionClient, size: CGFloat) -> some View {
        if let url = client.applicationURL,
           FileManager.default.fileExists(atPath: url.path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            IconTile(
                systemName: client.isStale ? "questionmark.app.fill" : "app.fill",
                tint: client.isStale ? Tint.orange : Tint.blue,
                size: size
            )
        }
    }

    private var hasReadableDatabase: Bool {
        appState.appPermissionSources.contains { $0.status == .available }
    }

    private var sourceDescription: String {
        if hasReadableDatabase {
            return String(localized: "Observed decisions come from local read-only TCC evidence. Declared reasons come from each app's Info.plist. Reset uses Apple's tccutil command; AppSift never writes the TCC database.")
        }
        return String(localized: "AppSift could not read a macOS privacy database. Grant Full Disk Access for a complete local inventory; app declarations may still be shown.")
    }

    private var sourceStatusSummary: String {
        appState.appPermissionSources.map { source in
            "\(source.scope.title): \(source.status.title) · \(source.rowCount)"
        }.joined(separator: "   ")
    }

    private func localizedName(_ service: AppPermissionService) -> String {
        String(localized: String.LocalizationValue(service.displayNameKey))
    }

    private func reconcileSelection() {
        guard !filteredClients.isEmpty else {
            selectedClientID = nil
            return
        }
        if let selectedClientID,
           filteredClients.contains(where: { $0.id == selectedClientID }) {
            return
        }
        selectedClientID = filteredClients.first?.id
    }

    private func clientAccessibilityValue(_ client: AppPermissionClient) -> String {
        String(
            format: String(localized: "%lld allowed, %lld denied"),
            Int64(client.allowedCount),
            Int64(client.deniedCount)
        )
    }
}

private extension AppPermissionDecision {
    var title: String {
        switch self {
        case .allowed: return String(localized: "Allowed")
        case .denied: return String(localized: "Denied")
        case .limited: return String(localized: "Limited")
        case .unknown: return String(localized: "Unknown")
        }
    }

    var icon: String {
        switch self {
        case .allowed: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .limited: return "minus.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .allowed: return Tint.green
        case .denied: return Tint.red
        case .limited: return Tint.orange
        case .unknown: return .secondary
        }
    }
}

private extension AppPermissionService {
    var icon: String {
        switch category {
        case .systemControl: return "gearshape.2.fill"
        case .mediaAndSensors: return "waveform.and.mic"
        case .personalData: return "person.crop.circle.badge.checkmark"
        case .filesAndFolders: return "folder.fill"
        case .other: return "hand.raised.fill"
        }
    }
}

private extension AppPermissionCategory {
    var title: LocalizedStringKey {
        switch self {
        case .systemControl: return "System Control"
        case .mediaAndSensors: return "Media & Sensors"
        case .personalData: return "Personal Data"
        case .filesAndFolders: return "Files & Folders"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .systemControl: return "gearshape.2.fill"
        case .mediaAndSensors: return "camera.mic.fill"
        case .personalData: return "person.crop.circle.fill"
        case .filesAndFolders: return "folder.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .systemControl: return Tint.orange
        case .mediaAndSensors: return Tint.blue
        case .personalData: return Tint.purple
        case .filesAndFolders: return Tint.green
        case .other: return .secondary
        }
    }
}

private extension AppPermissionDatabaseScope {
    var title: String {
        switch self {
        case .user: return String(localized: "User")
        case .system: return String(localized: "System")
        }
    }
}

private extension AppPermissionDatabaseStatus {
    var title: String {
        switch self {
        case .available: return String(localized: "Available")
        case .notFound: return String(localized: "Not found")
        case .permissionDenied: return String(localized: "Permission denied")
        case .unsupportedSchema: return String(localized: "Unsupported schema")
        case .readFailed: return String(localized: "Read failed")
        }
    }
}
