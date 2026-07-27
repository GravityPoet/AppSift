import AppKit
import SwiftUI
import XCTest
@testable import AppSift

@MainActor
final class SidebarVisualLayoutTests: XCTestCase {
    func testToolsLayoutRendersOffscreenAtDefaultWindowSize() throws {
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

        let appState = AppState()
        let lightImage = try render(
            MainWindow(initialSection: .tools)
                .environmentObject(appState)
                .environmentObject(ThemeManager.shared)
                .preferredColorScheme(.light),
            size: CGSize(width: 1000, height: 680)
        )
        let darkImage = try render(
            MainWindow(initialSection: .tools)
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
            lightImage,
            to: directory.appendingPathComponent("sidebar-tools-light.png")
        )
        try validateAndWrite(
            darkImage,
            to: directory.appendingPathComponent("sidebar-tools-dark.png")
        )
    }

    private func render<Content: View>(
        _ content: Content,
        size: CGSize
    ) throws -> NSBitmapImageRep {
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.setContentSize(size)
        window.contentView = hostingView
        window.contentView?.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        let image = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(
                in: hostingView.bounds
            )
        )
        hostingView.cacheDisplay(
            in: hostingView.bounds,
            to: image
        )
        return image
    }

    private func validateAndWrite(
        _ image: NSBitmapImageRep,
        to outputURL: URL
    ) throws {
        XCTAssertGreaterThanOrEqual(image.pixelsWide, 1000)
        XCTAssertGreaterThanOrEqual(image.pixelsHigh, 680)
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
