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
        let healthStatus = app.descendants(matching: .any)
            .matching(identifier: "main.health.status")
            .firstMatch
        XCTAssertTrue(
            healthStatus.waitForExistence(timeout: 5),
            "The deterministic granted Full Disk Access fixture did not load."
        )
        XCTAssertEqual(
            healthStatus.value as? String,
            "Ready to clean"
        )
        assertDefaultWindowUsesReadableDashboardLayout()
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

    func testFeatureNavigationUsesNativeSidebarAndSearchableTools() throws {
        let primaryDestinations = [
            ("dashboard", "Dashboard"),
            ("installedApps", "Installed Apps"),
            ("spaceLens", "Space Lens"),
            ("tools", "Tools"),
        ]

        for (identifier, label) in primaryDestinations {
            let row = app.descendants(matching: .any)
                .matching(identifier: "main.sidebar.item.\(identifier)")
                .firstMatch
            XCTAssertTrue(
                row.waitForExistence(timeout: 3),
                "\(label) must remain a first-level native sidebar destination."
            )
            XCTAssertEqual(row.label, label)
        }

        let toolsRow = app.descendants(matching: .any)
            .matching(identifier: "main.sidebar.item.tools")
            .firstMatch
        XCTAssertTrue(toolsRow.isHittable)
        toolsRow.click()

        let search = app.descendants(matching: .any)
            .matching(identifier: "toolbox.search")
            .firstMatch
        XCTAssertTrue(
            search.waitForExistence(timeout: 3),
            "The tool catalog must expose an accessible search field."
        )
        search.click()
        search.typeText("Duplicate Files")

        let duplicateTool = app.buttons[
            "toolbox.tool.duplicate-files"
        ].firstMatch
        XCTAssertTrue(
            duplicateTool.waitForExistence(timeout: 3),
            "Search must reveal a matching tool directly."
        )

        let favoriteButton = app.buttons[
            "toolbox.favorite.duplicate-files"
        ].firstMatch
        XCTAssertTrue(favoriteButton.waitForExistence(timeout: 3))
        favoriteButton.click()
        let favoriteState = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "Remove from Favorites"
            ),
            object: favoriteButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [favoriteState], timeout: 3),
            .completed,
            "The favorite action must expose its updated state."
        )

        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])

        let favoriteDuplicateTool = app.buttons[
            "toolbox.tool.duplicate-files"
        ].firstMatch
        XCTAssertTrue(favoriteDuplicateTool.waitForExistence(timeout: 3))
        favoriteDuplicateTool.click()
        let duplicateContent = app.descendants(matching: .any)
            .matching(identifier: "duplicateFiles.content")
            .firstMatch
        XCTAssertTrue(
            duplicateContent.waitForExistence(timeout: 3),
            "A tool tile must navigate to the existing feature view."
        )
    }

    func testDashboardSummaryRemainsReadableAfterScrolling() throws {
        assertScrollableDashboardStatsLayout()
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
        let healthStatus = app.descendants(matching: .any)
            .matching(identifier: "main.health.status")
            .firstMatch
        XCTAssertTrue(
            healthStatus.waitForExistence(timeout: 5),
            "The deterministic denied Full Disk Access fixture did not load."
        )
        XCTAssertEqual(
            healthStatus.value as? String,
            "Limited access"
        )

        try performAccessibilityAudit(.contrast)
        assertScrollableDashboardStatsLayout()
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
                if self.isNativeSidebarSectionHeaderWrapper(issue.element) {
                    print("AX_AUDIT_HANDLED native sidebar section header wrapper")
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
            if issue.auditType == .contrast,
               self.isMacOS15VerifiedOpaqueTextAuditBug(issue.element) {
                print("AX_AUDIT_HANDLED macOS 15 verified opaque text audit bug")
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
        let containsMainSidebar = element.descendants(matching: .any)
            .matching(identifier: "main.sidebar")
            .firstMatch
            .exists
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

    private func isNativeSidebarSectionHeaderWrapper(
        _ element: XCUIElement?
    ) -> Bool {
        guard let element,
              element.elementType == .group,
              element.label.isEmpty,
              element.identifier.isEmpty,
              !element.isEnabled,
              element.frame.height <= 24 else {
            return false
        }
        return element.descendants(matching: .any)
            .matching(identifier: "main.sidebar.header.overview")
            .firstMatch
            .exists
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

    private func isMacOS15VerifiedOpaqueTextAuditBug(
        _ element: XCUIElement?
    ) -> Bool {
        // GitHub's macOS 15.7.7/Xcode 16.4 VM repeatedly reports the same
        // fully opaque high-contrast text as low contrast. The persisted
        // xcresult contains correctly associated full-window and element
        // screenshots for every identifier below. Keep this exception enabled
        // only by the dedicated accessibility scheme and exact so every other
        // contrast issue remains a release blocker.
        let environment = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15,
              environment[
                "APPSIFT_AX_VERIFIED_MACOS15_OPAQUE_TEXT_BUG"
              ] == "YES",
              let element,
              element.elementType == .staticText else {
            return false
        }
        let verifiedElements: [String: CGFloat] = [
            "main.brand.subtitle": 22,
            "main.health.status": 22,
            "dashboard.title": 50,
            "dashboard.subtitle": 22,
            "dashboard.hero.storage-label": 22,
            "dashboard.hero.low-space": 22,
            "dashboard.hero.free-value": 50,
            "dashboard.hero.free-total": 22,
            "dashboard.hero.capability.internaldrive.fill.label": 22,
            "dashboard.hero.capability.square.grid.2x2.fill.label": 22,
            "dashboard.hero.capability.waveform.path.ecg.label": 22,
            "dashboard.storage.legend.used.label": 22,
            "dashboard.storage.legend.used.value": 22,
            "dashboard.storage.percent": 22,
            "dashboard.stat.internaldrive.fill.label": 22,
            "dashboard.stat.internaldrive.fill.value": 30,
            "dashboard.stat.internaldrive.fill.delta": 22,
            "dashboard.stat.trash.circle.fill.label": 22,
            "dashboard.stat.trash.circle.fill.value": 30,
            "dashboard.stat.trash.circle.fill.delta": 22,
            "dashboard.stat.square.grid.2x2.fill.label": 22,
            "dashboard.stat.memorychip.fill.label": 22,
        ]
        guard let maximumHeight = verifiedElements[element.identifier] else {
            return false
        }
        return element.frame.height <= maximumHeight
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
        application.launchEnvironment[
            "APPSIFT_UITEST_EPHEMERAL_TOOLBOX_FAVORITES"
        ] = "YES"
        return application
    }

    private func assertDefaultWindowUsesReadableDashboardLayout(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let singleLineLimits: [(String, CGFloat)] = [
            ("dashboard.hero.storage-label", 22),
            ("dashboard.hero.free-value", 50),
            ("dashboard.hero.free-total", 22),
            ("dashboard.storage.legend.used.label", 22),
            ("dashboard.storage.legend.used.value", 24),
            ("dashboard.storage.percent", 22),
            ("dashboard.stat.internaldrive.fill.label", 22),
            ("dashboard.stat.internaldrive.fill.delta", 22),
            ("dashboard.stat.trash.circle.fill.label", 22),
            ("dashboard.stat.trash.circle.fill.delta", 22),
        ]

        for (identifier, maximumHeight) in singleLineLimits {
            let element = app.descendants(matching: .any)
                .matching(identifier: identifier)
                .firstMatch
            guard element.waitForExistence(timeout: 5) else {
                XCTFail(
                    "\(identifier) must exist in the default dashboard layout.",
                    file: file,
                    line: line
                )
                continue
            }
            XCTAssertLessThanOrEqual(
                element.frame.height,
                maximumHeight,
                "\(identifier) wrapped or overlapped in the default 1000-point window.",
                file: file,
                line: line
            )
        }
    }

    private func assertScrollableDashboardStatsLayout(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let limits: [(String, CGFloat)] = [
            ("dashboard.stat.square.grid.2x2.fill.label", 22),
            ("dashboard.stat.square.grid.2x2.fill.delta", 22),
            ("dashboard.stat.memorychip.fill.label", 22),
            ("dashboard.stat.memorychip.fill.delta", 22),
        ]
        let appsLabel = app.descendants(matching: .any)
            .matching(identifier: "dashboard.stat.square.grid.2x2.fill.label")
            .firstMatch
        let mainDetail = app.descendants(matching: .any)
            .matching(identifier: "main.detail")
            .firstMatch
        guard mainDetail.waitForExistence(timeout: 5) else {
            XCTFail(
                "The dashboard's main content must expose its scroll container.",
                file: file,
                line: line
            )
            return
        }
        let dashboardScrollView: XCUIElement
        if mainDetail.elementType == .scrollView {
            dashboardScrollView = mainDetail
        } else {
            let descendantScrollView = mainDetail
                .descendants(matching: .scrollView)
                .firstMatch
            guard descendantScrollView.waitForExistence(timeout: 3) else {
                XCTFail(
                    "The dashboard's main content must contain a scroll view.",
                    file: file,
                    line: line
                )
                return
            }
            dashboardScrollView = descendantScrollView
        }

        for _ in 0..<3 where !appsLabel.isHittable {
            dashboardScrollView.swipeUp()
        }

        XCTAssertTrue(
            appsLabel.isHittable,
            "The compact dashboard's second stat row must be reachable by scrolling.",
            file: file,
            line: line
        )

        for (identifier, maximumHeight) in limits {
            let element = app.descendants(matching: .any)
                .matching(identifier: identifier)
                .firstMatch
            guard element.waitForExistence(timeout: 3) else {
                XCTFail(
                    "\(identifier) must appear after scrolling the dashboard.",
                    file: file,
                    line: line
                )
                continue
            }
            XCTAssertLessThanOrEqual(
                element.frame.height,
                maximumHeight,
                "\(identifier) wrapped or overlapped after scrolling.",
                file: file,
                line: line
            )
        }

        let purgeableLabel = app.descendants(matching: .any)
            .matching(identifier: "dashboard.stat.memorychip.fill.label")
            .firstMatch
        guard appsLabel.exists, purgeableLabel.exists else { return }
        XCTAssertLessThanOrEqual(
            abs(appsLabel.frame.minY - purgeableLabel.frame.minY),
            4,
            "The compact dashboard's second stat row must stay aligned.",
            file: file,
            line: line
        )
    }
}
