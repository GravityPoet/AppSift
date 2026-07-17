import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

enum DefaultApplicationCategory: String, CaseIterable, Hashable, Sendable {
    case documents
    case images
    case audio
    case video
    case archives
    case developer
    case other
}

enum DefaultApplicationEvidence: String, Hashable, Sendable {
    case commonTypeCatalog
    case applicationDeclaration
    case launchServicesCurrentHandler
    case launchServicesCandidates
}

struct DefaultApplicationCandidate: Identifiable, Hashable, Sendable {
    let name: String
    let bundleIdentifier: String
    let url: URL
    let isSystemApplication: Bool

    var id: String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

struct DefaultApplicationItem: Identifiable, Hashable, Sendable {
    let contentTypeIdentifier: String
    let displayName: String
    let filenameExtensions: [String]
    let category: DefaultApplicationCategory
    let currentApplication: DefaultApplicationCandidate
    let candidateApplications: [DefaultApplicationCandidate]
    let evidence: Set<DefaultApplicationEvidence>

    var id: String { contentTypeIdentifier }

    var alternativeCount: Int {
        candidateApplications.count {
            $0.id != currentApplication.id
        }
    }

    func replacingCurrentApplication(
        _ application: DefaultApplicationCandidate
    ) -> DefaultApplicationItem {
        DefaultApplicationItem(
            contentTypeIdentifier: contentTypeIdentifier,
            displayName: displayName,
            filenameExtensions: filenameExtensions,
            category: category,
            currentApplication: application,
            candidateApplications: candidateApplications,
            evidence: evidence
        )
    }
}

struct DefaultApplicationScanResult: Sendable {
    let items: [DefaultApplicationItem]
    let unreadableApplicationDeclarationCount: Int
    let wasTruncated: Bool
}

struct DefaultApplicationHandlerSnapshot: Sendable {
    let defaultApplicationURL: URL?
    let candidateApplicationURLs: [URL]
}

enum DefaultApplicationScanner {
    typealias HandlerProvider = @Sendable (
        _ contentTypeIdentifier: String
    ) -> DefaultApplicationHandlerSnapshot?

    private struct ContentTypeDescriptor {
        let identifier: String
        var filenameExtensions: Set<String>
        var evidence: Set<DefaultApplicationEvidence>
    }

    private struct DescriptorCollection {
        var descriptors: [String: ContentTypeDescriptor] = [:]
        var unreadableApplicationDeclarationCount = 0
        var wasTruncated = false
    }

    private static let maximumApplicationCount = 2_000
    private static let maximumContentTypes = 4_096
    private static let maximumDocumentTypesPerApplication = 256
    private static let maximumTypeValuesPerDeclaration = 128
    private static let maximumCandidateApplicationsPerType = 128
    private static let maximumInfoPlistBytes = 4_000_000

    private static let commonFilenameExtensions = [
        "txt", "rtf", "pdf", "md", "markdown", "csv", "tsv",
        "json", "yaml", "yml", "toml", "xml", "plist", "html", "htm",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "pages", "numbers", "key",
        "jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "tif", "tiff", "bmp",
        "mp3", "m4a", "wav", "flac", "aac",
        "mp4", "mov", "mkv", "avi", "webm",
        "zip", "7z", "rar", "tar", "gz", "bz2", "xz",
        "dmg", "pkg", "xip",
        "swift", "py", "js", "ts", "sh", "zsh", "rb", "go", "rs",
        "java", "c", "h", "cpp", "css", "sql",
    ]

    private static let developerFilenameExtensions: Set<String> = [
        "swift", "py", "js", "ts", "jsx", "tsx", "sh", "zsh", "bash",
        "rb", "go", "rs", "java", "c", "h", "m", "mm", "cpp", "cc",
        "hpp", "css", "scss", "sass", "less", "sql", "json", "yaml",
        "yml", "toml", "xml", "plist",
    ]

    private static let excludedContentTypeIdentifiers: Set<String> = [
        "public.item",
        "public.content",
        "public.composite-content",
        "public.data",
        "public.directory",
        "public.folder",
        "public.volume",
        "public.package",
        "com.apple.application-bundle",
        "public.application",
        "public.executable",
        "public.unix-executable",
        "public.symlink",
    ]

