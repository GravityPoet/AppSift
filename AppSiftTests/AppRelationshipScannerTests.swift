import XCTest
@testable import AppSift

final class AppRelationshipScannerTests: XCTestCase {
    func testRelationshipRequiresSameTeamAndExactGroupIdentifier() throws {
        let sharedGroup = "TEAM123456.shared.documents"
        let selected = makeReference(
            id: "selected",
            name: "Word",
            teamIdentifier: "TEAM123456",
            groups: [sharedGroup]
        )
        let exactPeer = makeReference(
            id: "peer",
            name: "Excel",
            teamIdentifier: "TEAM123456",
            groups: [sharedGroup]
        )
        let sameTeamOnly = makeReference(
            id: "same-team",
            name: "Teams",
            teamIdentifier: "TEAM123456",
            groups: ["TEAM123456.different"]
        )
        let crossTeam = makeReference(
            id: "cross-team",
            name: "Imposter",
            teamIdentifier: "OTHER12345",
            groups: [sharedGroup]
        )

        let result = AppRelationshipScanner.scan(
            applications: [selected, exactPeer, sameTeamOnly, crossTeam],
            selectedApplicationID: selected.id
        )
        let selectedGroups = result.groups(containing: selected.id)

        XCTAssertEqual(selectedGroups.count, 1)
        XCTAssertEqual(selectedGroups.first?.applications.map(\.id), ["peer", "selected"])
        XCTAssertEqual(result.relatedApplications(to: selected.id).map(\.id), ["peer"])
        XCTAssertFalse(result.relatedApplications(to: selected.id).contains { $0.id == sameTeamOnly.id })
        XCTAssertFalse(result.relatedApplications(to: selected.id).contains { $0.id == crossTeam.id })
    }

    func testUnsignedAndMalformedDeclarationsAreNotRelationshipEvidence() {
        let unsigned = makeReference(
            id: "unsigned",
            name: "Unsigned",
            teamIdentifier: "TEAM123456",
            groups: ["TEAM123456.shared"],
            status: .adHoc
        )
        let malformed = makeReference(
            id: "malformed",
            name: "Malformed",
            teamIdentifier: "TEAM123456",
            groups: ["TEAM123456../escape", "group.valid"]
        )

        let result = AppRelationshipScanner.scan(applications: [unsigned, malformed])

        XCTAssertEqual(result.ignoredUnsignedApplicationCount, 1)
        XCTAssertEqual(result.invalidGroupIdentifierCount, 1)
        XCTAssertEqual(result.groups.map(\.identifier), ["group.valid"])
    }

    func testPendingSignatureIsInspectedAndSelectedAppIsPrioritizedBeforeLimit() {
        let selected = makeReference(
            id: "selected",
            name: "Zulu",
            teamIdentifier: nil,
            groups: [],
            inspectionState: .pending
        )
        let alphabeticFirst = makeReference(
            id: "first",
            name: "Alpha",
            teamIdentifier: "FIRST12345",
            groups: ["FIRST12345.group"]
        )
        let inspectedSignature = signature(
            teamIdentifier: "SELECT1234",
            groups: ["SELECT1234.group"]
        )

        let result = AppRelationshipScanner.scan(
            applications: [alphabeticFirst, selected],
            selectedApplicationID: selected.id,
            maximumApplicationCount: 1,
            signatureProvider: { url in
                XCTAssertEqual(url, selected.url)
                return inspectedSignature
            }
        )

        XCTAssertEqual(result.scannedApplicationCount, 1)
        XCTAssertTrue(result.wasTruncated)
        XCTAssertEqual(result.groups.map(\.identifier), ["SELECT1234.group"])
    }

    func testLocationInspectionDoesNotFollowSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftRelationshipTests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let groupRoot = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: groupRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let groupIdentifier = "TEAM123456.shared"
        try FileManager.default.createSymbolicLink(
            at: groupRoot.appendingPathComponent(groupIdentifier),
            withDestinationURL: target
        )
        let reference = makeReference(
            id: "selected",
            name: "Example",
            teamIdentifier: "TEAM123456",
            groups: [groupIdentifier]
        )

        let result = AppRelationshipScanner.scan(
            applications: [reference],
            selectedApplicationID: reference.id,
            homeURL: home
        )
        let locations = try XCTUnwrap(result.groups.first?.locations)

        XCTAssertEqual(
            locations.first { $0.kind == .groupContainer }?.status,
            .unsafeType
        )
        XCTAssertEqual(
            locations.first { $0.kind == .applicationScripts }?.status,
            .notFound
        )
    }

    func testCancellationReturnsOnlyBoundedPartialEvidence() {
        let reference = makeReference(
            id: "selected",
            name: "Example",
            teamIdentifier: "TEAM123456",
            groups: ["TEAM123456.one", "TEAM123456.two"]
        )
        let cancellationCounter = CancellationCounter()

        let result = AppRelationshipScanner.scan(
            applications: [reference],
            shouldCancel: { cancellationCounter.nextShouldCancel() }
        )

        XCTAssertTrue(result.wasCancelled)
        XCTAssertLessThan(result.groups.count, 2)
    }

    private func makeReference(
        id: String,
        name: String,
        teamIdentifier: String?,
        groups: [String],
        status: AppSignatureStatus = .developerSigned,
        inspectionState: AppSignatureInspectionState = .inspected
    ) -> AppRelationshipApplicationReference {
        AppRelationshipApplicationReference(
            id: id,
            name: name,
            bundleIdentifier: "com.example.\(id)",
            url: URL(fileURLWithPath: "/Applications/\(name).app"),
            signature: AppSignatureMetadata(
                status: status,
                signingIdentifier: "com.example.\(id)",
                teamIdentifier: teamIdentifier,
                entitlementIdentifiers: groups,
                sharedContainerIdentifiers: groups
            ),
            signatureInspectionState: inspectionState
        )
    }

    private func signature(
        teamIdentifier: String,
        groups: [String]
    ) -> AppSignatureMetadata {
        AppSignatureMetadata(
            status: .developerSigned,
            signingIdentifier: "com.example.selected",
            teamIdentifier: teamIdentifier,
            entitlementIdentifiers: groups,
            sharedContainerIdentifiers: groups
        )
    }
}

private final class CancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func nextShouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count >= 2
    }
}
