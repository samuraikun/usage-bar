import Foundation

/// 画面に出す言語。対応するのは日本語と英語だけ。
public enum AppLanguage: String, Sendable, CaseIterable {
    case ja
    case en

    /// Mac の言語設定（優先する言語の並び）から選ぶ。日本語が英語より先にあれば日本語、それ以外は英語。
    public static func fromSystem(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        for identifier in preferredLanguages {
            let code = identifier.lowercased()
            if code.hasPrefix("ja") { return .ja }
            if code.hasPrefix("en") { return .en }
        }
        return .en
    }

    /// 日付や曜日の書式に使うロケール。
    public var locale: Locale {
        Locale(identifier: self == .ja ? "ja_JP" : "en_US")
    }
}

/// 利用者が選ぶ表示言語。`system` は Mac の言語設定に従う。
public enum LanguagePreference: String, Sendable, CaseIterable, Identifiable {
    case system
    case ja
    case en

    public var id: String { rawValue }

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        switch self {
        case .system: return AppLanguage.fromSystem(preferredLanguages: preferredLanguages)
        case .ja: return .ja
        case .en: return .en
        }
    }
}

/// 利用者に知らせる補足。文言は画面側で言語に合わせて作る。
public enum ProviderNote: Sendable, Equatable, Hashable {
    /// Claude の使用率を受け取る中継コマンドが、まだ値を書いていない。
    case claudeBridgeNotConfigured
    /// 圧縮済みの Codex のログを、トークン数の集計から外した件数。
    case compressedLogsSkipped(Int)
}
