import XCTest

@MainActor
final class AppSiftAccessibilityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = configuredApplication(appearance: "light")
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10),
            "AppSift did not reach the foreground for accessibility QA."
        )
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 10),
            "AppSift did not expose its main window."
        )
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testMainWindowVoiceOverHierarchyActionsAndLightContrast() throws {
        guard #available(macOS 14.0, *) else {
            throw XCTSkip("Automated accessibility audits require macOS 14 or newer.")
        }
        try app.performAccessibilityAudit(
            for: [
                .sufficientElementDescription,
                .contrast,
                .elementDetection,
                .parentChild,
                .action
            ]
        )
    }

    func testFeatureNavigationUsesNativeAccessibleButtons() throws {
        let featureLabels = [
            "Browser Privacy",
            "Space Lens",
            "Duplicate Files",
            "Similar Images",
            "iPhone & iPad Backups",
            "Downloads by Source",
            "System Maintenance",
            "System Residue"
        ]
        let sidebar = app.scrollViews["main.sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 3))

        for label in featureLabels {
            let button = app.buttons[label].firstMatch
            for _ in 0..<5 where !button.exists {
                sidebar.swipeUp()
            }
            XCTAssertTrue(
                button.waitForExistence(timeout: 3),
                "\(label) must be exposed as a native button for VoiceOver and Full Keyboard Access."
            )
            XCTAssertFalse(button.label.isEmpty)
        }
    }

    func testMainWindowDarkAppearanceContrast() throws {
        guard #available(macOS 14.0, *) else {
            throw XCTSkip("Automated accessibility audits require macOS 14 or newer.")
        }
        app.terminate()
        app = configuredApplication(appearance: "dark")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        try app.performAccessibilityAudit(for: .contrast)
    }

    private func configuredApplication(appearance: String) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "-AppSift.OnboardingComplete", "YES",
            "-AppSift.Appearance", appearance,
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-NSQuitAlwaysKeepsWindows", "NO"
        ]
        return application
    }
}
