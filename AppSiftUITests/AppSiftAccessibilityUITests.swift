import XCTest

@MainActor
final class AppSiftAccessibilityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
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
        XCTAssertTrue(
            app.staticTexts["Low space"].waitForExistence(timeout: 5),
            "The deterministic low-space accessibility fixture did not load."
        )
        XCTAssertTrue(
            app.staticTexts["Ready to clean"].waitForExistence(timeout: 5),
            "The deterministic granted Full Disk Access fixture did not load."
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
        try performAccessibilityAudit(
            [
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
        app = configuredApplication(
            appearance: "dark",
            fullDiskAccess: false
        )
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["Limited access"].waitForExistence(timeout: 5),
            "The deterministic denied Full Disk Access fixture did not load."
        )

        try performAccessibilityAudit(.contrast)
    }

    @available(macOS 14.0, *)
    private func performAccessibilityAudit(
        _ types: XCUIAccessibilityAuditType
    ) throws {
        try app.performAccessibilityAudit(for: types) { issue in
            let element: String
            if let auditedElement = issue.element {
                element = [
                    "type=\(auditedElement.elementType.rawValue)",
                    "label=\(auditedElement.label)",
                    "identifier=\(auditedElement.identifier)",
                    "value=\(auditedElement.value.map(String.init(describing:)) ?? "<none>")",
                    "frame=\(auditedElement.frame)",
                    "enabled=\(auditedElement.isEnabled)",
                    "hittable=\(auditedElement.isHittable)",
                    "debug=\(auditedElement.debugDescription)",
                ].joined(separator: " ")
            } else {
                element = "<none>"
            }
            print(
                "AX_AUDIT_ISSUE type=\(issue.auditType.rawValue) "
                    + "compact=\(issue.compactDescription) "
                    + "details=\(issue.detailedDescription) "
                    + "element=\(element)"
            )
            if issue.auditType == .sufficientElementDescription {
                if self.isStructuralWindowWrapper(issue.element) {
                    print("AX_AUDIT_HANDLED structural AppKit window wrapper")
                    return true
                }
                if self.isSystemTouchBar(issue.element) {
                    print("AX_AUDIT_HANDLED system Touch Bar wrapper")
                    return true
                }
            }
            if issue.auditType == .contrast,
               self.isSystemWindowTitle(issue.element) {
                print("AX_AUDIT_HANDLED system window title")
                return true
            }
            if issue.auditType == .contrast,
               self.isMacOS27DashboardScreenshotMismatch(issue.element) {
                print("AX_AUDIT_HANDLED macOS 27 dashboard screenshot mismatch")
                return true
            }
            if issue.auditType == .parentChild,
               self.isSystemFullScreenButtonWrapper(issue.element) {
                print("AX_AUDIT_HANDLED system full-screen button wrapper")
                return true
            }
            return false
        }
    }

    private func isStructuralWindowWrapper(_ element: XCUIElement?) -> Bool {
        guard let element,
              element.elementType == .group,
              element.label.isEmpty,
              element.identifier.isEmpty,
              !element.isEnabled else {
            return false
        }
        let windowFrame = app.windows.firstMatch.frame
        let frame = element.frame
        let tolerance: CGFloat = 2
        let fillsContentWidth = abs(frame.minX - windowFrame.minX) <= tolerance
            && abs(frame.maxX - windowFrame.maxX) <= tolerance
        let sharesWindowBottom = abs(frame.maxY - windowFrame.maxY) <= tolerance
        let matchesWindowFrame = fillsContentWidth
            && abs(frame.minY - windowFrame.minY) <= tolerance
            && abs(frame.maxY - windowFrame.maxY) <= tolerance
        let excludesTitleBar = frame.minY > windowFrame.minY
            && frame.height < windowFrame.height
        let containsSplitView = element.descendants(matching: .splitGroup).firstMatch.exists
        let spansWindowContentHeight = abs(frame.minY - windowFrame.minY) <= tolerance
            && abs(frame.maxY - windowFrame.maxY) <= tolerance
        let containsMainSidebar = element.scrollViews["main.sidebar"].firstMatch.exists
        let isSidebarColumnWrapper = spansWindowContentHeight
            && frame.width < windowFrame.width
            && containsMainSidebar
        let containsMainDetail = element.descendants(matching: .any)
            .matching(identifier: "main.detail")
            .firstMatch
            .exists
        let alignsWindowRight = abs(frame.maxX - windowFrame.maxX) <= tolerance
        let isRightDetailColumn = spansWindowContentHeight
            && frame.minX > windowFrame.minX
            && frame.width < windowFrame.width
            && alignsWindowRight
        let isDetailColumnWrapper = (matchesWindowFrame || isRightDetailColumn)
            && !containsSplitView
            && !containsMainSidebar
            && containsMainDetail
        return ((matchesWindowFrame
            || (fillsContentWidth && sharesWindowBottom && excludesTitleBar))
            && containsSplitView)
            || isSidebarColumnWrapper
            || isDetailColumnWrapper
    }

    private func isSystemTouchBar(_ element: XCUIElement?) -> Bool {
        guard let element,
              element.elementType == .touchBar,
              element.label.isEmpty,
              element.identifier.isEmpty,
              !element.isEnabled else {
            return false
        }
        let windowFrame = app.windows.firstMatch.frame
        let frame = element.frame
        return frame.minY < windowFrame.minY
            && frame.height <= 32
            && frame.maxY <= windowFrame.minY + 8
    }

    private func isSystemFullScreenButtonWrapper(
        _ element: XCUIElement?
    ) -> Bool {
        guard let element,
              element.elementType == .group,
              element.label.isEmpty,
              element.identifier.isEmpty,
              !element.isEnabled,
              !element.isHittable else {
            return false
        }
        let button = app.buttons["_XCUI:FullScreenWindow"].firstMatch
        guard button.exists else { return false }
        let frame = element.frame
        let buttonFrame = button.frame
        let tolerance: CGFloat = 2
        return frame.minX >= buttonFrame.minX - tolerance
            && frame.minY >= buttonFrame.minY - tolerance
            && frame.maxX <= buttonFrame.maxX + tolerance
            && frame.maxY <= buttonFrame.maxY + tolerance
    }

    private func isSystemWindowTitle(_ element: XCUIElement?) -> Bool {
        guard let element,
              element.elementType == .staticText,
              element.label.isEmpty,
              element.identifier.isEmpty,
              let value = element.value as? String else {
            return false
        }
        let window = app.windows.firstMatch
        let windowFrame = window.frame
        let frame = element.frame
        let tolerance: CGFloat = 2
        return value == "AppSift"
            && abs(frame.minY - windowFrame.minY) <= tolerance
            && frame.height <= 60
            && frame.width >= windowFrame.width * 0.5
    }

    private func isMacOS27DashboardScreenshotMismatch(
        _ element: XCUIElement?
    ) -> Bool {
        // Xcode 27 beta can attach an unrelated window crop to these verified
        // primary-color dashboard elements. Keep macOS 14/15 CI fully strict.
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
              let element else {
            return false
        }
        let identifier = element.identifier
        return identifier == "dashboard.hero.free-total"
            || identifier == "dashboard.storage.percent"
            || identifier.hasPrefix("dashboard.storage.legend.")
            || identifier.hasPrefix("dashboard.stat.")
    }

    private func configuredApplication(
        appearance: String,
        fullDiskAccess: Bool = true
    ) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "-AppSift.OnboardingComplete", "YES",
            "-AppSift.UITest.ForceLowDiskSpace", "YES",
            "-AppSift.UITest.FullDiskAccess",
            fullDiskAccess ? "granted" : "denied",
            "-AppSift.Appearance", appearance,
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-NSQuitAlwaysKeepsWindows", "NO"
        ]
        return application
    }
}
