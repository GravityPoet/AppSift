import Darwin
import Foundation
import XCTest
@testable import AppSift

final class ScannerScaleQATests: XCTestCase {
    func testSimilarImageProductionLimitsRemainTwentyThousandAndTwoMillionPairs() {
        XCTAssertEqual(
            SimilarImageScanner.Limits.production,
            SimilarImageScanner.Limits(
                maximumImages: 20_000,
                maximumCandidatePairs: 2_000_000
            )
        )
    }

    func testSimilarImageDiscoveryStopsAtConfiguredImageLimit() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftSimilarImageLimit")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<3 {
            try writeQAGradientPNG(
                to: root.appendingPathComponent("image-\(index).png"),
                width: 96,
                height: 72
            )
        }
        let scanner = SimilarImageScanner(
            limits: .init(maximumImages: 2, maximumCandidatePairs: 2_000_000)
        )

        let result = try await scanner.scan(rootURL: root)

        XCTAssertEqual(result.scannedImageCount, 2)
        XCTAssertTrue(result.wasTruncated)
    }

    func testSimilarImagePairGenerationStopsAtConfiguredComparisonLimit() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftSimilarPairLimit")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<3 {
            try writeQAGradientPNG(
                to: root.appendingPathComponent("image-\(index).png"),
                width: 128 + index * 8,
                height: 96 + index * 6
            )
        }
        let scanner = SimilarImageScanner(
            limits: .init(maximumImages: 20_000, maximumCandidatePairs: 1)
        )

        let result = try await scanner.scan(rootURL: root)

        XCTAssertEqual(result.scannedImageCount, 3)
        XCTAssertTrue(result.wasTruncated)
        XCTAssertEqual(result.groups.first?.items.count, 2)
    }

    func testSimilarImagePreCancellationReadsNoImages() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftSimilarCancel")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeQAGradientPNG(
            to: root.appendingPathComponent("image.png"),
            width: 128,
            height: 96
        )
        let task = Task {
            try await SimilarImageScanner().scan(rootURL: root)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled similar-image scan must stop before analysis.")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testSpaceLensLargeDirectoryCompletesWithinBudgetAndCountsEveryFile() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftSpaceLensScale")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileCount = 1_200
        for index in 0..<fileCount {
            try Data(repeating: UInt8(index % 251), count: 128).write(
                to: root.appendingPathComponent("item-\(index).bin")
            )
        }

        let residentBytesBefore = currentQAResidentMemoryBytes()
        let startedAt = Date()
        let result = try await SpaceLensScanner().scan(root: root)
        let elapsed = Date().timeIntervalSince(startedAt)
        let residentBytesAfter = currentQAResidentMemoryBytes()

        XCTAssertEqual(result.statistics.fileCount, fileCount)
        XCTAssertEqual(result.root.fileCount, fileCount)
        XCTAssertLessThan(elapsed, 20, "1,200-file Space Lens fixture took \(elapsed) seconds")
        assertQAResidentGrowth(
            from: residentBytesBefore,
            to: residentBytesAfter,
            maximumBytes: 96 * 1_024 * 1_024,
            workload: "1,200-file Space Lens"
        )
    }

    func testSpaceLensCancellationRespondsWhileDirectoryScanIsActive() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftSpaceLensActiveCancel")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<1_000 {
            try Data([UInt8(index % 251)]).write(
                to: root.appendingPathComponent("item-\(index).bin")
            )
        }
        let gate = QACancellationGate()
        let task = Task {
            try await SpaceLensScanner().scan(root: root) { progress in
                gate.pauseOnce(when: progress.examinedItemCount >= 250)
            }
        }
        XCTAssertEqual(gate.waitForPause(timeout: 5), .success)

        let cancellationStartedAt = Date()
        task.cancel()
        gate.resume()
        do {
            _ = try await task.value
            XCTFail("Space Lens must observe cancellation during traversal.")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(cancellationStartedAt),
            2,
            "Space Lens cancellation must not wait for the remaining traversal."
        )
    }

    func testSpaceLensHardLinkSetCountsPhysicalAllocationOnceAtScale() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftSpaceLensHardLinks")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<100 {
            let original = root.appendingPathComponent("original-\(index).bin")
            let alias = root.appendingPathComponent("alias-\(index).bin")
            try Data(repeating: UInt8(index), count: 4_096).write(to: original)
            XCTAssertEqual(link(original.path, alias.path), 0)
        }

        let result = try await SpaceLensScanner().scan(root: root)
        let fileNodes = result.root.children.filter { !$0.isContainer }

        XCTAssertEqual(result.statistics.fileCount, 200)
        XCTAssertEqual(result.statistics.hardLinkAliasCount, 100)
        XCTAssertEqual(fileNodes.count(where: { $0.allocatedSize == 0 }), 100)
        XCTAssertTrue(fileNodes.allSatisfy { !$0.isRemovalEligible })
    }

    func testDuplicateScannerLargeDirectoryCompletesWithinBudget() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftDuplicateScale")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<1_000 {
            let bytes = withUnsafeBytes(of: UInt64(index).bigEndian) { Data($0) }
            try bytes.write(to: root.appendingPathComponent("unique-\(index).bin"))
        }
        let duplicateData = Data(repeating: 0x7A, count: 4_096)
        try duplicateData.write(to: root.appendingPathComponent("duplicate-a.bin"))
        try duplicateData.write(to: root.appendingPathComponent("duplicate-b.bin"))

        let residentBytesBefore = currentQAResidentMemoryBytes()
        let startedAt = Date()
        let result = try await DuplicateFileScanner().scan(roots: [root])
        let elapsed = Date().timeIntervalSince(startedAt)
        let residentBytesAfter = currentQAResidentMemoryBytes()

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.duplicateFileCount, 1)
        XCTAssertGreaterThanOrEqual(result.statistics.examinedFileCount, 1_002)
        XCTAssertLessThan(elapsed, 20, "1,002-file duplicate scan took \(elapsed) seconds")
        assertQAResidentGrowth(
            from: residentBytesBefore,
            to: residentBytesAfter,
            maximumBytes: 96 * 1_024 * 1_024,
            workload: "1,002-file duplicate scan"
        )
    }

    func testDuplicateScannerCancellationRespondsDuringEnumeration() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftDuplicateActiveCancel")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<1_000 {
            try Data([UInt8(index % 251)]).write(
                to: root.appendingPathComponent("item-\(index).bin")
            )
        }
        let gate = QACancellationGate()
        let task = Task {
            try await DuplicateFileScanner().scan(roots: [root]) { progress in
                gate.pauseOnce(when: progress.examinedFileCount >= 200)
            }
        }
        XCTAssertEqual(gate.waitForPause(timeout: 5), .success)

        let cancellationStartedAt = Date()
        task.cancel()
        gate.resume()
        do {
            _ = try await task.value
            XCTFail("Duplicate scanning must observe cancellation during enumeration.")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(cancellationStartedAt),
            2,
            "Duplicate cancellation must not wait for the remaining enumeration."
        )
    }

    func testDisconnectedExternalDiskFailsWithoutReturningPartialTree() async throws {
        let root = try makeQATemporaryDirectory(prefix: "AppSiftDisconnectedVolume")
        let missingRoot = root.appendingPathComponent("Mounted Disk", isDirectory: true)
        try FileManager.default.createDirectory(at: missingRoot, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: root)

        do {
            _ = try await SpaceLensScanner().scan(root: missingRoot)
            XCTFail("A disconnected disk must not produce a partial result.")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileReadNoSuchFile)
        }
    }
}

