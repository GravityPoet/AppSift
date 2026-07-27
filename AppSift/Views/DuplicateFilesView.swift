import AppKit
import SwiftUI

struct DuplicateFilesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var showingRemovalConfirmation = false
    @State private var showingIgnoreList = false

    private let minimumSizeOptions: [(label: LocalizedStringKey, bytes: Int64)] = [
        ("All sizes", 1),
        ("1 MB and larger", 1_000_000),
        ("10 MB and larger", 10_000_000),
        ("100 MB and larger", 100_000_000),
        ("1 GB and larger", 1_000_000_000),
    ]

    private var filteredGroups: [DuplicateFileGroup] {
        guard !searchText.isEmpty else { return appState.duplicateFileGroups }
        let query = searchText.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return appState.duplicateFileGroups.filter { group in
            group.files.contains { file in
                (file.name + " " + file.url.path).folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ).contains(query)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    locationsCard

                    if appState.isScanningDuplicateFiles {
                        DuplicateScanProgressCard(
                            progress: appState.duplicateScanProgress,
                            cancel: appState.cancelDuplicateFileScan
                        )
                    } else if appState.hasScannedDuplicateFiles {
                        scanResults
                    } else {
                        readyCard
                    }
                }
                .padding(20)
            }
        }
        .accessibilityIdentifier("duplicateFiles.content")
        .navigationTitle("Duplicate Files")
        .searchable(
            text: $searchText,
            prompt: "Search duplicate files"
        )
        .toolbar {
            ToolbarItemGroup {
                if appState.isScanningDuplicateFiles
                    || appState.isRemovingDuplicateFiles {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    if appState.isScanningDuplicateFiles {
                        appState.cancelDuplicateFileScan()
                    } else {
                        appState.scanDuplicateFiles(force: true)
                    }
                } label: {
                    Label(
                        appState.isScanningDuplicateFiles ? "Cancel" : "Refresh",
                        systemImage: appState.isScanningDuplicateFiles
                            ? "xmark"
                            : "arrow.clockwise"
                    )
                }
                .disabled(
                    appState.isRemovingDuplicateFiles
                        || (!appState.isScanningDuplicateFiles
                            && appState.duplicateScanRoots.isEmpty)
                )
            }
        }
        .confirmationDialog(
            "Move Duplicate Files to Trash?",
            isPresented: $showingRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                appState.removeSelectedDuplicateFiles()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                String(
                    format: String(
                        localized: "%lld selected files (%@) will move to the macOS Trash. AppSift verifies their full hashes again and keeps at least one copy in each group."
                    ),
                    Int64(appState.selectedDuplicateFileIDs.count),
                    formattedBytes(appState.selectedDuplicateFileSize)
                )
            )
        }
        .alert(
            "Duplicate File Action Failed",
            isPresented: Binding(
                get: { appState.duplicateFileActionError != nil },
                set: {
                    if !$0 {
                        appState.duplicateFileActionError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                appState.duplicateFileActionError = nil
            }
        } message: {
            Text(appState.duplicateFileActionError ?? "")
        }
        .sheet(isPresented: $showingIgnoreList) {
            DuplicateIgnoreListSheet()
                .environmentObject(appState)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(
                systemName: "doc.on.doc.fill",
                tint: Tint.cyan,
                size: 34
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("Duplicate Files")
                    .font(.title2.weight(.semibold))
                Text("Find byte-for-byte identical files in any folder, disk, or external drive.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Size buckets narrow the search, sampled hashes remove false candidates, and full SHA-256 confirms every group.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 16)
            if let date = appState.lastDuplicateFileScanDate {
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

    private var locationsCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Scan Locations")
                            .font(.headline)
                        Text("Add one or more folders, mounted disks, or external drives.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        chooseScanLocations()
                    } label: {
                        Label("Add Location", systemImage: "plus")
                    }
                    .disabled(
                        appState.isScanningDuplicateFiles
                            || appState.isRemovingDuplicateFiles
                    )
                }

                if appState.duplicateScanRoots.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.badge.plus")
                            .font(.title2)
                            .foregroundStyle(Tint.cyan)
                        Text("No scan location selected.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(appState.duplicateScanRoots, id: \.path) { root in
                            scanLocationRow(root)
                            if root != appState.duplicateScanRoots.last {
                                Divider()
                                    .padding(.leading, 34)
                            }
                        }
                    }
                }

                Divider()

                HStack(spacing: 12) {
                    Text("Minimum File Size")
                        .font(.subheadline.weight(.medium))
                    Picker(
                        "Minimum File Size",
                        selection: Binding(
                            get: { appState.duplicateMinimumFileSize },
                            set: appState.setDuplicateMinimumFileSize
                        )
                    ) {
                        ForEach(minimumSizeOptions, id: \.bytes) { option in
                            Text(option.label)
                                .tag(option.bytes)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 190)

                    Spacer()

                    Button {
                        showingIgnoreList = true
                    } label: {
                        Label(
                            String(
                                format: String(localized: "Ignore List (%lld)"),
                                Int64(appState.ignoredDuplicatePaths.count)
                            ),
                            systemImage: "eye.slash"
                        )
                    }
                    .disabled(
                        appState.isScanningDuplicateFiles
                            || appState.isRemovingDuplicateFiles
                    )

                    Button {
                        appState.scanDuplicateFiles(force: true)
                    } label: {
                        Label("Scan for Duplicates", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(
                        GlowProminentButtonStyle(
                            tint: Tint.cyan,
                            gradient: TintGradient.of(Tint.cyan)
                        )
                    )
                    .disabled(
                        appState.duplicateScanRoots.isEmpty
                            || appState.isScanningDuplicateFiles
                            || appState.isRemovingDuplicateFiles
                    )
                }
            }
        }
    }

    private func scanLocationRow(_ root: URL) -> some View {
        let isAvailable = FileManager.default.fileExists(atPath: root.path)
        let isExternal = root.path.hasPrefix("/Volumes/")
        return HStack(spacing: 10) {
            Image(systemName: isExternal ? "externaldrive.fill" : "folder.fill")
                .foregroundStyle(isAvailable ? Tint.cyan : Tint.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(root.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !isAvailable {
                StatusChip(
                    label: String(localized: "Unavailable"),
                    systemImage: "exclamationmark.triangle.fill",
                    tint: Tint.orange
                )
            }
            Button {
                appState.removeDuplicateScanRoot(root)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Remove Location")
            .accessibilityLabel("Remove Location")
            .disabled(
                appState.isScanningDuplicateFiles
                    || appState.isRemovingDuplicateFiles
            )
        }
        .padding(.vertical, 8)
    }

    private var readyCard: some View {
        CardSurface {
            HStack(spacing: 14) {
                IconTile(
                    systemName: appState.duplicateScanRoots.isEmpty
                        ? "folder.badge.plus"
                        : "checkmark.shield.fill",
                    tint: appState.duplicateScanRoots.isEmpty
                        ? Tint.orange
                        : Tint.green,
                    size: 40
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        appState.duplicateScanRoots.isEmpty
                            ? "Choose Where to Scan"
                            : "Ready to Scan"
                    )
                    .font(.headline)
                    Text(
                        appState.duplicateScanRoots.isEmpty
                            ? "Select any folder, mounted disk, or external drive. AppSift never downloads cloud-only placeholders for this scan."
                            : "AppSift will skip unreadable files, cloud-only placeholders, package contents, and hard-link aliases."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var scanResults: some View {
        if let message = appState.duplicateFileActionMessage {
            successNotice(message)
        }

        if appState.duplicateFileGroups.isEmpty {
            CardSurface {
                HStack(spacing: 14) {
                    IconTile(
                        systemName: "checkmark.circle.fill",
                        tint: Tint.green,
                        size: 42
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No Exact Duplicates Found")
                            .font(.headline)
                        Text("No byte-for-byte duplicate groups matched the current locations, minimum size, and ignore list.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            resultsSummary
            scanBoundaryNotice

            ForEach(filteredGroups) { group in
                DuplicateFileGroupCard(group: group)
                    .environmentObject(appState)
            }

            if filteredGroups.isEmpty {
                Text("No duplicate groups match your search.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
    }

    private var resultsSummary: some View {
        CardSurface(elevation: .raised) {
            VStack(spacing: 14) {
                HStack(spacing: 24) {
                    metric(
                        value: "\(appState.duplicateFileGroups.count)",
                        label: "Groups"
                    )
                    metric(
                        value: "\(appState.duplicateFileCount)",
                        label: "Duplicate Copies"
                    )
                    metric(
                        value: formattedBytes(
                            appState.duplicateLogicalReclaimableSize
                        ),
                        label: "Logical Reclaimable"
                    )
                    metric(
                        value: formattedBytes(appState.selectedDuplicateFileSize),
                        label: "Selected"
                    )
                    Spacer(minLength: 8)
                }

                Divider()

                HStack(spacing: 10) {
                    Button("Smart Select") {
                        appState.applySuggestedDuplicateSelection()
                    }
                    Button("Clear Selection") {
                        appState.clearDuplicateFileSelection()
                    }
                    Spacer()
                    if appState.latestUndoableDuplicateFileRecord != nil {
                        Button {
                            appState.undoLatestDuplicateFileRemoval()
                        } label: {
                            Label("Undo Last Removal", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(appState.isRemovingDuplicateFiles)
                    }
                    Button {
                        showingRemovalConfirmation = true
                    } label: {
                        Label(
                            String(
                                format: String(localized: "Move %lld to Trash"),
                                Int64(appState.selectedDuplicateFileIDs.count)
                            ),
                            systemImage: "trash"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Tint.red)
                    .disabled(
                        appState.selectedDuplicateFileIDs.isEmpty
                            || appState.isRemovingDuplicateFiles
                    )
                }
            }
        }
    }

    private func metric(value: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var scanBoundaryNotice: some View {
        CardSurface(padding: 12, elevation: .flat) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Tint.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reclaimable size is an estimate")
                        .font(.subheadline.weight(.medium))
                    Text("APFS clones may share physical blocks, so Finder’s free-space increase can be smaller than the logical total. Hard links are counted once, and cloud-only placeholders are not downloaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(scanStatisticsText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var scanStatisticsText: String {
        let statistics = appState.duplicateScanStatistics
        return String(
            format: String(
                localized: "%lld files examined · %lld cloud placeholders skipped · %lld hard-link aliases skipped · %lld inaccessible"
            ),
            Int64(statistics.examinedFileCount),
            Int64(statistics.cloudPlaceholderCount),
            Int64(statistics.hardLinkAliasCount),
            Int64(statistics.inaccessibleItemCount)
        )
    }

    private func successNotice(_ message: String) -> some View {
        CardSurface(padding: 12, accent: Tint.green, elevation: .flat) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Tint.green)
                Text(message)
                    .font(.subheadline)
                Spacer()
                Button {
                    appState.duplicateFileActionMessage = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
            }
        }
    }

    private func chooseScanLocations() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = String(localized: "Add")
        panel.message = String(
            localized: "Choose folders, mounted disks, or external drives to scan for exact duplicates."
        )
        guard panel.runModal() == .OK else { return }
        appState.addDuplicateScanRoots(panel.urls)
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct DuplicateScanProgressCard: View {
    @ObservedObject var progress: DuplicateScanProgressState
    let cancel: () -> Void

    var body: some View {
        CardSurface(elevation: .raised) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(phaseTitle)
                            .font(.headline)
                        Text(
                            String(
                                format: String(
                                    localized: "%lld files examined · %lld hash candidates"
                                ),
                                Int64(progress.value.examinedFileCount),
                                Int64(progress.value.candidateFileCount)
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel", action: cancel)
                }

                if let fraction = progress.value.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                if !progress.value.currentPath.isEmpty {
                    Text(progress.value.currentPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var phaseTitle: LocalizedStringKey {
        switch progress.value.phase {
        case .enumerating: return "Finding Candidate Files"
        case .sampling: return "Comparing Sample Hashes"
        case .verifying: return "Verifying Full File Hashes"
        case .completed: return "Scan Complete"
        }
    }
}

private struct DuplicateFileGroupCard: View {
    @EnvironmentObject private var appState: AppState
    let group: DuplicateFileGroup
    @State private var isExpanded = true

    var body: some View {
        CardSurface(padding: 0) {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(spacing: 0) {
                    Divider()
                    ForEach(group.files) { item in
                        DuplicateFileRow(item: item, group: group)
                            .environmentObject(appState)
                        if item != group.files.last {
                            Divider()
                                .padding(.leading, 54)
                        }
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    IconTile(
                        systemName: "doc.on.doc.fill",
                        tint: Tint.cyan,
                        size: 34
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.files.first?.name ?? String(localized: "Duplicate Group"))
                            .font(.headline)
                            .lineLimit(1)
                        Text(
                            String(
                                format: String(
                                    localized: "%lld copies · %@ each · %@ reclaimable"
                                ),
                                Int64(group.files.count),
                                ByteCountFormatter.string(
                                    fromByteCount: group.fileSize,
                                    countStyle: .file
                                ),
                                ByteCountFormatter.string(
                                    fromByteCount: group.logicalReclaimableSize,
                                    countStyle: .file
                                )
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusChip(
                        label: String(
                            format: String(localized: "%lld selected"),
                            Int64(group.files.count {
                                appState.selectedDuplicateFileIDs.contains($0.id)
                            })
                        ),
                        systemImage: "checkmark.circle",
                        tint: Tint.cyan
                    )
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .disclosureGroupStyle(.automatic)
        }
    }
}

private struct DuplicateFileRow: View {
    @EnvironmentObject private var appState: AppState
    let item: DuplicateFileItem
    let group: DuplicateFileGroup

    private var isSelected: Bool {
        appState.selectedDuplicateFileIDs.contains(item.id)
    }

    private var isSuggestedKeeper: Bool {
        item.id == group.suggestedKeeperID
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                appState.toggleDuplicateFileSelection(item, in: group)
            } label: {
                Image(
                    systemName: isSelected
                        ? "checkmark.square.fill"
                        : "square"
                )
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(
                    item.isRemovalEligible
                        ? (isSelected
                            ? Tint.cyan
                            : Color(nsColor: .secondaryLabelColor))
                        : Color(nsColor: .tertiaryLabelColor)
                )
            }
            .buttonStyle(.plain)
            .disabled(!item.isRemovalEligible)
            .accessibilityLabel(
                isSelected ? "Deselect duplicate" : "Select duplicate"
            )

            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if isSuggestedKeeper {
                        StatusChip(
                            label: String(localized: "Suggested Keep"),
                            systemImage: "checkmark.shield.fill",
                            tint: Tint.green
                        )
                    }
                    if let protectionReason = item.protectionReason {
                        StatusChip(
                            label: protectionTitle(protectionReason),
                            systemImage: "lock.fill",
                            tint: Tint.orange
                        )
                    }
                }
                Text(item.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: item.size,
                            countStyle: .file
                        )
                    )
                    if let modifiedAt = item.modifiedAt {
                        Text(modifiedAt, style: .date)
                    }
                    if isSuggestedKeeper {
                        Text(keepReasonTitle(group.keepReason))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Button("Keep This") {
                appState.keepDuplicateFile(item, in: group)
            }
            .controlSize(.small)

            Button {
                appState.previewDuplicateFile(item, in: group)
            } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.plain)
            .help("Quick Look")
            .accessibilityLabel("Quick Look")

            Button {
                appState.revealDuplicateFile(item)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")

            Menu {
                Button("Ignore File") {
                    appState.ignoreDuplicatePath(item.url)
                }
                Button("Ignore Parent Folder") {
                    appState.ignoreDuplicatePath(
                        item.url.deletingLastPathComponent()
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("More Actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isSelected ? Tint.cyan.opacity(0.07) : Color.clear)
    }

    private func protectionTitle(
        _ reason: DuplicateFileProtectionReason
    ) -> String {
        switch reason {
        case .hardLinked: return String(localized: "Hard Link")
        case .systemLocation: return String(localized: "System Location")
        case .notWritable: return String(localized: "Read Only")
        }
    }

    private func keepReasonTitle(_ reason: DuplicateKeepReason) -> String {
        switch reason {
        case .protectedReference:
            return String(localized: "Protected reference")
        case .preferredLocation:
            return String(localized: "Preferred location")
        case .originalLookingName:
            return String(localized: "Original-looking name")
        case .oldestCopy:
            return String(localized: "Oldest copy")
        case .shortestPath:
            return String(localized: "Shortest path")
        }
    }
}

private struct DuplicateIgnoreListSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Duplicate Ignore List")
                        .font(.title3.weight(.semibold))
                    Text("Ignored files and folders are excluded from future duplicate scans.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)

            Divider()

            if appState.ignoredDuplicatePaths.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "eye.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("The ignore list is empty.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(
                    appState.ignoredDuplicatePaths.sorted(),
                    id: \.self
                ) { path in
                    HStack(spacing: 10) {
                        Image(systemName: "eye.slash")
                            .foregroundStyle(Tint.orange)
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            appState.removeIgnoredDuplicatePath(path)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .help("Remove from Ignore List")
                        .accessibilityLabel("Remove from Ignore List")
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 620, minHeight: 360)
    }
}
