import AppKit
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Owns the optional menu-bar status item. Nil until the monitor is enabled.
    private var menuBarController: MenuBarController?

    /// Normally AppSift quits when its window closes. When the menu-bar system
    /// monitor is enabled the app stays resident so the meters keep updating in
    /// the menu bar. The opt-in Trash watcher also needs a resident process so
    /// it can notice apps moved there after the main window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let keepsMenuBarMonitor = UserDefaults.standard.bool(
            forKey: "settings.general.menuBarMonitor"
        )
        let keepsTrashWatcher = UserDefaults.standard.bool(
            forKey: TrashAppWatcher.settingsKey
        )
        return !keepsMenuBarMonitor && !keepsTrashWatcher
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false

        // Install the menu-bar monitor if the user has it enabled. Never under
        // XCTest — the status-item machinery would stall the test-host run loop.
        if NSClassFromString("XCTestCase") == nil {
            syncMenuBarMonitor()
            configureTrashAppNotifications()
            syncTrashAppWatcher()
            NotificationCenter.default.addObserver(
                self, selector: #selector(syncMenuBarMonitor),
                name: .appSiftMenuBarMonitorChanged, object: nil
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(trashAppWatcherSettingChanged(_:)),
                name: .appSiftTrashAppWatcherChanged, object: nil
            )
        }
        // Touch TCC-protected paths so macOS registers AppSift in the
        // Full Disk Access pane on first launch (fixes issue #75).
        FullDiskAccessManager.shared.triggerRegistration()
        // Register the Finder Services provider so uninstall/reset actions
        // appear when an .app bundle is right-clicked.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            WindowOpener.shared.open?("main")
        }
        return true
    }

    /// Finder Services entry point. Declared in Info.plist as NSMessage
    /// `uninstallApp`; receives the right-clicked .app via the pasteboard and
    /// hands it to AppState through a notification. Brings AppSift forward so
    /// the user lands on the uninstall scan.
    @objc func uninstallApp(_ pboard: NSPasteboard,
                            userData: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        handleAppService(
            pboard,
            action: .uninstall,
            error: error
        )
    }

    /// Finder Services entry point for the narrower, recoverable App Reset.
    @objc func resetApp(_ pboard: NSPasteboard,
                        userData: String?,
                        error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        handleAppService(
            pboard,
            action: .reset,
            error: error
        )
    }

    private func handleAppService(
        _ pboard: NSPasteboard,
        action: ExternalAppAction,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard let appURL = urls.first(where: { $0.pathExtension == "app" }) else {
            error?.pointee = "Select an application (.app)." as NSString
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let request = ExternalAppRequest(path: appURL.path, action: action)
        ExternalAppRequestBuffer.pending = request
        NotificationCenter.default.post(
            name: .appSiftExternalAppAction,
            object: nil,
            userInfo: [
                "path": request.path,
                "action": request.action.rawValue,
            ]
        )
    }

    /// Create or tear down the menu-bar status item to match the current
    /// Settings toggle. Posted to whenever the toggle flips so it takes effect
    /// without a relaunch.
    @objc func syncMenuBarMonitor() {
        let enabled = UserDefaults.standard.bool(forKey: "settings.general.menuBarMonitor")
        if enabled, menuBarController == nil {
            menuBarController = MenuBarController()
        } else if !enabled, let controller = menuBarController {
            controller.teardown()
            menuBarController = nil
        }
    }

    @objc private func trashAppWatcherSettingChanged(_ notification: Notification) {
        syncTrashAppWatcher()
        if UserDefaults.standard.bool(forKey: TrashAppWatcher.settingsKey) {
            requestTrashAppNotificationAuthorizationIfNeeded()
        }
    }

    private func syncTrashAppWatcher() {
        guard UserDefaults.standard.bool(forKey: TrashAppWatcher.settingsKey) else {
            TrashAppWatcher.shared.stop()
            return
        }

        TrashAppWatcher.shared.start { [weak self] candidates in
            self?.handleDetectedTrashApps(candidates)
        }
    }

    private func configureTrashAppNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reviewAction = UNNotificationAction(
            identifier: TrashAppNotificationContract.reviewActionIdentifier,
            title: String(localized: "Review Leftovers"),
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: TrashAppNotificationContract.categoryIdentifier,
            actions: [reviewAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    private func requestTrashAppNotificationAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    Logger.shared.log(
                        "Trash app notification permission failed: \(error.localizedDescription)",
                        level: .warning
                    )
                } else if !granted {
                    Logger.shared.log(
                        "Trash app notifications were declined; in-app review remains enabled",
                        level: .info
                    )
                }
            }
        }
    }

    private func handleDetectedTrashApps(_ candidates: [TrashAppCandidate]) {
        guard !candidates.isEmpty else { return }
        TrashAppRequestBuffer.mergeDetected(candidates)
        NotificationCenter.default.post(
            name: .appSiftTrashAppsDetected,
            object: candidates
        )

        let content = UNMutableNotificationContent()
        if candidates.count == 1, let candidate = candidates.first {
            content.title = String(localized: "App moved to Trash")
            content.body = String(
                format: String(localized: "%@ was moved to Trash. Review its leftover files?"),
                candidate.appName
            )
        } else {
            content.title = String(localized: "Apps moved to Trash")
            content.body = String(
                format: String(localized: "%lld apps were moved to Trash. Review their leftover files."),
                Int64(candidates.count)
            )
        }
        content.categoryIdentifier = TrashAppNotificationContract.categoryIdentifier
        content.sound = .default
        content.userInfo = [
            TrashAppNotificationContract.pathsUserInfoKey: candidates.map(\.path)
        ]

        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(
            withIdentifiers: [TrashAppNotificationContract.notificationIdentifier]
        )
        center.add(
            UNNotificationRequest(
                identifier: TrashAppNotificationContract.notificationIdentifier,
                content: content,
                trigger: nil
            )
        ) { error in
            if let error {
                Logger.shared.log(
                    "Could not post Trash app notification: \(error.localizedDescription)",
                    level: .warning
                )
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        guard actionIdentifier == UNNotificationDefaultActionIdentifier
                || actionIdentifier == TrashAppNotificationContract.reviewActionIdentifier else {
            completionHandler()
            return
        }
        let paths = response.notification.request.content.userInfo[
            TrashAppNotificationContract.pathsUserInfoKey
        ] as? [String] ?? []
        guard !paths.isEmpty else {
            completionHandler()
            return
        }

        Task { @MainActor [weak self] in
            self?.openTrashAppReview(paths: paths)
            completionHandler()
        }
    }

    private func openTrashAppReview(paths: [String]) {
        TrashAppRequestBuffer.reviewPaths = paths
        NSApp.activate(ignoringOtherApps: true)
        WindowOpener.shared.open?("main")
        NotificationCenter.default.post(
            name: .appSiftReviewTrashApps,
            object: paths
        )
    }
}

extension Notification.Name {
    /// Posted when the "Show system monitor in menu bar" Settings toggle flips,
    /// so AppDelegate can add/remove the status item live.
    static let appSiftMenuBarMonitorChanged = Notification.Name("AppSift.MenuBarMonitorChanged")
}

@main
struct AppSiftApp: App {
    // This property is intentionally declared first: Swift initializes stored
    // properties in declaration order, so legacy preferences and undo history
    // are copied before AppState's shared stores read their default locations.
    private let _legacyMigration: Void = LegacyProductMigration.performIfNeeded()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var theme = ThemeManager.shared
    @AppStorage("AppSift.OnboardingComplete") private var onboardingComplete = false

    init() {
        // Enter CLI mode only when the first arg is a known command. Xcode and
        // LaunchServices inject args like -NSDocumentRevisionsDebugMode and
        // -psn_<pid> that must not be interpreted as CLI commands.
        if let first = CommandLine.arguments.dropFirst().first,
           CLI.isKnownCommand(first) {
            CLI.run()
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            Group {
                if onboardingComplete {
                    MainWindow()
                        .environmentObject(appState)
                        .frame(minWidth: 900, minHeight: 600)
                } else {
                    OnboardingView(isComplete: $onboardingComplete)
                }
            }
            .environmentObject(theme)
            .preferredColorScheme(theme.appearance.colorScheme)
            // Record the openWindow action so the menu-bar popover can reopen
            // this window after it's been closed (the popover lives outside the
            // scene graph and can't use openWindow itself).
            .background(WindowOpenerCapture())
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1000, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .textEditing) {
                Divider()
                Menu("Appearance") {
                    ForEach(AppearanceMode.allCases) { mode in
                        Button {
                            theme.appearance = mode
                        } label: {
                            Label {
                                Text(LocalizedStringKey(mode.label))
                            } icon: {
                                Image(systemName: theme.appearance == mode ? "checkmark" : mode.icon)
                            }
                        }
                    }
                }
            }
            CommandMenu("Updates") {
                Button("Check for Updates") {
                    UpdateService.shared.checkForUpdates()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }

        // The opt-in menu-bar system monitor is an AppKit NSStatusItem managed
        // by AppDelegate/MenuBarController rather than a SwiftUI MenuBarExtra:
        // a conditional `.window`-style MenuBarExtra fails to type-check, and an
        // unconditional one sets up status-item machinery that hangs the XCTest
        // host. The AppKit controller is only created when enabled and never
        // under tests, sidestepping both problems.
    }
}
