import Foundation
import XCTest
@testable import AppSift

final class AppPermissionControllerTests: XCTestCase {
    func testResetUsesFixedTCCUtilPathAndAllowlistedArguments() async throws {
        let capture = CommandCapture()
        let controller = AppPermissionController { executable, arguments in
            capture.store(executable: executable, arguments: arguments)
            return AppPermissionCommandResult(terminationStatus: 0, output: "")
        }
        let client = makeClient(bundleIdentifier: "com.example.Camera")

        let outcome = try await controller.reset(
            client: client,
            service: .camera
        )

        XCTAssertEqual(outcome.bundleIdentifier, "com.example.Camera")
        XCTAssertEqual(outcome.resetServiceName, "Camera")
        XCTAssertEqual(capture.executable?.path, "/usr/bin/tccutil")
        XCTAssertEqual(
            capture.arguments,
            ["reset", "Camera", "com.example.Camera"]
        )
    }

    func testPathClientCannotBeReset() async {
        let capture = CommandCapture()
        let controller = AppPermissionController { executable, arguments in
            capture.store(executable: executable, arguments: arguments)
            return AppPermissionCommandResult(terminationStatus: 0, output: "")
        }
        let client = AppPermissionClient(
            id: "1|/usr/local/bin/tool",
            name: "tool",
            clientIdentifier: "/usr/local/bin/tool",
            clientType: 1,
            bundleIdentifier: nil,
            applicationURL: nil,
            version: nil,
            isInstalled: false,
            records: [],
            declarations: []
        )

        XCTAssertFalse(controller.canReset(client: client, service: .camera))
        do {
            _ = try await controller.reset(client: client, service: .camera)
            XCTFail("Expected unsupported client")
        } catch AppPermissionControllerError.unsupportedClient {
            XCTAssertNil(capture.executable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidBundleIdentifierIsRejectedBeforeExecution() async {
        let capture = CommandCapture()
        let controller = AppPermissionController { executable, arguments in
            capture.store(executable: executable, arguments: arguments)
            return AppPermissionCommandResult(terminationStatus: 0, output: "")
        }
        let client = makeClient(bundleIdentifier: "--help")

        do {
            _ = try await controller.reset(client: client, service: .camera)
            XCTFail("Expected invalid bundle identifier")
        } catch AppPermissionControllerError.invalidBundleIdentifier {
            XCTAssertNil(capture.executable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnknownServiceNeverBecomesCommandArgument() async {
        let capture = CommandCapture()
        let controller = AppPermissionController { executable, arguments in
            capture.store(executable: executable, arguments: arguments)
            return AppPermissionCommandResult(terminationStatus: 0, output: "")
        }
        let client = makeClient(bundleIdentifier: "com.example.Future")
        let service = AppPermissionService(rawValue: "kTCCServiceFuturePrivateData")

        XCTAssertFalse(controller.canReset(client: client, service: service))
        do {
            _ = try await controller.reset(client: client, service: service)
            XCTFail("Expected unsupported service")
        } catch AppPermissionControllerError.unsupportedService {
            XCTAssertNil(capture.executable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCommandFailureIsBoundedAndReadable() async {
        let controller = AppPermissionController { _, _ in
            AppPermissionCommandResult(
                terminationStatus: 1,
                output: String(repeating: "failure\n", count: 200)
            )
        }

        do {
            _ = try await controller.reset(
                client: makeClient(bundleIdentifier: "com.example.Camera"),
                service: .camera
            )
            XCTFail("Expected command failure")
        } catch {
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("failure"))
            XCTAssertLessThan(description.count, 1_024)
        }
    }

    func testBundleIdentifierValidation() {
        XCTAssertTrue(
            AppPermissionController.isValidBundleIdentifier("com.example.Valid-App_2")
        )
        XCTAssertFalse(AppPermissionController.isValidBundleIdentifier("com example.App"))
        XCTAssertFalse(AppPermissionController.isValidBundleIdentifier("/Applications/App"))
        XCTAssertFalse(AppPermissionController.isValidBundleIdentifier("-com.example.App"))
        XCTAssertFalse(AppPermissionController.isValidBundleIdentifier("single"))
    }

    private func makeClient(bundleIdentifier: String) -> AppPermissionClient {
        AppPermissionClient(
            id: "0|\(bundleIdentifier)",
            name: "Example",
            clientIdentifier: bundleIdentifier,
            clientType: 0,
            bundleIdentifier: bundleIdentifier,
            applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
            version: "1.0",
            isInstalled: true,
            records: [],
            declarations: []
        )
    }
}

private final class CommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var executable: URL?
    private(set) var arguments: [String] = []

    func store(executable: URL, arguments: [String]) {
        lock.lock()
        self.executable = executable
        self.arguments = arguments
        lock.unlock()
    }
}
