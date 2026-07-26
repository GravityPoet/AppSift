import XCTest
@testable import AppSift

final class LocalizationFilesTests: XCTestCase {
    func testLegacyBrandOnlyAppearsInAttributionFiles() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let oldBrand = ["Pure", "Mac"].joined()
        let oldBrandVariants = [
            oldBrand,
            oldBrand.replacingOccurrences(of: "Mac", with: " Mac"),
            oldBrand.replacingOccurrences(of: "Mac", with: "-Mac"),
            oldBrand.replacingOccurrences(of: "Mac", with: "_Mac")
        ].map { $0.lowercased() }
        let allowedFiles: Set<String> = [
            "LICENSE",
            "NOTICE",
            "README.md",
            "AppSift/Info.plist",
            "docs/index.html",
            "docs/README.ar.md",
            "docs/README.es.md",
            "docs/README.ja.md",
            "docs/README.zh-Hans.md",
            "docs/README.zh-Hant.md"
        ]
        let ignoredDirectories: Set<String> = [
            ".git", ".build", "build", "DerivedData", "xcuserdata"
        ]
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        let enumerator = try XCTUnwrap(
            fileManager.enumerator(
                at: repositoryRoot,
                includingPropertiesForKeys: resourceKeys,
                options: [],
                errorHandler: { url, error in
                    XCTFail("Could not inspect \(url.path): \(error)")
                    return false
                }
            )
        )
        var violations: [String] = []

        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(
                of: repositoryRoot.path + "/",
                with: ""
            )
            let values = try fileURL.resourceValues(forKeys: Set(resourceKeys))