    static func scan(
        applicationURLs: [URL],
        fileManager: FileManager = .default,
        handlerProvider: @escaping HandlerProvider = { identifier in
            guard let type = UTType(identifier) else { return nil }
            return DefaultApplicationHandlerSnapshot(
                defaultApplicationURL: NSWorkspace.shared.urlForApplication(
                    toOpen: type
                ),
                candidateApplicationURLs: NSWorkspace.shared
                    .urlsForApplications(toOpen: type)
            )
        }
    ) -> DefaultApplicationScanResult {
        let collection = collectDescriptors(
            applicationURLs: applicationURLs,
            fileManager: fileManager
        )
        var items: [DefaultApplicationItem] = []
        var wasTruncated = collection.wasTruncated

        for descriptor in collection.descriptors.values {
            guard let type = UTType(descriptor.identifier),
                  shouldDisplay(type: type, descriptor: descriptor),
                  let snapshot = handlerProvider(descriptor.identifier),
                  let defaultURL = snapshot.defaultApplicationURL,
                  let current = candidate(
                    at: defaultURL,
                    fileManager: fileManager
                  ) else {
                continue
            }

            if snapshot.candidateApplicationURLs.count
                > maximumCandidateApplicationsPerType {
                wasTruncated = true
            }
            var candidatesByPath: [String: DefaultApplicationCandidate] = [:]
            for url in snapshot.candidateApplicationURLs
                .prefix(maximumCandidateApplicationsPerType) {
                guard let value = candidate(
                    at: url,
                    fileManager: fileManager
                ) else { continue }
                candidatesByPath[value.id] = value
            }
            candidatesByPath[current.id] = current
            let candidates = candidatesByPath.values.sorted(by: candidateSort)
            guard !candidates.isEmpty else { continue }

            var evidence = descriptor.evidence
            evidence.insert(.launchServicesCurrentHandler)
            if !snapshot.candidateApplicationURLs.isEmpty {
                evidence.insert(.launchServicesCandidates)
            }
            let extensions = normalizedExtensions(
                descriptor.filenameExtensions.union(
                    type.preferredFilenameExtension.map { [$0] } ?? []
                )
            )
            let displayName = bounded(type.localizedDescription, maximum: 512)
                ?? extensions.first.map { $0.uppercased() + " file" }
                ?? descriptor.identifier

            items.append(
                DefaultApplicationItem(
                    contentTypeIdentifier: descriptor.identifier,
                    displayName: displayName,
                    filenameExtensions: extensions,
                    category: category(for: type, extensions: extensions),
                    currentApplication: current,
                    candidateApplications: candidates,
                    evidence: evidence
                )
            )
        }

        return DefaultApplicationScanResult(
            items: items.sorted(by: itemSort),
            unreadableApplicationDeclarationCount:
                collection.unreadableApplicationDeclarationCount,
            wasTruncated: wasTruncated
        )
    }

    static func candidate(
        at applicationURL: URL,
        fileManager: FileManager = .default
    ) -> DefaultApplicationCandidate? {
        guard applicationURL.isFileURL else { return nil }
        let standardized = applicationURL.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath()
        guard resolved.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              !resolved.pathComponents.contains(".Trash"),
              !resolved.pathComponents.contains(".Trashes"),
              isRealDirectory(standardized),
              fileManager.fileExists(atPath: resolved.path),
              let bundle = Bundle(url: resolved),
              let identifier = bounded(
                bundle.bundleIdentifier,
                maximum: 512
              ),
              isReasonableBundleIdentifier(identifier) else {
            return nil
        }
        let localized = bundle.localizedInfoDictionary
        let info = bundle.infoDictionary
        let name = bounded(
            localized?["CFBundleDisplayName"] as? String,
            maximum: 512
        )
            ?? bounded(
                localized?["CFBundleName"] as? String,
                maximum: 512
            )
            ?? bounded(
                info?["CFBundleDisplayName"] as? String,
                maximum: 512
            )
            ?? bounded(info?["CFBundleName"] as? String, maximum: 512)
            ?? resolved.deletingPathExtension().lastPathComponent

        return DefaultApplicationCandidate(
            name: name,
            bundleIdentifier: identifier,
            url: resolved,
            isSystemApplication: resolved.path.hasPrefix("/System/")
        )
    }

