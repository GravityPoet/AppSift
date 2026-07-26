import AppKit
import SwiftUI

struct SimilarImagesView: View {
    @ObservedObject var center: SimilarImageCenter
    @State private var confirmsRemoval = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if center.source == .folder && center.rootURL == nil {
                EmptyStateView(
                    "Similar Images",
                    systemImage: "photo.stack.fill",
                    description: "Choose a local folder, mounted disk, or external drive. AppSift compares visual content and ranks image quality without uploading photos. Managed Photos libraries are excluded.",
                    action: { center.chooseFolder() },
                    actionLabel: "Choose Image Folder",
                    tint: Tint.purple
                )
            } else if center.source == .photoLibrary && !center.hasScanned && !center.isScanning {
                EmptyStateView(
                    "Photos Library",
                    systemImage: "photo.on.rectangle.angled",
                    description: "AppSift requests Photos read and write access only when you start this scan. Analysis stays on this Mac, iCloud-only originals are not downloaded, and cleanup uses Photos Recently Deleted.",
                    action: { center.scan(force: true) },
                    actionLabel: "Scan Photos Library",
                    tint: Tint.purple
                )
            } else if center.isScanning && !center.hasScanned {
                scanningState
            } else if center.hasScanned && center.groups.isEmpty {
                EmptyStateView(
                    "No Similar Image Groups",
                    systemImage: "checkmark.circle",
                    description: "No visually similar groups passed AppSift's local similarity thresholds in this folder.",
                    action: { center.scan(force: true) },
                    actionLabel: "Scan Again",
                    tint: Tint.green
                )
            } else {
                results
            }
        }
        .navigationTitle("Similar Images")
        .toolbar {
            ToolbarItemGroup {
                if center.source == .folder {
                    Button { center.chooseFolder() } label: {
                        Label("Choose Folder", systemImage: "folder.badge.gearshape")
                    }
                }
                Button {
                    center.isScanning ? center.cancelScan() : center.scan(force: true)
                } label: {
                    Label(
                        center.isScanning
                            ? String(localized: "Cancel Scan")
                            : center.source == .photoLibrary && !center.hasScanned
                                ? String(localized: "Scan Photos Library")
                                : String(localized: "Refresh"),
                        systemImage: center.isScanning ? "xmark.circle" : "arrow.clockwise"
                    )
                }
                Button(role: .destructive) { confirmsRemoval = true } label: {
                    Label(
                        center.source == .photoLibrary
                            ? String(localized: "Move Selected to Recently Deleted")
                            : String(localized: "Move Selected to Trash"),
                        systemImage: "trash"
                    )
                }
                .disabled(center.selectedIDs.isEmpty || center.isScanning || center.isRemoving)
            }
        }
        .confirmationDialog(
            center.source == .photoLibrary
                ? String(localized: "Move Photos to Recently Deleted?")
                : String(localized: "Move Similar Images to Trash?"),
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button(
                center.source == .photoLibrary
                    ? String(localized: "Move to Recently Deleted")
                    : String(localized: "Move to Trash"),
                role: .destructive
            ) { center.removeSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if center.source == .photoLibrary {
                Text(
                    String(
                        format: String(localized: "Move %lld selected Photos assets to Recently Deleted? Live Photo and RAW components stay together, and AppSift preserves at least one asset per group."),
                        Int64(center.selectedIDs.count)
                    )
                )
            } else {
                Text(
                    String(
                        format: String(localized: "Move %lld selected images (%@) to the Trash? AppSift will always preserve at least one image per group and keep recovery history."),
                        Int64(center.selectedIDs.count),
                        ByteCountFormatter.string(fromByteCount: center.selectedSize, countStyle: .file)
                    )
                )
            }
        }
        .alert("Similar Images", isPresented: Binding(
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
            IconTile(systemName: "photo.stack.fill", tint: Tint.purple, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("Similar Images")
                    .font(.title2.weight(.semibold))
                Text("Clusters photos with perceptual hashing and Vision feature distance, then recommends the strongest image in each group.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Quality combines relative resolution, sharpness, exposure balance, and detected-face confidence. It is a recommendation, not a subjective photo score.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(
                    center.source == .photoLibrary
                        ? String(localized: "Photos Library assets are accessed only through PhotoKit. Live Photo, RAW, and burst metadata stay attached to each asset.")
                        : String(localized: "Photos Library packages are never traversed as files; choose the Photos Library source to scan them safely through PhotoKit.")
                )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                Picker(
                    "Image Source",
                    selection: Binding(
                        get: { center.source },
                        set: { center.selectSource($0) }
                    )
                ) {
                    Text("Folder or Disk").tag(SimilarImageScanSource.folder)
                    Text("Photos Library").tag(SimilarImageScanSource.photoLibrary)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .accessibilityLabel("Image Source")
                if center.source == .photoLibrary {
                    Text("PhotoKit · local-only scan")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                } else if let root = center.rootURL {
                Text(root.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var scanningState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Analyzing images locally…")
                .font(.headline)
            if center.discoveredImageCount > 0 {
                ProgressView(
                    value: Double(center.completedImageCount),
                    total: Double(center.discoveredImageCount)
                )
                .frame(maxWidth: 320)
                Text(
                    String(
                        format: String(localized: "%lld of %lld images"),
                        Int64(center.completedImageCount),
                        Int64(center.discoveredImageCount)
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text(
                    center.source == .photoLibrary
                        ? String(localized: "Discovering accessible Photos Library assets…")
                        : String(localized: "Discovering supported local image files…")
                )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel Scan") { center.cancelScan() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                summary
                actionBar

                if let message = center.actionMessage {
                    actionNotice(message)
                }
                if let record = center.latestUndoableRecord {
                    undoNotice(record)
                }
                if center.cloudPlaceholderCount > 0 || center.unreadableCount > 0 || center.wasTruncated {
                    scanBoundaryNotice
                }

                ForEach(Array(center.groups.enumerated()), id: \.element.id) { index, group in
                    similarGroup(group, number: index + 1)
                }
            }
            .padding(20)
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            StatusChip(
                label: String(format: String(localized: "%lld groups"), Int64(center.groups.count)),
                systemImage: "rectangle.stack.fill",
                tint: Tint.purple
            )
            StatusChip(
                label: String(
                    format: String(localized: "%lld similar images"),
                    Int64(center.groups.reduce(0) { $0 + $1.items.count })
                ),
                systemImage: "photo.on.rectangle.angled",
                tint: Tint.blue
            )
            StatusChip(
                label: String(
                    format: String(localized: "%lld images analyzed"),
                    Int64(center.scannedImageCount)
                ),
                systemImage: "eye.fill",
                tint: Tint.green
            )
            Spacer()
        }
    }

    private var actionBar: some View {
        HStack(spacing: 9) {
            Button("Use Quality Suggestions") { center.useSuggestions() }
                .buttonStyle(.borderedProminent)
            Button("Clear Selection") { center.clearSelection() }
                .buttonStyle(.bordered)
                .disabled(center.selectedIDs.isEmpty)
            Spacer()
            if !center.selectedIDs.isEmpty {
                if center.source == .photoLibrary {
                    Text(
                        String(
                            format: String(localized: "%lld selected Photos assets"),
                            Int64(center.selectedIDs.count)
                        )
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                } else {
                    Text(
                        String(
                            format: String(localized: "%lld selected · %@"),
                            Int64(center.selectedIDs.count),
                            ByteCountFormatter.string(fromByteCount: center.selectedSize, countStyle: .file)
                        )
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func similarGroup(
        _ group: SimilarImageGroup,
        number: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.stack.fill").foregroundStyle(Tint.purple)
                Text(String(format: String(localized: "Similar Group %lld"), Int64(number)))
                    .font(.headline)
                Text("\(group.items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 230, maximum: 300), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(group.items) { item in
                    imageCard(item, in: group)
                }
            }
        }
    }

    private func imageCard(
        _ item: SimilarImageItem,
        in group: SimilarImageGroup
    ) -> some View {
        let isRecommended = item.id == group.recommendedKeepID
        return CardSurface(padding: 10, elevation: .flat) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    SimilarImageThumbnail(item: item, center: center)
                    if isRecommended {
                        StatusChip(
                            label: "Suggested Keep",
                            systemImage: "checkmark.seal.fill",
                            tint: Tint.green
                        )
                        .padding(7)
                    }
                }

                HStack(spacing: 7) {
                    Toggle("", isOn: Binding(
                        get: { center.selectedIDs.contains(item.id) },
                        set: { _ in center.toggle(item) }
                    ))
                    .labelsHidden()
                    Text(item.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text("\(Int((item.quality.overall * 100).rounded()))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(isRecommended ? Tint.green : .secondary)
                        .help("Relative quality recommendation")
                }

                Text(itemDetails(item))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if let reference = item.source.photoLibraryReference {
                    HStack(spacing: 6) {
                        if reference.isLivePhoto { sourceChip("Live Photo") }
                        if reference.isRAW { sourceChip("RAW") }
                        if reference.burstIdentifier != nil { sourceChip("Burst") }
                    }
                }

                HStack(spacing: 6) {
                    qualityChip("Sharp", item.quality.sharpness)
                    qualityChip("Exposure", item.quality.exposure)
                    if item.quality.face > 0 { qualityChip("Face", item.quality.face) }
                }

                HStack {
                    Button { center.preview(item, group: group) } label: {
                        Label("Preview", systemImage: "eye")
                    }
                    .buttonStyle(.borderless)
                    Button { center.reveal(item) } label: {
                        Label(
                            item.source.photoLibraryReference == nil
                                ? String(localized: "Reveal")
                                : String(localized: "Open Photos"),
                            systemImage: item.source.photoLibraryReference == nil ? "folder" : "photo"
                        )
                    }
                    .buttonStyle(.borderless)
                }
                .font(.caption)
            }
        }
    }

    private func itemDetails(_ item: SimilarImageItem) -> String {
        let dimensions = "\(item.pixelWidth) × \(item.pixelHeight)"
        guard item.source.photoLibraryReference == nil else {
            return dimensions + " · " + String(localized: "Photos asset")
        }
        return dimensions + " · "
            + ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)
    }

    private func sourceChip(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Tint.purple)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Tint.purple.opacity(0.09), in: Capsule())
    }

    private func qualityChip(_ title: LocalizedStringKey, _ value: Double) -> some View {
        HStack(spacing: 2) {
            Text(title)
            Text("\(Int((value * 100).rounded()))")
        }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.05), in: Capsule())
    }

    private func actionNotice(_ message: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Tint.green)
            Text(message).font(.subheadline)
            Spacer()
            Button { center.actionMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(Tint.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func undoNotice(_ record: ReviewedTrashRecord) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "trash.slash.fill").foregroundStyle(Tint.orange)
            Text("The latest similar-image cleanup can still be restored from the Trash.")
                .font(.subheadline)
            Spacer()
            Button("Undo") { center.undo(record) }
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
                    format: String(localized: "%lld cloud placeholders and %lld unreadable images were left untouched.%@"),
                    Int64(center.cloudPlaceholderCount),
                    Int64(center.unreadableCount),
                    center.wasTruncated ? String(localized: " The image or comparison safety limit was reached.") : ""
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

private struct SimilarImageThumbnail: View {
    let item: SimilarImageItem
    @ObservedObject var center: SimilarImageCenter
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.primary.opacity(0.04)
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .clipped()
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: item.id) {
            image = await center.thumbnail(for: item)
        }
        .accessibilityLabel(item.name)
    }
}
