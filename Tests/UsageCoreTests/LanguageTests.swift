import XCTest
@testable import UsageCore

final class LanguageTests: XCTestCase {
    func testFollowsTheFirstSupportedLanguageInMacOSSettings() {
        XCTAssertEqual(AppLanguage.fromSystem(preferredLanguages: ["ja-JP", "en-US"]), .ja)
        XCTAssertEqual(AppLanguage.fromSystem(preferredLanguages: ["en-GB", "ja-JP"]), .en)
        // 対応していない言語は飛ばし、次に並ぶ対応言語を使う。
        XCTAssertEqual(AppLanguage.fromSystem(preferredLanguages: ["fr-FR", "ja-JP"]), .ja)
        // どれにも当たらなければ英語。
        XCTAssertEqual(AppLanguage.fromSystem(preferredLanguages: ["de-DE", "zh-Hans"]), .en)
        XCTAssertEqual(AppLanguage.fromSystem(preferredLanguages: []), .en)
    }

    func testUserChoiceOverridesMacOSSettings() {
        XCTAssertEqual(LanguagePreference.en.resolved(preferredLanguages: ["ja-JP"]), .en)
        XCTAssertEqual(LanguagePreference.ja.resolved(preferredLanguages: ["en-US"]), .ja)
        XCTAssertEqual(LanguagePreference.system.resolved(preferredLanguages: ["ja-JP"]), .ja)
    }

    func testWindowLabelsInBothLanguages() {
        let cases: [(Int?, String, String, String)] = [
            (300, "x", "5時間枠", "5-hour"),
            (10080, "x", "週間枠", "Weekly"),
            (1440, "x", "1日枠", "Daily"),
            (4320, "x", "3日枠", "3-day"),
            (120, "x", "2時間枠", "2-hour"),
            (45, "x", "45分枠", "45-minute"),
            (nil, "spend_limit", "利用額の上限", "Spend limit"),
        ]
        for (minutes, id, ja, en) in cases {
            let window = RateWindow(id: id, usedPercent: 1, windowMinutes: minutes, resetsAt: nil)
            XCTAssertEqual(window.label(in: .ja), ja)
            XCTAssertEqual(window.label(in: .en), en)
        }
    }
}
