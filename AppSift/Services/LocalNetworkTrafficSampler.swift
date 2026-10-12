import Foundation

struct AppSiftLocalNetworkTrafficSample: Equatable, Sendable {
    let processID: Int32
    let processName: String
    let bytesReceived: UInt64
    let bytesSent: UInt64
}

/// Reads macOS per-process traffic counters without installing a system
/// extension. This is intentionally read-only: it cannot block sockets or
/// inspect payloads, so the Network Extension remains the enforcement path.
enum AppSiftLocalNetworkTrafficSampler {
    static func sample() async -> [AppSiftLocalNetworkTrafficSample] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runNettop())
            }
        }
    }

    static func parse(_ output: String) -> [AppSiftLocalNetworkTrafficSample] {
        AppSiftNettopParser.parse(output)
    }

    private static func runNettop() -> [AppSiftLocalNetworkTrafficSample] {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-x", "-n"]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: output, encoding: .utf8) else {
                return []
            }
            return parse(text)
        } catch {
            return []
        }
    }
}

enum AppSiftNettopParser {
    static func parse(_ output: String) -> [AppSiftLocalNetworkTrafficSample] {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let headerLine = lines.first else { return [] }

        let header = parseCSV(String(headerLine))
        guard let bytesInIndex = header.firstIndex(of: "bytes_in"),
              let bytesOutIndex = header.firstIndex(of: "bytes_out") else {
            return []
        }

        // nettop's per-process CSV places the process name in the first empty
        // header column: time,,interface,state,bytes_in,...
        let processIndex = header.firstIndex(of: "") ?? 1
        let requiredIndex = max(processIndex, max(bytesInIndex, bytesOutIndex))

        return lines.dropFirst().compactMap { line in
            let fields = parseCSV(String(line))
            guard fields.count > requiredIndex,
                  let process = fields[safe: processIndex],
                  let processID = processID(from: process),
                  let bytesReceived = UInt64(fields[safe: bytesInIndex] ?? ""),
                  let bytesSent = UInt64(fields[safe: bytesOutIndex] ?? "") else {
                return nil
            }

            return AppSiftLocalNetworkTrafficSample(
                processID: processID,
                processName: process,
                bytesReceived: bytesReceived,
                bytesSent: bytesSent
            )
        }
    }

    private static func processID(from value: String) -> Int32? {
        guard let separator = value.lastIndex(of: "."),
              let processID = Int32(value[value.index(after: separator)...]) else {
            return nil
        }
        return processID > 0 ? processID : nil
    }

    private static func parseCSV(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if quoted, next < line.endIndex, line[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    quoted.toggle()
                }
            } else if character == "," && !quoted {
                fields.append(field)
                field.removeAll(keepingCapacity: true)
            } else {
                field.append(character)
            }
            index = line.index(after: index)
        }
        fields.append(field)
        return fields
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
