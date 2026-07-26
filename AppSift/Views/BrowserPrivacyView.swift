import SwiftUI

struct BrowserPrivacyView: View {
    @ObservedObject var center: BrowserPrivacyCenter
    @State private var showCleanupConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if center.isScanning && !center.hasScanned {
                    progressState
                } else if !center.hasScanned {
                    firstScanState
                } else if center.groups.isEmpty {
                    emptyState
                } else {
                    results
                }
            }
        }
        .navigationTitle("Browser Privacy")
        .toolbar {
            ToolbarItemGroup {
                if center.latestUndoableTrashRecord != nil {
                    Button("Undo Files", action: center.undoLatestTrash)
                        .disabled(center.isCleaning)
                }
                if center.latestUndoableDatabaseRecord != nil {
                    Button("Undo Firefox", action: center.undoLatestDatabase)
                        .disabled(center.isCleaning)
                }
                if center.isScanning {
                    Button("Cancel", role: .cancel, action: center.cancelScan)
                } else {
                    Button(action: center.scan) {
                        Label("Scan Browser Data", systemImage: "arrow.clockwise")
                    }
                    .disabled(center.isCleaning)
                }
            }
        }
        .confirmationDialog(
            "Clean Selected Browser Data?",
            isPresented: $showCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clean Selected Data", role: .destructive, action: center.cleanSelected)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                String(
                    format: String(localized: "%lld selected categories (%@). AppSift will ask the selected browsers to quit first. History files, cookies, and caches move to Trash; Firefox history is changed only after a private rollback backup succeeds. Synced browser data may later return from another device."),
                    Int64(center.selectedGroups.count),
                    ByteCountFormatter.string(fromByteCount: center.selectedSize, countStyle: .file)
                )
            )
        }
        .alert("Browser Privacy", isPresented: Binding(
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
            IconTile(systemName: "hand.raised.fill", tint: Tint.purple, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("Browser Privacy")
                    .font(.title2.weight(.semibold))
                Text("Review local history, download records, cookies, and caches for Safari, Chrome, and Firefox.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Passwords, bookmarks, autofill, open tabs, extensions, and saved Wi-Fi networks are never selected or modified.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let date = center.lastScanDate {
                Text(date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var firstScanState: some View {
        EmptyStateView(
            "Review Browser Data",
            systemImage: "safari",
            description: "AppSift inventories database files and cache locations without reading URLs, cookie values, passwords, or page contents.",
            action: center.scan,
            actionLabel: "Scan Browser Data",
            tint: Tint.purple
        )
    }

    private var progressState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Measuring browser data...").font(.headline)
            Text("Only filesystem metadata is read during this scan.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        EmptyStateView(
            "No Supported Browser Data",
            systemImage: "checkmark.shield.fill",
            description: "No readable Safari, Chrome, or Firefox history, cookie, or cache targets were found.",
            action: center.scan,
            actionLabel: "Scan Again",
            tint: Tint.green
        )
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StatusChip(
                    label: String(format: String(localized: "%lld categories"), Int64(center.groups.count)),
                    systemImage: "list.bullet.rectangle",
                    tint: Tint.purple
                )
                StatusChip(
                    label: ByteCountFormatter.string(
                        fromByteCount: center.groups.reduce(0) { $0 + $1.allocatedSize },
                        countStyle: .file
                    ),
                    systemImage: "internaldrive.fill",
                    tint: Tint.blue
                )
                Spacer()
                Button("Select All") { center.selectedIDs = Set(center.groups.map(\.id)) }
                    .disabled(center.isCleaning)
                Button("Clear Selection") { center.selectedIDs.removeAll() }
                    .disabled(center.selectedIDs.isEmpty || center.isCleaning)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if let message = center.actionMessage {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Tint.green)
                    Text(message).font(.subheadline)
                    Spacer()
                    Button { center.actionMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(BrowserPrivacyBrowser.allCases, id: \.self) { browser in
                        let browserGroups = center.groups.filter { $0.browser == browser }
                        if !browserGroups.isEmpty {
                            browserSection(browser, groups: browserGroups)
                        }
                    }
                }
                .padding(20)
            }

            if !center.selectedGroups.isEmpty {
                HStack {
                    Text(
                        String(
                            format: String(localized: "%lld selected · %@"),
                            Int64(center.selectedGroups.count),
                            ByteCountFormatter.string(fromByteCount: center.selectedSize, countStyle: .file)
                        )
                    )
                    .font(.subheadline.weight(.medium))
                    Spacer()
                    Button(role: .destructive) { showCleanupConfirmation = true } label: {
                        if center.isCleaning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Clean Selected Data", systemImage: "trash")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(center.isCleaning)
                }
                .padding(14)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    private func browserSection(
        _ browser: BrowserPrivacyBrowser,
        groups: [BrowserPrivacyGroup]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: browser.icon)
                    .foregroundStyle(browser == .firefox ? Tint.orange : Tint.blue)
                Text(browser.displayName).font(.headline)
                if center.runningBrowsers.contains(browser) {
                    StatusChip(label: String(localized: "Running"), systemImage: "circle.fill", tint: Tint.orange)
                }
                Spacer()
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: groups.reduce(0) { $0 + $1.allocatedSize },
                        countStyle: .file
                    )
                )
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            }

            ForEach(groups) { group in
                groupRow(group)
            }
        }
    }

    private func groupRow(_ group: BrowserPrivacyGroup) -> some View {
        CardSurface(padding: 13, elevation: .flat) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { center.selectedIDs.contains(group.id) },
                    set: { selected in
                        if selected { center.selectedIDs.insert(group.id) }
                        else { center.selectedIDs.remove(group.id) }
                    }
                ))
                .labelsHidden()
                .disabled(center.isCleaning)

                IconTile(systemName: group.kind.icon, tint: Tint.purple, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.kind.title).font(.system(size: 13, weight: .semibold))
                    Text(
                        String(
                            format: String(localized: "%lld profile(s) · %lld filesystem target(s)"),
                            Int64(group.profileCount),
                            Int64(group.targets.count)
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if group.browser == .firefox && group.kind == .historyAndDownloads {
                        Text("Bookmarks are preserved by a schema-checked SQLite transaction with a private rollback backup.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(group.formattedSize)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    if let date = group.latestModificationDate {
                        Text(date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
