import XCTest
@testable import AppSift

final class ManagedExtensionScannerTests: XCTestCase {
    func testPluginKitParsingUsesRegistryStateBundleMetadataAndContainingApp() throws {
        let root = try makeTemporaryDirectory(prefix: "AppSiftPluginKit")
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Keka.app", isDirectory: true)
        let extensionURL = appURL.appendingPathComponent(
            "Contents/PlugIns/KekaFinderIntegration.appex",
            isDirectory: true
        )
        try makeBundle(
            at: extensionURL,
            name: "Keka Finder Integration",
            identifier: "com.example.keka.finder",
            version: "2.0",
            packageType: "XPC!",
            extensionPoint: "com.apple.FinderSync"
        )
        let owner = ExtensionOwnerApp(
            name: "Keka",
            bundleIdentifier: "com.example.keka",
            url: appURL,
            teamIdentifier: "TEAM123"
        )
        let output = "+    com.example.keka.finder(1.0)\tUUID\t2026-07-13 00:00:00 +0000\t\(extensionURL.path)"

        let items = ManagedExtensionScanner.parsePluginKitOutput(
            output,
            ownerApps: [owner]
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "Keka Finder Integration")
        XCTAssertEqual(items[0].identifier, "com.example.keka.finder")
        XCTAssertEqual(items[0].version, "2.0")
        XCTAssertEqual(items[0].kind, .finderExtension)
        XCTAssertEqual(items[0].state, .enabled)
        XCTAssertEqual(items[0].owner, owner)
        XCTAssertTrue(items[0].evidence.contains(.pluginKitRegistry))
        XCTAssertTrue(items[0].evidence.contains(.containingApplication))
        XCTAssertTrue(items[0].evidence.contains(.ownerCodeSignature))
        XCTAssertFalse(items[0].evidence.contains(.codeSignature))
    }