            if values.isDirectory == true {
                if ignoredDirectories.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            let lowercasePath = relativePath.lowercased()
            if oldBrandVariants.contains(where: lowercasePath.contains),
               !allowedFiles.contains(relativePath) {
                violations.append("legacy brand in path: \(relativePath)")
            }

            guard values.isRegularFile == true,
                  (values.fileSize ?? 0) <= 5_000_000,
                  let contents = try? String(contentsOf: fileURL, encoding: .utf8)
            else {
                continue
            }

            let lowercaseContents = contents.lowercased()
            guard oldBrandVariants.contains(where: lowercaseContents.contains),
                  !allowedFiles.contains(relativePath)
            else {
                continue
            }

            let matchingLines = contents
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, line -> String? in
                    let lowercaseLine = line.lowercased()
                    guard oldBrandVariants.contains(where: lowercaseLine.contains) else {
                        return nil
                    }
                    return "\(relativePath):\(index + 1)"
                }
            violations.append(contentsOf: matchingLines)
        }

        XCTAssertTrue(
            violations.isEmpty,
            "The retired product name may appear only in attribution files:\n\(violations.sorted().joined(separator: "\n"))"
        )
    }

    func testAllLocalizableStringsFilesHaveEnglishKeyParity() throws {
        let localizationFiles = try localizableStringsFiles()
        let englishURL = try XCTUnwrap(
            localizationFiles["en"],
            "Expected en.lproj/Localizable.strings to exist"
        )
        let englishKeys = try localizedKeys(in: englishURL)

        for (language, fileURL) in localizationFiles where language != "en" {
            let languageKeys = try localizedKeys(in: fileURL)
            let missingKeys = englishKeys.subtracting(languageKeys).sorted()
            let extraKeys = languageKeys.subtracting(englishKeys).sorted()

            XCTAssertTrue(
                missingKeys.isEmpty,
                "\(language).lproj/Localizable.strings is missing keys:\n\(missingKeys.joined(separator: "\n"))"
            )
            XCTAssertTrue(
                extraKeys.isEmpty,
                "\(language).lproj/Localizable.strings has extra keys:\n\(extraKeys.joined(separator: "\n"))"
            )
        }
    }

    func testLocalizationDirectoriesMatchSelectableLanguages() throws {
        let localizationDirectories = Set(try localizableStringsFiles().keys)
        let selectableLanguages = Set(
            AppLanguage.allCases
                .filter { $0 != .system }
                .map(\.rawValue)
        )

        XCTAssertEqual(localizationDirectories, selectableLanguages)
    }

    func testDeliveredFeatureViewsDoNotBypassLocalizationCatalog() throws {
        let sourceRoot = repositoryRoot()
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSift-Localization-Audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let sourcePaths = [
            "AppSift/Views/BrowserPrivacyView.swift",
            "AppSift/Views/DownloadsBySourceView.swift",
            "AppSift/Views/DuplicateFilesView.swift",
            "AppSift/Views/IOSBackupsView.swift",
            "AppSift/Views/SimilarImagesView.swift",
            "AppSift/Views/SpaceLensView.swift",
            "AppSift/Views/SystemHealthView.swift",
            "AppSift/Views/SystemMaintenanceView.swift",
            "AppSift/Views/SystemResidueView.swift",
            "AppSift/Views/TimeMachineSnapshotsView.swift",
            "AppSift/Views/Apps/StartupItemsView.swift"
        ].map { sourceRoot.appendingPathComponent($0).path }

        let process = Process()
        let diagnostics = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "extractLocStrings", "-SwiftUI", "-q", "-o", outputDirectory.path
        ] + sourcePaths
        process.standardError = diagnostics
        try process.run()
        process.waitUntilExit()

        let diagnosticText = String(
            data: diagnostics.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "extractLocStrings failed:\n\(diagnosticText)"
        )

        let extractedKeys = try localizedKeys(
            in: outputDirectory.appendingPathComponent("Localizable.strings")
        )
        let englishURL = try XCTUnwrap(localizableStringsFiles()["en"])
        let missingKeys = extractedKeys
            .subtracting(try localizedKeys(in: englishURL))
            .sorted()

        XCTAssertTrue(
            missingKeys.isEmpty,
            "Feature views contain localizable strings missing from the catalog:\n\(missingKeys.joined(separator: "\n"))"
        )
    }

    func testNewFeatureNarrativeCopyIsTranslatedInEverySupportedLanguage() throws {
        let files = try localizableStringsFiles()
        let englishURL = try XCTUnwrap(files["en"])
        let english = try localizedDictionary(in: englishURL)
        let narrativeKeys: Set<String> = [
            "Analyzing images locally…",
            "AppSift reads only bounded backup property lists and filesystem sizes.",
            "AppSift uses explicit conditions and evidence. It does not invent a numeric Mac health score.",
            "AppSift will ask Mail to quit, move only its Envelope Index files to the Trash, then reopen Mail if it was running. Mail may take time to rebuild search data.",
            "AppSift will restore the unchanged plist to its original LaunchAgents folder. Its missing executable will not be recreated.",
            "Apps may recreate these files with default settings. AppSift rechecks every file before moving it and keeps recovery history.",
            "Bookmarks are preserved by a schema-checked SQLite transaction with a private rollback backup.",
            "AppSift requests Photos read and write access only when you start this scan. Analysis stays on this Mac, iCloud-only originals are not downloaded, and cleanup uses Photos Recently Deleted.",
            "Clusters photos with perceptual hashing and Vision feature distance, then recommends the strongest image in each group.",
            "Connected Device Batteries",
            "Discovering supported local image files…",
            "Document contents are not uploaded or indexed by AppSift.",
            "Evidence-based checks for old user folders, unreadable property lists, and macOS document versions.",
            "Groups ordinary Downloads files by the app that created their local quarantine record.",
            "Measuring browser data...",
            "Modern and system startup items stay read-only. Current-user legacy LaunchAgents can be controlled, and broken plists can be moved to the Trash with undo.",
            "Mounted Disks",
            "Move Broken LaunchAgent to Trash?",
            "No repairable Mail index files found",
            "No supported mounted disks found",
            "No system alerts have been recorded on this Mac.",
            "Only filesystem metadata is read during this scan.",
            "Only the source app and origin domain are shown. Full URLs, browsing history, and file contents are never collected.",
            "Passwords, bookmarks, autofill, open tabs, extensions, and saved Wi-Fi networks are never selected or modified.",
            "Photos Library assets are accessed only through PhotoKit. Live Photo, RAW, and burst metadata stay attached to each asset.",
            "Photos Library packages are never traversed as files; choose the Photos Library source to scan them safely through PhotoKit.",
            "Quality combines relative resolution, sharpness, exposure balance, and detected-face confidence. It is a recommendation, not a subjective photo score.",
            "Reading local backup metadata...",
            "Recoverable Broken Item Cleanup",
            "Removing…",
            "Restore Broken LaunchAgent?",
            "Review Finder device backups by device, date, encryption status, and physical disk use.",
            "Review local history, download records, cookies, and caches for Safari, Chrome, and Firefox.",
            "Scanning diagnostic evidence…",
            "Spotlight search results on the selected disk may be incomplete while macOS rebuilds the index. Use this only to repair search problems.",
            "Targeted repair tools for specific macOS problems — not routine performance boosters.",
            "The latest download cleanup can still be restored from the Trash.",
            "The latest similar-image cleanup can still be restored from the Trash.",
            "The most recent LaunchAgent plist is still in the Trash and can be restored.",
            "The newest backup for each device is never selected automatically. Removal is recoverable through the macOS Trash.",
            "This clears AppSift's local alert log. It does not change system data or dismiss current conditions.",
            "This clears cached DNS answers and restarts the macOS DNS responder. Network requests may briefly pause."
        ]

        for (language, fileURL) in files where language != "en" {
            let localized = try localizedDictionary(in: fileURL)
            for key in narrativeKeys.sorted() {
                let englishValue = try XCTUnwrap(english[key], "English catalog is missing \(key)")
                let localizedValue = try XCTUnwrap(
                    localized[key],
                    "\(language) catalog is missing \(key)"
                )
                XCTAssertNotEqual(
                    localizedValue,
                    englishValue,
                    "\(language) still exposes English copy for: \(key)"
                )
            }
        }
    }

    private func localizableStringsFiles() throws -> [String: URL] {
        let sourceRoot = repositoryRoot()
        let appSourceDirectory = sourceRoot.appendingPathComponent("AppSift")
        let contents = try FileManager.default.contentsOfDirectory(
            at: appSourceDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        return contents.reduce(into: [String: URL]()) { result, url in
            guard url.pathExtension == "lproj",
                  FileManager.default.fileExists(atPath: url.appendingPathComponent("Localizable.strings").path)
            else {
                return
            }

            result[url.deletingPathExtension().lastPathComponent] = url.appendingPathComponent("Localizable.strings")
        }
    }

    private func localizedKeys(in fileURL: URL) throws -> Set<String> {
        Set(try localizedDictionary(in: fileURL).keys)
    }

    private func localizedDictionary(in fileURL: URL) throws -> [String: String] {
        let data = try Data(contentsOf: fileURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)

        guard let strings = plist as? [String: String] else {
            XCTFail("\(fileURL.path) is not a valid Localizable.strings dictionary")
            return [:]
        }

        return strings
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
