import SwiftUI
import UniformTypeIdentifiers

private enum DefaultApplicationFilter: String, CaseIterable, Identifiable {
    case all
    case common
    case documents
    case media
    case archives
    case developer
    case other

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .common: return "Common"
        case .documents: return "Documents"
        case .media: return "Media"
        case .archives: return "Archives"
        case .developer: return "Developer"
        case .other: return "Other"
        }
    }

    func includes(_ item: DefaultApplicationItem) -> Bool {
        switch self {
        case .all:
            return true
        case .common:
            return item.evidence.contains(.commonTypeCatalog)
        case .documents:
            return item.category == .documents
        case .media:
            return item.category == .images
                || item.category == .audio
                || item.category == .video
        case .archives:
            return item.category == .archives
        case .developer:
            return item.category == .developer
        case .other:
            return item.category == .other
        }
    }
}

private struct PendingDefaultApplicationChange: Identifiable {
    let item: DefaultApplicationItem
    let candidate: DefaultApplicationCandidate

    var id: String {
        "\(item.id)|\(candidate.id)"
    }
}

struct DefaultApplicationsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var filter: DefaultApplicationFilter = .common
    @State private var pendingChange: PendingDefaultApplicationChange?

    private var filteredItems: [DefaultApplicationItem] {
        appState.defaultApplications.filter { item in
            guard filter.includes(item) else { return false }
            guard !searchText.isEmpty else { return true }
            let query = searchText.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            let haystack = [
                item.displayName,
                item.contentTypeIdentifier,
                item.filenameExtensions.joined(separator: " "),
                item.currentApplication.name,
                item.currentApplication.bundleIdentifier,
                item.candidateApplications.map(\.name).joined(separator: " "),
            ]
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

            Group {
                if appState.isScanningDefaultApplications
                    && !appState.hasScannedDefaultApplications {
                    ProgressView(
                        LocalizedStringKey(
                            "Reading file type handlers from LaunchServices..."
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !appState.hasScannedDefaultApplications {
                    EmptyStateView(
                        "Default Applications",
                        systemImage: "arrow.up.forward.app.fill",
                        description: "See which app opens each file type, compare locally registered alternatives, and change defaults through Apple's public macOS API.",
                        action: { appState.scanDefaultApplications() },
                        actionLabel: "Scan Default Applications",
                        tint: Tint.blue
                    )
                } else if appState.defaultApplications.isEmpty {
                    EmptyStateView(
                        "No Default Applications Found",
                        systemImage: "questionmark.app.fill",
                        description: "LaunchServices did not return a verified default handler for the scanned file types.",
                        action: {
                            appState.scanDefaultApplications(force: true)
                        },
                        actionLabel: "Scan Again",
                        tint: Tint.orange
                    )
                } else {
                    results
                }
            }
        }
        .navigationTitle("Default Applications")
        .searchable(text: $searchText, prompt: "Search file types or applications")
        .toolbar {
            ToolbarItemGroup {
                if appState.isScanningDefaultApplications {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    appState.scanDefaultApplications(force: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(
                    appState.isScanningDefaultApplications
                        || appState.activeDefaultApplicationActionID != nil
                )
            }
        }
        .onAppear {
            appState.scanDefaultApplications()
        }
        .confirmationDialog(
            "Change Default Application?",
            isPresented: Binding(
                get: { pendingChange != nil },
                set: { if !$0 { pendingChange = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingChange {
                Button(
                    String(
                        format: String(localized: "Use %@"),
                        pendingChange.candidate.name
                    )
                ) {
                    appState.changeDefaultApplication(
                        pendingChange.item,
                        to: pendingChange.candidate
                    )
                    self.pendingChange = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingChange = nil
            }
        } message: {
            if let pendingChange {
                Text(
                    String(
                        format: String(
                            localized: "%@ will open %@ files by default. macOS may ask you to confirm this change."
                        ),
                        pendingChange.candidate.name,
                        typeSummary(pendingChange.item)
                    )
                )
            }
        }
        .alert("Default Application Change Failed", isPresented: Binding(
            get: { appState.defaultApplicationActionError != nil },
            set: {
                if !$0 { appState.defaultApplicationActionError = nil }
            }
        )) {
            Button("OK", role: .cancel) {
                appState.defaultApplicationActionError = nil
            }
        } message: {
            Text(appState.defaultApplicationActionError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(
                systemName: "arrow.up.forward.app.fill",
                tint: Tint.blue,
                size: 34
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("Default Applications")
                    .font(.title2.weight(.semibold))
                Text("Inspect and change file handlers with Apple's public NSWorkspace and UTType APIs. AppSift never edits the LaunchServices database directly.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                summary
                publicAPINotice

                if let message = appState.defaultApplicationActionMessage {
                    successNotice(message)
                }
                if appState.unreadableDefaultApplicationDeclarationCount > 0
                    || appState.defaultApplicationScanWasTruncated {
                    incompleteNotice
                }

                Picker("Filter", selection: $filter) {
                    ForEach(DefaultApplicationFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220, alignment: .leading)

                if filteredItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("No Matching File Types")
                            .font(.headline)
                        Text("Try another search or category filter.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else {
                    ForEach(DefaultApplicationCategory.allCases, id: \.self) {
                        category in
                        let items = filteredItems.filter {
                            $0.category == category
                        }
                        if !items.isEmpty {
                            applicationGroup(
                                category: category,
                                items: items
                            )
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
                    format: String(localized: "%lld file types"),
                    Int64(appState.defaultApplications.count)
                ),
                systemImage: "doc.on.doc.fill",
                tint: Tint.blue
            )
            StatusChip(
                label: String(
                    format: String(localized: "%lld with alternatives"),
                    Int64(appState.defaultApplications.count {
                        $0.alternativeCount > 0
                    })
                ),
                systemImage: "arrow.triangle.branch",
                tint: Tint.purple
            )
            StatusChip(
                label: String(
                    format: String(localized: "%lld system defaults"),
                    Int64(appState.defaultApplications.count {
                        $0.currentApplication.isSystemApplication
                    })
                ),
                systemImage: "apple.logo",
                tint: .secondary
            )
            Spacer()
        }
    }

    private var publicAPINotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(Tint.green)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Apple API only")
                    .font(.caption.weight(.semibold))
                Text("Every candidate comes from LaunchServices. Before changing anything, AppSift checks the current handler and candidate again, then verifies the result. Newer macOS versions may show a system confirmation for each file type.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Tint.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
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
            if let record = appState.latestUndoableDefaultApplicationRecord {
                Button("Undo") {
                    appState.undoDefaultApplicationChange(record)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.activeDefaultApplicationActionID != nil)
            }
            Button {
                appState.defaultApplicationActionMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(12)
        .background(Tint.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var incompleteNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tint.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Some File Type Declarations Were Incomplete")
                    .font(.caption.weight(.semibold))
                Text("AppSift shows only handlers returned by LaunchServices. Unreadable or safety-limited app declarations are not guessed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    String(
                        format: String(
                            localized: "%lld unreadable app declarations · truncated: %@"
                        ),
                        Int64(
                            appState
                                .unreadableDefaultApplicationDeclarationCount
                        ),
                        appState.defaultApplicationScanWasTruncated
                            ? String(localized: "Yes")
                            : String(localized: "No")
                    )
                )
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

    private func applicationGroup(
        category: DefaultApplicationCategory,
        items: [DefaultApplicationItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: category.icon)
                    .foregroundStyle(category.tint)
                Text(category.title)
                    .font(.headline)
                Text(items.count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ForEach(items) { item in
                DefaultApplicationRow(
                    item: item,
                    isChanging: appState
                        .activeDefaultApplicationActionID == item.id,
                    selectCandidate: { candidate in
                        pendingChange = PendingDefaultApplicationChange(
                            item: item,
                            candidate: candidate
                        )
                    }
                )
            }
        }
    }

    private func typeSummary(_ item: DefaultApplicationItem) -> String {
        if let first = item.filenameExtensions.first {
            return ".\(first)"
        }
        return item.displayName
    }
}

private struct DefaultApplicationRow: View {
    let item: DefaultApplicationItem
    let isChanging: Bool
    let selectCandidate: (DefaultApplicationCandidate) -> Void

    var body: some View {
        CardSurface(padding: 14, elevation: .flat) {
            HStack(alignment: .center, spacing: 14) {
                contentTypeIcon

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(item.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        StatusChip(
                            label: item.category.title,
                            systemImage: item.category.icon,
                            tint: item.category.tint
                        )
                    }

                    if !item.filenameExtensions.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(item.filenameExtensions.prefix(8), id: \.self) {
                                value in
                                Text(verbatim: ".\(value)")
                                    .font(.system(size: 10, weight: .medium).monospaced())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Color.primary.opacity(0.05),
                                        in: Capsule()
                                    )
                            }
                        }
                    }

                    Text(item.contentTypeIdentifier)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)

                    HStack(spacing: 6) {
                        ForEach(
                            item.evidence.sorted { $0.rawValue < $1.rawValue },
                            id: \.self
                        ) { evidence in
                            Text(evidence.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Color.primary.opacity(0.05),
                                    in: Capsule()
                                )
                        }
                    }
                }

                Spacer(minLength: 16)

                HStack(spacing: 10) {
                    applicationIcon(item.currentApplication)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(item.currentApplication.name)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            if item.currentApplication.isSystemApplication {
                                Text(verbatim: "macOS")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        Color.primary.opacity(0.05),
                                        in: Capsule()
                                    )
                            }
                        }
                        Text(item.currentApplication.bundleIdentifier)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .frame(width: 190, alignment: .leading)
                }

                if isChanging {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 86)
                } else {
                    Menu {
                        ForEach(
                            item.candidateApplications.filter {
                                $0.id != item.currentApplication.id
                            }
                        ) { candidate in
                            Button {
                                selectCandidate(candidate)
                            } label: {
                                Label {
                                    Text(candidate.name)
                                } icon: {
                                    Image(
                                        nsImage: NSWorkspace.shared.icon(
                                            forFile: candidate.url.path
                                        )
                                    )
                                }
                            }
                        }
                    } label: {
                        Label("Change", systemImage: "arrow.left.arrow.right")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(item.alternativeCount == 0)
                    .help(
                        item.alternativeCount == 0
                            ? String(localized: "No other registered application can open this file type.")
                            : String(localized: "Choose another registered application")
                    )
                }
            }
        }
    }

    private var contentTypeIcon: some View {
        Group {
            if let type = UTType(item.contentTypeIdentifier) {
                Image(nsImage: NSWorkspace.shared.icon(for: type))
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: item.category.icon)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
                    .foregroundStyle(item.category.tint)
            }
        }
        .frame(width: 34, height: 34)
    }

    private func applicationIcon(
        _ application: DefaultApplicationCandidate
    ) -> some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
            .resizable()
            .scaledToFit()
            .frame(width: 30, height: 30)
    }
}

private extension DefaultApplicationCategory {
    var title: String {
        switch self {
        case .documents: return String(localized: "Documents")
        case .images: return String(localized: "Images")
        case .audio: return String(localized: "Audio")
        case .video: return String(localized: "Video")
        case .archives: return String(localized: "Archives")
        case .developer: return String(localized: "Developer")
        case .other: return String(localized: "Other")
        }
    }

    var icon: String {
        switch self {
        case .documents: return "doc.fill"
        case .images: return "photo.fill"
        case .audio: return "waveform"
        case .video: return "film.fill"
        case .archives: return "archivebox.fill"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .other: return "square.grid.2x2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .documents: return Tint.blue
        case .images: return Tint.pink
        case .audio: return Tint.purple
        case .video: return Tint.orange
        case .archives: return Tint.cyan
        case .developer: return Tint.green
        case .other: return .secondary
        }
    }
}

private extension DefaultApplicationEvidence {
    var title: String {
        switch self {
        case .commonTypeCatalog:
            return String(localized: "Common file type")
        case .applicationDeclaration:
            return String(localized: "App declaration")
        case .launchServicesCurrentHandler:
            return String(localized: "LaunchServices default")
        case .launchServicesCandidates:
            return String(localized: "Registered candidates")
        }
    }
}
