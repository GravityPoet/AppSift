import Foundation
import XCTest
@testable import AppSift

final class DuplicateFileScannerTests: XCTestCase {
    func testFindsOnlyByteIdenticalFiles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("same-content".utf8).write(
            to: root.appendingPathComponent("original.txt")
        )
        try Data("same-content".utf8).write(
            to: root.appendingPathComponent("copy.txt")
        )
        try Data("diff-content".utf8).write(
            to: root.appendingPathComponent("same-size.txt")
        )

        let result = try await DuplicateFileScanner().scan(roots: [root])

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(
            Set(result.groups[0].files.map(\.name)),
            ["original.txt", "copy.txt"]
        )
        XCTAssertEqual(result.duplicateFileCount, 1)
    }

    func testFullHashRejectsFilesWhoseSamplesMatch() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        var first = Data(repeating: 0x41, count: 512 * 1024)
        var second = first
        first[128 * 1024] = 0x42
        second[128 * 1024] = 0x43
        try first.write(to: root.appendingPathComponent("first.bin"))
        try second.write(to: root.appendingPathComponent("second.bin"))

        let result = try await DuplicateFileScanner().scan(roots: [root])

        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(result.statistics.candidateFileCount, 2)
    }

    func testHardLinkAliasIsNotCountedAsAnotherCopy() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = root.appendingPathComponent("original.txt")
        let alias = root.appendingPathComponent("alias.txt")
        try Data("same-content".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: alias)

        let result = try await DuplicateFileScanner().scan(roots: [root])

        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(result.statistics.hardLinkAliasCount, 1)
    }

    func testSystemLocationProtectionResolvesVarSymlink() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("same-content".utf8).write(
            to: root.appendingPathComponent("first.txt")
        )
        try Data("same-content".utf8).write(
            to: root.appendingPathComponent("second.txt")
        )

        let result = try await DuplicateFileScanner().scan(roots: [root])
        let group = try XCTUnwrap(result.groups.first)

        XCTAssertTrue(group.files.allSatisfy {
            $0.protectionReason == .systemLocation
        }, "\(group.files.map { ($0.url.path, $0.protectionReason?.rawValue) })")
    }

    func testIgnoredDirectoryIsPruned() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let ignored = root.appendingPathComponent("ignored", isDirectory: true)
        let included = root.appendingPathComponent("included", isDirectory: true)
        try FileManager.default.createDirectory(
            at: ignored,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: included,
            withIntermediateDirectories: true
        )
        try Data("same-content".utf8).write(
            to: ignored.appendingPathComponent("one.txt")
        )
        try Data("same-content".utf8).write(
            to: ignored.appendingPathComponent("two.txt")
        )
        try Data("same-content".utf8).write(
            to: included.appendingPathComponent("three.txt")
        )

        let result = try await DuplicateFileScanner().scan(
            roots: [root],
            ignoredPaths: [ignored.path]
        )

        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertGreaterThan(result.statistics.ignoredItemCount, 0)
    }

    func testNestedRootsAreCollapsedBeforeEnumeration() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        try Data("same-content".utf8).write(
            to: nested.appendingPathComponent("first.txt")
        )
        try Data("same-content".utf8).write(
            to: nested.appendingPathComponent("second.txt")
        )

        let result = try await DuplicateFileScanner().scan(
            roots: [nested, root]
        )

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.statistics.hardLinkAliasCount, 0)
    }

    func testCancellationStopsBeforeReadingFiles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("same-content".utf8).write(
            to: root.appendingPathComponent("first.txt")
        )
        try Data("same-content".utf8).write(
            to: root.appendingPathComponent("second.txt")
        )
        let task = Task {
            try await DuplicateFileScanner().scan(roots: [root])
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testCloudPlaceholderPolicySkipsUndownloadedItems() {
        XCTAssertTrue(DuplicateFileScanner.isCloudPlaceholder(
            path: "/Users/test/Library/Mobile Documents/file.mov",
            isUbiquitousItem: true,
            downloadingStatus: .notDownloaded,
            fileSize: 100,
            allocatedSize: 0
        ))
        XCTAssertFalse(DuplicateFileScanner.isCloudPlaceholder(
            path: "/Users/test/Library/Mobile Documents/file.mov",
            isUbiquitousItem: true,
            downloadingStatus: .current,
            fileSize: 100,
            allocatedSize: 100
        ))
        XCTAssertTrue(DuplicateFileScanner.isCloudPlaceholder(
            path: "/Users/test/Library/CloudStorage/Drive/file.mov",
            isUbiquitousItem: false,
            downloadingStatus: nil,
            fileSize: 100,
            allocatedSize: 0
        ))
    }

    func testKeeperRecommendationPrefersProtectedReference() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("original.txt")
        let secondURL = root.appendingPathComponent("original copy.txt")
        try Data("same".utf8).write(to: firstURL)
        try Data("same".utf8).write(to: secondURL)

        let firstFingerprint = try XCTUnwrap(
            DuplicateFileScanner.currentFingerprint(for: firstURL)
        )
        let secondFingerprint = try XCTUnwrap(
            DuplicateFileScanner.currentFingerprint(for: secondURL)
        )
        let first = DuplicateFileItem(
            url: firstURL,
            name: firstURL.lastPathComponent,
            size: firstFingerprint.fileSize,
            allocatedSize: firstFingerprint.allocatedSize,
            createdAt: Date(),
            modifiedAt: Date(),
            contentTypeIdentifier: nil,
            fingerprint: firstFingerprint,
            protectionReason: .hardLinked
        )
        let second = DuplicateFileItem(
            url: secondURL,
            name: secondURL.lastPathComponent,
            size: secondFingerprint.fileSize,
            allocatedSize: secondFingerprint.allocatedSize,
            createdAt: Date().addingTimeInterval(-100),
            modifiedAt: Date().addingTimeInterval(-100),
            contentTypeIdentifier: nil,
            fingerprint: secondFingerprint,
            protectionReason: nil
        )

        let recommendation = DuplicateFileScanner.keeperRecommendation(
            for: [second, first]
        )

        XCTAssertEqual(recommendation.item.id, first.id)
        XCTAssertEqual(recommendation.reason, .protectedReference)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AppSiftDuplicateScanner-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
