import SwiftUI

struct IOSBackupsView: View {
    @ObservedObject var center: IOSBackupCenter
    @State private var showRemovalConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if center.isScanning && !center.hasScanned {
                    progressState
                } else if !center.hasScanned {
                    firstScanState
                } else if center.backups.isEmpty {
                    emptyState
                } else {
                    results
                }
            }
        }
        .navigationTitle("iPhone & iPad Backups")
        .toolbar {
            ToolbarItemGroup {
                if center.latestUndoableRecord != nil {
                    Button("Undo", action: center.undoLatest)
                        .disabled(center.isRemoving)
                }
                if center.isScanning {
                    Button("Cancel", role: .cancel, action: center.cancelScan)
                } else {
                    Button(action: center.scan) {
                        Label("Scan Backups", systemImage: "arrow.clockwise")
                    }
                    .disabled(center.isRemoving)
                }
            }
        }
        .confirmationDialog(
            "Move Device Backups to Trash?",
            isPresented: $showRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive, action: center.removeSelected)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                String(
                    format: String(localized: "%lld selected backup(s) (%@) will move to the macOS Trash. The device cannot be restored from those backups unless you undo the action or recover them from Trash."),
                    Int64(center.selectedBackups.count),
                    ByteCountFormatter.string(fromByteCount: center.selectedSize, countStyle: .file)
                )
            )
        }
        .alert("Device Backups", isPresented: Binding(
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
            IconTile(systemName: "iphone.gen3", tint: Tint.blue, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("iPhone & iPad Backups")
                    .font(.title2.weight(.semibold))
                Text("Review Finder device backups by device, date, encryption status, and physical disk use.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("The newest backup for each device is never selected automatically. Removal is recoverable through the macOS Trash.")
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
            "Find Local Device Backups",
            systemImage: "iphone",
            description: "Scan Finder's local MobileSync backups without opening their personal contents.",
            action: center.scan,
            actionLabel: "Scan Backups",
            tint: Tint.blue
        )
    }

    private var progressState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Reading local backup metadata...").font(.headline)
            Text("AppSift reads only bounded backup property lists and filesystem sizes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        EmptyStateView(
            "No Local Device Backups",
            systemImage: "checkmark.circle",
            description: "Finder has no readable iPhone or iPad backups in MobileSync on this Mac.",
            action: center.scan,
            actionLabel: "Scan Again",
            tint: Tint.green
        )
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StatusChip(
                    label: String(format: String(localized: "%lld backups"), Int64(center.backups.count)),
                    systemImage: "externaldrive.fill",
                    tint: Tint.blue
                )
                StatusChip(
                    label: ByteCountFormatter.string(
                        fromByteCount: center.backups.reduce(0) { $0 + $1.allocatedSize },
                        countStyle: .file
                    ),
                    systemImage: "internaldrive.fill",
                    tint: Tint.purple
                )
                Spacer()
                Button("Select Older", action: center.selectOlderBackups)
                    .disabled(center.isRemoving)
                Button("Clear Selection") { center.selectedIDs.removeAll() }
                    .disabled(center.selectedIDs.isEmpty || center.isRemoving)
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
                LazyVStack(spacing: 10) {
                    ForEach(center.backups) { backup in
                        backupRow(backup)
                    }
                }
                .padding(20)
            }

            if !center.selectedBackups.isEmpty {
                HStack {
                    Text(
                        String(
                            format: String(localized: "%lld selected · %@"),
                            Int64(center.selectedBackups.count),
                            ByteCountFormatter.string(fromByteCount: center.selectedSize, countStyle: .file)
                        )
                    )
                    .font(.subheadline.weight(.medium))
                    Spacer()
                    Button(role: .destructive) { showRemovalConfirmation = true } label: {
                        if center.isRemoving {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Move to Trash", systemImage: "trash")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(center.isRemoving)
                }
                .padding(14)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    private func backupRow(_ backup: IOSBackupItem) -> some View {
        CardSurface(padding: 14, elevation: .flat) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { center.selectedIDs.contains(backup.id) },
                    set: { selected in
                        if selected { center.selectedIDs.insert(backup.id) }
                        else { center.selectedIDs.remove(backup.id) }
                    }
                ))
                .labelsHidden()
                .disabled(!backup.isSafeToRemove || center.isRemoving)

                IconTile(
                    systemName: backup.productType?.lowercased().contains("ipad") == true
                        ? "ipad" : "iphone",
                    tint: backup.completionState == .inProgress ? Tint.orange : Tint.blue,
                    size: 34
                )

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(backup.deviceName).font(.system(size: 13, weight: .semibold))
                        if backup.isLatestForDevice {
                            StatusChip(label: String(localized: "Newest"), systemImage: "star.fill", tint: Tint.green)
                        }
                        if backup.isEncrypted {
                            StatusChip(label: String(localized: "Encrypted"), systemImage: "lock.fill", tint: Tint.purple)
                        }
                        if backup.completionState == .inProgress {
                            StatusChip(label: String(localized: "In Progress"), systemImage: "clock.fill", tint: Tint.orange)
                        }
                    }
                    HStack(spacing: 8) {
                        if let type = backup.productType { Text(type) }
                        if let version = backup.productVersion { Text("iOS/iPadOS \(version)") }
                        if let date = backup.lastBackupDate { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(backup.url.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(backup.formattedSize).font(.system(size: 13, weight: .semibold).monospacedDigit())
                    Text(String(format: String(localized: "%lld files"), Int64(backup.fileCount)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Button("Reveal") { center.reveal(backup) }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
        }
    }
}
