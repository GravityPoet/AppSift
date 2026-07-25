import AppKit
import Darwin
import Foundation

struct MacOSSoftwareUpdate: Identifiable, Hashable, Sendable {
    let label: String
    let title: String
    let version: String?
    let sizeBytes: Int64?
    let isRecommended: Bool
    let requiresRestart: Bool

    var id: String { label }
}

struct MacOSUpdateScanResult: Sendable {
    let updates: [MacOSSoftwareUpdate]
    let checkedAt: Date
}

enum MacOSUpdateError: LocalizedError, Equatable {
    case toolUnavailable
    case timedOut
    case commandFailed
    case outputTooLarge
    case unsupportedOutput

    var errorDescription: String? {
        switch self {
        case .toolUnavailable: return String(localized: "The macOS Software Update tool is unavailable.")
        case .timedOut: return String(localized: "macOS did not finish checking for updates in time.")
        case .commandFailed: return String(localized: "macOS could not check for system updates.")
        case .outputTooLarge: return String(localized: "The Software Update response exceeded AppSift's safety limit.")
        case .unsupportedOutput: return String(localized: "macOS returned an update format AppSift could not verify safely.")
        }
    }
}

actor MacOSUpdateScanner {
    private static let executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
    private static let timeout: TimeInterval = 120
    private static let maximumOutputBytes = 2_000_000

    func scan() throws -> MacOSUpdateScanResult {
        guard FileManager.default.isExecutableFile(atPath: Self.executableURL.path) else {
            throw MacOSUpdateError.toolUnavailable
        }
        let output = try runListCommand()
        return MacOSUpdateScanResult(
            updates: try Self.parse(output),
            checkedAt: Date()
        )
    }

    static func parse(_ output: String) throws -> [MacOSSoftwareUpdate] {
        let normalized = output.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.localizedCaseInsensitiveContains("No new software available")
            || normalized.localizedCaseInsensitiveContains("No updates are available") {
            return []
        }

        struct Builder {
            var label: String
            var title: String?
            var version: String?
            var sizeBytes: Int64?
            var recommended = false
            var restart = false
        }
        var builders: [Builder] = []
        var current: Builder?

        func finish(_ value: Builder?, into builders: inout [Builder]) {
            guard let value else { return }
            builders.append(value)
        }

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = line.range(of: "Label:", options: [.caseInsensitive]) {
                finish(current, into: &builders)
                let label = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty, label.count <= 1_024 {
                    current = Builder(label: String(label))
                } else {
                    current = nil
                }
                continue
            }
            guard current != nil else { continue }
            let fields = splitFields(line)
            for (key, value) in fields {
                switch key.lowercased() {
                case "title": current?.title = String(value.prefix(512))
                case "version": current?.version = String(value.prefix(128))
                case "size": current?.sizeBytes = parseSize(value)
                case "recommended": current?.recommended = value.uppercased().hasPrefix("YES")
                case "action": current?.restart = value.lowercased().contains("restart")
                default: break
                }
            }
        }
        finish(current, into: &builders)

        let updates = builders.compactMap { builder -> MacOSSoftwareUpdate? in
            let title = builder.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title, !title.isEmpty else { return nil }
            return MacOSSoftwareUpdate(
                label: builder.label,
                title: title,
                version: builder.version,
                sizeBytes: builder.sizeBytes,
                isRecommended: builder.recommended,
                requiresRestart: builder.restart
            )
        }
        if !builders.isEmpty && updates.isEmpty { throw MacOSUpdateError.unsupportedOutput }
        if builders.isEmpty,
           normalized.localizedCaseInsensitiveContains("Software Update found") {
            throw MacOSUpdateError.unsupportedOutput
        }
        return updates
    }

    private func runListCommand() throws -> String {
        let process = Process()
        process.executableURL = Self.executableURL
        process.arguments = ["--list"]
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "C"
        environment["LC_ALL"] = "C"
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let output = BoundedUpdateOutput(maximumBytes: Self.maximumOutputBytes)
        let readerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let handle = pipe.fileHandleForReading
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                output.append(data)
            }
            readerFinished.signal()
        }

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForWriting.closeFile()
            _ = readerFinished.wait(timeout: .now() + 1)
            throw MacOSUpdateError.commandFailed
        }

        if terminated.wait(timeout: .now() + Self.timeout) == .timedOut {
            process.terminate()
            if terminated.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1)
            }
            pipe.fileHandleForWriting.closeFile()
            _ = readerFinished.wait(timeout: .now() + 2)
            throw MacOSUpdateError.timedOut
        }
        pipe.fileHandleForWriting.closeFile()
        _ = readerFinished.wait(timeout: .now() + 2)
        let snapshot = output.snapshot()
        guard !snapshot.truncated else { throw MacOSUpdateError.outputTooLarge }
        guard process.terminationStatus == 0 else { throw MacOSUpdateError.commandFailed }
        guard let string = String(data: snapshot.data, encoding: .utf8) else {
            throw MacOSUpdateError.unsupportedOutput
        }
        return string
    }

    private static func splitFields(_ line: String) -> [(String, String)] {
        let keys = ["Title:", "Version:", "Size:", "Recommended:", "Action:"]
        var positions: [(String, String.Index)] = []
        for key in keys {
            if let range = line.range(of: key, options: [.caseInsensitive]) {
                positions.append((String(key.dropLast()), range.lowerBound))
            }
        }
        positions.sort { $0.1 < $1.1 }
        var result: [(String, String)] = []
        for index in positions.indices {
            let key = positions[index].0
            guard let marker = line.range(
                of: key + ":",
                options: [.caseInsensitive],
                range: positions[index].1..<line.endIndex
            ) else { continue }
            let end = index + 1 < positions.count ? positions[index + 1].1 : line.endIndex
            let raw = line[marker.upperBound..<end]
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            result.append((key, raw))
        }
        return result
    }

    private static func parseSize(_ raw: String) -> Int64? {
        let clean = raw.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^([0-9]+(?:\.[0-9]+)?)\s*(KIB|KB|K|MIB|MB|M|GIB|GB|G|TIB|TB|T|B)?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)),
              let numberRange = Range(match.range(at: 1), in: clean),
              let number = Double(clean[numberRange]) else { return nil }
        var multiplier = 1.0
        if match.range(at: 2).location != NSNotFound,
           let unitRange = Range(match.range(at: 2), in: clean) {
            switch clean[unitRange].uppercased() {
            case "K": multiplier = 1_000
            case "KB": multiplier = 1_000
            case "KIB": multiplier = 1_024
            case "M": multiplier = 1_000_000
            case "MB": multiplier = 1_000_000
            case "MIB": multiplier = 1_048_576
            case "G": multiplier = 1_000_000_000
            case "GB": multiplier = 1_000_000_000
            case "GIB": multiplier = 1_073_741_824
            case "T": multiplier = 1_000_000_000_000
            case "TB": multiplier = 1_000_000_000_000
            case "TIB": multiplier = 1_099_511_627_776
            default: break
            }
        }
        let bytes = number * multiplier
        guard bytes.isFinite, bytes >= 0, bytes <= Double(Int64.max) else { return nil }
        return Int64(bytes.rounded())
    }
}