    func testPluginKitParsingExcludesAppleSystemExtensionsAndTracksDisabledState() throws {
        let root = try makeTemporaryDirectory(prefix: "AppSiftPluginKitFilter")
        defer { try? FileManager.default.removeItem(at: root) }
        let thirdParty = root.appendingPathComponent("Share.appex", isDirectory: true)
        try makeBundle(
            at: thirdParty,
            name: "Share Extension",
            identifier: "com.example.share",
            version: "1.0",
            packageType: "XPC!",
            extensionPoint: "com.apple.share-services"
        )
        let output = """
        +    com.apple.Notes.Share(1.0)\tUUID\tdate\t/System/Applications/Notes.app/Contents/PlugIns/Share.appex
        -    com.example.share(1.0)\tUUID\tdate\t\(thirdParty.path)
        """

        let items = ManagedExtensionScanner.parsePluginKitOutput(
            output,
            ownerApps: []
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].identifier, "com.example.share")
        XCTAssertEqual(items[0].kind, .shareExtension)
        XCTAssertEqual(items[0].state, .disabled)
    }

    func testSystemExtensionParsingDistinguishesEnabledAndApprovalRequired() throws {
        let owner = ExtensionOwnerApp(
            name: "OBS",
            bundleIdentifier: "com.obsproject.obs-studio",
            url: URL(fileURLWithPath: "/Applications/OBS.app", isDirectory: true),
            teamIdentifier: "OBS123"
        )
        let output = """
        2 extension(s)
        --- com.apple.system_extension.cmio (Camera Extensions)
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        \t*\tOBS123\tcom.obs.camera (32.1.1/123)\tOBS Virtual Camera\t[activated waiting for user]
        --- com.apple.system_extension.network_extension (Network Extensions)
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tNET123\tcom.example.network (2.0/20)\tNetwork Filter\t[activated enabled]
        """

        let items = ManagedExtensionScanner.parseSystemExtensionsOutput(
            output,
            ownerApps: [owner]
        )

        XCTAssertEqual(items.count, 2)
        let camera = try XCTUnwrap(items.first { $0.identifier == "com.obs.camera" })
        XCTAssertEqual(camera.state, .needsApproval)
        XCTAssertEqual(camera.profileName, "Camera")
        XCTAssertNil(camera.owner)
        XCTAssertFalse(camera.evidence.contains(.containingApplication))
        let network = try XCTUnwrap(items.first { $0.identifier == "com.example.network" })
        XCTAssertEqual(network.state, .enabled)
        XCTAssertEqual(network.profileName, "Network")
        XCTAssertNil(network.owner)
    }

    func testSystemExtensionParsingFindsExactContainingAppBundle() throws {
        let root = try makeTemporaryDirectory(prefix: "AppSiftSystemExtensionOwner")
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("OBS.app", isDirectory: true)
        let extensionURL = appURL.appendingPathComponent(
            "Contents/Library/SystemExtensions/OBS.systemextension",
            isDirectory: true
        )
        try makeBundle(
            at: extensionURL,
            name: "OBS Virtual Camera",
            identifier: "com.obs.camera",
            version: "32.1.1",
            packageType: "SYSX"
        )
        let owner = ExtensionOwnerApp(
            name: "OBS",
            bundleIdentifier: "com.obsproject.obs-studio",
            url: appURL
        )
        let output = """
        --- com.apple.system_extension.cmio (Camera Extensions)
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tOBS123\tcom.obs.camera (32.1.1/123)\tOBS Virtual Camera\t[activated enabled]
        """

        let item = try XCTUnwrap(
            ManagedExtensionScanner.parseSystemExtensionsOutput(
                output,
                ownerApps: [owner]
            ).first
        )

        XCTAssertEqual(item.owner, owner)
        XCTAssertTrue(item.evidence.contains(.systemExtensionRegistry))
        XCTAssertTrue(item.evidence.contains(.containingApplication))
        XCTAssertFalse(item.evidence.contains(.ownerCodeSignature))
    }

    func testSystemExtensionParsingDoesNotGuessOwnerFromTeamIdentifier() throws {
        let owner = ExtensionOwnerApp(
            name: "Another App",
            bundleIdentifier: "com.example.another-app",
            url: URL(fileURLWithPath: "/Applications/Another App.app", isDirectory: true),
            teamIdentifier: "TEAM123",
            developerName: "Example Developer"
        )
        let output = """
        --- com.apple.system_extension.network_extension (Network Extensions)
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tTEAM123\tcom.example.network-extension (1.0/1)\tNetwork Extension\t[activated enabled]
        """

        let item = try XCTUnwrap(
            ManagedExtensionScanner.parseSystemExtensionsOutput(
                output,
                ownerApps: [owner]
            ).first
        )

        XCTAssertNil(item.owner)
        XCTAssertNil(item.developerName)
        XCTAssertFalse(item.evidence.contains(.containingApplication))
        XCTAssertFalse(item.evidence.contains(.ownerCodeSignature))
    }

    func testChromiumScanUsesOnlyManifestAndExtensionStateFields() throws {
        let root = try makeTemporaryDirectory(prefix: "AppSiftChromium")
        defer { try? FileManager.default.removeItem(at: root) }
        let browserRoot = root.appendingPathComponent("Chrome", isDirectory: true)
        let profile = browserRoot.appendingPathComponent("Default", isDirectory: true)
        let extensionID = "abcdefghijklmnopabcdefghijklmnop"
        let version = profile
            .appendingPathComponent("Extensions/\(extensionID)/1.2.3_0", isDirectory: true)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try writeJSON([
            "name": "__MSG_extensionName__",
            "version": "1.2.3",
            "default_locale": "en",
            "permissions": ["storage", "tabs"],
            "host_permissions": ["https://example.com/*"],
        ], to: version.appendingPathComponent("manifest.json"))
        let messages = version.appendingPathComponent(
            "_locales/en/messages.json",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: messages.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeJSON([
            "extensionName": ["message": "Evidence Extension"],
        ], to: messages)
        try writeJSON([
            "extensions": [
                "settings": [extensionID: ["state": 1]],
            ],
            "history": ["recent": "must not enter the model"],
            "account_info": ["email": "must-not-be-read@example.com"],
        ], to: profile.appendingPathComponent("Preferences"))

        let source = BrowserExtensionSource(
            family: .chromium,
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            applicationURL: nil,
            profileRoot: browserRoot,
            managementPage: "chrome://extensions/"
        )
        let result = ManagedExtensionScanner.scan(
            ownerApps: [],
            homeURL: root,
            pluginKitOutputProvider: { .init(output: "") },
            systemExtensionsOutputProvider: { .init(output: "") },
            browserSources: [source],
            filesystemRoots: []
        )

        XCTAssertTrue(result.incompleteSources.isEmpty)
        XCTAssertEqual(result.items.count, 1)
        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.name, "Evidence Extension")
        XCTAssertEqual(item.identifier, extensionID)
        XCTAssertEqual(item.version, "1.2.3")
        XCTAssertEqual(item.state, .enabled)
        XCTAssertEqual(item.profileName, "Default")
        XCTAssertEqual(item.permissionCount, 3)
        XCTAssertEqual(item.owner?.name, "Google Chrome")
        XCTAssertTrue(item.evidence.contains(.browserManifest))
        XCTAssertTrue(item.evidence.contains(.browserPreference))
    }

    func testChromiumScanRejectsSymlinkedExtensionDirectory() throws {
        let root = try makeTemporaryDirectory(prefix: "AppSiftChromiumSymlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let browserRoot = root.appendingPathComponent("Chrome", isDirectory: true)
        let extensionsRoot = browserRoot.appendingPathComponent(
            "Default/Extensions",
            isDirectory: true
        )
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try writeJSON(
            ["name": "Unsafe", "version": "1"],
            to: outside.appendingPathComponent("manifest.json")
        )
        try FileManager.default.createDirectory(
            at: extensionsRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: extensionsRoot.appendingPathComponent("abcdefghijklmnopabcdefghijklmnop"),
            withDestinationURL: outside
        )
        let source = BrowserExtensionSource(
            family: .chromium,
            name: "Chrome",
            bundleIdentifier: "com.google.Chrome",
            applicationURL: nil,
            profileRoot: browserRoot,
            managementPage: "chrome://extensions/"
        )

        let result = ManagedExtensionScanner.scan(
            ownerApps: [],
            homeURL: root,
            pluginKitOutputProvider: { .init(output: "") },
            systemExtensionsOutputProvider: { .init(output: "") },
            browserSources: [source],
            filesystemRoots: []
        )

        XCTAssertTrue(result.items.isEmpty)
    }

    func testChromiumScanUsesRootProfileSecurePreferencesAndCaseInsensitiveMessageKey() throws {
        let root = try makeTemporaryDirectory(prefix: "AppSiftChromiumSecure")
        defer { try? FileManager.default.removeItem(at: root) }
        let browserRoot = root.appendingPathComponent("Opera", isDirectory: true)
        let enabledID = "abcdefghijklmnopabcdefghijklmnop"
        let disabledID = "ponmlkjihgfedcbaponmlkjihgfedcba"

        for identifier in [enabledID, disabledID] {
            let version = browserRoot.appendingPathComponent(
                "Extensions/\(identifier)/1.0.0_0",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: version,
                withIntermediateDirectories: true
            )
            try writeJSON([
                "name": "__MSG_APP_NAME__",
                "version": "1.0.0",
                "default_locale": "en",
            ], to: version.appendingPathComponent("manifest.json"))
            try writeJSON([
                "app_name": ["message": identifier == enabledID ? "Enabled Add-on" : "Disabled Add-on"],
            ], to: version.appendingPathComponent("_locales/en/messages.json"))
        }
        try writeJSON([
            "extensions": [
                "settings": [
                    enabledID: ["disable_reasons": []],
                    disabledID: ["disable_reasons": [1, 2]],
                ],
            ],
        ], to: browserRoot.appendingPathComponent("Secure Preferences"))
        try writeJSON([
            "extensions": [
                "settings": [
                    enabledID: ["state": 0],
                    disabledID: ["state": 1],
                ],
            ],
        ], to: browserRoot.appendingPathComponent("Preferences"))

        let source = BrowserExtensionSource(
            family: .chromium,
            name: "Opera",
            bundleIdentifier: "com.operasoftware.Opera",
            applicationURL: nil,
            profileRoot: browserRoot,
            managementPage: "opera://extensions/"
        )
        let result = ManagedExtensionScanner.scan(
            ownerApps: [],
            homeURL: root,
            pluginKitOutputProvider: { .init(output: "") },
            systemExtensionsOutputProvider: { .init(output: "") },
            browserSources: [source],
            filesystemRoots: []
        )

        XCTAssertTrue(result.incompleteSources.isEmpty)
        XCTAssertEqual(result.items.count, 2)
        let enabled = try XCTUnwrap(result.items.first { $0.identifier == enabledID })
        XCTAssertEqual(enabled.name, "Enabled Add-on")
        XCTAssertEqual(enabled.state, .enabled)
        XCTAssertEqual(enabled.profileName, "Default")
        let disabled = try XCTUnwrap(result.items.first { $0.identifier == disabledID })
        XCTAssertEqual(disabled.name, "Disabled Add-on")
        XCTAssertEqual(disabled.state, .disabled)
        XCTAssertEqual(disabled.profileName, "Default")
    }

    func testChromiumScanRejectsSymlinkedManifestFile() throws {
        let root = try makeTemporaryDirectory(prefix: "AppSiftChromiumManifestSymlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let browserRoot = root.appendingPathComponent("Chrome", isDirectory: true)
        let version = browserRoot.appendingPathComponent(
            "Default/Extensions/abcdefghijklmnopabcdefghijklmnop/1.0_0",
            isDirectory: true
        )
        let outsideManifest = root.appendingPathComponent("outside-manifest.json")
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try writeJSON(["name": "Outside", "version": "1.0"], to: outsideManifest)
        try FileManager.default.createSymbolicLink(
            at: version.appendingPathComponent("manifest.json"),
            withDestinationURL: outsideManifest
        )
        let source = BrowserExtensionSource(
            family: .chromium,
            name: "Chrome",
            bundleIdentifier: "com.google.Chrome",
            applicationURL: nil,
            profileRoot: browserRoot,
            managementPage: "chrome://extensions/"
        )

        let result = ManagedExtensionScanner.scan(
            ownerApps: [],
            homeURL: root,
            pluginKitOutputProvider: { .init(output: "") },
            systemExtensionsOutputProvider: { .init(output: "") },
            browserSources: [source],
            filesystemRoots: []
        )

        XCTAssertTrue(result.items.isEmpty)
    }

    func testChromiumScanSelectsNewestAcrossManyInstalledVersions() throws {
        let root = try makeTemporaryDirectory(prefix: "AppSiftChromiumVersions")
        defer { try? FileManager.default.removeItem(at: root) }
        let browserRoot = root.appendingPathComponent("Chrome", isDirectory: true)
        let extensionID = "abcdefghijklmnopabcdefghijklmnop"
        for versionNumber in 1...20 {
            let version = browserRoot.appendingPathComponent(
                "Default/Extensions/\(extensionID)/\(versionNumber).0_0",
                isDirectory: true
            )
            try writeJSON([
                "name": "Versioned Add-on",
                "version": "\(versionNumber).0",
            ], to: version.appendingPathComponent("manifest.json"))
        }
        let source = BrowserExtensionSource(
            family: .chromium,
            name: "Chrome",
            bundleIdentifier: "com.google.Chrome",
            applicationURL: nil,
            profileRoot: browserRoot,
            managementPage: "chrome://extensions/"
        )

        let result = ManagedExtensionScanner.scan(
            ownerApps: [],
            homeURL: root,
            pluginKitOutputProvider: { .init(output: "") },
            systemExtensionsOutputProvider: { .init(output: "") },
            browserSources: [source],
            filesystemRoots: []
        )

        XCTAssertEqual(result.items.first?.version, "20.0")
    }

    func testFirefoxScanUsesLocalAddonStateAndRejectsExternalPath() throws {
        let root = try makeTemporaryDirectory(prefix: "AppSiftFirefox")
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = root.appendingPathComponent("Profiles", isDirectory: true)
        let profile = profiles.appendingPathComponent("profile.default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try writeJSON([
            "addons": [[
                "id": "addon@example.com",
                "type": "extension",
                "version": "4.0",
                "active": false,
                "userDisabled": true,
                "isBuiltin": false,
                "hidden": false,
                "location": "app-profile",
                "path": "/tmp/outside-addon.xpi",
                "defaultLocale": ["name": "Firefox Add-on"],
                "userPermissions": [
                    "permissions": ["tabs"],
                    "origins": ["https://example.com/*"],
                ],
            ]],
        ], to: profile.appendingPathComponent("extensions.json"))
        let source = BrowserExtensionSource(
            family: .firefox,
            name: "Firefox",
            bundleIdentifier: "org.mozilla.firefox",
            applicationURL: nil,
            profileRoot: profiles,
            managementPage: "about:addons"
        )

        let result = ManagedExtensionScanner.scan(
            ownerApps: [],
            homeURL: root,
            pluginKitOutputProvider: { .init(output: "") },
            systemExtensionsOutputProvider: { .init(output: "") },
            browserSources: [source],
            filesystemRoots: []
        )

        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.name, "Firefox Add-on")
        XCTAssertEqual(item.state, .disabled)
        XCTAssertEqual(item.permissionCount, 2)
        XCTAssertTrue(item.evidence.contains(.browserProfileRegistry))
        XCTAssertFalse(item.evidence.contains(.browserManifest))
        XCTAssertNil(item.url, "A profile record must not point AppSift outside the profile")
    }

    func testFirefoxScanRejectsSymlinkedAddonPathInsideProfile() throws {
        let root = try makeTemporaryDirectory(prefix: "AppSiftFirefoxSymlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = root.appendingPathComponent("Profiles", isDirectory: true)
        let profile = profiles.appendingPathComponent("profile.default", isDirectory: true)
        let extensionsDirectory = profile.appendingPathComponent("extensions", isDirectory: true)
        let outside = root.appendingPathComponent("outside-addon.xpi")
        try FileManager.default.createDirectory(
            at: extensionsDirectory,
            withIntermediateDirectories: true
        )
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: extensionsDirectory.appendingPathComponent("linked-addon.xpi"),
            withDestinationURL: outside
        )
        try writeJSON([
            "addons": [[
                "id": "addon@example.com",
                "type": "extension",
                "version": "1.0",
                "active": true,
                "isBuiltin": false,
                "hidden": false,
                "location": "app-profile",
                "path": "extensions/linked-addon.xpi",
                "defaultLocale": ["name": "Linked Add-on"],
            ]],
        ], to: profile.appendingPathComponent("extensions.json"))
        let source = BrowserExtensionSource(
            family: .firefox,
            name: "Firefox",
            bundleIdentifier: "org.mozilla.firefox",
            applicationURL: nil,
            profileRoot: profiles,
            managementPage: "about:addons"
        )

        let result = ManagedExtensionScanner.scan(
            ownerApps: [],
            homeURL: root,
            pluginKitOutputProvider: { .init(output: "") },
            systemExtensionsOutputProvider: { .init(output: "") },
            browserSources: [source],
            filesystemRoots: []
        )

        XCTAssertEqual(result.items.first?.state, .enabled)
        XCTAssertNil(result.items.first?.url)
    }

    func testFilesystemScanAcceptsRealBundleAndRejectsSymlinkAndAppleItem() throws {
        let root = try makeTemporaryDirectory(prefix: "AppSiftLegacyExtensions")
        defer { try? FileManager.default.removeItem(at: root) }
        let accepted = root.appendingPathComponent("ThirdParty.saver", isDirectory: true)
        let apple = root.appendingPathComponent("Apple.saver", isDirectory: true)
        let linked = root.appendingPathComponent("Linked.saver", isDirectory: true)
        try makeBundle(
            at: accepted,
            name: "Third Party Saver",
            identifier: "com.example.saver",
            version: "3.0",
            packageType: "BNDL"
        )
        try makeBundle(
            at: apple,
            name: "Apple Saver",
            identifier: "com.apple.saver",
            version: "1.0",
            packageType: "BNDL"
        )
        try FileManager.default.createSymbolicLink(
            at: linked,
            withDestinationURL: accepted
        )
        let filesystemRoot = FilesystemExtensionRoot(
            url: root,
            kind: .screenSaver,
            scope: .user,
            pathExtensions: ["saver"]
        )

        let result = ManagedExtensionScanner.scan(
            ownerApps: [],
            homeURL: root,
            pluginKitOutputProvider: { .init(output: "") },
            systemExtensionsOutputProvider: { .init(output: "") },
            browserSources: [],
            filesystemRoots: [filesystemRoot]
        )

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].identifier, "com.example.saver")
        XCTAssertEqual(result.items[0].kind, .screenSaver)
        XCTAssertEqual(result.items[0].state, .installed)
        XCTAssertEqual(result.items[0].management, .reveal)
    }

    func testFilesystemScanRejectsInfoPlistSymlinkOutsideBundle() throws {
        let root = try makeTemporaryDirectory(prefix: "AppSiftLegacyInfoSymlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Unsafe.saver", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let outsidePlist = root.appendingPathComponent("outside.plist")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleDisplayName": "Unsafe Saver",
                "CFBundleIdentifier": "com.example.unsafe",
                "CFBundleShortVersionString": "1.0",
                "CFBundlePackageType": "BNDL",
            ],
            format: .xml,
            options: 0
        )
        try data.write(to: outsidePlist)
        try FileManager.default.createSymbolicLink(
            at: contents.appendingPathComponent("Info.plist"),
            withDestinationURL: outsidePlist
        )
        let filesystemRoot = FilesystemExtensionRoot(
            url: root,
            kind: .screenSaver,
            scope: .user,
            pathExtensions: ["saver"]
        )

        let result = ManagedExtensionScanner.scan(
            ownerApps: [],
            homeURL: root,
            pluginKitOutputProvider: { .init(output: "") },
            systemExtensionsOutputProvider: { .init(output: "") },
            browserSources: [],
            filesystemRoots: [filesystemRoot]
        )

        XCTAssertTrue(result.items.isEmpty)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeBundle(
        at url: URL,
        name: String,
        identifier: String,
        version: String,
        packageType: String,
        extensionPoint: String? = nil
    ) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleDisplayName": name,
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundlePackageType": packageType,
        ]
        if let extensionPoint {
            info["NSExtension"] = [
                "NSExtensionPointIdentifier": extensionPoint,
            ]
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func writeJSON(_ value: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: url)
    }
}

