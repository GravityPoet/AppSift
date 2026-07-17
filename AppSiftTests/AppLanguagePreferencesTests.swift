import Darwin
import XCTest
@testable import AppSift

final class AppLanguagePreferencesTests: XCTestCase {
    func testApplyCustomLanguageSetsAppleLanguagesAndPreservesLocale() {
        let context = makeDefaults()
        let defaults = context.defaults
        defaults.set("pt_BR", forKey: "AppleLocale")

        AppLanguagePreferences.apply(.english, defaults: defaults)

        XCTAssertEqual(defaults.array(forKey: "AppleLanguages") as? [String], ["en"])
        XCTAssertEqual(defaults.string(forKey: "AppleLocale"), "pt_BR")
    }

    func testApplySystemLanguageRemovesAppleLanguagesAndPreservesLocale() {
        let context = makeDefaults()
        let defaults = context.defaults
        defaults.set(["en"], forKey: "AppleLanguages")
        defaults.set("pt_BR", forKey: "AppleLocale")

        AppLanguagePreferences.apply(.system, defaults: defaults)

        XCTAssertNil(defaults.persistentDomain(forName: context.suiteName)?["AppleLanguages"])
        XCTAssertEqual(defaults.string(forKey: "AppleLocale"), "pt_BR")
    }

    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "AppSiftTests.AppLanguagePreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

final class LegacyProductMigrationTests: XCTestCase {
    func testPreferenceMigrationMapsProductKeysAndPreservesExistingChoices() {
        let context = makeDefaults()
        let defaults = context.defaults
        defaults.set("light", forKey: "AppSift.Appearance")

        LegacyProductMigration.migratePreferences(
            [
                "PureMac.Appearance": "dark",
                "PureMac.OnboardingComplete": true,
                "settings.cleaning.skipHiddenFiles": false,
                "AppleLanguages": ["zh-Hans"],
                "NSWindow Frame PureMac": "must-not-migrate",
            ],
            into: defaults
        )

        XCTAssertEqual(defaults.string(forKey: "AppSift.Appearance"), "light")
        XCTAssertTrue(defaults.bool(forKey: "AppSift.OnboardingComplete"))
        XCTAssertEqual(
            defaults.object(forKey: "settings.cleaning.skipHiddenFiles") as? Bool,
            false
        )
        // macOS may normalize language identifiers (for example, zh-Hans-CN).
        // Verify the migrated preference semantically instead of relying on the
        // exact spelling returned by UserDefaults.
        let migratedLanguages = defaults.stringArray(forKey: "AppleLanguages") ?? []
        XCTAssertEqual(migratedLanguages.first?.lowercased().hasPrefix("zh-hans"), true)
        XCTAssertNil(defaults.object(forKey: "NSWindow Frame PureMac"))
    }

    func testHistoryMigrationCopiesKnownFilesPrivatelyAndLeavesSourcesIntact() throws {
        let root = temporaryDirectory()
        let context = makeDefaults()
        let legacyNamed = root.appendingPathComponent(
            "Library/Application Support/PureMac",
            isDirectory: true
        )
        let legacyBundle = root.appendingPathComponent(
            "Library/Application Support/com.puremac.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacyNamed,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: legacyBundle,
            withIntermediateDirectories: true
        )
        let installationSource = legacyNamed.appendingPathComponent(
            "installation-file-removal-history.json"
        )
        let removalSource = legacyBundle.appendingPathComponent("app-removal-history.json")
        try Data("installation".utf8).write(to: installationSource)
        try Data("removal".utf8).write(to: removalSource)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: installationSource.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: removalSource.path
        )

        XCTAssertTrue(
            LegacyProductMigration.migrateLegacyData(
                homeDirectory: root,
                legacyPreferences: [:],
                defaults: context.defaults
            )
        )

        let installationDestination = root.appendingPathComponent(
            "Library/Application Support/AppSift/installation-file-removal-history.json"
        )
        let removalDestination = root.appendingPathComponent(
            "Library/Application Support/com.gravitypoet.appsift/app-removal-history.json"
        )
        XCTAssertEqual(try Data(contentsOf: installationDestination), Data("installation".utf8))
        XCTAssertEqual(try Data(contentsOf: removalDestination), Data("removal".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installationSource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: removalSource.path))
        XCTAssertEqual(fileMode(installationDestination), 0o600)
        XCTAssertEqual(fileMode(removalDestination), 0o600)
        XCTAssertEqual(fileMode(installationDestination.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(fileMode(removalDestination.deletingLastPathComponent()), 0o700)
    }

    func testHistoryMigrationNeverOverwritesNewProductHistory() throws {
        let root = temporaryDirectory()
        let context = makeDefaults()
        let source = root.appendingPathComponent(
            "Library/Application Support/com.puremac.app/app-removal-history.json"
        )
        let destination = root.appendingPathComponent(
            "Library/Application Support/com.gravitypoet.appsift/app-removal-history.json"
        )
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(to: source)
        try Data("current".utf8).write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: source.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )

        XCTAssertTrue(
            LegacyProductMigration.migrateLegacyData(
                homeDirectory: root,
                legacyPreferences: [:],
                defaults: context.defaults
            )
        )
        XCTAssertEqual(try Data(contentsOf: destination), Data("current".utf8))
    }

    func testHistoryMigrationIgnoresSymlinkedLegacyHistory() throws {
        let root = temporaryDirectory()
        let context = makeDefaults()
        let external = root.appendingPathComponent("outside.json")
        let source = root.appendingPathComponent(
            "Library/Application Support/com.puremac.app/app-removal-history.json"
        )
        try Data("outside".utf8).write(to: external)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: source,
            withDestinationURL: external
        )

        XCTAssertTrue(
            LegacyProductMigration.migrateLegacyData(
                homeDirectory: root,
                legacyPreferences: [:],
                defaults: context.defaults
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "Library/Application Support/com.gravitypoet.appsift/app-removal-history.json"
                ).path
            )
        )
    }

    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "AppSiftTests.LegacyProductMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (defaults, suiteName)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AppSift-LegacyMigrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try! FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func fileMode(_ url: URL) -> mode_t {
        var information = stat()
        XCTAssertEqual(lstat(url.path, &information), 0)
        return information.st_mode & 0o777
    }
}