    private static func collectDescriptors(
        applicationURLs: [URL],
        fileManager: FileManager
    ) -> DescriptorCollection {
        var collection = DescriptorCollection()
        for filenameExtension in commonFilenameExtensions {
            guard let type = UTType(filenameExtension: filenameExtension) else {
                continue
            }
            addDescriptor(
                identifier: type.identifier,
                filenameExtensions: [filenameExtension],
                evidence: .commonTypeCatalog,
                collection: &collection
            )
        }

        if applicationURLs.count > maximumApplicationCount {
            collection.wasTruncated = true
        }
        for applicationURL in applicationURLs.prefix(maximumApplicationCount) {
            guard let dictionary = loadInfoDictionary(
                applicationURL: applicationURL,
                fileManager: fileManager
            ) else {
                if fileManager.fileExists(
                    atPath: applicationURL
                        .appendingPathComponent("Contents/Info.plist")
                        .path
                ) {
                    collection.unreadableApplicationDeclarationCount += 1
                }
                continue
            }
            collectDocumentTypes(
                from: dictionary,
                collection: &collection
            )
            collectTypeDeclarations(
                from: dictionary["UTExportedTypeDeclarations"],
                collection: &collection
            )
            collectTypeDeclarations(
                from: dictionary["UTImportedTypeDeclarations"],
                collection: &collection
            )
        }
        return collection
    }

    private static func collectDocumentTypes(
        from dictionary: [String: Any],
        collection: inout DescriptorCollection
    ) {
        guard let values = dictionary["CFBundleDocumentTypes"] as? [[String: Any]] else {
            return
        }
        if values.count > maximumDocumentTypesPerApplication {
            collection.wasTruncated = true
        }
        for value in values.prefix(maximumDocumentTypesPerApplication) {
            let extensions = stringValues(value["CFBundleTypeExtensions"])
                .filter(isReasonableFilenameExtension)
            let identifiers = stringValues(value["LSItemContentTypes"])
                .filter(isReasonableContentTypeIdentifier)
            for identifier in identifiers.prefix(maximumTypeValuesPerDeclaration) {
                addDescriptor(
                    identifier: identifier,
                    filenameExtensions: extensions,
                    evidence: .applicationDeclaration,
                    collection: &collection
                )
            }
            for filenameExtension in extensions.prefix(
                maximumTypeValuesPerDeclaration
            ) {
                guard let type = UTType(
                    filenameExtension: filenameExtension
                ) else { continue }
                addDescriptor(
                    identifier: type.identifier,
                    filenameExtensions: [filenameExtension],
                    evidence: .applicationDeclaration,
                    collection: &collection
                )
            }
        }
    }

    private static func collectTypeDeclarations(
        from rawValue: Any?,
        collection: inout DescriptorCollection
    ) {
        guard let values = rawValue as? [[String: Any]] else { return }
        if values.count > maximumDocumentTypesPerApplication {
            collection.wasTruncated = true
        }
        for value in values.prefix(maximumDocumentTypesPerApplication) {
            guard let identifier = bounded(
                value["UTTypeIdentifier"] as? String,
                maximum: 512
            ),
                  isReasonableContentTypeIdentifier(identifier) else {
                continue
            }
            let tags = value["UTTypeTagSpecification"] as? [String: Any]
            let extensions = stringValues(tags?["public.filename-extension"])
                .filter(isReasonableFilenameExtension)
            addDescriptor(
                identifier: identifier,
                filenameExtensions: extensions,
                evidence: .applicationDeclaration,
                collection: &collection
            )
        }
    }

    private static func addDescriptor(
        identifier: String,
        filenameExtensions: [String],
        evidence: DefaultApplicationEvidence,
        collection: inout DescriptorCollection
    ) {
        guard isReasonableContentTypeIdentifier(identifier),
              !excludedContentTypeIdentifiers.contains(identifier) else {
            return
        }
        if var existing = collection.descriptors[identifier] {
            existing.filenameExtensions.formUnion(
                filenameExtensions.map { $0.lowercased() }
            )
            existing.evidence.insert(evidence)
            collection.descriptors[identifier] = existing
            return
        }
        guard collection.descriptors.count < maximumContentTypes else {
            collection.wasTruncated = true
            return
        }
        collection.descriptors[identifier] = ContentTypeDescriptor(
            identifier: identifier,
            filenameExtensions: Set(
                filenameExtensions.map { $0.lowercased() }
            ),
            evidence: [evidence]
        )
    }

