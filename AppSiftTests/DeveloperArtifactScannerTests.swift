import Foundation
import XCTest
@testable import AppSift

final class DeveloperArtifactScannerTests: XCTestCase {
    func testFindsCargoRegistryAtExactGlobalPath() throws {
        let home = try makeHome()
        let registry = home
            .appendingPathComponent(".cargo", isDirectory: true)
            .appendingPathComponent("registry", isDirectory: true)
        try FileManager.default.createDirectory(
            at: registry.appendingPathComponent("cache", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeBytes(8_192, to: registry.appendingPathComponent("cache/package.crate"))

        let result = DeveloperArtifactScanner(
            homeURL: home,
            projectRoots: [],
            virtualEnvironmentURLs: []
        ).scan()

        let candidate = try XCTUnwrap(
            result.candidates.first { $0.kind == .cargoRegistry }
        )
        XCTAssertEqual(candidate.url.standardizedFileURL, registry.standardizedFileURL)
        XCTAssertEqual(candidate.size, 8_192)
        XCTAssertEqual(candidate.evidence, [.cargoRegistryPath])
        XCTAssertFalse(candidate.isSelectedByDefault)
        XCTAssertTrue(candidate.isRemovalEligible)
        XCTAssertTrue(
            DeveloperArtifactScanner.isSafeRemovalRoot(
                candidate,
                homeURL: home
            )
        )
        XCTAssertTrue(
            DeveloperArtifactScanner.isSafeRemovalRoot(
                resolvedPath: registry.path,
                homeURL: home,
                expectedSize: candidate.size
            )
        )
        XCTAssertFalse(
            DeveloperArtifactScanner.isSafeRemovalRoot(
                resolvedPath: registry.path,
                homeURL: home,
                expectedSize: candidate.size + 1
            )
        )

        try writeBytes(
            16_384,
            to: registry.appendingPathComponent("cache/changed.crate")
        )
        XCTAssertFalse(
            DeveloperArtifactScanner.isSafeRemovalRoot(
                candidate,
                homeURL: home
            )
        )
    }

    func testFindsRustTargetsOnlyWithAdjacentCargoManifest() throws {
        let home = try makeHome()
        let tools = home.appendingPathComponent("Tools", isDirectory: true)
        let project = tools
            .appendingPathComponent("AI-tools", isDirectory: true)
            .appendingPathComponent("FinalSub", isDirectory: true)
            .appendingPathComponent("src-tauri", isDirectory: true)
        let target = project.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("workspace".utf8).write(
            to: project.appendingPathComponent("Cargo.toml")
        )
        try writeBytes(16_384, to: target.appendingPathComponent("debug.bin"))

        let unrelatedTarget = tools
            .appendingPathComponent("unrelated", isDirectory: true)
            .appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unrelatedTarget,
            withIntermediateDirectories: true
        )
        try writeBytes(32_768, to: unrelatedTarget.appendingPathComponent("data.bin"))

        let result = DeveloperArtifactScanner(
            homeURL: home,
            projectRoots: [tools],
            virtualEnvironmentURLs: []
        ).scan()

        let targets = result.candidates.filter { $0.kind == .rustTarget }
        XCTAssertEqual(targets.count, 1)
        let candidate = try XCTUnwrap(targets.first)
        XCTAssertEqual(candidate.url.standardizedFileURL, target.standardizedFileURL)
        XCTAssertEqual(candidate.projectRoot?.standardizedFileURL, project.standardizedFileURL)
        XCTAssertEqual(candidate.name, "src-tauri target")
        XCTAssertEqual(candidate.size, 16_384)
        XCTAssertEqual(
            candidate.evidence,
            [.cargoManifest, .rustTargetDirectory]
        )
        XCTAssertTrue(
            DeveloperArtifactScanner.isSafeRemovalRoot(
                candidate,
                homeURL: home
            )
        )
    }

    func testRemovalValidationRejectsTargetOutsideBoundedProjectRoots() throws {
        let home = try makeHome()
        let project = home
            .appendingPathComponent("Library/Caches/NotAProject", isDirectory: true)
        let target = project.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("workspace".utf8).write(
            to: project.appendingPathComponent("Cargo.toml")
        )
        try writeBytes(8_192, to: target.appendingPathComponent("payload.bin"))

        let forged = DeveloperArtifactCandidate(
            url: target,
            name: "NotAProject target",
            kind: .rustTarget,
            size: 8_192,
            projectRoot: project,
            evidence: [.cargoManifest, .rustTargetDirectory],
            lastModified: nil,
            foreignOwnerCount: 0,
            wasTruncated: false
        )

        XCTAssertFalse(
            DeveloperArtifactScanner.isSafeRemovalRoot(
                forged,
                homeURL: home
            )
        )
    }

    func testDiscoversSubalignerEnvironmentOnlyWithMarkers() throws {
        let home = try makeHome()
        let workflow = home
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent("AI-tools", isDirectory: true)
            .appendingPathComponent("subtitle-local-workflow", isDirectory: true)
        let environment = workflow.appendingPathComponent(
            ".venv-subaligner",
            isDirectory: true
        )
        let bin = environment.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("home = /opt/python".utf8).write(
            to: environment.appendingPathComponent("pyvenv.cfg")
        )
        try writeBytes(4_096, to: bin.appendingPathComponent("python"))
        try writeBytes(8_192, to: environment.appendingPathComponent("lib/site-packages.bin"))

        let missingMarker = workflow.appendingPathComponent(
            "other/.venv-subaligner",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: missingMarker, withIntermediateDirectories: true)
        try writeBytes(4_096, to: missingMarker.appendingPathComponent("payload.bin"))

        let tools = home.appendingPathComponent("Tools", isDirectory: true)
        let result = DeveloperArtifactScanner(
            homeURL: home,
            projectRoots: [tools],
            virtualEnvironmentURLs: []
        ).scan()

        let environments = result.candidates.filter {
            $0.kind == .subalignerVirtualEnvironment
        }
        XCTAssertEqual(environments.count, 1)
        let candidate = try XCTUnwrap(environments.first)
        XCTAssertEqual(candidate.url.standardizedFileURL, environment.standardizedFileURL)
        // The scan includes the required `pyvenv.cfg` marker in the estimate.
        XCTAssertEqual(candidate.size, 12_288 + Int64("home = /opt/python".utf8.count))
        XCTAssertEqual(
            candidate.evidence,
            [
                .subalignerEnvironmentName,
                .pythonEnvironmentMarker,
                .pythonExecutable,
            ]
        )
        XCTAssertFalse(candidate.isSelectedByDefault)
    }

    func testRejectsSymlinkedProjectAndCargoRoots() throws {
        let home = try makeHome()
        let outside = home
            .deletingLastPathComponent()
            .appendingPathComponent("appsift-dev-artifacts-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }

        let outsideProject = outside.appendingPathComponent("Project", isDirectory: true)
        let outsideTarget = outsideProject.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideTarget, withIntermediateDirectories: true)
        try Data("workspace".utf8).write(
            to: outsideProject.appendingPathComponent("Cargo.toml")
        )
        try writeBytes(8_192, to: outsideTarget.appendingPathComponent("payload.bin"))

        let tools = home.appendingPathComponent("Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: tools.appendingPathComponent("linked-project"),
            withDestinationURL: outsideProject
        )

        let cargoParent = home.appendingPathComponent(".cargo", isDirectory: true)
        try FileManager.default.createDirectory(at: cargoParent, withIntermediateDirectories: true)
        let realRegistry = outside.appendingPathComponent("registry", isDirectory: true)
        try FileManager.default.createDirectory(at: realRegistry, withIntermediateDirectories: true)
        try writeBytes(8_192, to: realRegistry.appendingPathComponent("pkg"))
        try FileManager.default.createSymbolicLink(
            at: cargoParent.appendingPathComponent("registry"),
            withDestinationURL: realRegistry
        )

        let result = DeveloperArtifactScanner(
            homeURL: home,
            projectRoots: [tools],
            virtualEnvironmentURLs: []
        ).scan()

        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testRejectsProjectRootsOwnedByAnotherUser() throws {
        let home = try makeHome()
        let tools = home.appendingPathComponent("Tools", isDirectory: true)
        let project = tools.appendingPathComponent("RustProject", isDirectory: true)
        let target = project.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("workspace".utf8).write(
            to: project.appendingPathComponent("Cargo.toml")
        )
        try writeBytes(8_192, to: target.appendingPathComponent("payload.bin"))

        // Use a deliberately different owner ID rather than chowning a test
        // fixture (which would require elevated privileges).
        let differentUserID: uid_t = getuid() == 0 ? 1 : 0
        let result = DeveloperArtifactScanner(
            homeURL: home,
            projectRoots: [tools],
            virtualEnvironmentURLs: [],
            currentUserID: differentUserID
        ).scan()

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertGreaterThan(result.inaccessibleRootCount, 0)
    }

    func testTruncatedMeasurementIsReportedAndNotRemovalEligible() throws {
        let home = try makeHome()
        let registry = home
            .appendingPathComponent(".cargo", isDirectory: true)
            .appendingPathComponent("registry", isDirectory: true)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        for index in 0..<3 {
            try writeBytes(
                1_024,
                to: registry.appendingPathComponent("package-\(index)")
            )
        }

        let result = DeveloperArtifactScanner(
            homeURL: home,
            projectRoots: [],
            virtualEnvironmentURLs: [],
            maximumEntriesPerCandidate: 1
        ).scan()

        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertTrue(candidate.wasTruncated)
        XCTAssertTrue(result.wasTruncated)
        XCTAssertFalse(candidate.isRemovalEligible)
    }

    func testExplicitEnvironmentOutsideHomeIsIgnored() throws {
        let home = try makeHome()
        let outside = home.deletingLastPathComponent()
            .appendingPathComponent("appsift-subaligner-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try Data("home=/tmp/python".utf8).write(
            to: outside.appendingPathComponent("pyvenv.cfg")
        )
        try writeBytes(1_024, to: outside.appendingPathComponent("bin/python"))

        let result = DeveloperArtifactScanner(
            homeURL: home,
            projectRoots: [],
            virtualEnvironmentURLs: [
                outside.appendingPathComponent(".venv-subaligner", isDirectory: true)
            ]
        ).scan()

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertGreaterThan(result.inaccessibleRootCount, 0)
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".appsift-developer-artifacts-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home.standardizedFileURL
    }

    private func writeBytes(_ count: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x5A, count: count).write(to: url, options: .atomic)
    }
}
