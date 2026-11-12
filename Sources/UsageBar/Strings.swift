import SwiftUI
import UsageCore

/// 画面の文言。日本語と英語の対応表をコードで持つ。
/// `.strings` ファイルではなくコードにしているのは、設定画面で言語を変えたときに再起動なしで切り替えるため。
struct Strings {
    let language: AppLanguage

    private func t(_ ja: String, _ en: String) -> String {
        language == .ja ? ja : en
    }

    var loading: String { t("ログを読み込んでいます…", "Reading logs…") }

    func observed(_ ago: String) -> String { t("使用率の取得: \(ago)", "Updated \(ago)") }

    func stale(_ ago: String, provider: String) -> String {
        t("\(ago)に取得した値です。\(provider) を使うと更新されます。",
          "Last received \(ago). It updates when you use \(provider).")
    }

    var claudeSetupIntro: String {
        t("使用率はまだ届いていません。Claude Code のステータスラインから受け取るため、次のコマンドを一度だけ実行してください。",
          "No usage received yet. UsageBar gets it from Claude Code's status line. Run this command once:")
    }
    var copyCommand: String { t("コマンドをコピー", "Copy command") }
    var claudeSetupAfter: String {
        t("設定後、Claude Code で応答を受け取るたびに更新されます。",
          "After that, it updates every time Claude Code receives a response.")
    }
    var codexMissing: String {
        t("使用率はまだ見つかっていません。Codex CLI を使うと、ログから読み取って表示します。",
          "No usage found yet. Use Codex CLI and UsageBar will read it from the logs.")
    }

    func modelWindowStale(_ ago: String) -> String {
        t("\(ago)の値です。Claude Code で /usage を開くと更新されます。",
          "As of \(ago). Open /usage in Claude Code to update it.")
    }

    var resetPassed: String { t("リセット済み（次に使ったときに更新）", "Reset (updates on next use)") }
    func resets(_ remaining: String, at moment: String) -> String {
        t("リセット: \(remaining)（\(moment)）", "Resets \(remaining) (\(moment))")
    }

    var total: String { t("合計", "Total") }
    var input: String { t("入力", "Input") }
    var output: String { t("出力", "Output") }
    var cacheRead: String { t("キャッシュ読込", "Cache read") }
    var today: String { t("今日", "Today") }
    var last5Hours: String { t("直近5時間", "Last 5h") }
    var chartDay: String { t("日", "Day") }
    var chartTokens: String { t("トークン", "Tokens") }
    var chartAccessibility: String { t("過去7日のトークン数", "Tokens over the last 7 days") }

    var noNetwork: String {
        t("外部との通信なし（App Sandbox で通信の権限を付けていません）・ログは読み取り専用",
          "No network access (sandboxed without the network permission). Logs are read-only.")
    }
    var showPercent: String { t("メニューバーに使用率を表示", "Show percentages in the menu bar") }
    var launchAtLogin: String { t("ログイン時に起動", "Open at login") }
    func launchAtLoginFailed(_ detail: String) -> String { t("設定できませんでした: \(detail)", "Could not change the setting: \(detail)") }
    var languageLabel: String { t("表示言語", "Language") }
    func languageOption(_ preference: LanguagePreference) -> String {
        switch preference {
        case .system: return t("Mac の設定に合わせる", "Match macOS")
        case .ja: return "日本語"
        case .en: return "English"
        }
    }
    var reload: String { t("再読み込み", "Reload") }
    var quit: String { t("終了", "Quit") }

    func menuBarAccessibility(claude: String, codex: String) -> String {
        t("Claude \(claude)、Codex \(codex)", "Claude \(claude), Codex \(codex)")
    }

    func note(_ note: ProviderNote) -> String {
        switch note {
        case .claudeBridgeNotConfigured:
            return t("使用率は Claude Code のステータスライン連携（usagebar-bridge）から受け取ります。",
                     "Usage comes from the Claude Code status line helper (usagebar-bridge).")
        case .compressedLogsSkipped(let count):
            return t("圧縮済み（.zst）の古いログ \(count) 件はトークン数の集計に含めていません。",
                     "\(count) older compressed (.zst) logs are not included in the token totals.")
        }
    }
}

private struct AppLanguageKey: EnvironmentKey {
    static let defaultValue: AppLanguage = .fromSystem()
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }
}
