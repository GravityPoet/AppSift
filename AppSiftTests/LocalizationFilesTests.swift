import XCTest

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

    private func localizableStringsFiles() throws -> [String: URL] {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
        let data = try Data(contentsOf: fileURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)

        guard let strings = plist as? [String: String] else {
            XCTFail("\(fileURL.path) is not a valid Localizable.strings dictionary")
            return []
        }

        return Set(strings.keys)
    }
}
