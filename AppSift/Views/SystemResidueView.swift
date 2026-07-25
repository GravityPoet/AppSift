import SwiftUI

private enum SystemResidueTab: String, CaseIterable, Identifiable {
    case oldUsers = "Old User Data"
    case preferences = "Damaged Preferences"
    case documentVersions = "Document Versions"

    var id: String { rawValue }
}

struct SystemResidueView: View {
    @ObservedObject var center: SystemResidueCenter
    @State private var selectedTab: SystemResidueTab = .oldUsers
    @State private var confirmsPreferenceRemoval = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if center.isScanning && !center.hasScanned {
                scanningState
            } else {
                content
            }
        }
        .navigationTitle("System Residue Diagnostics")
        .toolbar {
            Button {
                center.isScanning ? center.cancelScan() : center.scan(force: true)
            } label: {
                Label(
                    center.isScanning ? "Cancel Scan" : "Refresh",
                    systemImage: center.isScanning ? "xmark.circle" : "arrow.clockwise"
                )
            }
        }
        .onAppear { center.scan() }
        .confirmationDialog(
            "Move Invalid Preferences to Trash?",
            isPresented: $confirmsPreferenceRemoval,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                center.removeSelectedPreferences()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apps may recreate these files with default settings. AppSift rechecks every file before moving it and keeps recovery history.")
        }
        .alert("System Residue Diagnostics", isPresented: Binding(
            get: { center.errorMessage != nil },
            set: { if !$0 { center.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { center.errorMessage = nil }
        } message: {
            Text(center.errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(systemName: "stethoscope", tint: Tint.orange, size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text("System Residue Diagnostics")
                        .font(.title2.weight(.semibold))
                    Text("Evidence-based checks for old user folders, unreadable property lists, and macOS document versions.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if center.isScanning {
                    ProgressView().controlSize(.small)
                }
            }

            Picker("Diagnostic", selection: $selectedTab) {
                ForEach(SystemResidueTab.allCases) { tab in
                    Text(LocalizedStringKey(tab.rawValue)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var scanningState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Scanning diagnostic evidence…")
                .font(.headline)
            Text("Document contents are not uploaded or indexed by AppSift.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Cancel Scan") { center.cancelScan() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let message = center.actionMessage {
                    actionNotice(message)
                }
                scanBoundary
                switch selectedTab {
                case .oldUsers:
                    oldUsersContent
                case .preferences:
                    preferencesContent
                case .documentVersions:
                    documentVersionsContent
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var oldUsersContent: some View {
        diagnosticIntro(
            title: "Old User Account Residue",
            description: "Folders are flagged only when no local account matches their name, their owner UID conflicts with the account, or they are inside the legacy Deleted Users location. AppSift does not delete them automatically."
        )
        if center.legacyUsers.isEmpty {
            emptyResult("No Old User Folders Found", icon: "person.crop.circle.badge.checkmark")
        } else {
            ForEach(center.legacyUsers) { item in
                CardSurface(padding: 14) {
                    HStack(spacing: 12) {
                        IconTile(systemName: "person.crop.circle", tint: Tint.orange, size: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.url.lastPathComponent)
                                .font(.headline)
                            Text(item.url.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(legacyReason(item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(item.isAccessible
                                 ? ByteCountFormatter.string(fromByteCount: item.allocatedSize, countStyle: .file)
                                 : String(localized: "Size unavailable"))
                                .font(.subheadline.monospacedDigit())
                            Text(String(format: String(localized: "%lld files"), Int64(item.fileCount)))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Button("Reveal") { center.reveal(item.url) }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var preferencesContent: some View {
        diagnosticIntro(
            title: "Damaged Preference Files",
            description: "Only local .plist files that PropertyListSerialization cannot parse are shown. Stale but valid preferences are not labeled damaged. Nothing is selected automatically."
        )
        if !center.selectedPreferenceIDs.isEmpty {
            HStack(spacing: 9) {
                Text(
                    String(
                        format: String(localized: "%lld selected · %@"),
                        Int64(center.selectedPreferenceIDs.count),
                        ByteCountFormatter.string(
                            fromByteCount: center.selectedPreferenceSize,
                            countStyle: .file
                        )
                    )
                )
                .font(.caption.monospacedDigit())
                Spacer()
                Button("Clear Selection") { center.clearPreferenceSelection() }
                    .buttonStyle(.bordered)
                Button("Move Selected to Trash", role: .destructive) {
                    confirmsPreferenceRemoval = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(center.isRemoving)
            }
        }
        if let record = center.latestUndoablePreferenceRecord {
            HStack {
                Label("A recoverable preference cleanup is available.", systemImage: "arrow.uturn.backward.circle.fill")
                Spacer()
                Button("Undo") { center.undoPreferenceRemoval(record) }
                    .buttonStyle(.bordered)
                    .disabled(center.isRemoving)
            }
            .font(.subheadline)
            .padding(12)
            .background(Tint.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        if center.corruptPreferences.isEmpty {
            emptyResult("No Damaged Preferences Found", icon: "checkmark.seal.fill")
        } else {
            ForEach(center.corruptPreferences) { item in
                CardSurface(padding: 12) {
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(
                            get: { center.selectedPreferenceIDs.contains(item.id) },
                            set: { _ in center.togglePreference(item) }
                        )) { EmptyView() }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.url.lastPathComponent)
                                .font(.headline)
                            Text(item.reason)
                                .font(.caption)
                                .foregroundStyle(Tint.orange)
                            Text(item.url.path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Menu {
                            Button("Quick Look") { center.preview(item) }
                            Button("Reveal in Finder") { center.reveal(item.url) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var documentVersionsContent: some View {
        diagnosticIntro(
            title: "Document History Versions",
            description: "This is a read-only inventory using macOS NSFileVersion metadata. Historical versions are never preselected or removed because they may be the only recovery copy."
        )
        if center.documentVersions.isEmpty {
            emptyResult("No Document History Found", icon: "clock.badge.checkmark")
        } else {
            ForEach(center.documentVersions) { item in
                CardSurface(padding: 14) {
                    HStack(spacing: 12) {
                        IconTile(systemName: "clock.arrow.circlepath", tint: Tint.blue, size: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                                .font(.headline)
                            Text(item.url.path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(String(format: String(localized: "%lld saved versions"), Int64(item.versionCount)))
                                .font(.subheadline.monospacedDigit())
                            if let date = item.newestVersionDate {
                                Text(date, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Reveal") { center.reveal(item.url) }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func diagnosticIntro(title: LocalizedStringKey, description: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }

    private var scanBoundary: some View {
        HStack(spacing: 8) {
            StatusChip(
                label: String(
                    format: String(localized: "%lld preferences checked"),
                    Int64(center.statistics.preferenceFilesChecked)
                ),
                systemImage: "doc.text.magnifyingglass",
                tint: Tint.purple
            )
            StatusChip(
                label: String(
                    format: String(localized: "%lld documents checked"),
                    Int64(center.statistics.documentFilesChecked)
                ),
                systemImage: "doc.text",
                tint: Tint.blue
            )
            if center.statistics.inaccessibleCount > 0 {
                StatusChip(
                    label: String(
                        format: String(localized: "%lld inaccessible"),
                        Int64(center.statistics.inaccessibleCount)
                    ),
                    systemImage: "lock.fill",
                    tint: Tint.orange
                )
            }
            if center.statistics.wasTruncated {
                StatusChip(label: "Safety limit reached", systemImage: "exclamationmark.triangle.fill", tint: Tint.orange)
            }
            Spacer()
        }
    }

    private func emptyResult(_ title: LocalizedStringKey, icon: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(Tint.green)
            Text(title).font(.headline)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func actionNotice(_ message: String) -> some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.subheadline)
            .foregroundStyle(Tint.green)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tint.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func legacyReason(_ item: LegacyUserResidue) -> String {
        switch item.kind {
        case .missingAccount:
            return String(
                format: String(localized: "No local account matches this folder (owner UID %u)."),
                item.ownerID
            )
        case .deletedUsersFolder:
            return String(localized: "Legacy macOS Deleted Users storage.")
        case .deletedUserDiskImage:
            return String(localized: "A legacy user disk image has no matching local account.")
        case .ownerMismatch:
            return String(
                format: String(localized: "Folder owner UID %u does not match account UID %u."),
                item.ownerID,
                item.expectedOwnerID ?? 0
            )
        }
    }
}
