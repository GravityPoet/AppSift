import AppKit
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            CleaningSettingsView()
                .tabItem { Label("Cleaning", systemImage: "trash") }
            ScheduleSettingsView()
                .tabItem { Label("Schedule", systemImage: "clock") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 430)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var trashAppWatcher = TrashAppWatcher.shared
    @AppStorage("settings.general.launchAtLogin") private var launchAtLogin = false
    @AppStorage(SearchSensitivity.defaultsKey) private var sensitivity: SearchSensitivity = .enhanced
    @AppStorage("settings.general.confirmBeforeDelete") private var confirmBeforeDelete = true
    @AppStorage("settings.general.menuBarMonitor") private var menuBarMonitor = false
    @AppStorage(TrashAppWatcher.settingsKey) private var watchTrashApps = false
    @AppStorage(Haptics.soundEffectsKey) private var soundEffects = true
    @AppStorage(AppLanguage.preferenceKey) private var appLanguageRaw = AppLanguage.current.rawValue
    @State private var languageNeedsRelaunch = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch AppSift at login", isOn: launchAtLoginBinding)
            }

            Section("Appearance") {
                Picker("Appearance", selection: appearanceBinding) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.label)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text("Choose how AppSift follows light and dark appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("App Scanning") {
                Picker("Search sensitivity", selection: $sensitivity) {
                    ForEach(SearchSensitivity.allCases) { level in
                        VStack(alignment: .leading) {
                            Text(LocalizedStringKey(level.rawValue))
                            Text(LocalizedStringKey(level.description))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Trash Monitoring") {
                Toggle("Watch for apps moved to Trash", isOn: trashAppWatcherBinding)
                Text("Detect newly added apps in your Trash and offer a leftover review. AppSift never deletes automatically. Enable Launch at login to monitor every session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if watchTrashApps && trashAppWatcher.status == .retrying {
                    Label(
                        "Trash monitoring is temporarily unavailable. AppSift will retry automatically.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(Tint.orange)
                }
            }

            Section("Language") {
                Picker("Language", selection: appLanguageBinding) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.displayName)).tag(language)
                    }
                }

                if languageNeedsRelaunch {
                    Text("Restart AppSift to apply the selected language.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity.combined(with: .move(edge: .top)))

                    Button("Relaunch Now") {
                        relaunchApp()
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Section("System Monitor") {
                Toggle("Show system monitor in menu bar", isOn: menuBarMonitorBinding)
                Text("Live CPU, memory, and disk meters in the menu bar. AppSift keeps running in the background while this is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sound") {
                Toggle("Play sound effects", isOn: $soundEffects)
            }

            Section("Safety") {
                Toggle("Confirm before deleting files", isOn: $confirmBeforeDelete)
            }
        }
        .formStyle(.grouped)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                   value: languageNeedsRelaunch)
    }

    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(
            get: { theme.appearance },
            set: { theme.appearance = $0 }
        )
    }

    private var menuBarMonitorBinding: Binding<Bool> {
        Binding(
            get: { menuBarMonitor },
            set: { newValue in
                menuBarMonitor = newValue
                // Tell AppDelegate to add/remove the status item without relaunch.
                NotificationCenter.default.post(name: .appSiftMenuBarMonitorChanged, object: nil)
            }
        )
    }

    private var trashAppWatcherBinding: Binding<Bool> {
        Binding(
            get: { watchTrashApps },
            set: { newValue in
                watchTrashApps = newValue
                NotificationCenter.default.post(
                    name: .appSiftTrashAppWatcherChanged,
                    object: nil
                )
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                launchAtLogin = newValue
                toggleLaunchAtLogin(newValue)
            }
        )
    }

    private var appLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: appLanguageRaw) ?? .system },
            set: { newValue in
                appLanguageRaw = newValue.rawValue
                applyLanguage(newValue)
            }
        )
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Logger.shared.log("Failed to \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)", level: .error)
            launchAtLogin = !enabled
        }
    }

    private func applyLanguage(_ language: AppLanguage) {
        AppLanguagePreferences.apply(language)
        languageNeedsRelaunch = true
    }

    private func relaunchApp() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            NSApp.terminate(nil)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]

        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            Logger.shared.log("Failed to relaunch AppSift: \(error.localizedDescription)", level: .error)
        }
    }
}

