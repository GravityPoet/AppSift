import XCTest
@testable import AppSift

final class StorageAuditServiceTests: XCTestCase {
    func testFixtureScanReportsCoverageAndVirtualMachineAsset() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftStorageAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vm = root.appendingPathComponent("Windows.utm", isDirectory: true)
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
        let canonicalVMPath = vm.resolvingSymlinksInPath().path
        try Data(repeating: 0x41, count: 4096).write(
            to: vm.appendingPathComponent("disk.qcow2")
        )
        try Data(repeating: 0x42, count: 512).write(
            to: root.appendingPathComponent("ordinary.bin")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: root.appendingPathComponent("ordinary.bin")
        )

        let volume = SystemVolumeSnapshot(
            path: root.path,
            name: "QA External",
            totalBytes: 10_000_000,
            availableBytes: 5_000_000,
            isInternal: false,
            isRemovable: true,
            isReadOnly: false
        )
        let service = StorageAuditService(
            volumeProvider: { [volume] },
            processProvider: {
                [SystemProcessMemorySnapshot(
                    pid: 123,
                    name: "QEMU",
                    residentBytes: 4_000_000,
                    commandLine: "qemu -drive file=\(canonicalVMPath)/disk.qcow2"
                )]
            }
        )

        let report = await service.scan(includeInternal: false)
        let result = try XCTUnwrap(report.volumes.first)
        XCTAssertEqual(result.status, .scanned)
        XCTAssertGreaterThanOrEqual(result.fileCount, 2)
        XCTAssertGreaterThanOrEqual(result.directoryCount, 2)
        XCTAssertGreaterThanOrEqual(result.symbolicLinkCount, 1)
        XCTAssertTrue(report.virtualMachines.contains { $0.path.hasSuffix("/Windows.utm") })
        XCTAssertTrue(report.virtualMachines.contains { $0.isRunning })
        XCTAssertTrue(report.coverageNotes.contains { $0.contains("Windows") })
    }

    func testTimeMachineVolumeIsMetadataOnly() async throws {
        let volume = SystemVolumeSnapshot(
            path: "/Volumes/Time Machine",
            name: "Time Machine",
            totalBytes: 100,
            availableBytes: 50,
            isInternal: false,
            isRemovable: true,
            isReadOnly: false
        )
        let service = StorageAuditService(volumeProvider: { [volume] })
        let report = await service.scan(includeInternal: false)
        XCTAssertEqual(report.volumes.first?.status, .metadataOnly)
        XCTAssertEqual(report.volumes.first?.fileCount, 0)
        XCTAssertFalse(report.coverageNotes.isEmpty)
    }

    func testSystemVolumeIsMetadataOnlyAndDataVolumeIsScanned() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftStorageAudit-Data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x43, count: 128).write(to: root.appendingPathComponent("data.bin"))

        let system = SystemVolumeSnapshot(
            path: "/",
            name: "System",
            totalBytes: 100,
            availableBytes: 50,
            isInternal: true,
            isRemovable: false,
            isReadOnly: true
        )
        let data = SystemVolumeSnapshot(
            path: root.path,
            name: "Data",
            totalBytes: 100,
            availableBytes: 40,
            isInternal: true,
            isRemovable: false,
            isReadOnly: false,
            volumeRole: "Data"
        )
        let report = await StorageAuditService(volumeProvider: { [system, data] })
            .scan(includeInternal: true)

        XCTAssertEqual(report.volumes.map(\.path), ["/", root.path])
        XCTAssertEqual(report.volumes.first?.status, .metadataOnly)
        XCTAssertEqual(report.volumes.first?.scannedItemCount, 0)
        XCTAssertEqual(report.volumes.last?.status, .scanned)
        XCTAssertEqual(report.volumes.last?.fileCount, 1)
    }

    func testConfiguredFirmlinkIsCountedAndNotTraversed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftStorageAudit-Firmlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 256).write(to: linked.appendingPathComponent("inside.bin"))
        try Data(repeating: 0x45, count: 64).write(to: root.appendingPathComponent("outside.bin"))

        let volume = SystemVolumeSnapshot(
            path: root.path,
            name: "Firmlink Fixture",
            totalBytes: 100,
            availableBytes: 50,
            isInternal: false,
            isRemovable: true,
            isReadOnly: false
        )
        let report = await StorageAuditService(
            volumeProvider: { [volume] },
            firmlinkRoots: [linked.path]
        ).scan(includeInternal: false)
        let result = try XCTUnwrap(report.volumes.first)

        XCTAssertEqual(result.firmlinkSkippedCount, 1)
        XCTAssertEqual(result.fileCount, 1)
        XCTAssertFalse(result.topItems.contains { $0.path.contains("inside.bin") })
    }
}
