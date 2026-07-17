//
//  AppConstants.swift
//  AppSift
//
//  Created by Theo Sementa on 12/04/2026.
//

import Darwin
import Foundation

struct AppConstants {
    static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
}

enum ProductIdentity {
    static let name = "AppSift"
    static let subtitle = "AppSift — Cleaner & Uninstaller"
    static let bundleIdentifier = "com.gravitypoet.appsift"
    static let schedulerLabel = "com.gravitypoet.appsift.scheduler"
    static let repositoryURL = URL(string: "https://github.com/GravityPoet/AppSift")!
    static let latestReleaseURL = repositoryURL.appendingPathComponent("releases/latest")
}

/// One-time compatibility bridge from the former PureMac product identity.
/// The migration only copies bounded, user-owned preferences and undo history;
/// it never removes or mutates the legacy data, so rolling back remains safe.
enum LegacyProductMigration {
    static let legacyBundleIdentifier = "com.puremac.app"
    static let markerKey = "AppSift.LegacyPureMacMigrationVersion"
    static let currentVersion = 1

    private struct FileMapping {
        let source: URL
        let destination: URL
        let maximumBytes: Int64
    }

    static func performIfNeeded(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        currentUserID: uid_t = getuid()
    ) {
        guard NSClassFromString("XCTestCase") == nil,
              defaults.integer(forKey: markerKey) < currentVersion else {
            return
        }

        let legacyPreferences = defaults.persistentDomain(
            forName: legacyBundleIdentifier
        ) ?? [:]
        let filesMigrated = migrateLegacyData(
            homeDirectory: homeDirectory,
            legacyPreferences: legacyPreferences,
            defaults: defaults,
            fileManager: fileManager,
            currentUserID: currentUserID
        )
        if filesMigrated {
            defaults.set(currentVersion, forKey: markerKey)
        }
    }

    @discardableResult
    static func migrateLegacyData(
        homeDirectory: URL,
        legacyPreferences: [String: Any],
        defaults: UserDefaults,
        fileManager: FileManager = .default,
        currentUserID: uid_t = getuid()
    ) -> Bool {
        migratePreferences(legacyPreferences, into: defaults)
        var allFilesMigrated = true
        for mapping in fileMappings(homeDirectory: homeDirectory) {
            if !copyLegacyFile(
                mapping,
                fileManager: fileManager,
                currentUserID: currentUserID
            ) {
                allFilesMigrated = false
            }
        }
        return allFilesMigrated
    }

    static func migratePreferences(
        _ legacyPreferences: [String: Any],
        into defaults: UserDefaults
    ) {
        for key in legacyPreferences.keys.sorted().prefix(256) {
            guard let destinationKey = destinationPreferenceKey(for: key),
                  defaults.object(forKey: destinationKey) == nil,
                  let value = legacyPreferences[key],
                  PropertyListSerialization.propertyList(value, isValidFor: .binary),
                  let encoded = try? PropertyListSerialization.data(
                    fromPropertyList: [destinationKey: value],
                    format: .binary,
                    options: 0
                  ),
                  encoded.count <= 256_000 else {
                continue
            }
            defaults.set(value, forKey: destinationKey)
        }
    }

    private static func destinationPreferenceKey(for legacyKey: String) -> String? {
        if legacyKey.hasPrefix("settings.") || legacyKey == "AppleLanguages" {
            return legacyKey
        }
        guard legacyKey.hasPrefix("PureMac.") else { return nil }
        return "AppSift." + legacyKey.dropFirst("PureMac.".count)
    }