private func currentQAResidentMemoryBytes() -> UInt64? {
    var information = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info_data_t>.size
            / MemoryLayout<natural_t>.size
    )
    let status = withUnsafeMutablePointer(to: &information) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                $0,
                &count
            )
        }
    }
    guard status == KERN_SUCCESS else { return nil }
    return UInt64(information.resident_size)
}

private func assertQAResidentGrowth(
    from before: UInt64?,
    to after: UInt64?,
    maximumBytes: UInt64,
    workload: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let before, let after else {
        XCTFail("Could not read resident memory for \(workload).", file: file, line: line)
        return
    }
    let growth = after > before ? after - before : 0
    XCTAssertLessThanOrEqual(
        growth,
        maximumBytes,
        "\(workload) retained \(growth) bytes; ceiling is \(maximumBytes).",
        file: file,
        line: line
    )
}

private final class QACancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private var hasPaused = false

    func pauseOnce(when condition: Bool) {
        guard condition else { return }
        lock.lock()
        let shouldPause = !hasPaused
        hasPaused = true
        lock.unlock()
        guard shouldPause else { return }
        entered.signal()
        _ = released.wait(timeout: .now() + 10)
    }

    func waitForPause(timeout: TimeInterval) -> DispatchTimeoutResult {
        entered.wait(timeout: .now() + timeout)
    }

    func resume() {
        released.signal()
    }
}
