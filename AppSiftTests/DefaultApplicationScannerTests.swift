import UniformTypeIdentifiers
import XCTest
@testable import AppSift

final class DefaultApplicationScannerTests: XCTestCase {
    func testScanUsesAppDeclarationsLaunchServicesAndRealBundleIdentity() throws {
        let root = try makeTemporaryDirectory(prefix: "AppSiftDefaultAppsScan")
        defer { try? FileManager.default.removeItem(at: root) }
        let declaringApp = root.appendingPathComponent("Editor.app", isDirectory: true)
        try makeApplication(
            at: declaringApp,
            name: "Editor",
            bundleIdentifier: "com.example.editor",
            documentTypes: [[
                "LSItemContentTypes": ["com.adobe.pdf"],
                "CFBundleTypeExtensions": ["pdf"],
            ]]
        )
        let preview = root.appendingPathComponent("Preview.app", isDirectory: true)
        let alternative = root.appendingPathComponent("Alternative.app", isDirectory: true)
        try makeApplication(
            at: preview,
            name: "Preview",
            bundleIdentifier: "com.example.preview"
        )
        try makeApplication(
            at: alternative,
            name: "Alternative",
            bundleIdentifier: "com.example.alternative"
        )

        let result = DefaultApplicationScanner.scan(
            applicationURLs: [declaringApp],
            handlerProvider: { identifier in
                guard identifier == "com.adobe.pdf" else { return nil }
                return DefaultApplicationHandlerSnapshot(
                    defaultApplicationURL: preview,
                    candidateApplicationURLs: [alternative, preview, alternative]
                )
            }
        )

        let item = try XCTUnwrap(
            result.items.first { $0.contentTypeIdentifier == "com.adobe.pdf" }
        )
        XCTAssertEqual(item.currentApplication.name, "Preview")
        XCTAssertEqual(item.currentApplication.bundleIdentifier, "com.example.preview")
        XCTAssertEqual(item.candidateApplications.count, 2)
        XCTAssertEqual(item.alternativeCount, 1)
        XCTAssertEqual(item.filenameExtensions, ["pdf"])
        XCTAssertEqual(item.category, .documents)
        XCTAssertTrue(item.evidence.contains(.applicationDeclaration))
        XCTAssertTrue(item.evidence.contains(.commonTypeCatalog))
        XCTAssertTrue(item.evidence.contains(.launchServicesCurrentHandler))
        XCTAssertTrue(item.evidence.contains(.launchServicesCandidates))
        XCTAssertEqual(result.unreadableApplicationDeclarationCount, 0)
        XCTAssertFalse(result.wasTruncated)
    }

    func testScanExcludesMissingSymlinkedAndTrashApplications() throws {
        let root = try makeTemporaryDirectory(prefix: "AppSiftDefaultAppsFilter")
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("Current.app", isDirectory: true)
        let realAlternative = root.appendingPathComponent("Real.app", isDirectory: true)
        let linkedAlternative = root.appendingPathComponent("Linked.app", isDirectory: true)
        let trashAlternative = root
            .appendingPathComponent(".Trash", isDirectory: true)
            .appendingPathComponent("Trash.app", isDirectory: true)
        try makeApplication(
            at: current,
            name: "Current",
            bundleIdentifier: "com.example.current"
        )
        try makeApplication(
            at: realAlternative,
            name: "Real",
            bundleIdentifier: "com.example.real"
        )
        try FileManager.default.createSymbolicLink(
            at: linkedAlternative,
            withDestinationURL: realAlternative
        )
        try makeApplication(
            at: trashAlternative,
            name: "Trash",
            bundleIdentifier: "com.example.trash"
        )
        let missing = root.appendingPathComponent("Missing.app", isDirectory: true)

        let result = DefaultApplicationScanner.scan(
            applicationURLs: [],
            handlerProvider: { identifier in
                guard identifier == "public.plain-text" else { return nil }
                return DefaultApplicationHandlerSnapshot(
                    defaultApplicationURL: current,
                    candidateApplicationURLs: [
                        current,
                        realAlternative,
                        linkedAlternative,
                        trashAlternative,
                        missing,
                    ]
                )
            }
        )

        let item = try XCTUnwrap(
            result.items.first { $0.contentTypeIdentifier == "public.plain-text" }
        )
        XCTAssertEqual(
            Set(item.candidateApplications.map(\.bundleIdentifier)),
            ["com.example.current", "com.example.real"]
        )
    }

    func testScanClassifiesMediaArchivesAndDeveloperTypes() throws {
        let root = try makeTemporaryDirectory(prefix: "AppSiftDefaultAppsKinds")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Handler.app", isDirectory: true)
        try makeApplication(
            at: app,
            name: "Handler",
            bundleIdentifier: "com.example.handler"
        )
        let identifiers = Set([
            try XCTUnwrap(UTType(filenameExtension: "png")).identifier,
            try XCTUnwrap(UTType(filenameExtension: "mp3")).identifier,
            try XCTUnwrap(UTType(filenameExtension: "mov")).identifier,
            try XCTUnwrap(UTType(filenameExtension: "zip")).identifier,
            try XCTUnwrap(UTType(filenameExtension: "swift")).identifier,
        ])

        let result = DefaultApplicationScanner.scan(
            applicationURLs: [],
            handlerProvider: { identifier in
                guard identifiers.contains(identifier) else { return nil }
                return DefaultApplicationHandlerSnapshot(
                    defaultApplicationURL: app,
                    candidateApplicationURLs: [app]
                )
            }
        )

        let categories = Dictionary(
            uniqueKeysWithValues: result.items.map {
                ($0.contentTypeIdentifier, $0.category)
            }
        )
        XCTAssertEqual(
            categories[try XCTUnwrap(UTType(filenameExtension: "png")).identifier],
            .images
        )
        XCTAssertEqual(
            categories[try XCTUnwrap(UTType(filenameExtension: "mp3")).identifier],
            .audio
        )
        XCTAssertEqual(
            categories[try XCTUnwrap(UTType(filenameExtension: "mov")).identifier],
            .video
        )
        XCTAssertEqual(
            categories[try XCTUnwrap(UTType(filenameExtension: "zip")).identifier],
            .archives
        )
        XCTAssertEqual(
            categories[try XCTUnwrap(UTType(filenameExtension: "swift")).identifier],
            .developer
        )
    }

    func testUnreadableExistingInfoPlistIsReportedWithoutGuessing() throws {
        let root = try makeTemporaryDirectory(prefix: "AppSiftDefaultAppsUnreadable")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Broken.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(
            to: contents.appendingPathComponent("Info.plist")
        )

        let result = DefaultApplicationScanner.scan(
            applicationURLs: [app],
            handlerProvider: { _ in nil }
        )

        XCTAssertEqual(result.unreadableApplicationDeclarationCount, 1)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(prefix)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func makeApplication(
        at url: URL,
        name: String,
        bundleIdentifier: String,
        documentTypes: [[String: Any]] = []
    ) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contents,
            withIntermediateDirectories: true
        )
        var info: [String: Any] = [
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
        ]
        if !documentTypes.isEmpty {
            info["CFBundleDocumentTypes"] = documentTypes
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
