import Darwin
import XCTest
@testable import AppSift

final class SpaceLensScannerTests: XCTestCase {
    func testBuildsCompleteTreeAndAggregatesNestedSizes() async throws {
        let root = try makeRoot()
        let folder = root.appendingPathComponent(
            "Projects",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: 8_192).write(
            to: folder.appendingPathComponent("alpha.bin")
        )
        try Data(repeating: 0x42, count: 16_384).write(
            to: root.appendingPathComponent("beta.bin")
        )

        let result = try await SpaceLensScanner().scan(root: root)

        XCTAssertEqual(result.statistics.fileCount, 2)
        XCTAssertEqual(result.root.fileCount, 2)
        XCTAssertEqual(result.root.logicalSize, 24_576)
        XCTAssertGreaterThan(result.root.allocatedSize, 0)
        XCTAssertEqual(result.root.children.count, 2)
        let project = try XCTUnwrap(
            result.root.children.first { $0.name == "Projects" }
        )
        XCTAssertTrue(project.isContainer)
        XCTAssertEqual(project.logicalSize, 8_192)
        XCTAssertEqual(project.children.first?.name, "alpha.bin")
        XCTAssertEqual(result.root.protectionReason, .scanRoot)
    }

    func testSystemTemporaryLocationsStayProtected() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "AppSiftSpaceLensProtected-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        try Data(repeating: 0x43, count: 4_096).write(
            to: root.appendingPathComponent("system-temp.bin")
        )

        let result = try await SpaceLensScanner().scan(root: root)
        let file = try XCTUnwrap(result.root.children.first)

        XCTAssertEqual(file.protectionReason, .systemLocation)
        XCTAssertFalse(file.isRemovalEligible)
    }

    func testHardLinksCountPhysicalAllocationOnceAndStayProtected() async throws {
        let root = try makeRoot()
        let original = root.appendingPathComponent("original.bin")
        let alias = root.appendingPathComponent("alias.bin")
        try Data(repeating: 0xAB, count: 32_768).write(to: original)
        XCTAssertEqual(link(original.path, alias.path), 0)

        let result = try await SpaceLensScanner().scan(root: root)
        let files = result.root.children.filter { !$0.isContainer }

        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(result.statistics.hardLinkAliasCount, 1)
        XCTAssertEqual(files.filter { $0.allocatedSize == 0 }.count, 1)
        XCTAssertTrue(files.allSatisfy {
            $0.protectionReason == .hardLinked
        })
    }

    func testAPFSCloneContentIsNotCountedTwiceWhenMetadataIsAvailable() async throws {
        let root = try makeRoot()
        let original = root.appendingPathComponent("original.bin")
        let clone = root.appendingPathComponent("clone.bin")
        try Data(repeating: 0xCD, count: 1_048_576).write(to: original)
        guard clonefile(original.path, clone.path, 0) == 0 else {
            throw XCTSkip("The test volume does not support APFS clones.")
        }

        let result = try await SpaceLensScanner().scan(root: root)
        guard result.statistics.cloneCandidateCount > 0 else {
            throw XCTSkip("Foundation did not expose clone metadata.")
        }

        XCTAssertEqual(result.statistics.cloneAliasCount, 1)
        XCTAssertEqual(
            result.root.children.filter(\.isCloneAlias).count,
            1
        )
        XCTAssertEqual(
            result.root.children.filter { $0.allocatedSize == 0 }.count,
            1
        )
    }

    func testPackageContentsRemainAvailableForDrillDown() async throws {
        let root = try makeRoot()
        let package = root.appendingPathComponent(
            "Example.app",
            isDirectory: true
        )
        let contents = package.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: contents,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x11, count: 4_096).write(
            to: contents.appendingPathComponent("payload")
        )

        let result = try await SpaceLensScanner().scan(root: root)
        let packageNode = try XCTUnwrap(
            result.root.children.first { $0.name == "Example.app" }
        )

        XCTAssertEqual(packageNode.kind, .package)
        XCTAssertEqual(packageNode.fileCount, 1)
        XCTAssertEqual(packageNode.logicalSize, 4_096)
        XCTAssertEqual(packageNode.protectionReason, .appManagedLibrary)
        XCTAssertFalse(packageNode.children.isEmpty)
    }

    func testSymbolicLinksAreSkippedWithoutFollowingTargets() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        try Data(repeating: 0x22, count: 1_024).write(
            to: outside.appendingPathComponent("outside.bin")
        )
        let linkURL = root.appendingPathComponent("linked-folder")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: outside
        )

        let result = try await SpaceLensScanner().scan(root: root)

        XCTAssertEqual(result.statistics.symbolicLinkCount, 1)
        XCTAssertEqual(result.root.fileCount, 0)
        XCTAssertTrue(result.root.children.isEmpty)
    }

    func testVerificationTokenChangesWhenNestedContentMetadataChanges() async throws {
        let root = try makeRoot()
        let folder = root.appendingPathComponent(
            "Folder",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let file = folder.appendingPathComponent("value.bin")
        try Data(repeating: 0x31, count: 512).write(to: file)
        let originalToken = try XCTUnwrap(
            SpaceLensScanner.verificationToken(for: folder)
        )

        try Data(repeating: 0x32, count: 1_024).write(to: file)
        let changedToken = try XCTUnwrap(
            SpaceLensScanner.verificationToken(for: folder)
        )

        XCTAssertNotEqual(originalToken, changedToken)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".appsift-space-lens-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}

final class SpaceLensTreemapLayoutTests: XCTestCase {
    func testTilesCoverBoundsWithoutOverlapping() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 500)
        let entries = [
            SpaceLensTreemapEntry(id: "a", weight: 50),
            SpaceLensTreemapEntry(id: "b", weight: 25),
            SpaceLensTreemapEntry(id: "c", weight: 15),
            SpaceLensTreemapEntry(id: "d", weight: 10),
        ]

        let tiles = SpaceLensTreemapLayout.tiles(
            for: entries,
            in: bounds
        )

        XCTAssertEqual(tiles.count, entries.count)
        let coveredArea = tiles.reduce(CGFloat(0)) {
            $0 + $1.rect.width * $1.rect.height
        }
        XCTAssertEqual(
            coveredArea,
            bounds.width * bounds.height,
            accuracy: 0.01
        )
        for tile in tiles {
            XCTAssertTrue(bounds.contains(tile.rect))
        }
        for firstIndex in tiles.indices {
            for secondIndex in tiles.indices
            where firstIndex < secondIndex {
                let intersection = tiles[firstIndex].rect.intersection(
                    tiles[secondIndex].rect
                )
                XCTAssertTrue(
                    intersection.isNull
                        || intersection.width == 0
                        || intersection.height == 0
                )
            }
        }
    }

    func testLayoutIsDeterministicAndIgnoresInvalidWeights() {
        let entries = [
            SpaceLensTreemapEntry(id: "equal-b", weight: 10),
            SpaceLensTreemapEntry(id: "equal-a", weight: 10),
            SpaceLensTreemapEntry(id: "zero", weight: 0),
            SpaceLensTreemapEntry(id: "negative", weight: -1),
        ]
        let bounds = CGRect(x: 4, y: 8, width: 320, height: 180)

        let first = SpaceLensTreemapLayout.tiles(
            for: entries,
            in: bounds
        )
        let second = SpaceLensTreemapLayout.tiles(
            for: Array(entries.reversed()),
            in: bounds
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.id), ["equal-a", "equal-b"])
    }
}
