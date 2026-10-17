import SwiftUI

struct StorageAuditView: View {
    @ObservedObject var center: StorageAuditCenter

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                if center.isScanning {
                    scanProgress
                }
                if let report = center.report {
                    summary(report)
                    volumes(report)
                    processes(report)
                    virtualMachines(report)
                    coverage(report)
                } else if !center.isScanning {
                    readyCard
                }
            }
            .padding(20)
        }
        .navigationTitle("Storage Audit")
        .toolbar {
            ToolbarItemGroup {
                if center.isScanning {
                    Button("Cancel", action: center.cancel)
                } else {
                    Button("Scan Mac and External Disks") {
                        center.scan(force: true)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(systemName: "waveform.path.ecg.rectangle", tint: Tint.cyan, size: 38, corner: 11)
            VStack(alignment: .leading, spacing: 4) {
                Text("Storage Audit")
                    .font(.title2.weight(.semibold))
                Text("Measure the Mac and mounted external disks without classifying or deleting files.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Time Machine volumes are metadata-only; Windows guest contents are not entered.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var readyCard: some View {
        CardSurface(padding: 24, accent: Tint.cyan, elevation: .raised) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Read-only coverage audit", systemImage: "checkmark.shield.fill")
                    .font(.headline)
                Text("The audit separates the internal volume from each mounted external volume, reports unreadable paths, and identifies host-side UTM assets.")
                    .foregroundStyle(.secondary)
                Button("Scan Mac and External Disks") { center.scan(force: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var scanProgress: some View {
        CardSurface(padding: 16, accent: Tint.cyan) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning \(center.progress.volumePath.isEmpty ? "volumes" : center.progress.volumePath)")
                        .font(.headline)
                    Spacer()
                    Text("\(center.progress.examinedItemCount) items")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !center.progress.currentPath.isEmpty {
                    Text(center.progress.currentPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func summary(_ report: StorageAuditReport) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            metric("Volumes", value: "\(report.volumes.count)", icon: "externaldrive.fill", tint: Tint.cyan)
            metric("Files", value: "\(report.totalFileCount)", icon: "doc.fill", tint: Tint.blue)
            metric("Directories", value: "\(report.totalDirectoryCount)", icon: "folder.fill", tint: Tint.purple)
            metric("Unreadable", value: "\(report.totalInaccessibleCount)", icon: "lock.fill", tint: report.totalInaccessibleCount > 0 ? Tint.orange : Tint.green)
            metric("Process memory", value: formatted(report.processes.prefix(16).reduce(0) { $0 + $1.residentBytes }), icon: "memorychip.fill", tint: Tint.pink)
            if let memory = report.memory {
                metric("Memory", value: "\(formatted(memory.usedBytes)) / \(formatted(memory.totalBytes))", icon: "memorychip", tint: Tint.orange)
                metric("Swap", value: formatted(memory.swapUsedBytes), icon: "arrow.triangle.2.circlepath", tint: Tint.purple)
            }
            if let trash = report.trash {
                metric("Trash", value: "\(trash.itemCount)", icon: "trash.fill", tint: Tint.orange)
            }
        }
    }

    private func volumes(_ report: StorageAuditReport) -> some View {
        section("Volumes", icon: "externaldrive.fill") {
            ForEach(report.volumes) { volume in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: volume.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                            .foregroundStyle(volume.isInternal ? Tint.blue : Tint.cyan)
                        Text(volume.name).font(.headline)
                        Spacer()
                        Text(volume.status.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(volume.status == .scanned ? Tint.green : Tint.orange)
                    }
                    Text(volume.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    if let device = volume.deviceIdentifier {
                        Text(
                            [
                                device,
                                volume.filesystemType,
                                volume.volumeRole,
                            ]
                            .compactMap { $0 }
                            .joined(separator: " · ")
                        )
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 14) {
                        Text("Used \(formatted(volume.usedBytes)) / \(formatted(volume.totalBytes))")
                        if volume.isMetadataOnly {
                            Text("metadata only")
                        } else if volume.status == .scanned {
                            Text("\(volume.fileCount) files · \(volume.directoryCount) dirs")
                            Text("\(volume.inaccessibleItemCount) unreadable")
                            Text(String.localizedStringWithFormat(
                                String(localized: "%@ symlinks · %@ cloud · %@ nested · %@ firmlinks · %@ hard-link aliases"),
                                "\(volume.symbolicLinkCount)",
                                "\(volume.cloudPlaceholderCount)",
                                "\(volume.nestedVolumeCount)",
                                "\(volume.firmlinkSkippedCount)",
                                "\(volume.hardLinkAliasCount)"
                            ))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text("Logical \(formatted(volume.logicalBytes)) · allocated \(formatted(volume.allocatedBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = volume.errorSummary {
                        Text(error).font(.caption).foregroundStyle(Tint.orange)
                    }
                    if !volume.topItems.isEmpty {
                        ForEach(volume.topItems.prefix(5)) { item in
                            HStack {
                                Text(item.path).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(formatted(item.allocatedBytes)).monospacedDigit()
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    if !volume.inaccessiblePaths.isEmpty {
                        Text("Unreadable path samples")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Tint.orange)
                        ForEach(volume.inaccessiblePaths.prefix(8), id: \.self) { path in
                            Text(path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.vertical, 6)
                if volume.id != report.volumes.last?.id { Divider() }
            }
        }
    }

    private func processes(_ report: StorageAuditReport) -> some View {
        section("Largest Processes by RSS", icon: "memorychip.fill") {
            ForEach(report.processes.prefix(16)) { process in
                HStack {
                    Text(process.name).lineLimit(1)
                    Spacer()
                    Text(formatted(process.residentBytes)).monospacedDigit()
                }
                .font(.caption)
                .padding(.vertical, 3)
            }
        }
    }

    private func virtualMachines(_ report: StorageAuditReport) -> some View {
        section("Virtual Machine Host Assets", icon: "rectangle.3.group.fill") {
            if report.virtualMachines.isEmpty {
                Text("No UTM or virtual disk assets were discovered on mounted volumes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(report.virtualMachines) { asset in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(asset.path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(formatted(asset.allocatedBytes)).monospacedDigit()
                        }
                        .font(.caption)
                        Text(asset.isRunning ? "Running · guest not entered" : "Not observed running · guest not entered")
                            .font(.caption2)
                            .foregroundStyle(asset.isRunning ? Tint.orange : .secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func coverage(_ report: StorageAuditReport) -> some View {
        section("Coverage and Boundaries", icon: "info.circle.fill") {
            ForEach(report.coverageNotes, id: \.self) { note in
                Label(note, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, icon: String, @ViewBuilder content: () -> Content) -> some View {
        CardSurface(padding: 16, accent: Tint.cyan) {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: icon).font(.headline)
                content()
            }
        }
    }

    private func metric(_ title: LocalizedStringKey, value: String, icon: String, tint: Color) -> some View {
        CardSurface(padding: 14, accent: tint) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value).font(.headline.monospacedDigit())
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
