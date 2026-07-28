import AppKit
import SwiftUI
import XCTest
@testable import AppSift

@MainActor
final class SidebarVisualLayoutTests: XCTestCase {
    func testPrimaryLayoutsRenderOffscreenAtDefaultWindowSize() throws {
        let defaults = UserDefaults.standard
        let favoritesKey = ToolboxFavorites.storageKey
        let previousFavorites = defaults.object(forKey: favoritesKey)
        defaults.set("", forKey: favoritesKey)
        defer {
            if let previousFavorites {
                defaults.set(previousFavorites, forKey: favoritesKey)
            } else {
                defaults.removeObject(forKey: favoritesKey)
            }
        }

        let appState = AppState(performStartupTasks: false)
        appState.fdaBannerDismissed = true
        let gibibyte: Int64 = 1_073_741_824
        appState.diskInfo = DiskInfo(
            totalSpace: 512 * gibibyte,
            freeSpace: 158 * gibibyte,
            usedSpace: 354 * gibibyte,
            purgeableSpace: 12 * gibibyte
        )
        let lightRender = try render(
            MainWindow(
                initialSection: .tools,
                highlightsSidebarSelection: true
            )
                .environmentObject(appState)
                .environmentObject(ThemeManager.shared)
                .preferredColorScheme(.light),
            size: CGSize(width: 1000, height: 680)
        )
        let darkRender = try render(
            MainWindow(
                initialSection: .tools,
                highlightsSidebarSelection: true
            )
                .environmentObject(appState)
                .environmentObject(ThemeManager.shared)
                .preferredColorScheme(.dark),
            size: CGSize(width: 1000, height: 680)
        )
        let dashboardLightRender = try render(
            MainWindow(
                initialSection: .cleaning(.smartScan),
                highlightsSidebarSelection: true
            )
                .environmentObject(appState)
                .environmentObject(ThemeManager.shared)
                .preferredColorScheme(.light),
            size: CGSize(width: 1000, height: 680)
        )
        let dashboardDarkRender = try render(
            MainWindow(
                initialSection: .cleaning(.smartScan),
                highlightsSidebarSelection: true
            )
                .environmentObject(appState)
                .environmentObject(ThemeManager.shared)
                .preferredColorScheme(.dark),
            size: CGSize(width: 1000, height: 680)
        )

        let outputDirectory = ProcessInfo.processInfo.environment[
            "APPSIFT_VISUAL_QA_OUTPUT"
        ] ?? repositoryRoot()
            .appendingPathComponent("build/visual-qa", isDirectory: true)
            .path
        let directory = URL(
            fileURLWithPath: outputDirectory,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try validateAndWrite(
            lightRender.image,
            contentSize: lightRender.contentSize,
            to: directory.appendingPathComponent("sidebar-tools-light.png")
        )
        try validateAndWrite(
            darkRender.image,
            contentSize: darkRender.contentSize,
            to: directory.appendingPathComponent("sidebar-tools-dark.png")
        )
        try validateAndWrite(
            dashboardLightRender.image,
            contentSize: dashboardLightRender.contentSize,
            to: directory.appendingPathComponent("dashboard-light.png")
        )
        try validateAndWrite(
            dashboardDarkRender.image,
            contentSize: dashboardDarkRender.contentSize,
            to: directory.appendingPathComponent("dashboard-dark.png")
        )
    }

    private func render<Content: View>(
        _ content: Content,
        size: CGSize
    ) throws -> (image: NSBitmapImageRep, contentSize: CGSize) {
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setContentSize(size)
        hostingView.frame = CGRect(origin: .zero, size: size)
        window.contentView?.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(
            until: Date().addingTimeInterval(1.0)
        )
        window.contentView?.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        hostingView.displayIfNeeded()

        let image = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(
                in: hostingView.bounds
            )
        )
        hostingView.cacheDisplay(
            in: hostingView.bounds,
            to: image
        )
        return (image, hostingView.bounds.size)
    }

    private func validateAndWrite(
        _ image: NSBitmapImageRep,
        contentSize: CGSize,
        to outputURL: URL
    ) throws {
        // macOS 15 reserves 24 points of a titled window for its titlebar,
        // while newer AppKit versions expose the requested content height.
        // Validate the usable viewport and that the bitmap covers all of it.
        XCTAssertGreaterThanOrEqual(contentSize.width, 980)
        XCTAssertGreaterThanOrEqual(contentSize.height, 640)
        XCTAssertGreaterThanOrEqual(
            image.pixelsWide,
            Int(contentSize.width.rounded(.down))
        )
        XCTAssertGreaterThanOrEqual(
            image.pixelsHigh,
            Int(contentSize.height.rounded(.down))
        )
        let png = try XCTUnwrap(
            image.representation(using: .png, properties: [:])
        )
        try png.write(to: outputURL, options: .atomic)
        XCTAssertGreaterThan(png.count, 10_000)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
