import AppKit
import Foundation

@_silgen_name("fs_snapshot_list")
private func fsSnapshotList(
    _ fd: CInt,
    _ attrList: UnsafeMutablePointer<attrlist>,
    _ attrBuffer: UnsafeMutableRawPointer,
    _ bufferSize: Int,
    _ flags: UInt32
) -> CInt

actor TimeMachineSnapshotService {
    enum ServiceError: LocalizedError {
        case commandFailed(String)
        case backupInProgress
        case authorizationCancelled
        case authorizationFailed

        var errorDescription: String? {
            switch self {
            case .commandFailed(let detail):
                return detail
            case .backupInProgress:
                return String(localized: "Time Machine is backing up. Wait for it to finish before deleting snapshots.")
            case .authorizationCancelled:
                return String(localized: "Administrator authorization was cancelled. No snapshots were deleted.")
            case .authorizationFailed:
                return String(localized: "Administrator authorization failed. No snapshots were deleted.")
            }
        }
    }

    func scan() throws -> TimeMachineSnapshotScanResult {
        let snapshotOutput = try runProcess(
            executable: "/usr/bin/tmutil",
            arguments: ["listlocalsnapshots", "/"]
        )
        let statusOutput = (try? runProcess(
            executable: "/usr/bin/tmutil",
            arguments: ["status"]
        )) ?? ""

        let privateSizes = Self.apfsSnapshotPrivateSizes()

        return TimeMachineSnapshotScanResult(
            snapshots: Self.parseSnapshots(snapshotOutput, privateSizes: privateSizes),
            isBackupRunning: Self.parseBackupRunning(statusOutput)
        )
    }

    func delete(_ snapshots: [TimeMachineSnapshot]) async throws -> TimeMachineSnapshotDeletionResult {
        guard !snapshots.isEmpty else {
            return TimeMachineSnapshotDeletionResult(
                deletedCount: 0,
                freedSpace: 0,
                remainingSnapshotIDs: []
            )
        }

        let current = try scan()
        guard !current.isBackupRunning else { throw ServiceError.backupInProgress }

        let currentIDs = Set(current.snapshots.map(\.id))
        let requestedIDs = Set(snapshots.map(\.id))
        let existingIDs = requestedIDs.intersection(currentIDs)
        guard !existingIDs.isEmpty else {
            return TimeMachineSnapshotDeletionResult(
                deletedCount: 0,
                freedSpace: 0,
                remainingSnapshotIDs: []
            )
        }

        let validTokens = existingIDs.sorted().filter(Self.isValidDateToken)
        guard validTokens.count == existingIDs.count else {
            throw ServiceError.commandFailed(String(localized: "Snapshot identifiers changed. Refresh and try again."))
        }

        let beforeFree = currentFreeSpace()
        let deleteCommands = validTokens
            .map { "/usr/bin/tmutil deletelocalsnapshots \($0)" }
            .joined(separator: "; ")
        // A command can fail for one stale snapshot after earlier snapshots
        // were already deleted. Always rescan and report the observed result
        // instead of trusting the shell's final exit status.
        let commands = "\(deleteCommands); true"
        let script = "do shell script \(appleScriptLiteral(commands)) with administrator privileges"

        let executionResult: (success: Bool, cancelled: Bool) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let appleScript = NSAppleScript(source: script)
                var errorInfo: NSDictionary?
                appleScript?.executeAndReturnError(&errorInfo)
                let errorNumber = errorInfo?[NSAppleScript.errorNumber] as? Int
                continuation.resume(returning: (errorInfo == nil, errorNumber == -128))
            }
        }

        if executionResult.cancelled { throw ServiceError.authorizationCancelled }
        guard executionResult.success else { throw ServiceError.authorizationFailed }

        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let refreshed = try scan()
        let remainingIDs = Set(refreshed.snapshots.map(\.id)).intersection(existingIDs)
        let deletedCount = existingIDs.count - remainingIDs.count
        let freedSpace = max(0, currentFreeSpace() - beforeFree)

        return TimeMachineSnapshotDeletionResult(
            deletedCount: deletedCount,
            freedSpace: freedSpace,
            remainingSnapshotIDs: remainingIDs
        )
    }

    static func parseSnapshots(
        _ output: String,
        privateSizes: [String: Int64] = [:]
    ) -> [TimeMachineSnapshot] {
        let prefix = "com.apple.TimeMachine."
        let suffix = ".local"

        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> TimeMachineSnapshot? in
                let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }

                let tokenStart = name.index(name.startIndex, offsetBy: prefix.count)
                let tokenEnd = name.index(name.endIndex, offsetBy: -suffix.count)
                let dateToken = String(name[tokenStart..<tokenEnd])
                guard isValidDateToken(dateToken),
                      let createdAt = snapshotDateFormatter.date(from: dateToken)
                else {
                    return nil
                }

                return TimeMachineSnapshot(
                    name: name,
                    dateToken: dateToken,
                    createdAt: createdAt,
                    privateSize: privateSizes[name]
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func parseBackupRunning(_ output: String) -> Bool {
        output.range(of: #"Running\s*=\s*1\s*;"#, options: .regularExpression) != nil
    }

    static func isValidDateToken(_ token: String) -> Bool {
        guard token.range(
            of: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#,
            options: .regularExpression
        ) != nil else {
            return false
        }
        return snapshotDateFormatter.date(from: token) != nil
    }

    private static let snapshotDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.isLenient = false
        return formatter
    }()

    private static let apfsSnapshotVolumePaths = [
        "/System/Volumes/Data",
        "/",
    ]

    static func apfsSnapshotPrivateSizes(volumePaths: [String] = apfsSnapshotVolumePaths) -> [String: Int64] {
        volumePaths.reduce(into: [:]) { result, path in
            for (name, privateSize) in privateSizesOnAPFSVolume(path) {
                result[name] = privateSize
            }
        }
    }

    private static func privateSizesOnAPFSVolume(_ path: String) -> [String: Int64] {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(
            UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(bitPattern: ATTR_CMN_NAME)
        )
        attributes.forkattr = attrgroup_t(UInt32(bitPattern: ATTR_CMNEXT_PRIVATESIZE))

        var results: [String: Int64] = [:]
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize,
            alignment: MemoryLayout<Int64>.alignment
        )
        defer { buffer.deallocate() }

        while true {
            let count = fsSnapshotList(fd, &attributes, buffer, bufferSize, 0)
            guard count > 0 else { break }

            parseAPFSSnapshotMetadata(buffer: buffer, count: Int(count), into: &results)
        }

        return results
    }

    private static func parseAPFSSnapshotMetadata(
        buffer: UnsafeMutableRawPointer,
        count: Int,
        into results: inout [String: Int64]
    ) {
        var offset = 0

        for _ in 0..<count {
            let record = buffer.advanced(by: offset)
            let recordLength = Int(record.load(as: UInt32.self))
            guard recordLength > 0 else { break }

            var cursor = record.advanced(by: MemoryLayout<UInt32>.size)
            let returnedAttributes = cursor.load(as: attribute_set_t.self)
            cursor = cursor.advanced(by: MemoryLayout<attribute_set_t>.size)

            var snapshotName: String?
            if UInt32(returnedAttributes.commonattr) & UInt32(bitPattern: ATTR_CMN_NAME) != 0 {
                let referencePointer = cursor
                let reference = referencePointer.load(as: attrreference_t.self)
                cursor = cursor.advanced(by: MemoryLayout<attrreference_t>.size)

                if reference.attr_dataoffset > 0, reference.attr_length > 0 {
                    let namePointer = referencePointer
                        .advanced(by: Int(reference.attr_dataoffset))
                        .assumingMemoryBound(to: CChar.self)
                    snapshotName = String(cString: namePointer)
                }
            }

            var privateSize: Int64?
            if UInt32(returnedAttributes.forkattr) & UInt32(bitPattern: ATTR_CMNEXT_PRIVATESIZE) != 0 {
                privateSize = cursor.load(as: Int64.self)
            }

            if let snapshotName, let privateSize {
                results[snapshotName] = privateSize
            }

            offset += recordLength
        }
    }

    private func runProcess(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw ServiceError.commandFailed(error.localizedDescription)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServiceError.commandFailed(
                detail?.isEmpty == false ? detail! : String(localized: "Time Machine command failed.")
            )
        }

        return output
    }

    private func currentFreeSpace() -> Int64 {
        guard let value = try? FileManager.default.attributesOfFileSystem(forPath: "/")[.systemFreeSize]
            as? NSNumber else {
            return 0
        }
        return value.int64Value
    }

    private func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
