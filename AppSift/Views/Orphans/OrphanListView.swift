import SwiftUI

struct OrphanListView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedOrphans: Set<URL> = []
    @State private var isRemoving = false
    @State private var removalErrorMessage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let trashService = OrphanTrashService()

    var body: some View {
        Group {
            if appState.isSearchingOrphans {
                VStack(spacing: 16) {
                    ProgressView(LocalizedStringKey("Scanning for orphaned files..."))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.orphanedFiles.isEmpty {
                EmptyStateView("No Orphaned Files", systemImage: "checkmark.circle", description: "No leftover files from uninstalled apps were found.", action: { appState.findOrphans() }, actionLabel: "Scan for Orphans", tint: Tint.green)
            } else {
                List {
                    // No .staggered(): List is lazy, so a delayed-reveal would
                    // blank each row as it scrolls in. The removal transition
                    // below still gives the sweep-out on delete.
                    ForEach(Array(appState.orphanedFiles.enumerated()), id: \.element) { _, fileURL in
                        OrphanRowView(
                            fileURL: fileURL,
                            isSelected: orphanBinding(for: fileURL),
                            fileSize: fileSize(fileURL),
                            onReveal: { revealInFinder(fileURL) },
                            onCopyPath: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(fileURL.path, forType: .string)
                            },
                            onIgnore: { ignoreOrphans([fileURL]) },
                            onTrash: { Task { await removeSingleOrphan(fileURL) } }
                        )
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .opacity,
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                )
                        )
                    }
                }
            }
        }
        .navigationTitle(orphanedFilesTitle)
        .toolbar {
            ToolbarItemGroup {
                if !appState.orphanedFiles.isEmpty {
                    Button(LocalizedStringKey(selectedOrphans.count == appState.orphanedFiles.count ? "Deselect All" : "Select All")) {
                        if selectedOrphans.count == appState.orphanedFiles.count {
                            selectedOrphans.removeAll()
                        } else {
                            selectedOrphans = Set(appState.orphanedFiles)
                        }
                    }
                }

                Button("Scan for Orphans") {
                    appState.findOrphans()
                }

                if !selectedOrphans.isEmpty {
                    Button(ignoreSelectedLabel) {
                        ignoreOrphans(Array(selectedOrphans))
                    }
                    .disabled(isRemoving)

                    Button(removeSelectedLabel, role: .destructive) {
                        Task {
                            await removeSelectedOrphans()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isRemoving)
                }
            }
        }
        .alert("Some files could not be moved to Trash", isPresented: Binding(
            get: { removalErrorMessage != nil },
            set: { if !$0 { removalErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalErrorMessage ?? "")
        }
    }

    private var orphanedFilesTitle: String {
        String(format: String(localized: "Orphaned Files (%lld)"), Int64(appState.orphanedFiles.count))
    }

    private var removeSelectedLabel: String {
        String(format: String(localized: "Move Selected to Trash (%lld)"), Int64(selectedOrphans.count))
    }

    private var ignoreSelectedLabel: String {
        String(format: String(localized: "Ignore Selected (%lld)"), Int64(selectedOrphans.count))
    }

    /// Persist the given URLs to the ignore list (so future scans skip them)
    /// and drop them from the local selection.
    private func ignoreOrphans(_ urls: [URL]) {
        appState.ignoreOrphans(urls)
        selectedOrphans.subtract(urls)
    }

    private func orphanBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { selectedOrphans.contains(url) },
            set: { selected in
                if selected {
                    selectedOrphans.insert(url)
                } else {
                    selectedOrphans.remove(url)
                }
            }
        )
    }

    private func fileSize(_ url: URL) -> Int64? {
        if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
           let size = values.totalFileAllocatedSize, size > 0 {
            return Int64(size)
        }
        if let values = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey]),
           let size = values.fileAllocatedSize {
            return Int64(size)
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }

    private func removeSelectedOrphans() async {
        isRemoving = true
        defer { isRemoving = false }

        let urlsToRemove = selectedOrphans
        var failedPaths: [String] = []
        var removedURLs: Set<URL> = []

        for url in urlsToRemove {
            switch trashService.trash(url) {
            case .trashed, .missing:
                removedURLs.insert(url)
            case .blocked:
                failedPaths.append("\(url.path) (blocked by safety policy)")
            case .permissionDenied:
                failedPaths.append("\(url.path) (permission denied; not permanently deleted)")
            case .failed(let message):
                failedPaths.append("\(url.path) (\(message))")
            }
        }

        // Sweep removed rows out (per-row transitions are attached in the
        // List above); plain assignment under Reduce Motion.
        if reduceMotion {
            appState.orphanedFiles.removeAll { removedURLs.contains($0) }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                appState.orphanedFiles.removeAll { removedURLs.contains($0) }
            }
        }
        selectedOrphans.subtract(removedURLs)

        if !failedPaths.isEmpty {
            let preview = failedPaths.prefix(3).joined(separator: "\n")
            let suffix = failedPaths.count > 3 ? "\n…" : ""
            removalErrorMessage = "\(failedPaths.count) item(s) could not be moved to Trash.\n\n\(preview)\(suffix)"
        }
    }

    private func revealInFinder(_ url: URL) {
        // activateFileViewerSelecting handles sandbox-bookmarked paths and
        // missing files better than selectFile(_:inFileViewerRootedAtPath:),
        // which silently no-ops when the path is unreachable from Finder's
        // current scope. If the target itself was removed since the scan,
        // fall back to opening the enclosing directory so the user lands
        // somewhere useful instead of nothing happening.
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let parent = url.deletingLastPathComponent()
        if fm.fileExists(atPath: parent.path) {
            NSWorkspace.shared.open(parent)
        }
    }

    private func removeSingleOrphan(_ url: URL) async {
        let previous = selectedOrphans
        selectedOrphans = [url]
        await removeSelectedOrphans()
        selectedOrphans = previous.subtracting([url])
    }

}

// MARK: - Row

/// Orphan row extracted to its own struct so hover highlight and the springy
/// checkbox are per-row state.
private struct OrphanRowView: View {
    let fileURL: URL
    @Binding var isSelected: Bool
    let fileSize: Int64?
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    let onIgnore: () -> Void
    let onTrash: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Toggle(isOn: $isSelected) {
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                    .resizable()
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(fileURL.lastPathComponent)
                        .lineLimit(1)
                    Text(fileURL.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if let size = fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(AnimatedCheckboxStyle(tint: Tint.pink))
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") { onReveal() }
            Button("Copy Path") { onCopyPath() }
            Divider()
            Button("Always Ignore") { onIgnore() }
            Button("Move to Trash", role: .destructive) { onTrash() }
        }
    }
}
