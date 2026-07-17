import Foundation
import CoreServices

enum AppUsageStatus: String, Codable, Hashable, Sendable {
    case recentlyUsed
    case unused
    case unknown
}

enum AppUsageFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case unused30
    case unused90
    case unused180
    case unknown

    var id: String { rawValue }

    var thresholdDays: Int? {
        switch self {
        case .all, .unknown: nil
        case .unused30: 30
        case .unused90: 90
        case .unused180: 180
        }
    }

    func matches(
        lastUsedAt: Date?,
        referenceDate: Date = Date()
    ) -> Bool {
        switch self {
        case .all:
            true
        case .unknown:
            AppUsageAnalyzer.status(
                lastUsedAt: lastUsedAt,
                thresholdDays: 1,
                referenceDate: referenceDate
            ) == .unknown
        case .unused30, .unused90, .unused180:
            AppUsageAnalyzer.status(
                lastUsedAt: lastUsedAt,
                thresholdDays: thresholdDays ?? 90,
                referenceDate: referenceDate
            ) == .unused
        }
    }
}

struct AppUsageCLIOptions: Equatable, Sendable {
    let thresholdDays: Int
    let outputsJSON: Bool

    static func parse(_ arguments: [String]) -> AppUsageCLIOptions? {
        var thresholdDays = 90
        var outputsJSON = false
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--json":
                outputsJSON = true
                index += 1
            case "--days":
                guard index + 1 < arguments.count,
                      let parsed = Int(arguments[index + 1]),
                      [30, 90, 180].contains(parsed) else {
                    return nil
                }
                thresholdDays = parsed
                index += 2
            default:
                return nil
            }
        }

        return AppUsageCLIOptions(
            thresholdDays: thresholdDays,
            outputsJSON: outputsJSON
        )
    }
}

enum AppUsageAnalyzer {
    static func status(
        lastUsedAt: Date?,
        thresholdDays: Int,
        referenceDate: Date = Date()
    ) -> AppUsageStatus {
        guard thresholdDays > 0,
              let lastUsedAt,
              lastUsedAt <= referenceDate else {
            return .unknown
        }

        let threshold = TimeInterval(thresholdDays) * 24 * 60 * 60
        return referenceDate.timeIntervalSince(lastUsedAt) >= threshold
            ? .unused
            : .recentlyUsed
    }

    static func compareLastUsed(
        _ lhs: Date?,
        _ rhs: Date?,
        newestFirst: Bool,
        referenceDate: Date = Date()
    ) -> ComparisonResult {
        let validLHS = lhs.flatMap { $0 <= referenceDate ? $0 : nil }
        let validRHS = rhs.flatMap { $0 <= referenceDate ? $0 : nil }
        switch (validLHS, validRHS) {
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return .orderedDescending
        case (_, nil):
            return .orderedAscending
        case let (lhs?, rhs?):
            let result = lhs.compare(rhs)
            guard newestFirst else { return result }
            switch result {
            case .orderedAscending: return .orderedDescending
            case .orderedDescending: return .orderedAscending
            case .orderedSame: return .orderedSame
            }
        }
    }
}

enum AppUsageMetadataReader {
    static func lastUsedDate(at url: URL) -> Date? {
        lastUsedDate(at: url, attributeProvider: metadataValue)
    }

    static func lastUsedDate(
        at url: URL,
        attributeProvider: (URL) -> Any?
    ) -> Date? {
        attributeProvider(url) as? Date
    }

    private static func metadataValue(at url: URL) -> Any? {
        guard let item = MDItemCreate(
            kCFAllocatorDefault,
            url.path as CFString
        ) else {
            return nil
        }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate)
    }
}

struct AppUsageReportSummary: Codable, Equatable, Sendable {
    let total: Int
    let recentlyUsed: Int
    let unused: Int
    let unknown: Int
}

struct AppUsageReportItem: Codable, Equatable, Sendable {
    let name: String
    let bundleIdentifier: String
    let path: String
    let version: String?
    let bytes: Int64
    let lastUsedAt: Date?
    let daysSinceLastUse: Int?
    let status: AppUsageStatus

    private enum CodingKeys: String, CodingKey {
        case name
        case bundleIdentifier
        case path
        case version
        case bytes
        case lastUsedAt
        case daysSinceLastUse
        case status
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encode(bytes, forKey: .bytes)
        if let lastUsedAt {
            try container.encode(lastUsedAt, forKey: .lastUsedAt)
        } else {
            try container.encodeNil(forKey: .lastUsedAt)
        }
        if let daysSinceLastUse {
            try container.encode(daysSinceLastUse, forKey: .daysSinceLastUse)
        } else {
            try container.encodeNil(forKey: .daysSinceLastUse)
        }
        try container.encode(status, forKey: .status)
    }
}

struct AppUsageReport: Codable, Equatable, Sendable {
    let generatedAt: Date
    let thresholdDays: Int
    let summary: AppUsageReportSummary
    let applications: [AppUsageReportItem]

    static func make(
        applications: [InstalledApp],
        thresholdDays: Int,
        referenceDate: Date = Date()
    ) -> AppUsageReport {
        let effectiveThreshold = thresholdDays > 0 ? thresholdDays : 90
        let items = applications.map { app in
            let status = AppUsageAnalyzer.status(
                lastUsedAt: app.lastUsedAt,
                thresholdDays: effectiveThreshold,
                referenceDate: referenceDate
            )
            let daysSinceLastUse: Int?
            if let lastUsedAt = app.lastUsedAt,
               lastUsedAt <= referenceDate {
                daysSinceLastUse = Int(
                    referenceDate.timeIntervalSince(lastUsedAt) / (24 * 60 * 60)
                )
            } else {
                daysSinceLastUse = nil
            }
            return AppUsageReportItem(
                name: app.appName,
                bundleIdentifier: app.bundleIdentifier,
                path: app.path.path,
                version: app.versionSummary,
                bytes: app.size,
                lastUsedAt: app.lastUsedAt,
                daysSinceLastUse: daysSinceLastUse,
                status: status
            )
        }.sorted { lhs, rhs in
            let usageResult = AppUsageAnalyzer.compareLastUsed(
                lhs.lastUsedAt,
                rhs.lastUsedAt,
                newestFirst: false,
                referenceDate: referenceDate
            )
            if usageResult != .orderedSame {
                return usageResult == .orderedAscending
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                == .orderedAscending
        }

        return AppUsageReport(
            generatedAt: referenceDate,
            thresholdDays: effectiveThreshold,
            summary: AppUsageReportSummary(
                total: items.count,
                recentlyUsed: items.filter { $0.status == .recentlyUsed }.count,
                unused: items.filter { $0.status == .unused }.count,
                unknown: items.filter { $0.status == .unknown }.count
            ),
            applications: items
        )
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
