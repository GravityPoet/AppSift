import SwiftUI

struct SystemMaintenanceView: View {
    @ObservedObject var center: SystemMaintenanceCenter
    @State private var confirmsDNSRefresh = false
    @State private var confirmsSpotlightRebuild = false
    @State private var confirmsMailRepair = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let message = center.actionMessage {
                    actionNotice(message)
                }
                dnsCard
                spotlightCard
                mailCard
            }
            .padding(20)
        }
        .navigationTitle("System Maintenance")
        .toolbar {
            Button { center.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(center.isRefreshing)
        }
        .onAppear { center.refresh() }
        .confirmationDialog(
            "Refresh DNS Cache?",
            isPresented: $confirmsDNSRefresh,
            titleVisibility: .visible
        ) {
            Button("Refresh DNS Cache") { center.flushDNSCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears cached DNS answers and restarts the macOS DNS responder. Network requests may briefly pause.")
        }
        .confirmationDialog(
            "Rebuild Spotlight Index?",
            isPresented: $confirmsSpotlightRebuild,
            titleVisibility: .visible
        ) {
            Button("Start Rebuild") { center.rebuildSelectedSpotlightIndex() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Spotlight search results on the selected disk may be incomplete while macOS rebuilds the index. Use this only to repair search problems.")
        }
        .confirmationDialog(
            "Repair the Mail Index?",
            isPresented: $confirmsMailRepair,
            titleVisibility: .visible
        ) {
            Button("Repair Mail Index") { center.repairMailIndex() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("AppSift will ask Mail to quit, move only its Envelope Index files to the Trash, then reopen Mail if it was running. Mail may take time to rebuild search data.")
        }
        .alert("System Maintenance", isPresented: Binding(
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
            IconTile(systemName: "wrench.and.screwdriver.fill", tint: Tint.blue, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("System Maintenance")
                    .font(.title2.weight(.semibold))
                Text("Targeted repair tools for specific macOS problems — not routine performance boosters.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if center.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var dnsCard: some View {
        maintenanceCard(
            icon: "network",
            tint: Tint.cyan,
            title: "DNS Cache",
            description: "Refresh cached domain-name answers when websites resolve incorrectly after a network or DNS change."
        ) {
            Button {
                confirmsDNSRefresh = true
            } label: {
                if center.isRunningDNS {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh DNS Cache", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(center.isRunningDNS)
        }
    }

    private var spotlightCard: some View {
        maintenanceCard(
            icon: "magnifyingglass.circle.fill",
            tint: Tint.purple,
            title: "Spotlight Index",
            description: "Rebuild one mounted disk when Spotlight search results are missing or stale."
        ) {
            VStack(alignment: .trailing, spacing: 8) {
                if center.spotlightVolumes.isEmpty {
                    Text("No supported mounted disks found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Disk", selection: $center.selectedSpotlightVolumeID) {
                        ForEach(center.spotlightVolumes) { volume in
                            Text("\(volume.name) — \(spotlightStateLabel(volume.indexState))")
                                .tag(Optional(volume.id))
                        }
                    }
                    .frame(maxWidth: 310)

                    Button {
                        confirmsSpotlightRebuild = true
                    } label: {
                        if center.isRunningSpotlight {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Rebuild Selected Index", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        center.selectedSpotlightVolumeID == nil
                            || center.isRunningSpotlight
                            || selectedSpotlightVolume?.isReadOnly == true
                    )
                }
            }
        }
    }

    private var mailCard: some View {
        maintenanceCard(
            icon: "envelope.badge.fill",
            tint: Tint.orange,
            title: "Mail Search Index",
            description: "Recreate Mail's local Envelope Index when message search is incomplete or broken. Messages and attachments are not deleted."
        ) {
            VStack(alignment: .trailing, spacing: 8) {
                if center.mailIndex.permissionDenied {
                    Label("Full Disk Access may be required", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(Tint.orange)
                } else if center.mailIndex.files.isEmpty {
                    Text("No repairable Mail index files found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        String(
                            format: String(localized: "%lld index files · %@"),
                            Int64(center.mailIndex.files.count),
                            ByteCountFormatter.string(
                                fromByteCount: center.mailIndex.totalSize,
                                countStyle: .file
                            )
                        )
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    Button {
                        confirmsMailRepair = true
                    } label: {
                        if center.isRepairingMail {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Repair Mail Index", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(center.isRepairingMail)
                }

                if let record = center.latestUndoableMailRecord {
                    Button("Restore Previous Mail Index") {
                        center.undoMailRepair(record)
                    }
                    .buttonStyle(.bordered)
                    .disabled(center.isRepairingMail)
                }
            }
        }
    }

    private func maintenanceCard<Actions: View>(
        icon: String,
        tint: Color,
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        CardSurface(padding: 16) {
            HStack(alignment: .center, spacing: 14) {
                IconTile(systemName: icon, tint: tint, size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 20)
                actions()
            }
        }
    }

    private func actionNotice(_ message: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Tint.green)
            Text(message)
                .font(.subheadline)
            Spacer()
            Button {
                center.actionMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Tint.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var selectedSpotlightVolume: SpotlightVolume? {
        center.selectedSpotlightVolumeID.flatMap { id in
            center.spotlightVolumes.first { $0.id == id }
        }
    }

    private func spotlightStateLabel(_ state: SpotlightIndexState) -> String {
        switch state {
        case .enabled: return String(localized: "Indexing enabled")
        case .disabled: return String(localized: "Indexing disabled")
        case .unavailable: return String(localized: "Unavailable")
        case .unknown: return String(localized: "Status unknown")
        }
    }
}
