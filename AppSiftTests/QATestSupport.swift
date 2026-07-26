import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AppSift

func makeQATemporaryDirectory(prefix: String) throws -> URL {
    // Use an owned cache path rather than /tmp. SQLite's NOFOLLOW mode rejects
    // macOS's /var and /tmp compatibility symlinks, while real browser data
    // lives below the user's non-symlinked home directory.
    let cacheRoot = try FileManager.default.url(
        for: .cachesDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    ).appendingPathComponent("AppSift-QAFixtures", isDirectory: true)
    try FileManager.default.createDirectory(
        at: cacheRoot,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let url = cacheRoot
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    return url.standardizedFileURL
}

func writeQAPlist(_ value: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try PropertyListSerialization.data(
        fromPropertyList: value,
        format: .binary,
        options: 0
    )
    try data.write(to: url, options: .atomic)
}

func makeQAIOSBackup(
    at url: URL,
    deviceID: String,
    deviceName: String,
    date: Date,
    encrypted: Bool = true
) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try writeQAPlist(
        [
            "Target Identifier": deviceID,
            "Device Name": deviceName,
            "Product Type": "iPhone17,1",
            "Product Version": "18.5",
            "Last Backup Date": date,
        ],
        to: url.appendingPathComponent("Info.plist")
    )
    try writeQAPlist(
        ["IsEncrypted": encrypted],
        to: url.appendingPathComponent("Manifest.plist")
    )
    try writeQAPlist(
        ["SnapshotState": "finished", "Date": date],
        to: url.appendingPathComponent("Status.plist")
    )
    try Data(repeating: 0x55, count: 8_192).write(
        to: url.appendingPathComponent("payload.bin"),
        options: .atomic
    )
}

func writeQAGradientPNG(to url: URL, width: Int, height: Int) throws {
    precondition(width > 1 && height > 1)
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            let horizontal = UInt8((x * 220) / max(1, width - 1) + 16)
            let vertical = UInt8((y * 96) / max(1, height - 1) + 64)
            bytes[offset] = horizontal
            bytes[offset + 1] = vertical
            bytes[offset + 2] = UInt8((Int(horizontal) + Int(vertical)) / 2)
            bytes[offset + 3] = 255
        }
    }
    let data = Data(bytes)
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
          ),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
          ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

@MainActor
func waitForQACondition(
    timeout: TimeInterval = 8,
    pollIntervalNanoseconds: UInt64 = 20_000_000,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline {
            XCTFail("Timed out waiting for asynchronous QA condition.", file: file, line: line)
            throw CocoaError(.userCancelled)
        }
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
}

final class DisposableTrashRecycler: @unchecked Sendable {
    let trashRoot: URL
    private let failedPaths: Set<String>

    init(trashRoot: URL, failedPaths: Set<String> = []) throws {
        self.trashRoot = trashRoot.standardizedFileURL
        self.failedPaths = failedPaths
        try FileManager.default.createDirectory(
            at: self.trashRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
    }

    func recycle(_ urls: [URL]) async -> [URL: URL] {
        var mapping: [URL: URL] = [:]
        for url in urls where !failedPaths.contains(url.path) {
            let destination = trashRoot.appendingPathComponent(
                "\(UUID().uuidString)-\(url.lastPathComponent)"
            )
            do {
                try FileManager.default.moveItem(at: url, to: destination)
                mapping[url] = destination
            } catch {
                continue
            }
        }
        return mapping
    }
}

func makeQATrashService(
    historyURL: URL,
    trashRoot: URL,
    failedPaths: Set<String> = []
) throws -> ReviewedTrashService {
    try makeQATrashService(
        historyStore: ReviewedTrashHistoryStore(fileURL: historyURL),
        trashRoot: trashRoot,
        failedPaths: failedPaths
    )
}

func makeQATrashService(
    historyStore: ReviewedTrashHistoryStore,
    trashRoot: URL,
    failedPaths: Set<String> = []
) throws -> ReviewedTrashService {
    let recycler = try DisposableTrashRecycler(
        trashRoot: trashRoot,
        failedPaths: failedPaths
    )
    return ReviewedTrashService(
        historyStore: historyStore,
        additionalTrashRoots: [trashRoot],
        recycler: { urls in await recycler.recycle(urls) }
    )
}

func makeQATrashCandidate(
    for url: URL,
    allowedRoot: URL,
    requiresDirectChild: Bool = false
) throws -> ReviewedTrashCandidate {
    ReviewedTrashCandidate(
        id: url.path,
        name: url.lastPathComponent,
        url: url,
        size: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
        fingerprint: try XCTUnwrap(ReviewedTrashFingerprint.read(at: url)),
        allowedRoot: allowedRoot,
        requiresDirectChild: requiresDirectChild
    )
}