    private static func loadInfoDictionary(
        applicationURL: URL,
        fileManager: FileManager
    ) -> [String: Any]? {
        let root = applicationURL.standardizedFileURL
        let infoURL = root.appendingPathComponent("Contents/Info.plist")
        guard isSafeRegularFile(infoURL, containedIn: root),
              let attributes = try? fileManager.attributesOfItem(
                atPath: infoURL.path
              ),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0,
              size <= maximumInfoPlistBytes,
              let data = try? Data(contentsOf: infoURL, options: .mappedIfSafe),
              data.count <= maximumInfoPlistBytes,
              let dictionary = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private static func shouldDisplay(
        type: UTType,
        descriptor: ContentTypeDescriptor
    ) -> Bool {
        guard !excludedContentTypeIdentifiers.contains(type.identifier) else {
            return false
        }
        return type.preferredFilenameExtension != nil
            || !descriptor.filenameExtensions.isEmpty
    }

    private static func category(
        for type: UTType,
        extensions: [String]
    ) -> DefaultApplicationCategory {
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) { return .video }
        if let archive = UTType("public.archive"), type.conforms(to: archive) {
            return .archives
        }
        if type.conforms(to: .sourceCode)
            || !developerFilenameExtensions.isDisjoint(with: extensions) {
            return .developer
        }
        if type.conforms(to: .text) || type.conforms(to: .pdf) {
            return .documents
        }
        return .other
    }

    private static func normalizedExtensions(
        _ values: Set<String>
    ) -> [String] {
        Array(values)
            .filter(isReasonableFilenameExtension)
            .sorted {
                let comparison = $0.localizedCaseInsensitiveCompare($1)
                if comparison == .orderedSame { return $0 < $1 }
                return comparison == .orderedAscending
            }
            .prefix(32)
            .map { $0 }
    }

    private static func stringValues(_ value: Any?) -> [String] {
        if let string = value as? String {
            return [string]
        }
        return (value as? [Any] ?? []).compactMap { $0 as? String }
    }

    private static func isReasonableFilenameExtension(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty,
              normalized != "*",
              normalized.utf8.count <= 64 else {
            return false
        }
        return normalized.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || ["+", "-", "_"].contains(Character(String($0)))
        }
    }

    private static func isReasonableContentTypeIdentifier(
        _ value: String
    ) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || [".", "-", "_"].contains(Character(String($0)))
        }
    }

    private static func isReasonableBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || [".", "-", "_"].contains(Character(String($0)))
        }
    }

    private static func isSafeRegularFile(
        _ url: URL,
        containedIn rootURL: URL
    ) -> Bool {
        let standardized = url.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath()
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") else { return false }
        var info = stat()
        guard lstat(standardized.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func bounded(
        _ value: String?,
        maximum: Int
    ) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximum,
              trimmed.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return trimmed
    }

    private static func itemSort(
        _ lhs: DefaultApplicationItem,
        _ rhs: DefaultApplicationItem
    ) -> Bool {
        let lhsCategory = categoryOrder(lhs.category)
        let rhsCategory = categoryOrder(rhs.category)
        if lhsCategory != rhsCategory { return lhsCategory < rhsCategory }
        let comparison = lhs.displayName.localizedCaseInsensitiveCompare(
            rhs.displayName
        )
        if comparison == .orderedSame {
            return lhs.contentTypeIdentifier < rhs.contentTypeIdentifier
        }
        return comparison == .orderedAscending
    }

    private static func candidateSort(
        _ lhs: DefaultApplicationCandidate,
        _ rhs: DefaultApplicationCandidate
    ) -> Bool {
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if comparison == .orderedSame { return lhs.id < rhs.id }
        return comparison == .orderedAscending
    }

    private static func categoryOrder(
        _ category: DefaultApplicationCategory
    ) -> Int {
        switch category {
        case .documents: return 0
        case .images: return 1
        case .audio: return 2
        case .video: return 3
        case .archives: return 4
        case .developer: return 5
        case .other: return 6
        }
    }
}
