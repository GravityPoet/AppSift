import AppKit
import XCTest
@testable import AppSift

final class AppUsageAnalyzerTests: XCTestCase {
    func testMissingLastUsedDateIsUnknownInsteadOfNeverOpened() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(
            AppUsageAnalyzer.status(
                lastUsedAt: nil,
                thresholdDays: 90,
                referenceDate: now
            ),
            .unknown
        )
    }

    func testThresholdBoundaryAndFutureDateAreClassifiedConservatively() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 24 * 60 * 60

        XCTAssertEqual(
            AppUsageAnalyzer.status(
                lastUsedAt: now.addingTimeInterval(-90 * day),
                thresholdDays: 90,
                referenceDate: now
            ),
            .unused
        )
        XCTAssertEqual(
            AppUsageAnalyzer.status(
                lastUsedAt: now.addingTimeInterval(-89 * day),
                thresholdDays: 90,
                referenceDate: now
            ),
            .recentlyUsed
        )
        XCTAssertEqual(
            AppUsageAnalyzer.status(
                lastUsedAt: now.addingTimeInterval(1),
                thresholdDays: 90,
                referenceDate: now
            ),
            .unknown
        )
    }

    func testMetadataReaderAcceptsDateEvidenceAndRejectsOtherValues() {
        let url = URL(fileURLWithPath: "/Applications/Example.app")
        let expected = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            AppUsageMetadataReader.lastUsedDate(at: url) { requestedURL in
                XCTAssertEqual(requestedURL, url)
                return expected
            },
            expected
        )
        XCTAssertNil(
            AppUsageMetadataReader.lastUsedDate(at: url) { _ in
                "2026-01-01"
            }
        )
    }

    func testUsageFiltersNeverTreatMissingEvidenceAsUnused() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 24 * 60 * 60

        XCTAssertTrue(
            AppUsageFilter.unused90.matches(
                lastUsedAt: now.addingTimeInterval(-100 * day),
                referenceDate: now
            )
        )
        XCTAssertFalse(
            AppUsageFilter.unused90.matches(
                lastUsedAt: nil,
                referenceDate: now
            )
        )
        XCTAssertTrue(
            AppUsageFilter.unknown.matches(
                lastUsedAt: nil,
                referenceDate: now
            )
        )
        XCTAssertTrue(
            AppUsageFilter.unknown.matches(
                lastUsedAt: now.addingTimeInterval(1),
                referenceDate: now
            )
        )
    }

    func testLastUsedSortingKeepsUnknownEvidenceAfterKnownDates() {
        let older = Date(timeIntervalSince1970: 1_600_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_000)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(
            AppUsageAnalyzer.compareLastUsed(
                older,
                newer,
                newestFirst: false
            ),
            .orderedAscending
        )
        XCTAssertEqual(
            AppUsageAnalyzer.compareLastUsed(
                older,
                newer,
                newestFirst: true
            ),
            .orderedDescending
        )
        XCTAssertEqual(
            AppUsageAnalyzer.compareLastUsed(
                nil,
                newer,
                newestFirst: true
            ),
            .orderedDescending
        )
        XCTAssertEqual(
            AppUsageAnalyzer.compareLastUsed(
                now.addingTimeInterval(1),
                newer,
                newestFirst: false,
                referenceDate: now
            ),
            .orderedDescending
        )
    }

    func testUsageReportJSONCarriesSummaryStatusAndExplicitMissingEvidence() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let apps = [
            InstalledApp(
                appName: "Old App",
                bundleIdentifier: "com.example.old",
                path: URL(fileURLWithPath: "/Applications/Old App.app"),
                icon: NSImage(),
                size: 1_024,
                version: "1.0",
                lastUsedAt: now.addingTimeInterval(-100 * day)
            ),
            InstalledApp(
                appName: "Unknown App",
                bundleIdentifier: "com.example.unknown",
                path: URL(fileURLWithPath: "/Applications/Unknown App.app"),
                icon: NSImage(),
                size: 2_048,
                version: "2.0",
                lastUsedAt: nil
            ),
        ]

        let report = AppUsageReport.make(
            applications: apps,
            thresholdDays: 90,
            referenceDate: now
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: report.encodedJSON())
                as? [String: Any]
        )
        let summary = try XCTUnwrap(object["summary"] as? [String: Any])
        let rows = try XCTUnwrap(object["applications"] as? [[String: Any]])

        XCTAssertEqual(object["thresholdDays"] as? Int, 90)
        XCTAssertEqual(summary["total"] as? Int, 2)
        XCTAssertEqual(summary["unused"] as? Int, 1)
        XCTAssertEqual(summary["unknown"] as? Int, 1)
        XCTAssertEqual(rows.map { $0["status"] as? String }, ["unused", "unknown"])
        XCTAssertTrue(rows[1]["lastUsedAt"] is NSNull)
    }

    func testCLIOptionsAcceptOnlyDocumentedThresholds() {
        XCTAssertEqual(
            AppUsageCLIOptions.parse([]),
            AppUsageCLIOptions(thresholdDays: 90, outputsJSON: false)
        )
        XCTAssertEqual(
            AppUsageCLIOptions.parse(["--json", "--days", "180"]),
            AppUsageCLIOptions(thresholdDays: 180, outputsJSON: true)
        )
        XCTAssertNil(AppUsageCLIOptions.parse(["--days", "45"]))
        XCTAssertNil(AppUsageCLIOptions.parse(["--days"]))
        XCTAssertNil(AppUsageCLIOptions.parse(["--mystery"]))
    }
}
