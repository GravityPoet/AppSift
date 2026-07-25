import AppKit
import SwiftUI

struct SpaceLensView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var hoveredNodeID: String?
    @State private var showingRemovalConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if appState.isScanningSpaceLens {
                scanningContent
            } else if appState.hasScannedSpaceLens,
                      appState.spaceLensResult != nil {
                resultContent
            } else {
                readyContent
            }
        }
        .navigationTitle("Space Lens")
        .toolbar {
            ToolbarItemGroup {
                if appState.isScanningSpaceLens
                    || appState.isRemovingSpaceLensItems {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    if appState.isScanningSpaceLens {
                        appState.cancelSpaceLensScan()
                    } else {
                        appState.scanSpaceLens(force: true)
                    }
                } label: {
                    Label(
                        appState.isScanningSpaceLens ? "Cancel" : "Refresh",
                        systemImage: appState.isScanningSpaceLens
                            ? "xmark"
                            : "arrow.clockwise"
                    )
                }
                .disabled(
                    appState.isRemovingSpaceLensItems
                        || (
                            !appState.isScanningSpaceLens
                                && appState.spaceLensScanRoot == nil
                        )
                )
            }
        }
        .confirmationDialog(
            "Move Space Lens Items to Trash?",
            isPresented: $showingRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                appState.removeSelectedSpaceLensItems()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                String(
                    format: String(
                        localized: "%lld selected items (%@ allocated) will move to the macOS Trash. AppSift revalidates every item and keeps a local undo record."
                    ),
                    Int64(appState.selectedSpaceLensNodeIDs.count),
                    formattedBytes(
                        appState.selectedSpaceLensAllocatedSize
                    )
                )
            )
        }
        .alert(
            "Space Lens Action Failed",
            isPresented: Binding(
                get: { appState.spaceLensActionError != nil },
                set: {
                    if !$0 {
                        appState.spaceLensActionError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                appState.spaceLensActionError = nil
            }
        } message: {
            Text(appState.spaceLensActionError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(
                systemName: "square.3.layers.3d",
                tint: Tint.purple,
                size: 34
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("Space Lens")
                    .font(.title2.weight(.semibold))
                Text("See where disk space goes, then drill into the folders that matter.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Physical allocation is clone-aware; logical size remains available for comparison.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 16)
            if let date = appState.lastSpaceLensScanDate {
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

    private var readyContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                locationCard

                CardSurface(elevation: .raised) {
                    HStack(spacing: 18) {
                        IconTile(
                            systemName: "rectangle.3.group.fill",
                            tint: Tint.purple,
                            size: 52,
                            corner: 12,
                            glow: true
                        )
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Build an Interactive Storage Map")
                                .font(.title3.weight(.semibold))
                            Text("AppSift reads file metadata locally, aggregates the full directory tree, and turns each folder into an area proportional to its size.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                            HStack(spacing: 8) {
                                featureChip(
                                    "Cancelable",
                                    icon: "xmark.circle"
                                )
                                featureChip(
                                    "Clone-aware",
                                    icon: "square.on.square"
                                )
                                featureChip(
                                    "Trash-first",
                                    icon: "trash"
                                )
                                featureChip(
                                    "On-device",
                                    icon: "lock.shield"
                                )
                            }
                            .padding(.top, 4)
                        }
                        Spacer(minLength: 12)
                    }
                }

                boundaryNotice
            }
            .padding(20)
        }
    }

    private var scanningContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                locationCard
                SpaceLensProgressCard(
                    progress: appState.spaceLensScanProgress,
                    cancel: appState.cancelSpaceLensScan
                )
                boundaryNotice
            }
            .padding(20)
        }
    }

    private var resultContent: some View {
        VStack(spacing: 12) {
            if let message = appState.spaceLensActionMessage {
                successNotice(message)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }

            resultToolbar
                .padding(.horizontal, 16)
                .padding(.top, appState.spaceLensActionMessage == nil ? 12 : 0)

            if let result = appState.spaceLensResult,
               let currentNode = appState.currentSpaceLensNode {
                storageSummary(result)
                    .padding(.horizontal, 16)

                HSplitView {
                    SpaceLensMapPanel(
                        node: currentNode,
                        sizeMode: appState.spaceLensSizeMode,
                        unaccountedSize: currentNode.id == result.root.id
                            ? result.unaccountedAllocatedSize
                            : nil,
                        hoveredNodeID: $hoveredNodeID,
                        selectedNodeIDs:
                            appState.selectedSpaceLensNodeIDs,
                        open: appState.navigateSpaceLensInto,
                        toggleSelection:
                            appState.toggleSpaceLensSelection,
                        preview: appState.previewSpaceLensNode,
                        reveal: appState.revealSpaceLensNode
                    )
                    .frame(minWidth: 410)

                    SpaceLensRankingPanel(
                        node: currentNode,
                        sizeMode: appState.spaceLensSizeMode,
                        searchText: $searchText,
                        hoveredNodeID: $hoveredNodeID,
                        selectedNodeIDs:
                            appState.selectedSpaceLensNodeIDs,
                        open: appState.navigateSpaceLensInto,
                        toggleSelection:
                            appState.toggleSpaceLensSelection,
                        preview: appState.previewSpaceLensNode,
                        reveal: appState.revealSpaceLensNode
                    )
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                actionBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }

    private var locationCard: some View {
        CardSurface {
            HStack(spacing: 14) {
                IconTile(
                    systemName: locationIcon,
                    tint: Tint.purple,
                    size: 38
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text("Scan Location")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(locationName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(appState.spaceLensScanRoot?.path ?? "No location selected")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    chooseLocation()
                } label: {
                    Label("Choose Location", systemImage: "folder.badge.plus")
                }
                .disabled(
                    appState.isScanningSpaceLens
                        || appState.isRemovingSpaceLensItems
                )
                Button {
                    appState.scanSpaceLens(force: true)
                } label: {
                    Label("Scan", systemImage: "viewfinder")
                }
                .buttonStyle(
                    GlowProminentButtonStyle(
                        tint: Tint.purple,
                        gradient: TintGradient.of(Tint.purple)
                    )
                )
                .disabled(
                    appState.spaceLensScanRoot == nil
                        || appState.isScanningSpaceLens
                        || appState.isRemovingSpaceLensItems
                )
            }
        }
    }

    private var resultToolbar: some View {
        HStack(spacing: 8) {
            Button {
                appState.navigateSpaceLensUp()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(appState.spaceLensNavigationPath.count <= 1)
            .help("Go Up")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(appState.spaceLensNavigationNodes) { node in
                        Button {
                            appState.navigateSpaceLens(to: node.id)
                        } label: {
                            HStack(spacing: 4) {
                                if node.id
                                    == appState.spaceLensNavigationNodes.first?.id {
                                    Image(systemName: locationIcon)
                                        .font(.caption2)
                                }
                                Text(node.name)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(
                            node.id == appState.currentSpaceLensNode?.id
                                ? .semibold
                                : .regular
                        ))
                        .foregroundStyle(
                            node.id == appState.currentSpaceLensNode?.id
                                ? Tint.blue
                                : .secondary
                        )

                        if node.id
                            != appState.spaceLensNavigationNodes.last?.id {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            Picker(
                "Size",
                selection: Binding(
                    get: { appState.spaceLensSizeMode },
                    set: appState.setSpaceLensSizeMode
                )
            ) {
                Text("Physical").tag(SpaceLensSizeMode.allocated)
                Text("Logical").tag(SpaceLensSizeMode.logical)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 170)

            Button {
                chooseLocation()
            } label: {
                Label("Location", systemImage: "externaldrive")
            }
            .disabled(appState.isRemovingSpaceLensItems)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
    }

    private func storageSummary(
        _ result: SpaceLensScanResult
    ) -> some View {
        HStack(spacing: 0) {
            summaryMetric(
                formattedBytes(result.root.allocatedSize),
                label: "Physical Scanned",
                icon: "internaldrive.fill",
                tint: Tint.purple
            )
            summaryDivider
            summaryMetric(
                formattedBytes(result.root.logicalSize),
                label: "Logical Content",
                icon: "doc.on.doc",
                tint: Tint.blue
            )
            summaryDivider
            summaryMetric(
                "\(result.statistics.fileCount)",
                label: "Files",
                icon: "doc.fill",
                tint: Tint.cyan
            )
            summaryDivider
            if let unaccounted = result.unaccountedAllocatedSize,
               unaccounted > 0 {
                summaryMetric(
                    formattedBytes(unaccounted),
                    label: "Unaccounted",
                    icon: "questionmark.folder.fill",
                    tint: Tint.orange
                )
            } else {
                summaryMetric(
                    "\(result.statistics.inaccessibleItemCount)",
                    label: "Unreadable",
                    icon: "lock.fill",
                    tint: result.statistics.inaccessibleItemCount > 0
                        ? Tint.orange
                        : Tint.green
                )
            }
        }
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Text(
                appState.spaceLensSizeMode == .allocated
                    ? "Physical mode counts hard links and confirmed APFS clone streams once."
                    : "Logical mode shows each file path's full content size."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)

            Spacer()

            if appState.latestUndoableSpaceLensRecord != nil {
                Button {
                    appState.undoLatestSpaceLensRemoval()
                } label: {
                    Label("Undo Last Removal", systemImage: "arrow.uturn.backward")
                }
                .disabled(
                    appState.isScanningSpaceLens
                        || appState.isRemovingSpaceLensItems
                )
            }

            Button("Clear Selection") {
                appState.clearSpaceLensSelection()
            }
            .disabled(appState.selectedSpaceLensNodeIDs.isEmpty)

            Button {
                appState.selectAllEligibleSpaceLensItems()
            } label: {
                Label("Select Eligible", systemImage: "checkmark.circle")
            }
            .disabled(
                appState.currentSpaceLensNode?.children.contains(
                    where: \.isRemovalEligible
                ) != true
            )

            Button {
                showingRemovalConfirmation = true
            } label: {
                Label(
                    String(
                        format: String(localized: "Move %lld to Trash"),
                        Int64(appState.selectedSpaceLensNodeIDs.count)
                    ),
                    systemImage: "trash"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(Tint.red)
            .disabled(
                appState.selectedSpaceLensNodeIDs.isEmpty
                    || appState.isScanningSpaceLens
                    || appState.isRemovingSpaceLensItems
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
    }

    private var boundaryNotice: some View {
        CardSurface {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(Tint.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("A map, not a cleanup recommendation")
                        .font(.subheadline.weight(.semibold))
                    Text("Space Lens never auto-selects personal files. System locations, app-managed libraries, hard links, cloud-only placeholders, unreadable items, and folders containing protected descendants stay non-removable here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func featureChip(
        _ label: LocalizedStringKey,
        icon: String
    ) -> some View {
        Label(label, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(Tint.purple)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Tint.purple.opacity(0.10))
            )
    }

    private func successNotice(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Tint.green)
            Text(message)
                .font(.subheadline)
            Spacer()
            Button {
                appState.spaceLensActionMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Tint.green.opacity(0.10))
        )
    }

    private func summaryMetric(
        _ value: String,
        label: LocalizedStringKey,
        icon: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private var summaryDivider: some View {
        Divider()
            .frame(height: 28)
    }

    private var locationName: String {
        guard let root = appState.spaceLensScanRoot else {
            return String(localized: "No location selected")
        }
        return root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
    }

    private var locationIcon: String {
        guard let path = appState.spaceLensScanRoot?.path else {
            return "folder.fill"
        }
        return path.hasPrefix("/Volumes/")
            ? "externaldrive.fill"
            : "folder.fill"
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a Folder or Disk")
        panel.prompt = String(localized: "Choose")
        panel.message = String(
            localized: "Select one folder, mounted disk, or external drive to map."
        )
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        if let root = appState.spaceLensScanRoot {
            panel.directoryURL = root
        }
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        searchText = ""
        hoveredNodeID = nil
        appState.setSpaceLensScanRoot(url)
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(0, bytes),
            countStyle: .file
        )
    }
}

private struct SpaceLensProgressCard: View {
    @ObservedObject var progress: SpaceLensScanProgressState
    let cancel: () -> Void

    var body: some View {
        CardSurface(elevation: .raised) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(progress.value.phase == .finalizing
                            ? "Finalizing the storage map"
                            : "Scanning the directory tree")
                            .font(.headline)
                        Text("Sizes appear as AppSift aggregates each completed branch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel", role: .cancel, action: cancel)
                }

                HStack(spacing: 18) {
                    progressMetric(
                        "\(progress.value.fileCount)",
                        label: "Files"
                    )
                    progressMetric(
                        "\(progress.value.directoryCount)",
                        label: "Folders"
                    )
                    progressMetric(
                        ByteCountFormatter.string(
                            fromByteCount:
                                progress.value.allocatedBytes,
                            countStyle: .file
                        ),
                        label: "Physical Counted"
                    )
                    Spacer()
                }

                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(Tint.purple)
                    Text(progress.value.currentPath.isEmpty
                        ? String(localized: "Preparing scan…")
                        : progress.value.currentPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.035))
                )
            }
        }
    }

    private func progressMetric(
        _ value: String,
        label: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SpaceLensMapPanel: View {
    let node: SpaceLensNode
    let sizeMode: SpaceLensSizeMode
    let unaccountedSize: Int64?
    @Binding var hoveredNodeID: String?
    let selectedNodeIDs: Set<String>
    let open: (SpaceLensNode) -> Void
    let toggleSelection: (SpaceLensNode) -> Void
    let preview: (SpaceLensNode) -> Void
    let reveal: (SpaceLensNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(
                        String(
                            format: String(
                                localized: "%lld files · %lld folders · %@"
                            ),
                            Int64(node.fileCount),
                            Int64(max(0, node.directoryCount - 1)),
                            formattedBytes(sizeMode.size(of: node))
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                StatusChip(
                    label: sizeMode == .allocated
                        ? String(localized: "Physical")
                        : String(localized: "Logical"),
                    systemImage: sizeMode == .allocated
                        ? "internaldrive"
                        : "doc.on.doc",
                    tint: Tint.purple
                )
            }
            .padding(12)

            Divider()

            SpaceLensTreemapView(
                nodes: node.children,
                sizeMode: sizeMode,
                unaccountedSize: unaccountedSize,
                hoveredNodeID: $hoveredNodeID,
                selectedNodeIDs: selectedNodeIDs,
                open: open,
                toggleSelection: toggleSelection,
                preview: preview,
                reveal: reveal
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(0, bytes),
            countStyle: .file
        )
    }
}

private struct SpaceLensTreemapView: View {
    let nodes: [SpaceLensNode]
    let sizeMode: SpaceLensSizeMode
    let unaccountedSize: Int64?
    @Binding var hoveredNodeID: String?
    let selectedNodeIDs: Set<String>
    let open: (SpaceLensNode) -> Void
    let toggleSelection: (SpaceLensNode) -> Void
    let preview: (SpaceLensNode) -> Void
    let reveal: (SpaceLensNode) -> Void

    private static let otherID = "__space_lens_other__"
    private static let unaccountedID = "__space_lens_unaccounted__"
    private static let maximumTiles = 72

    var body: some View {
        GeometryReader { geometry in
            let items = displayItems
            let tiles = SpaceLensTreemapLayout.tiles(
                for: items.map {
                    SpaceLensTreemapEntry(
                        id: $0.id,
                        weight: Double($0.size)
                    )
                },
                in: CGRect(
                    origin: .zero,
                    size: geometry.size
                ).insetBy(dx: 4, dy: 4)
            )

            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)

                if tiles.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.dashed")
                            .font(.title)
                            .foregroundStyle(.tertiary)
                        Text("No measurable items in this folder")
                            .font(.subheadline.weight(.medium))
                        Text("Zero-allocation aliases and unavailable placeholders remain visible in the ranked list.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    )
                } else {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) {
                        index,
                        tile in
                        if let item = items.first(where: {
                            $0.id == tile.id
                        }) {
                            tileView(
                                item,
                                index: index,
                                rect: tile.rect.insetBy(
                                    dx: 1.5,
                                    dy: 1.5
                                )
                            )
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Storage treemap")
    }

    @ViewBuilder
    private func tileView(
        _ item: DisplayItem,
        index: Int,
        rect: CGRect
    ) -> some View {
        if let node = item.node {
            Button {
                if node.isContainer {
                    open(node)
                } else {
                    toggleSelection(node)
                }
            } label: {
                tileLabel(
                    item,
                    index: index,
                    rect: rect,
                    isInteractive: true
                )
            }
            .buttonStyle(.plain)
            .frame(
                width: max(0, rect.width),
                height: max(0, rect.height)
            )
            .position(x: rect.midX, y: rect.midY)
            .help("\(node.url.path) — \(formattedBytes(item.size))")
            .onHover {
                hoveredNodeID = $0 ? node.id : nil
            }
            .contextMenu {
                if node.isContainer {
                    Button("Open Folder") { open(node) }
                }
                Button("Quick Look") { preview(node) }
                Button("Reveal in Finder") { reveal(node) }
                Divider()
                Button(
                    selectedNodeIDs.contains(node.id)
                        ? "Deselect"
                        : "Select for Trash"
                ) {
                    toggleSelection(node)
                }
                .disabled(!node.isRemovalEligible)
            }
            .accessibilityLabel(
                "\(node.name), \(formattedBytes(item.size))"
            )
            .accessibilityHint(
                node.isContainer
                    ? "Open this folder in Space Lens"
                    : "Toggle selection for Trash"
            )
        } else {
            tileLabel(
                item,
                index: index,
                rect: rect,
                isInteractive: false
            )
            .frame(
                width: max(0, rect.width),
                height: max(0, rect.height)
            )
            .position(x: rect.midX, y: rect.midY)
            .help("\(item.name) — \(formattedBytes(item.size))")
        }
    }

    private func tileLabel(
        _ item: DisplayItem,
        index: Int,
        rect: CGRect,
        isInteractive: Bool
    ) -> some View {
        let selected = selectedNodeIDs.contains(item.id)
        let hovered = hoveredNodeID == item.id
        let tint = tileColor(for: item, index: index)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            tint.opacity(selected ? 0.95 : 0.82),
                            tint.opacity(selected ? 0.78 : 0.60),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            selected
                                ? Color.white.opacity(0.95)
                                : Color.white.opacity(hovered ? 0.72 : 0.22),
                            lineWidth: selected ? 2.5 : (hovered ? 1.5 : 0.5)
                        )
                )
                .shadow(
                    color: .black.opacity(hovered && isInteractive ? 0.16 : 0),
                    radius: 5,
                    y: 2
                )

            if rect.width >= 70, rect.height >= 44 {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(item.name)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(rect.height >= 64 ? 2 : 1)
                        Spacer(minLength: 0)
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                        }
                    }
                    Text(formattedBytes(item.size))
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .opacity(0.86)
                }
                .foregroundStyle(Color.white)
                .shadow(color: .black.opacity(0.22), radius: 1, y: 1)
                .padding(7)
            } else if rect.width >= 34, rect.height >= 30 {
                Image(systemName: item.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .padding(6)
            }
        }
        .scaleEffect(hovered && isInteractive ? 0.985 : 1)
        .animation(MotionTokens.snappy, value: hovered)
        .animation(MotionTokens.snappy, value: selected)
    }

    private var displayItems: [DisplayItem] {
        var positiveNodes = nodes.filter {
            sizeMode.size(of: $0) > 0
        }.sorted {
            let first = sizeMode.size(of: $0)
            let second = sizeMode.size(of: $1)
            if first != second { return first > second }
            return $0.name.localizedStandardCompare($1.name)
                == .orderedAscending
        }

        let reservedSyntheticCount =
            (unaccountedSize ?? 0) > 0 ? 1 : 0
        let directLimit = max(
            1,
            Self.maximumTiles - reservedSyntheticCount
        )
        var items: [DisplayItem]
        if positiveNodes.count > directLimit {
            let visibleCount = max(1, directLimit - 1)
            let remainder = positiveNodes.dropFirst(visibleCount)
            positiveNodes = Array(positiveNodes.prefix(visibleCount))
            items = positiveNodes.map {
                DisplayItem(node: $0, sizeMode: sizeMode)
            }
            items.append(DisplayItem(
                id: Self.otherID,
                name: String(
                    format: String(localized: "Other Items (%lld)"),
                    Int64(remainder.count)
                ),
                size: remainder.reduce(0) {
                    $0 + sizeMode.size(of: $1)
                },
                icon: "ellipsis",
                node: nil,
                isUnaccounted: false
            ))
        } else {
            items = positiveNodes.map {
                DisplayItem(node: $0, sizeMode: sizeMode)
            }
        }

        if let unaccountedSize, unaccountedSize > 0 {
            items.append(DisplayItem(
                id: Self.unaccountedID,
                name: String(localized: "Unaccounted Space"),
                size: unaccountedSize,
                icon: "questionmark.folder.fill",
                node: nil,
                isUnaccounted: true
            ))
        }
        return items
    }

    private func tileColor(
        for item: DisplayItem,
        index: Int
    ) -> Color {
        if item.isUnaccounted {
            return Tint.orange
        }
        guard let node = item.node else {
            return Color.gray
        }
        if node.isCloudPlaceholder || node.isCloneAlias {
            return Tint.cyan
        }
        let palette: [Color] = [
            Tint.blue,
            Tint.purple,
            Tint.cyan,
            Tint.green,
            Tint.pink,
            Tint.orange,
        ]
        let scalarSeed = node.name.unicodeScalars.reduce(0) {
            ($0 &* 31) &+ Int($1.value)
        }
        return palette[abs(scalarSeed + index) % palette.count]
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(0, bytes),
            countStyle: .file
        )
    }

    private struct DisplayItem {
        let id: String
        let name: String
        let size: Int64
        let icon: String
        let node: SpaceLensNode?
        let isUnaccounted: Bool

        init(node: SpaceLensNode, sizeMode: SpaceLensSizeMode) {
            self.id = node.id
            self.name = node.name
            self.size = sizeMode.size(of: node)
            self.icon = node.isContainer ? "folder.fill" : "doc.fill"
            self.node = node
            self.isUnaccounted = false
        }

        init(
            id: String,
            name: String,
            size: Int64,
            icon: String,
            node: SpaceLensNode?,
            isUnaccounted: Bool
        ) {
            self.id = id
            self.name = name
            self.size = size
            self.icon = icon
            self.node = node
            self.isUnaccounted = isUnaccounted
        }
    }
}

private struct SpaceLensRankingPanel: View {
    let node: SpaceLensNode
    let sizeMode: SpaceLensSizeMode
    @Binding var searchText: String
    @Binding var hoveredNodeID: String?
    let selectedNodeIDs: Set<String>
    let open: (SpaceLensNode) -> Void
    let toggleSelection: (SpaceLensNode) -> Void
    let preview: (SpaceLensNode) -> Void
    let reveal: (SpaceLensNode) -> Void

    private var filteredNodes: [SpaceLensNode] {
        let sorted = node.children.sorted {
            let first = sizeMode.size(of: $0)
            let second = sizeMode.size(of: $1)
            if first != second { return first > second }
            return $0.name.localizedStandardCompare($1.name)
                == .orderedAscending
        }
        guard !searchText.isEmpty else { return sorted }
        let query = searchText.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return sorted.filter {
            ($0.name + " " + $0.url.path).folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ).contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Largest Items")
                        .font(.headline)
                    Text(
                        String(
                            format: String(localized: "%lld direct items"),
                            Int64(node.children.count)
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter this folder", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.045))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            Divider()

            if filteredNodes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No items match this filter.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredNodes) { child in
                            rankingRow(child)
                            if child.id != filteredNodes.last?.id {
                                Divider()
                                    .padding(.leading, 42)
                            }
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func rankingRow(_ child: SpaceLensNode) -> some View {
        let selected = selectedNodeIDs.contains(child.id)
        let hovered = hoveredNodeID == child.id
        let largest = max(
            1,
            filteredNodes.map { sizeMode.size(of: $0) }.max() ?? 1
        )
        let ratio = min(
            1,
            Double(sizeMode.size(of: child)) / Double(largest)
        )

        return HStack(spacing: 8) {
            Button {
                toggleSelection(child)
            } label: {
                Image(systemName: selected
                    ? "checkmark.square.fill"
                    : "square")
                    .foregroundStyle(
                        child.isRemovalEligible
                            ? (
                                selected
                                    ? Tint.blue
                                    : Color(nsColor: .secondaryLabelColor)
                            )
                            : Color(nsColor: .tertiaryLabelColor)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!child.isRemovalEligible)
            .accessibilityLabel(
                selected
                    ? Text("Deselect")
                    : Text("Toggle selection for Trash")
            )
            .help(child.isRemovalEligible
                ? "Select for Trash"
                : protectionHelp(child))

            Button {
                if child.isContainer {
                    open(child)
                } else {
                    toggleSelection(child)
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: icon(for: child))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(tint(for: child))
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Text(child.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if child.isCloneAlias {
                                Image(systemName: "square.on.square")
                                    .font(.caption2)
                                    .foregroundStyle(Tint.cyan)
                                    .help("Confirmed APFS clone alias")
                            }
                            if child.isCloudPlaceholder {
                                Image(systemName: "icloud")
                                    .font(.caption2)
                                    .foregroundStyle(Tint.cyan)
                                    .help("Cloud-only placeholder")
                            }
                            if child.protectionReason != nil
                                || child.protectedDescendantCount > 0 {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Tint.orange)
                                    .help(protectionHelp(child))
                            }
                            Spacer(minLength: 2)
                            Text(formattedBytes(sizeMode.size(of: child)))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }

                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary.opacity(0.055))
                                Capsule()
                                    .fill(tint(for: child).opacity(0.55))
                                    .frame(
                                        width: max(
                                            2,
                                            geometry.size.width * ratio
                                        )
                                    )
                            }
                        }
                        .frame(height: 3)
                    }

                    if child.isContainer {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            selected
                ? Tint.blue.opacity(0.10)
                : Color.primary.opacity(hovered ? 0.045 : 0)
        )
        .contentShape(Rectangle())
        .onHover {
            hoveredNodeID = $0 ? child.id : nil
        }
        .contextMenu {
            if child.isContainer {
                Button("Open Folder") { open(child) }
            }
            Button("Quick Look") { preview(child) }
            Button("Reveal in Finder") { reveal(child) }
            Divider()
            Button(
                selected ? "Deselect" : "Select for Trash"
            ) {
                toggleSelection(child)
            }
            .disabled(!child.isRemovalEligible)
        }
    }

    private func icon(for node: SpaceLensNode) -> String {
        if node.isCloudPlaceholder {
            return "icloud.fill"
        }
        switch node.kind {
        case .directory:
            return "folder.fill"
        case .package:
            return "shippingbox.fill"
        case .file:
            return "doc.fill"
        }
    }

    private func tint(for node: SpaceLensNode) -> Color {
        if node.isCloudPlaceholder || node.isCloneAlias {
            return Tint.cyan
        }
        switch node.kind {
        case .directory:
            return Tint.blue
        case .package:
            return Tint.purple
        case .file:
            return Tint.green
        }
    }

    private func protectionHelp(_ node: SpaceLensNode) -> String {
        if node.protectedDescendantCount > 0 {
            return String(
                localized: "Contains protected items. Open the folder to review eligible children."
            )
        }
        switch node.protectionReason {
        case .scanRoot:
            return String(localized: "The scan root cannot be removed.")
        case .systemLocation:
            return String(localized: "Protected system location.")
        case .appManagedLibrary:
            return String(
                localized: "Use the owning app to manage this library or application."
            )
        case .inaccessible:
            return String(localized: "AppSift could not read this item completely.")
        case .differentOwner:
            return String(localized: "Owned by another user or system account.")
        case .notWritable:
            return String(localized: "This item is not writable.")
        case .hardLinked:
            return String(
                localized: "Hard-linked files stay protected because deleting one path may not reclaim space."
            )
        case .cloudPlaceholder:
            return String(
                localized: "Cloud-only placeholders stay protected to avoid changing cloud data."
            )
        case nil:
            return String(localized: "Protected item.")
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(0, bytes),
            countStyle: .file
        )
    }
}