@MainActor
final class ManagedExtensionAppStateTests: XCTestCase {
    func testExtensionsCLICommandIsRecognized() {
        XCTAssertTrue(CLI.isKnownCommand("extensions"))
    }

    func testExtensionsCLITextSanitizerRemovesTerminalControls() {
        XCTAssertEqual(
            CLI.terminalSafe("Safe\n\u{001B}[31m\tName"),
            "Safe [31m Name"
        )
    }

    func testBrowserApplicationVerificationRequiresExactBundleIdentifier() throws {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSiftBrowser-\(UUID().uuidString).app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appURL) }
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.google.Chrome",
                "CFBundlePackageType": "APPL",
            ],
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        XCTAssertTrue(
            AppState.browserApplicationMatches(
                appURL,
                bundleIdentifier: "com.google.Chrome"
            )
        )
        XCTAssertFalse(
            AppState.browserApplicationMatches(
                appURL,
                bundleIdentifier: "com.brave.Browser"
            )
        )
    }

    func testAppStateScansExtensionsWithoutBlockingStartup() async throws {
        let item = ManagedExtension(
            id: "test-extension",
            name: "Test Extension",
            identifier: "com.example.extension",
            version: "1.0",
            kind: .appExtension,
            state: .systemDefault,
            scope: .embedded,
            url: nil,
            owner: nil,
            teamIdentifier: nil,
            developerName: nil,
            profileName: nil,
            permissionCount: nil,
            evidence: [.pluginKitRegistry],
            management: .systemSettings
        )
        let appState = AppState(
            performStartupTasks: false,
            managedExtensionsScanner: { _ in
                ManagedExtensionScanResult(
                    items: [item],
                    incompleteSources: [.browserExtensions]
                )
            }
        )

        XCTAssertFalse(appState.hasScannedExtensions)
        appState.scanExtensions()
        for _ in 0..<100 where !appState.hasScannedExtensions {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(appState.hasScannedExtensions)
        XCTAssertFalse(appState.isScanningExtensions)
        XCTAssertEqual(appState.managedExtensions, [item])
        XCTAssertEqual(appState.incompleteExtensionSources, [.browserExtensions])
    }
}
