import SwiftUI

struct DownloadsBySourceView: View {
    @ObservedObject var center: DownloadSourceCenter
    @State private var searchText = ""
    @State private var confirmsRemoval = false

    private var filteredItems: [DownloadSourceItem] {
        guard !searchText.isEmpty else { return center.items }
        let query = searchText.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return center.items.filter { item in
            [item.name, item.source.title, item.sourceAgentName, item.originHost]
                .compactMap { $0 }
                .joined(separator: " ")
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                .contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if center.isScanning && !center.hasScanned {
                ProgressView(LocalizedStringKey("Classifying downloads by source…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !center.hasScanned {
                EmptyStateView(
                    "Downloads by Source",
                    systemImage: "arrow.down.doc.fill",
                    description: "Classify ordinary files in Downloads using local quarantine metadata from Safari, Chrome, Firefox, Slack, Mail, AirDrop, and other apps.",
                    action: { center.scan() },
                    actionLabel: "Scan Downloads",
                    tint: Tint.blue
                )
            } else if center.items.isEmpty {
                EmptyStateView(
                    "No Downloads Found",
                    systemImage: "checkmark.circle",
                    description: "No local ordinary files are currently available in Downloads. Cloud placeholders were left untouched.",
                    action: { center.scan(force: true) },
                    actionLabel: "Scan Again",
                    tint: Tint.green
                )
            } else {
                results
            }
        }
        .navigationTitle("Downloads by Source")
        .searchable(text: $searchText, prompt: "Search downloads")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    center.openDownloadsFolder()
                } label: {
                    Label("Open Downloads", systemImage: "folder")
                }
                Button {
                    center.isScanning ? center.cancelScan() : center.scan(force: true)
                } label: {
                    Label(
                        center.isScanning ? "Cancel Scan" : "Refresh",
                        systemImage: center.isScanning ? "xmark.circle" : "arrow.clockwise"
                    )
                }
                Button(role: .destructive) {
                    confirmsRemoval = true
                } label: {
                    Label("Move Selected to Trash", systemImage: "trash")
                }
                .disabled(center.selectedIDs.isEmpty || center.isRemoving || center.isScanning)
            }
        }
        .onAppear { center.scan() }
        .confirmationDialog(
            "Move Selected Downloads to Trash?",
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { center.removeSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                String(
                    format: String(localized: "Move %lld selected files (%@) to the Trash? Their download source does not affect the deletion, and AppSift will keep recovery history."),
                    Int64(center.selectedIDs.count),
                    ByteCountFormatter.string(fromByteCount: center.selectedSize, countStyle: .file)
                )
            )
        }
        .alert("Downloads by Source", isPresented: Binding(
            get: { center.errorMessage != nil },
            set: { if !$0 { center.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { center.errorMessage = nil }
        } message: {
            Text(center.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(systemName: "arrow.down.doc.fill", tint: Tint.blue, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloads by Source")
                    .font(.title2.weight(.semibold))
                Text("Groups ordinary Downloads files by the app that created their local quarantine record.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Only the source app and origin domain are shown. Full URLs, browsing history, and file contents are never collected.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if center.isScanning || center.isRemoving {
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

                if let message = center.actionMessage {
                    actionNotice(message)
                }
                if let record = center.latestUndoableRecord {
                    undoNotice(record)
                }
                if center.inaccessibleCount > 0 || center.cloudPlaceholderCount > 0 || center.wasTruncated {
                    scanBoundaryNotice
                }

                ForEach(DownloadSource.allCases, id: \.self) { source in
                    let sourceItems = filteredItems.filter { $0.source == source }
                    if !sourceItems.isEmpty {
                        sourceGroup(source, items: sourceItems)
                    }
                }
            }
            .padding(20)
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            StatusChip(
                label: String(format: String(localized: "%lld files"), Int64(center.items.count)),
                systemImage: "doc.fill",
                tint: Tint.blue
            )
            StatusChip(
                label: ByteCountFormatter.string(
                    fromByteCount: center.items.reduce(0) { $0 + $1.size },
                    countStyle: .file
                ),
                systemImage: "internaldrive.fill",
                tint: Tint.purple
            )
            if !center.selectedIDs.isEmpty {
                StatusChip(
                    label: String(
                        format: String(localized: "%lld selected"),
                        Int64(center.selectedIDs.count)
                    ),
                    systemImage: "checkmark.circle.fill",
                    tint: Tint.orange
                )
            }
            Spacer()
        }
    }

    private func sourceGroup(
        _ source: DownloadSource,
        items: [DownloadSourceItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: source.icon)
                    .foregroundStyle(source.tint)
                Text(source.title)
                    .font(.headline)
                Text("\(items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                Menu {
                    Button("Select This Source") { center.selectAll(in: source) }
                    Button("Deselect This Source") { center.deselectAll(in: source) }
                } label: {
                    Label("Selection", systemImage: "checklist")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            ForEach(items) { item in
                downloadRow(item, alongside: items)
            }
        }
    }

    private func downloadRow(
        _ item: DownloadSourceItem,
        alongside items: [DownloadSourceItem]
    ) -> some View {
        CardSurface(padding: 12, elevation: .flat) {
            HStack(alignment: .top, spacing: 11) {
                Toggle("", isOn: Binding(
                    get: { center.selectedIDs.contains(item.id) },
                    set: { _ in center.toggleSelection(item) }
                ))
                .labelsHidden()

                IconTile(systemName: "doc.fill", tint: item.source.tint, size: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(item.url.deletingLastPathComponent().path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                        if let date = item.modifiedAt {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let agent = item.sourceAgentName {
                            Text(agent)
                        }
                        if let host = item.originHost {
                            Label(host, systemImage: "globe")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button { center.preview(item, sourceItems: items) } label: {
                    Image(systemName: "eye")
                }
                .buttonStyle(.borderless)
                .help("Preview")
                .accessibilityLabel("Quick Look")
                Button { center.reveal(item) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal")
                .accessibilityLabel("Reveal")
            }
        }
    }

    private func actionNotice(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Tint.green)
            Text(message).font(.subheadline)
            Spacer()
            Button { center.actionMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(Tint.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func undoNotice(_ record: ReviewedTrashRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "trash.slash.fill").foregroundStyle(Tint.orange)
            Text("The latest download cleanup can still be restored from the Trash.")
                .font(.subheadline)
            Spacer()
            Button("Undo", action: { center.undo(record) })
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(center.isRemoving)
        }
        .padding(12)
        .background(Tint.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var scanBoundaryNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle.fill").foregroundStyle(Tint.orange)
            Text(
                String(
                    format: String(localized: "%lld inaccessible files and %lld cloud placeholders were left untouched.%@"),
                    Int64(center.inaccessibleCount),
                    Int64(center.cloudPlaceholderCount),
                    center.wasTruncated ? String(localized: " The safety item limit was reached.") : ""
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(Tint.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private extension DownloadSource {
    var title: String {
        switch self {
        case .safari: return String(localized: "Safari")
        case .chrome: return String(localized: "Google Chrome")
        case .firefox: return String(localized: "Firefox")
        case .slack: return String(localized: "Slack")
        case .mail: return String(localized: "Mail")
        case .airDrop: return String(localized: "AirDrop")
        case .otherApplication: return String(localized: "Other Apps")
        case .unknown: return String(localized: "Unknown Source")
        }
    }

    var icon: String {
        switch self {
        case .safari: return "safari.fill"
        case .chrome, .firefox: return "globe"
        case .slack: return "number.square.fill"
        case .mail: return "envelope.fill"
        case .airDrop: return "airplayaudio"
        case .otherApplication: return "app.fill"
        case .unknown: return "questionmark.folder.fill"
        }
    }

    var tint: Color {
        switch self {
        case .safari, .airDrop: return Tint.blue
        case .chrome: return Tint.green
        case .firefox: return Tint.orange
        case .slack: return Tint.purple
        case .mail: return Tint.cyan
        case .otherApplication: return Tint.pink
        case .unknown: return .secondary
        }
    }
}
