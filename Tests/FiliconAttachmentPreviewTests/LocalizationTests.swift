import AppKit
import Foundation
import SwiftUI
import CustomDump
import FiliconAutomations
import Testing
@testable import Filicon

@Suite("UI localization")
struct LocalizationTests {
    @MainActor @Test func teamsAvailabilityRendersInSevenLanguagesAndBothAppearances() async throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for dark in [false, true] {
                try await withUIRenderTurn {
                    let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
                        Text("Microsoft Teams").font(.headline)
                        Text(FiliconLocalization.string(AutomationIngressProvider.microsoftTeams.authenticationSemantics, language: language))
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                        Divider()
                        TeamsRoutineAvailabilityNotice()
                    }.padding(24).frame(width: 440).background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = .init(x: 0, y: 0, width: 440, height: 480)
                    host.layoutSubtreeIfNeeded()
                    #expect(host.fittingSize.height <= 480)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    #expect(!png.isEmpty)
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try png.write(to: output.appending(path: "teams-\(language)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }

    @Test func teamsTransportAndUnavailablePoliciesAreDisclosedInSevenLanguages() {
        let authentication = AutomationIngressProvider.microsoftTeams.authenticationSemantics
        let notice = TeamsRoutineAvailabilityNotice.message
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            let auth = FiliconLocalization.string(authentication, language: language)
            let availability = FiliconLocalization.string(notice, language: language)
            expectNoDifference(auth == authentication, language == "en")
            expectNoDifference(availability == notice, language == "en")
            expectNoDifference(FiliconLocalization.string("Message contains (required)", language: language) == "Message contains (required)", language == "en")
            for token in ["Authorization", "HMAC", "base64", "rawBody", "Filicon"] { #expect(auth.contains(token)) }
            for token in ["Graph", "aadGroupId", "Bot", "blockUnauthenticatedUsers"] { #expect(availability.contains(token)) }
        }
    }

    @Test func pagerDutyAuthenticationDisclosureIsLocalizedWithoutChangingProtocolNames() {
        let key = AutomationIngressProvider.pagerDuty.authenticationSemantics
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            let text = FiliconLocalization.string(key, language: language)
            expectNoDifference(text == key, language == "en")
            for token in ["x-pagerduty-signature", "v1=HMAC(rawBody)", "event.id", "X-Webhook-Id", "occurred_at"] {
                #expect(text.contains(token))
            }
        }
    }

    @Test func sentryAuthenticationDisclosureIsLocalizedWithoutChangingProtocolNames() {
        let key = AutomationIngressProvider.sentry.authenticationSemantics
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            let text = FiliconLocalization.string(key, language: language)
            expectNoDifference(text == key, language == "en")
            for token in ["sentry-hook-signature", "HMAC(rawBody)", "sha256=", "Request-ID"] {
                #expect(text.contains(token))
            }
        }
    }

    @Test(arguments: [
        ("en-US", "en"), ("zh-TW", "zh-Hant"), ("zh-HK", "zh-Hant"),
        ("zh-MO", "zh-Hant"), ("zh_Hant_US", "zh-Hant"),
        ("zh-Hans-HK", "zh-Hans"), ("zh-CN", "zh-Hans"),
        ("fr-CA", "fr"), ("es-MX", "es"), ("ja-JP", "ja"),
        ("ko-KR", "ko"), ("de-DE", "en"), ("ar-SA", "en")
    ])
    func resolvesSystemLanguage(input: String, expected: String) {
        #expect(AppLanguage.systemLocale(preferredLanguages: [input]).identifier == expected)
    }

    @Test func unsupportedPrimaryLanguageUsesEnglish() {
        #expect(AppLanguage.systemLocale(preferredLanguages: ["de-DE", "fr-FR"]).identifier == "en")
        #expect(AppLanguage.systemLocale(preferredLanguages: []).identifier == "en")
    }

    @Test(arguments: [
        ("en", "Connect a bot"), ("zh-Hant", "連接機器人"),
        ("zh-Hans", "连接机器人"), ("fr", "Connecter un bot"),
        ("es", "Conectar un bot"), ("ja", "ボットを接続"), ("ko", "봇 연결")
    ])
    func loadsEachPackagedCatalog(language: String, expected: String) {
        #expect(FiliconLocalization.string("Connect a bot", language: language) == expected)
    }

    @Test func interpolationPreservesUserContentAndSupportsReordering() {
        let value: LocalizedText = "\("{1} Alice 👋") of \("10")"
        #expect(value.key == "{0} of {1}")
        #expect(value.arguments == ["{1} Alice 👋", "10"])
        #expect(FiliconLocalization.render(value, language: "en") == "{1} Alice 👋 of 10")
        #expect(FiliconLocalization.render(value, language: "ko") == "10 중 {1} Alice 👋")
    }

    @Test func absentKeyAndUnsupportedLanguageFallBackSafely() {
        #expect(FiliconLocalization.string("Connect a bot", language: "de") == "Connect a bot")
        #expect(FiliconLocalization.string("Custom user text 👋", language: "ja") == "Custom user text 👋")
    }

    @Test func missingArgumentDoesNotCrash() {
        let value = LocalizedText(key: "{0} of {1}", arguments: ["3"])
        #expect(FiliconLocalization.render(value, language: "en") == "3 of {1}")
    }

    @Test func explicitLanguagesIgnoreSystemPreference() {
        for language in AppLanguage.allCases where language != .system {
            #expect(language.locale.identifier == language.rawValue)
        }
    }
}