    private static func fileMappings(homeDirectory: URL) -> [FileMapping] {
        let support = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let legacyNamed = support.appendingPathComponent("PureMac", isDirectory: true)
        let currentNamed = support.appendingPathComponent("AppSift", isDirectory: true)
        let legacyBundle = support.appendingPathComponent(
            legacyBundleIdentifier,
            isDirectory: true
        )
        let currentBundle = support.appendingPathComponent(
            ProductIdentity.bundleIdentifier,
            isDirectory: true
        )

        return [
            FileMapping(
                source: legacyNamed.appendingPathComponent(
                    "installation-file-removal-history.json"
                ),
                destination: currentNamed.appendingPathComponent(
                    "installation-file-removal-history.json"
                ),
                maximumBytes: 512_000
            ),
            FileMapping(
                source: legacyBundle.appendingPathComponent("app-removal-history.json"),
                destination: currentBundle.appendingPathComponent("app-removal-history.json"),
                maximumBytes: 2_000_000
            ),
            FileMapping(
                source: legacyBundle.appendingPathComponent(
                    "startup-item-control-history.json"
                ),
                destination: currentBundle.appendingPathComponent(
                    "startup-item-control-history.json"
                ),
                maximumBytes: 512_000
            ),
            FileMapping(
                source: legacyBundle.appendingPathComponent(
                    "default-application-control-history.json"
                ),
                destination: currentBundle.appendingPathComponent(
                    "default-application-control-history.json"
                ),
                maximumBytes: 512_000
            ),
        ]
    }

    private static func copyLegacyFile(
        _ mapping: FileMapping,
        fileManager: FileManager,
        currentUserID: uid_t
    ) -> Bool {
        guard fileManager.fileExists(atPath: mapping.source.path) else { return true }
        guard isSafeLegacyRegularFile(
            mapping.source,
            maximumBytes: mapping.maximumBytes,
            currentUserID: currentUserID
        ) else {
            return true
        }

        if fileManager.fileExists(atPath: mapping.destination.path) {
            return isSafeRegularFile(
                mapping.destination,
                maximumBytes: mapping.maximumBytes,
                currentUserID: currentUserID
            )
        }

        let parent = mapping.destination.deletingLastPathComponent()
        guard preparePrivateDirectory(
            parent,
            fileManager: fileManager,
            currentUserID: currentUserID
        ) else {
            return false
        }

        let temporary = parent.appendingPathComponent(
            ".appsift-migration-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: temporary) }

        do {
            try fileManager.copyItem(at: mapping.source, to: temporary)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporary.path
            )
            guard isSafeRegularFile(
                temporary,
                maximumBytes: mapping.maximumBytes,
                currentUserID: currentUserID
            ) else {
                return false
            }
            try fileManager.moveItem(at: temporary, to: mapping.destination)
            return isSafeRegularFile(
                mapping.destination,
                maximumBytes: mapping.maximumBytes,
                currentUserID: currentUserID
            )
        } catch {
            if fileManager.fileExists(atPath: mapping.destination.path) {
                return isSafeRegularFile(
                    mapping.destination,
                    maximumBytes: mapping.maximumBytes,
                    currentUserID: currentUserID
                )
            }
            return false
        }
    }

    private static func preparePrivateDirectory(
        _ url: URL,
        fileManager: FileManager,
        currentUserID: uid_t
    ) -> Bool {
        do {
            if !fileManager.fileExists(atPath: url.path) {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            guard isOwnedDirectory(url, currentUserID: currentUserID) else { return false }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
            return isOwnedDirectory(url, currentUserID: currentUserID)
        } catch {
            return false
        }
    }

    private static func isOwnedDirectory(_ url: URL, currentUserID: uid_t) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFDIR
            && information.st_uid == currentUserID
    }

    private static func isSafeRegularFile(
        _ url: URL,
        maximumBytes: Int64,
        currentUserID: uid_t
    ) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFREG
            && information.st_uid == currentUserID
            && information.st_nlink == 1
            && information.st_size >= 0
            && information.st_size <= maximumBytes
            && information.st_mode & 0o077 == 0
    }

    private static func isSafeLegacyRegularFile(
        _ url: URL,
        maximumBytes: Int64,
        currentUserID: uid_t
    ) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFREG
            && information.st_uid == currentUserID
            && information.st_nlink == 1
            && information.st_size >= 0
            && information.st_size <= maximumBytes
            && information.st_mode & 0o022 == 0
    }
}
