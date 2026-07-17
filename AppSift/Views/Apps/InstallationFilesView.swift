import SwiftUI

private enum InstallationFileFilter: String, CaseIterable, Identifiable {
    case all
    case diskImages
    case packages
    case xipArchives
    case applicationArchives

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .diskImages: return "DMG"
        case .packages: return "PKG / MPKG"
        case .xipArchives: return "XIP"
        case .applicationArchives: return "ZIP"
        }
    }

    func includes(_ item: InstallationFileItem) -> Bool {
        switch self {
        case .all: return true
        case .diskImages: return item.kind == .diskImage
        case .packages:
            return item.kind == .installerPackage
                || item.kind == .installerMetaPackage
        case .xipArchives: return item.kind == .xipArchive
        case .applicationArchives: return item.kind == .applicationArchive
        }
    }
}

struct InstallationFilesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var filter: InstallationFileFilter = .all
    @State private var showingMoveConfirmation = false

    private var filteredItems: [InstallationFileItem] {
        appState.installationFiles.filter { item in
            guard filter.includes(item) else { return false }
            guard !searchText.isEmpty else { return true }
            let query = searchText.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            let haystack = [
                item.name,
                item.url.path,
                item.kind.rawValue,
                item.quarantineOriginURL?.host,
                item.quarantineAgentName,
                item.signature.developerName,
                item.signature.teamIdentifier,
                item.relatedApplication?.name,
                item.relatedApplication?.bundleIdentifier,
                item.containedApplicationName,
            ]
            .compactMap { $0 }
            .joined(separator: " ")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            return haystack.contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if appState.isScanningInstallationFiles
                    && !appState.hasScannedInstallationFiles {
                    ProgressView(
                        LocalizedStringKey(
                            "Finding DMG, PKG, MPKG, XIP, and single-App ZIP files..."
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !appState.hasScannedInstallationFiles {
                    EmptyStateView(
                        "Installation Files",
                        systemImage: "shippingbox.fill",
                        description: "Find local DMG, PKG, MPKG, XIP, and single-App ZIP files with Spotlight, signature, quarantine, package-payload, and archive-content evidence.",
                        action: { appState.scanInstallationFiles() },
                        actionLabel: "Scan Installation Files",
                        tint: Tint.orange
                    )
                } else if appState.installationFiles.isEmpty {
                    EmptyStateView(
                        "No Installation Files Found",
                        systemImage: "checkmark.circle.fill",
                        description: "No evidence-backed DMG, PKG, MPKG, XIP, or single-App ZIP files were found on the indexed local data volume.",
                        action: { appState.scanInstallationFiles(force: true) },
                        actionLabel: "Scan Again",
                        tint: Tint.green
                    )
                } else {
                    results
                }
            }
        }
        .navigationTitle("Installation Files")
        .searchable(text: $searchText, prompt: "Search installation files")
        .toolbar {
            ToolbarItemGroup {
                if appState.isScanningInstallationFiles
                    || appState.isRemovingInstallationFiles {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    appState.scanInstallationFiles(force: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(
                    appState.isScanningInstallationFiles
                        || appState.isRemovingInstallationFiles
                )
            }
        }
        .onAppear {
            appState.scanInstallationFiles()
        }
        .confirmationDialog(
            "Move Installation Files to Trash?",
            isPresented: $showingMoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                appState.removeSelectedInstallationFiles()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                String(
                    format: String(
                        localized: "%lld selected files (%@) will move to the macOS Trash. AppSift records their exact original locations for Undo."
                    ),
                    Int64(appState.selectedInstallationFileIDs.count),
                    ByteCountFormatter.string(
                        fromByteCount: appState.selectedInstallationFileSize,
                        countStyle: .file
                    )
                )
            )
        }
        .alert("Installation File Action Failed", isPresented: Binding(
            get: { appState.installationFileActionError != nil },
            set: { if !$0 { appState.installationFileActionError = nil } }
        )) {
            Button("OK", role: .cancel) {
                appState.installationFileActionError = nil
            }
        } message: {
            Text(appState.installationFileActionError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(
                systemName: "shippingbox.fill",
                tint: Tint.orange,
                size: 34
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("Installation Files")
                    .font(.title2.weight(.semibold))
                Text("Find leftover installers without a private vendor database or unsafe image mounting.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Nothing is selected automatically. Removal is Trash-first, revalidated at click time, and locally undoable.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 16)
            if let date = appState.lastInstallationFileScanDate {
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

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                summary

                if let message = appState.installationFileActionMessage {
                    successNotice(message)
                }

                evidenceNotice

                if appState.installationFileScanWasTruncated
                    || appState.installationFileInaccessibleCount > 0 {
                    incompleteNotice
                }

                Picker("Filter", selection: $filter) {
                    ForEach(InstallationFileFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                selectionBar

                if filteredItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("No Matching Installation Files")
                            .font(.headline)
                        Text("Try another search or file-type filter.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else {
                    ForEach(filteredItems) { item in
                        InstallationFileRow(
                            item: item,
                            isSelected: appState.selectedInstallationFileIDs
                                .contains(item.id),
                            toggleSelection: {
                                appState.toggleInstallationFileSelection(item)
                            },
                            approveSelection: {
                                appState.approveManagedInstallationFileSelection(
                                    item
                                )
                            },
                            reveal: { appState.revealInstallationFile(item) }
                        )
                    }
                }
            }
            .padding(20)
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            StatusChip(
                label: String(
                    format: String(localized: "%lld files"),
                    Int64(appState.installationFiles.count)
                ),
                systemImage: "doc.on.doc.fill",
                tint: Tint.blue
            )
            StatusChip(
                label: ByteCountFormatter.string(
                    fromByteCount: appState.removableInstallationFileSize,
                    countStyle: .file
                ),
                systemImage: "trash.fill",
                tint: Tint.green
            )
            let protectedCount = appState.installationFiles.count {
                !$0.isRemovable
            } + appState.installationFileIgnoredCount
            StatusChip(
                label: String(
                    format: String(localized: "%lld protected or ignored"),
                    Int64(protectedCount)
                ),
                systemImage: "lock.shield.fill",
                tint: Tint.orange
            )
            Spacer()
        }
    }

    private var evidenceNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(Tint.green)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Evidence before cleanup")
                    .font(.subheadline.weight(.semibold))
                Text("AppSift validates the extension, Uniform Type, regular-file identity, ownership, volume, links, signature, quarantine source, and package payload where available. A PKG is linked to an installed app only when both its payload app name and installer Team ID match. A ZIP appears only when a bounded read-only listing proves one outer App bundle; AppSift never expands it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            Tint.green.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Tint.green.opacity(0.16), lineWidth: 0.5)
        )
    }

    private var incompleteNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tint.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Some Scan Results Were Incomplete")
                    .font(.caption.weight(.semibold))
                Text(
                    String(
                        format: String(
                            localized: "%lld candidates could not be inspected. Truncated: %@. AppSift shows verified results without guessing."
                        ),
                        Int64(appState.installationFileInaccessibleCount),
                        appState.installationFileScanWasTruncated
                            ? String(localized: "Yes")
                            : String(localized: "No")
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(
            Tint.orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            if appState.selectedInstallationFileIDs.isEmpty {
                Button("Select All Removable") {
                    appState.selectAllRemovableInstallationFiles()
                }
                .disabled(appState.isRemovingInstallationFiles)
            } else {
                Button("Clear Selection") {
                    appState.clearInstallationFileSelection()
                }
                .disabled(appState.isRemovingInstallationFiles)
            }
            Spacer()
            if !appState.selectedInstallationFileIDs.isEmpty {
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: appState.selectedInstallationFileSize,
                        countStyle: .file
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                Button("Move to Trash") {
                    showingMoveConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Tint.orange)
                .disabled(appState.isRemovingInstallationFiles)
            }
        }
        .frame(minHeight: 28)
    }

    private func successNotice(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Tint.green)
            Text(message)
                .font(.subheadline)
            Spacer()
            if appState.latestUndoableInstallationFileRecord != nil {
                Button("Undo") {
                    appState.undoLatestInstallationFileRemoval()
                }
                .disabled(appState.isRemovingInstallationFiles)
            }
            Button {
                appState.installationFileActionMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(12)
        .background(
            Tint.green.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}

private struct InstallationFileRow: View {
    let item: InstallationFileItem
    let isSelected: Bool
    let toggleSelection: () -> Void
    let approveSelection: () -> Void
    let reveal: () -> Void
    @State private var showingManagedSelectionReview = false

    var body: some View {
        CardSurface(padding: 14, elevation: .flat) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    if isSelected || item.isRemovable {
                        toggleSelection()
                    } else if item.allowsExplicitSelection {
                        showingManagedSelectionReview = true
                    }
                } label: {
                    Image(systemName: checkboxImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(selectionTint)
                }
                .buttonStyle(.plain)
                .disabled(!item.isRemovable && !item.allowsExplicitSelection)
                .help(selectionHelp)
                .confirmationDialog(
                    "Select App-Managed Installer?",
                    isPresented: $showingManagedSelectionReview,
                    titleVisibility: .visible
                ) {
                    Button("Select Anyway") {
                        approveSelection()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This file is inside an app-managed Library folder. Its app may still need it or recreate it. AppSift will still revalidate it and move it to Trash only after the final confirmation.")
                }

                IconTile(
                    systemName: kindIcon,
                    tint: kindTint,
                    size: 32
                )

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        StatusChip(
                            label: kindTitle,
                            systemImage: kindIcon,
                            tint: kindTint
                        )
                        if !item.isRemovable {
                            StatusChip(
                                label: protectionTitle,
                                systemImage: "lock.fill",
                                tint: Tint.orange
                            )
                        }
                    }

                    Text(item.url.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 10) {
                        Label(signatureTitle, systemImage: "checkmark.seal")
                        if let team = item.signature.teamIdentifier {
                            Label(team, systemImage: "person.badge.key")
                        }
                        if item.signature.notarizationStatus == .notarized {
                            Label("Notarized", systemImage: "checkmark.shield.fill")
                                .foregroundStyle(Tint.green)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    if let source = sourceSummary {
                        Label(source, systemImage: "arrow.down.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let app = item.relatedApplication {
                        Label(
                            String(
                                format: String(localized: "Verified package for %@"),
                                app.name
                            ),
                            systemImage: "link.badge.plus"
                        )
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Tint.blue)
                    }

                    if let applicationName = item.containedApplicationName {
                        Label(
                            String(
                                format: String(localized: "Contains %@.app"),
                                applicationName
                            ),
                            systemImage: "archivebox.badge"
                        )
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Tint.cyan)
                    }

                    HStack(spacing: 5) {
                        ForEach(
                            Array(item.evidence.sorted {
                                $0.rawValue < $1.rawValue
                            }.prefix(5)),
                            id: \.self
                        ) { evidence in
                            Text(evidenceTitle(evidence))
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Color.primary.opacity(0.05),
                                    in: Capsule()
                                )
                        }
                        if item.evidence.count > 5 {
                            Text("+\(item.evidence.count - 5)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 8) {
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: item.size,
                            countStyle: .file
                        )
                    )
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    if let date = item.modifiedAt {
                        Text(date, format: .dateTime.year().month(.abbreviated).day())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button("Reveal", action: reveal)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private var checkboxImage: String {
        isSelected ? "checkmark.circle.fill" : "circle"
    }

    private var selectionTint: Color {
        if isSelected { return Tint.blue }
        if item.isRemovable { return Color.secondary }
        if item.allowsExplicitSelection { return Tint.orange }
        return Color.secondary.opacity(0.45)
    }

    private var selectionHelp: LocalizedStringKey {
        if item.isRemovable { return "Select for Trash" }
        if item.allowsExplicitSelection { return "Review before selection" }
        return "Protected result"
    }

    private var kindTitle: String {
        switch item.kind {
        case .diskImage: return "DMG"
        case .installerPackage: return "PKG"
        case .installerMetaPackage: return "MPKG"
        case .xipArchive: return "XIP"
        case .applicationArchive: return "ZIP"
        }
    }

    private var kindIcon: String {
        switch item.kind {
        case .diskImage: return "externaldrive.fill"
        case .installerPackage: return "shippingbox.fill"
        case .installerMetaPackage: return "shippingbox.fill"
        case .xipArchive: return "archivebox.fill"
        case .applicationArchive: return "archivebox.fill"
        }
    }

    private var kindTint: Color {
        switch item.kind {
        case .diskImage: return Tint.blue
        case .installerPackage: return Tint.orange
        case .installerMetaPackage: return Tint.orange
        case .xipArchive: return Tint.purple
        case .applicationArchive: return Tint.cyan
        }
    }

    private var signatureTitle: String {
        switch item.signature.status {
        case .developerSigned: return String(localized: "Developer signed")
        case .appleSigned: return String(localized: "Apple signed")
        case .locallySigned: return String(localized: "Locally signed")
        case .adHoc: return String(localized: "Ad hoc signed")
        case .unsigned: return String(localized: "Unsigned")
        case .invalid: return String(localized: "Invalid signature")
        case .unknown:
            if item.kind == .applicationArchive {
                return String(localized: "Archive not expanded")
            }
            return String(localized: "Signature unknown")
        }
    }

    private var protectionTitle: String {
        guard case .protected(let reason) = item.removalEligibility else {
            return String(localized: "Removable")
        }
        switch reason {
        case .applicationManagedCache:
            return String(localized: "App-managed")
        case .differentDataVolume:
            return String(localized: "Other volume")
        case .differentOwner:
            return String(localized: "Other owner")
        case .hardLinked:
            return String(localized: "Hard linked")
        case .outsideUserHome:
            return String(localized: "Outside home")
        }
    }

    private var sourceSummary: String? {
        if let origin = item.quarantineOriginURL {
            return origin.host ?? origin.absoluteString
        }
        return item.quarantineAgentName
    }

    private func evidenceTitle(_ evidence: InstallationFileEvidence) -> String {
        switch evidence {
        case .spotlightMetadata: return String(localized: "Spotlight")
        case .filenameExtension: return String(localized: "Extension")
        case .uniformType: return String(localized: "Uniform Type")
        case .regularFile: return String(localized: "Regular file")
        case .quarantineOrigin: return String(localized: "Download source")
        case .quarantineAgent: return String(localized: "Download agent")
        case .codeSignature: return String(localized: "Signature")
        case .developerTeam: return String(localized: "Team ID")
        case .notarization: return String(localized: "Notarization")
        case .installerPackageSignature: return String(localized: "PKG signature")
        case .installerPackagePayload: return String(localized: "PKG payload")
        case .applicationArchiveContents:
            return String(localized: "Single App archive")
        case .installedApplicationNameMatch: return String(localized: "App name match")
        case .installedApplicationTeamMatch: return String(localized: "Team match")
        }
    }
}
