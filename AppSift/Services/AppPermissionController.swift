import AppKit
import Foundation

struct AppPermissionCommandResult: Sendable {
    let terminationStatus: Int32
    let output: String
}

struct AppPermissionResetOutcome: Sendable {
    let bundleIdentifier: String
    let service: AppPermissionService
    let resetServiceName: String
}

enum AppPermissionControllerError: LocalizedError {
    case unsupportedClient
    case unsupportedService
    case invalidBundleIdentifier
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedClient:
            return String(
                localized: "Only bundle-identified app permissions can be reset safely."
            )
        case .unsupportedService:
            return String(
                localized: "macOS does not document a reset command for this permission."
            )
        case .invalidBundleIdentifier:
            return String(
                localized: "The app bundle identifier is not valid for a permission reset."
            )
        case .commandFailed(let detail):
            let base = String(
                localized: "macOS did not reset this permission. Open System Settings and change it there."
            )
            return detail.isEmpty ? base : "\(base) \(detail)"
        }
    }
}

final class AppPermissionController: @unchecked Sendable {
    typealias CommandRunner = @Sendable (
        _ executableURL: URL,
        _ arguments: [String]
    ) async throws -> AppPermissionCommandResult

    private let commandRunner: CommandRunner

    init(commandRunner: @escaping CommandRunner = { executableURL, arguments in
        try await AppPermissionController.runCommand(
            executableURL: executableURL,
            arguments: arguments
        )
    }) {
        self.commandRunner = commandRunner
    }

    func canReset(
        client: AppPermissionClient,
        service: AppPermissionService
    ) -> Bool {
        guard client.clientType == 0,
              let bundleIdentifier = client.bundleIdentifier,
              bundleIdentifier == client.clientIdentifier,
              Self.isValidBundleIdentifier(bundleIdentifier),
              service.resetServiceName != nil else {
            return false
        }
        return true
    }

    func reset(
        client: AppPermissionClient,
        service: AppPermissionService
    ) async throws -> AppPermissionResetOutcome {
        guard client.clientType == 0,
              let bundleIdentifier = client.bundleIdentifier,
              bundleIdentifier == client.clientIdentifier else {
            throw AppPermissionControllerError.unsupportedClient
        }
        guard Self.isValidBundleIdentifier(bundleIdentifier) else {
            throw AppPermissionControllerError.invalidBundleIdentifier
        }
        guard let resetServiceName = service.resetServiceName else {
            throw AppPermissionControllerError.unsupportedService
        }

        let result = try await commandRunner(
            URL(fileURLWithPath: "/usr/bin/tccutil"),
            ["reset", resetServiceName, bundleIdentifier]
        )
        guard result.terminationStatus == 0 else {
            throw AppPermissionControllerError.commandFailed(
                Self.normalizedOutput(result.output)
            )
        }
        return AppPermissionResetOutcome(
            bundleIdentifier: bundleIdentifier,
            service: service,
            resetServiceName: resetServiceName
        )
    }

    @MainActor
    @discardableResult
    func openSystemSettings(for service: AppPermissionService) -> Bool {
        if let anchor = service.systemSettingsAnchor,
           let url = URL(
               string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
           ),
           NSWorkspace.shared.open(url) {
            return true
        }

        let applicationURL = URL(
            fileURLWithPath: "/System/Applications/System Settings.app",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: applicationURL.path) else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        )
        return true
    }

    static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 255,
              value.contains("."),
              let first = value.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else {
            return false
        }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-._"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func runCommand(
        executableURL: URL,
        arguments: [String]
    ) async throws -> AppPermissionCommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            process.standardInput = FileHandle.nullDevice

            try process.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return AppPermissionCommandResult(
                terminationStatus: process.terminationStatus,
                output: String(data: data.prefix(8_192), encoding: .utf8) ?? ""
            )
        }.value
    }

    private static func normalizedOutput(_ value: String) -> String {
        value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .prefix(512)
            .description
    }
}
