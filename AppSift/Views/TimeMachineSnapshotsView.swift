import SwiftUI

struct TimeMachineSnapshotsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showDeleteConfirmation = false

    private var selectedSnapshots: [TimeMachineSnapshot] {
        appState.localTimeMachineSnapshots.filter {
            appState.selectedTimeMachineSnapshotIDs.contains($0.id)
        }
    }

    private var knownSnapshotSize: Int64 {
        appState.localTimeMachineSnapshots.compactMap(\.privateSize).reduce(0, +)
    }

    private var selectedKnownSnapshotSize: Int64 {
        selectedSnapshots.compactMap(\.privateSize).reduce(0, +)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                summary
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 12)

                scanStatusStrip
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

                if appState.hasScannedTimeMachineSnapshots && !appState.localTimeMachineSnapshots.isEmpty {
                    actionBar
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                }

                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if !appState.hasScannedTimeMachineSnapshots {
                appState.scanLocalTimeMachineSnapshots()
            }
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Snapshots", role: .destructive) {
                appState.deleteSelectedTimeMachineSnapshots()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the selected local recovery points. External Time Machine backups are not affected.")
        }
        .alert("Time Machine Snapshots", isPresented: Binding(
            get: { appState.timeMachineSnapshotError != nil },
            set: { if !$0 { appState.timeMachineSnapshotError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.timeMachineSnapshotError = nil }
        } message: {
            Text(appState.timeMachineSnapshotError ?? "")
        }
    }

    private var summary: some View {
        CardSurface(padding: 18) {
            HStack(alignment: .center, spacing: 16) {
                IconTile(systemName: "clock.arrow.circlepath", tint: Tint.orange, size: 56, corner: 14)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Local Recovery Points")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Review Time Machine snapshots stored on this Mac. They are never included in Smart Scan or automatic cleanup.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 7) {
                    Text(snapshotCountLabel)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    HStack(spacing: 6) {
                        StatusChip(
                            label: appState.isTimeMachineBackupRunning
                                ? String(localized: "Backup Running")
                                : String(localized: "Backup Idle"),
                            systemImage: appState.isTimeMachineBackupRunning ? "arrow.triangle.2.circlepath" : "checkmark",
                            tint: appState.isTimeMachineBackupRunning ? Tint.orange : Tint.green
                        )
                        StatusChip(
                            label: appState.diskInfo.formattedFree,
                            systemImage: "internaldrive",
                            tint: Tint.blue
                        )
                        if knownSnapshotSize > 0 {
                            StatusChip(
                                label: formattedBytes(knownSnapshotSize),
                                systemImage: "chart.pie",
                                tint: Tint.orange
                            )
                        }
                    }
                }
            }
        }
    }

    private var scanStatusStrip: some View {
        HStack(spacing: 8) {
            if appState.isScanningTimeMachineSnapshots {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning local snapshots...")
                    .font(.system(size: 12, weight: .medium))
            } else if appState.hasScannedTimeMachineSnapshots {
                Image(systemName: appState.localTimeMachineSnapshots.isEmpty ? "checkmark.circle.fill" : "clock.badge.checkmark")
                    .foregroundStyle(appState.localTimeMachineSnapshots.isEmpty ? Tint.green : Tint.orange)
                Text(lastScanResultLabel)
                    .font(.system(size: 12, weight: .medium))
            } else {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Tint.blue)
                Text("Refresh local snapshots")
                    .font(.system(size: 12, weight: .medium))
            }

            Spacer(minLength: 8)

            if appState.hasScannedTimeMachineSnapshots,
               let lastScanDate = appState.lastTimeMachineSnapshotScanDate {
                StatusChip(
                    label: String(
                        format: String(localized: "Last scan: %@"),
                        DateFormatter.localizedString(from: lastScanDate, dateStyle: .none, timeStyle: .short)
                    ),
                    systemImage: "clock",
                    tint: Tint.blue
                )
            }

            Button {
                appState.scanLocalTimeMachineSnapshots()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh local snapshots")
            .disabled(appState.isScanningTimeMachineSnapshots || appState.isDeletingTimeMachineSnapshots)
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        if appState.isScanningTimeMachineSnapshots {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                Text("Scanning local snapshots...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appState.localTimeMachineSnapshots.isEmpty {
            EmptyStateView(
                "No Local Snapshots",
                systemImage: "clock.badge.checkmark",
                description: "No Time Machine local snapshots are stored on this Mac.",
                action: { appState.scanLocalTimeMachineSnapshots() },
                actionLabel: "Scan Again",
                tint: Tint.green
            )
        } else {
            VStack(spacing: 0) {
                if appState.isTimeMachineBackupRunning {
                    backupRunningNotice
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                }

                LazyVStack(spacing: 0) {
                    ForEach(appState.localTimeMachineSnapshots) { snapshot in
                        snapshotRow(snapshot)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)

                        if snapshot.id != appState.localTimeMachineSnapshots.last?.id {
                            Divider()
                                .padding(.leading, 54)
                        }
                    }
                }
                .padding(.vertical, 6)
                .background(.bar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    private var backupRunningNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tint.orange)
            Text("Deletion is disabled while Time Machine is backing up.")
                .font(.callout)
            Spacer()
        }
        .padding(10)
        .background(Tint.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func snapshotRow(_ snapshot: TimeMachineSnapshot) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: selectionBinding(for: snapshot))
                .labelsHidden()
                .toggleStyle(.checkbox)

            IconTile(systemName: "clock.fill", tint: Tint.orange, size: 30, corner: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 13.5, weight: .medium))
                Text(snapshot.name)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(snapshotSizeLabel(snapshot))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                Text("Local Snapshot")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            selectionBinding(for: snapshot).wrappedValue.toggle()
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if appState.lastTimeMachineDeletedCount > 0 {
                    Text(lastDeletionLabel)
                        .font(.system(size: 12, weight: .medium))
                    Text(lastFreedSpaceLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text(snapshotSizeFootnote)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Select All") {
                appState.selectedTimeMachineSnapshotIDs = Set(appState.localTimeMachineSnapshots.map(\.id))
            }
            Button("Deselect All") {
                appState.selectedTimeMachineSnapshotIDs.removeAll()
            }

            Button {
                appState.openTimeMachine()
            } label: {
                Label("Open Time Machine", systemImage: "clock.arrow.circlepath")
            }
            .help("Browse or restore files in Time Machine")
            .disabled(appState.isDeletingTimeMachineSnapshots)

            Button {
                showDeleteConfirmation = true
            } label: {
                Label(deleteButtonLabel, systemImage: "trash")
            }
            .buttonStyle(GlowProminentButtonStyle(tint: Tint.red, gradient: TintGradient.destructive))
            .disabled(
                selectedSnapshots.isEmpty
                    || appState.isTimeMachineBackupRunning
                    || appState.isDeletingTimeMachineSnapshots
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func selectionBinding(for snapshot: TimeMachineSnapshot) -> Binding<Bool> {
        Binding(
            get: { appState.selectedTimeMachineSnapshotIDs.contains(snapshot.id) },
            set: { isSelected in
                if isSelected {
                    appState.selectedTimeMachineSnapshotIDs.insert(snapshot.id)
                } else {
                    appState.selectedTimeMachineSnapshotIDs.remove(snapshot.id)
                }
            }
        )
    }

    private var snapshotCountLabel: String {
        String(
            format: String(localized: "%lld snapshots"),
            Int64(appState.localTimeMachineSnapshots.count)
        )
    }

    private var lastScanResultLabel: String {
        if appState.localTimeMachineSnapshots.isEmpty {
            return String(localized: "Scan found no local snapshots.")
        }

        return String(
            format: String(localized: "Scan found %lld local snapshot(s)."),
            Int64(appState.localTimeMachineSnapshots.count)
        )
    }

    private var deleteButtonLabel: String {
        if selectedKnownSnapshotSize > 0 {
            return String(
                format: String(localized: "Delete %lld Selected (%@)"),
                Int64(selectedSnapshots.count),
                formattedBytes(selectedKnownSnapshotSize)
            )
        }

        return String(
            format: String(localized: "Delete %lld Selected"),
            Int64(selectedSnapshots.count)
        )
    }

    private var deleteConfirmationTitle: String {
        String(
            format: String(localized: "Delete %lld local snapshot(s)?"),
            Int64(selectedSnapshots.count)
        )
    }

    private var lastDeletionLabel: String {
        String(
            format: String(localized: "Deleted %lld snapshot(s)"),
            Int64(appState.lastTimeMachineDeletedCount)
        )
    }

    private var lastFreedSpaceLabel: String {
        let formatted = ByteCountFormatter.string(
            fromByteCount: appState.lastTimeMachineFreedSpace,
            countStyle: .file
        )
        return String(format: String(localized: "Available space increased by %@"), formatted)
    }

    private var snapshotSizeFootnote: String {
        knownSnapshotSize > 0
            ? String(localized: "Size shows APFS private bytes. Actual free space is verified after deletion.")
            : String(localized: "Snapshot size is unavailable on this volume.")
    }

    private func snapshotSizeLabel(_ snapshot: TimeMachineSnapshot) -> String {
        guard let privateSize = snapshot.privateSize else {
            return String(localized: "Size Unknown")
        }
        return formattedBytes(privateSize)
    }

    private func formattedBytes(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}