private final class BoundedUpdateOutput: @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !truncated else { return }
        let remaining = maximumBytes - data.count
        guard remaining > 0 else {
            truncated = true
            return
        }
        data.append(chunk.prefix(remaining))
        if chunk.count > remaining { truncated = true }
    }

    func snapshot() -> (data: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, truncated)
    }
}

@MainActor
final class MacOSUpdateCenter: ObservableObject {
    @Published private(set) var updates: [MacOSSoftwareUpdate] = []
    @Published private(set) var isChecking = false
    @Published private(set) var hasChecked = false
    @Published private(set) var lastCheckDate: Date?
    @Published var errorMessage: String?

    private let scanner: MacOSUpdateScanner
    private var task: Task<Void, Never>?

    init(scanner: MacOSUpdateScanner = MacOSUpdateScanner()) {
        self.scanner = scanner
    }

    func check() {
        guard !isChecking else { return }
        task?.cancel()
        isChecking = true
        errorMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await scanner.scan()
                guard !Task.isCancelled else { return }
                updates = result.updates
                lastCheckDate = result.checkedAt
                hasChecked = true
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                hasChecked = true
            }
            isChecking = false
        }
    }

    func openSoftwareUpdateSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Software-Update-Settings.extension",
            "x-apple.systempreferences:com.apple.preferences.softwareupdate",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }
}
