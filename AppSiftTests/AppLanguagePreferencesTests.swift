import XCTest
@testable import AppSift

final class AppLanguagePreferencesTests: XCTestCase {
    func testFreshInstallDefaultsToSystemLanguage() {
        let context = makeDefaults()

        XCTAssertEqual(
            AppLanguage.resolve(
                defaults: context.defaults,
                bundleIdentifier: context.suiteName
            ),
            .system
        )
    }

    func testExplicitCustomerChoiceOverridesSystemDefault() {
        let context = makeDefaults()
        context.defaults.set(
            AppLanguage.japanese.rawValue,
            forKey: AppLanguage.preferenceKey
        )

        XCTAssertEqual(
            AppLanguage.resolve(
                defaults: context.defaults,
                bundleIdentifier: context.suiteName
            ),
            .japanese
        )
    }

    func testLegacyAppLanguageOverrideIsPreserved() {
        let context = makeDefaults()
        context.defaults.set(["zh_Hant"], forKey: "AppleLanguages")

        XCTAssertEqual(
            AppLanguage.resolve(
                defaults: context.defaults,
                bundleIdentifier: context.suiteName
            ),
            .traditionalChinese
        )
    }

    func testUnsupportedLegacyOverrideFallsBackToSystemLanguage() {
        let context = makeDefaults()
        context.defaults.set(["fr-FR"], forKey: "AppleLanguages")

        XCTAssertEqual(
            AppLanguage.resolve(
                defaults: context.defaults,
                bundleIdentifier: context.suiteName
            ),
            .system
        )
    }

    func testSupportedLocalizationsFollowSystemLanguagePreferences() {
        let supported = AppLanguage.allCases
            .filter { $0 != .system }
            .map(\.rawValue)
        let expectations = [
            "zh-Hans-CN": "zh-Hans",
            "zh-Hant-TW": "zh-Hant",
            "ja-JP": "ja",
            "es-ES": "es",
            "ar-SA": "ar",
            "pt-BR": "pt-BR",
            "fr-FR": "en",
        ]

        for (systemLanguage, expectedLocalization) in expectations {
            XCTAssertEqual(
                Bundle.preferredLocalizations(
                    from: supported,
                    forPreferences: [systemLanguage]
                ).first,
                expectedLocalization,
                "Expected \(systemLanguage) to select \(expectedLocalization)"
            )
        }
    }

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
