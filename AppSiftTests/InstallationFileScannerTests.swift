import XCTest
@testable import AppSift

final class InstallationFileScannerTests: XCTestCase {
    func testRecognizesOnlySupportedExtensionsAndMatchingUniformTypes() {
        XCTAssertEqual(
            InstallationFileScanner.kind(
                for: URL(fileURLWithPath: "/Users/test/Example.DMG")
            ),
            .diskImage
        )
        XCTAssertEqual(
            InstallationFileScanner.kind(
                for: URL(fileURLWithPath: "/Users/test/Example.pkg"),
                contentTypeIdentifier: "com.apple.installer-package-archive"
            ),
            .installerPackage
        )
        XCTAssertEqual(
            InstallationFileScanner.kind(
                for: URL(fileURLWithPath: "/Users/test/Example.xip")
            ),
            .xipArchive
        )
        XCTAssertEqual(
            InstallationFileScanner.kind(
                for: URL(fileURLWithPath: "/Users/test/Example.mpkg"),
                contentTypeIdentifier: "com.apple.installer-package-archive"
            ),
            .installerMetaPackage
        )
        XCTAssertEqual(
            InstallationFileScanner.kind(
                for: URL(fileURLWithPath: "/Users/test/Example.zip"),
                contentTypeIdentifier: "public.zip-archive"
            ),
            .applicationArchive
        )
        XCTAssertNil(
            InstallationFileScanner.kind(
                for: URL(fileURLWithPath: "/Users/test/Example.dmg"),
                contentTypeIdentifier: "public.jpeg"
            )
        )
        XCTAssertEqual(
            InstallationFileScanner.kind(
                for: URL(fileURLWithPath: "/Users/test/Example.zip")
            ),
            .applicationArchive
        )
    }

    func testMetaPackageUsesTheExistingPackageEvidencePipeline() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let package = try fixture.file(
            "home/Downloads/Example.mpkg",
            data: "flat meta package"
        )
        let signatureOutput = """
        Package "Example.mpkg":
           Status: signed by a developer certificate issued by Apple for distribution
           Certificate Chain:
            1. Developer ID Installer: Example Company (ABCDE12345)
        """
        let provider: InstallationFileScanner.PackageCommandProvider = { arguments in
            InstallationPackageCommandResult(
                exitCode: 0,
                output: Data(
                    (arguments.first == "--check-signature"
                        ? signatureOutput
                        : "./Applications/Example.app").utf8
                ),
                timedOut: false,
                truncated: false
            )
        }