// MARK: - Cleaning

struct CleaningSettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("settings.cleaning.skipHiddenFiles") private var skipHiddenFiles = true
    @AppStorage("settings.cleaning.largeFileThreshold") private var largeFileThresholdMB: Int = 100
    @AppStorage("settings.cleaning.oldFileMonths") private var oldFileMonths: Int = 12

    private static let excludedFoldersKey = "settings.cleaning.largeFileExcludedFolders"
    @State private var excludedFolders: [String] = []

    var body: some View {
        Form {
            Section("File Discovery") {
                Toggle("Skip hidden files during scan", isOn: $skipHiddenFiles)
            }

            Section("Large Files") {
                Stepper(
                    String(format: String(localized: "Minimum size: %lld MB"), Int64(largeFileThresholdMB)),
                    value: $largeFileThresholdMB,
                    in: 10...1000,
                    step: 10
                )
                Stepper(
                    String(format: String(localized: "Files older than: %lld months"), Int64(oldFileMonths)),
                    value: $oldFileMonths,
                    in: 1...60
                )
            }

            Section("Excluded Folders") {
                if excludedFolders.isEmpty {
                    Text("Files inside these folders are skipped from the Large & Old Files scan (Downloads, Documents, Desktop).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(excludedFolders, id: \.self) { folder in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text((folder as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(folder)
                            Spacer()
                            Button {
                                removeExcludedFolder(folder)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(String(localized: "Remove from exclusions"))
                        }
                    }
                }
                Button("Add Folder…") { addExcludedFolder() }
            }

            Section("Orphan Finder") {
                HStack {
                    // Read the live count directly (it's a UserDefaults-backed
                    // computed property on AppState) so it stays correct when
                    // orphans are ignored from the Orphans view while this tab
                    // is open. AppState fires objectWillChange on both ignore
                    // (via @Published orphanedFiles) and clear, re-rendering this.
                    Text(String(format: String(localized: "Ignored orphans: %lld"), Int64(appState.ignoredOrphanCount)))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget Ignored") {
                        appState.clearIgnoredOrphans()
                    }
                    .disabled(appState.ignoredOrphanCount == 0)
                }
                Text("Ignored files won't appear in future orphan scans.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            excludedFolders = UserDefaults.standard.stringArray(forKey: Self.excludedFoldersKey) ?? []
        }
    }

    private func persistExcludedFolders() {
        UserDefaults.standard.set(excludedFolders, forKey: Self.excludedFoldersKey)
    }

    private func addExcludedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add Folder…")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !excludedFolders.contains(url.path) {
            excludedFolders.append(url.path)
        }
        persistExcludedFolders()
    }

    private func removeExcludedFolder(_ folder: String) {
        excludedFolders.removeAll { $0 == folder }
        persistExcludedFolders()
    }
}

// MARK: - Schedule

struct ScheduleSettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section("Automatic Scanning") {
                Toggle("Enable scheduled scanning", isOn: $appState.scheduler.config.isEnabled)

                if appState.scheduler.config.isEnabled {
                    Group {
                        Picker("Scan interval", selection: $appState.scheduler.config.interval) {
                            ForEach(ScheduleInterval.allCases) { interval in
                                Text(LocalizedStringKey(interval.rawValue)).tag(interval)
                            }
                        }

                        Toggle("Auto-clean after scan", isOn: $appState.scheduler.config.autoClean)
                        Toggle("Notify on completion", isOn: $appState.scheduler.config.notifyOnCompletion)

                        HStack {
                            Text("Last run")
                            Spacer()
                            Text(appState.scheduler.config.formattedLastRun)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .formStyle(.grouped)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                   value: appState.scheduler.config.isEnabled)
    }
}

// MARK: - About

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                HStack {
                    if let appIcon = NSImage(named: "AppIcon") {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ProductIdentity.name)
                            .font(.title2.bold())
                        Text(
                            String(
                                format: String(localized: "Version %@"),
                                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                            )
                        )
                            .foregroundStyle(.secondary)
                        Text(ProductIdentity.subtitle)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }

            Section {
                Link("GitHub Repository", destination: ProductIdentity.repositoryURL)
                Link(
                    "Report an Issue",
                    destination: ProductIdentity.repositoryURL.appendingPathComponent("issues")
                )
            }

            Section {
                Text("MIT License")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