        let result = InstallationFileScanner.scan(
            candidateURLs: [package],
            installedApps: [],
            homeURL: fixture.home,
            packageCommandProvider: provider,
            signatureProvider: { _ in .unknown }
        )

        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.kind, .installerMetaPackage)
        XCTAssertEqual(item.signature.teamIdentifier, "ABCDE12345")
        XCTAssertTrue(item.evidence.contains(.installerPackageSignature))
        XCTAssertTrue(item.evidence.contains(.installerPackagePayload))
    }

    func testAcceptsACompleteSingleApplicationZIPWithoutExpandingIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let archive = try fixture.file(
            "home/Downloads/Example.zip",
            data: "archive placeholder"
        )
        let listing = """
        Example.app/Contents/Info.plist
        Example.app/Contents/MacOS/Example
        Example.app/Contents/Frameworks/Example Helper.app/Contents/Info.plist
        """

        let result = InstallationFileScanner.scan(
            candidateURLs: [archive],
            installedApps: [],
            homeURL: fixture.home,
            archiveListingProvider: { _, _ in
                InstallationArchiveListingResult(
                    exitCode: 0,
                    output: Data(listing.utf8),
                    reportedEntryCount: 3,
                    timedOut: false,
                    truncated: false
                )
            },
            signatureProvider: { _ in .unknown }
        )

        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.kind, .applicationArchive)
        XCTAssertEqual(item.containedApplicationName, "Example")
        XCTAssertEqual(item.signature, .unknown)
        XCTAssertTrue(item.evidence.contains(.applicationArchiveContents))
    }

    func testReadsARealDittoApplicationZIPWithTheBoundedSystemLister() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let appRoot = try fixture.directory(
            "home/Downloads/Real Example.app/Contents/MacOS"
        ).deletingLastPathComponent().deletingLastPathComponent()
        _ = try fixture.file(
            "home/Downloads/Real Example.app/Contents/Info.plist",
            data: "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>"
        )
        _ = try fixture.file(
            "home/Downloads/Real Example.app/Contents/MacOS/Real Example",
            data: "executable placeholder"
        )
        let archive = fixture.home
            .appendingPathComponent("Downloads/Real Example.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c", "-k", "--keepParent", appRoot.path, archive.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let homeURL = fixture.home
        let result = await Task.detached(priority: .utility) {
            InstallationFileScanner.scan(
                candidateURLs: [archive],
                installedApps: [],
                homeURL: homeURL,
                signatureProvider: { _ in .unknown }
            )
        }.value

        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.containedApplicationName, "Real Example")
        XCTAssertTrue(item.evidence.contains(.applicationArchiveContents))
    }

    func testRejectsOrdinaryAmbiguousAndUnsafeZIPListings() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let downloads = try fixture.directory("home/Downloads")
        let listings = [
            "Documents/Report.pdf\n",
            "One.app/Contents/Info.plist\nOne.app/Contents/MacOS/One\nTwo.app/Contents/Info.plist\nTwo.app/Contents/MacOS/Two\n",
            "../Example.app/Contents/Info.plist\n../Example.app/Contents/MacOS/Example\n",
            "/Example.app/Contents/Info.plist\n/Example.app/Contents/MacOS/Example\n",
            "Example.app\\Contents\\Info.plist\nExample.app\\Contents\\MacOS\\Example\n",
            "Example.app/Contents/Info.plist\n",
            "Example.app/Contents/Info.plist\nExample.app/Contents/MacOS/Example\npostinstall.sh\n",
        ]

        for (index, listing) in listings.enumerated() {
            let archive = downloads.appendingPathComponent("Unsafe-\(index).zip")
            try Data("archive placeholder".utf8).write(to: archive)
            let entryCount = listing.split(
                separator: "\n",
                omittingEmptySubsequences: true
            ).count
            let result = InstallationFileScanner.scan(
                candidateURLs: [archive],
                installedApps: [],
                homeURL: fixture.home,
                archiveListingProvider: { _, _ in
                    InstallationArchiveListingResult(
                        exitCode: 0,
                        output: Data(listing.utf8),
                        reportedEntryCount: entryCount,
                        timedOut: false,
                        truncated: false
                    )
                },
                signatureProvider: { _ in .unknown }
            )
            XCTAssertTrue(result.items.isEmpty, "Accepted unsafe listing \(index)")
        }
    }

    func testRejectsZIPsOutsideDownloadLocationsAndIncompleteListings() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let outsideDownloadLocation = try fixture.file(
            "home/Documents/Example.zip",
            data: "archive placeholder"
        )
        let download = try fixture.file(
            "home/Downloads/Example.zip",
            data: "archive placeholder"
        )
        let validListing = """
        Example.app/Contents/Info.plist
        Example.app/Contents/MacOS/Example
        """
        let successful = InstallationArchiveListingResult(
            exitCode: 0,
            output: Data(validListing.utf8),
            reportedEntryCount: 2,
            timedOut: false,
            truncated: false
        )

        let untrustedLocation = InstallationFileScanner.scan(
            candidateURLs: [outsideDownloadLocation],
            installedApps: [],
            homeURL: fixture.home,
            archiveListingProvider: { _, _ in successful },
            signatureProvider: { _ in .unknown }
        )
        XCTAssertTrue(untrustedLocation.items.isEmpty)

        for failed in [
            InstallationArchiveListingResult(
                exitCode: 0,
                output: Data(validListing.utf8),
                reportedEntryCount: 3,
                timedOut: false,
                truncated: false
            ),
            InstallationArchiveListingResult(
                exitCode: 0,
                output: Data(validListing.utf8),
                reportedEntryCount: 2,
                timedOut: true,
                truncated: false
            ),
            InstallationArchiveListingResult(
                exitCode: 0,
                output: Data(validListing.utf8),
                reportedEntryCount: 2,
                timedOut: false,
                truncated: true
            ),
            InstallationArchiveListingResult(
                exitCode: 0,
                output: Data([0xFF]),
                reportedEntryCount: 1,
                timedOut: false,
                truncated: false
            ),
        ] {
            let result = InstallationFileScanner.scan(
                candidateURLs: [download],
                installedApps: [],
                homeURL: fixture.home,
                archiveListingProvider: { _, _ in failed },
                signatureProvider: { _ in .unknown }
            )
            XCTAssertTrue(result.items.isEmpty)
        }
    }

    func testScanDeduplicatesAndProtectsManagedOutsideHomeAndHardLinkedFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let downloads = try fixture.directory("home/Downloads")
        let cache = try fixture.directory("home/Library/Caches/com.example")
        let outside = try fixture.directory("outside")
        let regular = try fixture.file("home/Downloads/Example.dmg", data: "regular")
        let managed = try fixture.file(
            "home/Library/Caches/com.example/Update.dmg",
            data: "managed"
        )
        let outsideFile = try fixture.file("outside/Outside.pkg", data: "outside")
        let hardLinked = downloads.appendingPathComponent("HardLinked.xip")
        try Data("hard-link".utf8).write(to: hardLinked)
        try FileManager.default.linkItem(
            at: hardLinked,
            to: downloads.appendingPathComponent("HardLinked-copy.xip")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))

        let result = InstallationFileScanner.scan(
            candidateURLs: [
                regular, regular, managed, outsideFile, hardLinked,
            ],
            installedApps: [],
            homeURL: fixture.home,
            packageCommandProvider: { _ in
                InstallationPackageCommandResult(
                    exitCode: 1,
                    output: Data(),
                    timedOut: false,
                    truncated: false
                )
            },
            signatureProvider: { _ in .unknown }
        )

        XCTAssertEqual(result.items.count, 4)
        XCTAssertEqual(
            result.items.first { $0.url == regular }?.removalEligibility,
            .eligible
        )
        XCTAssertEqual(
            result.items.first { $0.url == managed }?.removalEligibility,
            .protected(.applicationManagedCache)
        )
        XCTAssertTrue(
            try XCTUnwrap(result.items.first(where: { $0.url == managed }))
                .allowsExplicitSelection
        )
        XCTAssertEqual(
            result.items.first { $0.url == outsideFile }?.removalEligibility,
            .protected(.outsideUserHome)
        )
        XCTAssertFalse(
            try XCTUnwrap(result.items.first(where: { $0.url == outsideFile }))
                .allowsExplicitSelection
        )
        XCTAssertEqual(
            result.items.first { $0.url == hardLinked }?.removalEligibility,
            .protected(.hardLinked)
        )
        XCTAssertFalse(
            try XCTUnwrap(result.items.first { $0.url == regular })
                .evidence.contains(.spotlightMetadata)
        )
    }

    func testScanRejectsSymlinkedPathsAndIgnoresSystemManagedRoots() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let realDirectory = try fixture.directory("home/Real")
        let realFile = realDirectory.appendingPathComponent("Example.dmg")
        try Data("image".utf8).write(to: realFile)
        let linkDirectory = fixture.home.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(
            at: linkDirectory,
            withDestinationURL: realDirectory
        )
        let linkedFile = linkDirectory.appendingPathComponent("Example.dmg")

        let result = InstallationFileScanner.scan(
            candidateURLs: [linkedFile],
            installedApps: [],
            homeURL: fixture.home,
            signatureProvider: { _ in .unknown }
        )

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.inaccessibleCandidateCount, 1)
        XCTAssertTrue(InstallationFileScanner.isIgnoredPath(
            URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Test.dmg"),
            homeURL: fixture.home
        ))
        XCTAssertTrue(InstallationFileScanner.isIgnoredPath(
            URL(fileURLWithPath: "/System/Library/Test.pkg"),
            homeURL: fixture.home
        ))
        XCTAssertTrue(InstallationFileScanner.isIgnoredPath(
            fixture.home.appendingPathComponent(".Trash/Test.xip"),
            homeURL: fixture.home
        ))
        XCTAssertTrue(InstallationFileScanner.isIgnoredPath(
            fixture.home.appendingPathComponent("Apps/Test.app/Contents/Test.dmg"),
            homeURL: fixture.home
        ))
    }

    func testPackageAssociationRequiresBothPayloadNameAndTeamIdentifier() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let package = try fixture.file(
            "home/Downloads/Example.pkg",
            data: "package"
        )
        let app = InstallationFileApplicationReference(
            name: "Example",
            bundleIdentifier: "com.example.app",
            url: URL(fileURLWithPath: "/Applications/Example.app"),
            teamIdentifier: "ABCDE12345"
        )
        let signatureOutput = """
        Package "Example.pkg":
           Status: signed by a developer certificate issued by Apple for distribution
           Notarization: trusted by the Apple notary service
           Certificate Chain:
            1. Developer ID Installer: Example Company (ABCDE12345)
        """
        let payloadOutput = """
        ./Applications/Example.app
        ./Applications/Example.app/Contents/MacOS/Example
        """
        let provider: InstallationFileScanner.PackageCommandProvider = { arguments in
            let output = arguments.first == "--check-signature"
                ? signatureOutput
                : payloadOutput
            return InstallationPackageCommandResult(
                exitCode: 0,
                output: Data(output.utf8),
                timedOut: false,
                truncated: false
            )
        }

        let matched = InstallationFileScanner.scan(
            candidateURLs: [package],
            installedApps: [app],
            homeURL: fixture.home,
            packageCommandProvider: provider,
            signatureProvider: { _ in .unknown }
        )
        let matchedItem = try XCTUnwrap(matched.items.first)
        XCTAssertEqual(matchedItem.relatedApplication, app)
        XCTAssertEqual(matchedItem.signature.teamIdentifier, "ABCDE12345")
        XCTAssertEqual(matchedItem.signature.notarizationStatus, .notarized)
        XCTAssertTrue(matchedItem.evidence.contains(.installedApplicationNameMatch))
        XCTAssertTrue(matchedItem.evidence.contains(.installedApplicationTeamMatch))

        let wrongTeamApp = InstallationFileApplicationReference(
            name: "Example",
            bundleIdentifier: "com.example.app",
            url: URL(fileURLWithPath: "/Applications/Example.app"),
            teamIdentifier: "ZZZZZ99999"
        )
        let notMatched = InstallationFileScanner.scan(
            candidateURLs: [package],
            installedApps: [wrongTeamApp],
            homeURL: fixture.home,
            packageCommandProvider: provider,
            signatureProvider: { _ in .unknown }
        )
        XCTAssertNil(notMatched.items.first?.relatedApplication)
    }

    func testScanReportsCancellationAndCandidateTruncation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try fixture.file("home/Downloads/Example.dmg", data: "image")

        let cancelled = InstallationFileScanner.scan(
            candidateURLs: [file],
            installedApps: [],
            homeURL: fixture.home,
            shouldCancel: { true }
        )
        XCTAssertTrue(cancelled.wasCancelled)
        XCTAssertTrue(cancelled.items.isEmpty)

        let truncated = InstallationFileScanner.scan(
            candidateURLs: Array(repeating: file, count: 5_001),
            installedApps: [],
            homeURL: fixture.home,
            signatureProvider: { _ in .unknown }
        )
        XCTAssertTrue(truncated.wasTruncated)
        XCTAssertEqual(truncated.items.count, 1)
    }

    func testMergeKeepsDirectlyInspectedPathsWhileSpotlightCatchesUp() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let indexed = try fixture.file(
            "home/Downloads/Indexed.dmg",
            data: "indexed"
        )
        let restored = try fixture.file(
            "home/Downloads/Restored.pkg",
            data: "restored"
        )
        let indexedResult = InstallationFileScanner.scan(
            candidateURLs: [indexed],
            installedApps: [],
            homeURL: fixture.home,
            candidateURLsAreSpotlightResults: true,
            signatureProvider: { _ in .unknown }
        )
        let restoredResult = InstallationFileScanner.scan(
            candidateURLs: [restored],
            installedApps: [],
            homeURL: fixture.home,
            packageCommandProvider: { _ in
                InstallationPackageCommandResult(
                    exitCode: 1,
                    output: Data(),
                    timedOut: false,
                    truncated: false
                )
            },
            signatureProvider: { _ in .unknown }
        )

        let merged = InstallationFileScanner.merging(
            indexedResult,
            restoredResult
        )

        XCTAssertEqual(Set(merged.items.map(\.url)), [indexed, restored])
        XCTAssertTrue(
            try XCTUnwrap(merged.items.first(where: { $0.url == indexed }))
                .evidence.contains(.spotlightMetadata)
        )
        XCTAssertFalse(
            try XCTUnwrap(merged.items.first(where: { $0.url == restored }))
                .evidence.contains(.spotlightMetadata)
        )
    }
}

private final class Fixture {
    let root: URL
    let home: URL

    init() throws {
        root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".appsift-installation-scanner-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
    }

    func directory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    func file(_ relativePath: String, data: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(data.utf8).write(to: url)
        return url
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
