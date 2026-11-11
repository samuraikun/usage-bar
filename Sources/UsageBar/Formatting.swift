import Foundation
import UsageCore

enum Format {
    static func tokens(_ value: Int64) -> String {
        let number = Double(value)
        switch abs(number) {
        case 1_000_000_000...: return String(format: "%.2fB", number / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", number / 1_000_000)
        case 1_000...: return String(format: "%.1fK", number / 1_000)
        default: return "\(value)"
        }
    }

    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        return "\(Int(min(max(value, 0), 1000).rounded()))%"
    }

    /// 「あと2時間10分」「in 2h 10m」のような残り時間。
    static func remaining(until date: Date, now: Date, language: AppLanguage) -> String {
        let seconds = safeSeconds(date.timeIntervalSince(now))
        guard seconds > 0 else { return language == .ja ? "リセット済み" : "reset" }
        return language == .ja ? "あと" + duration(seconds, language: language) : "in " + duration(seconds, language: language)
    }

    /// 「3分前」「3m ago」のような経過時間。
    static func ago(_ date: Date, now: Date, language: AppLanguage) -> String {
        let seconds = safeSeconds(now.timeIntervalSince(date))
        if seconds < 60 { return language == .ja ? "たった今" : "just now" }
        return language == .ja ? duration(seconds, language: language) + "前" : duration(seconds, language: language) + " ago"
    }

    /// 秒数を整数に直す。範囲外や非有限値でもあふれないよう、±100 年に収める。
    static func safeSeconds(_ interval: TimeInterval) -> Int {
        guard interval.isFinite else { return 0 }
        return Int(min(max(interval, -3_155_760_000), 3_155_760_000))
    }

    static func duration(_ seconds: Int, language: AppLanguage) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        switch language {
        case .ja:
            if days > 0 { return hours > 0 ? "\(days)日\(hours)時間" : "\(days)日" }
            if hours > 0 { return minutes > 0 ? "\(hours)時間\(minutes)分" : "\(hours)時間" }
            return "\(max(minutes, 1))分"
        case .en:
            if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
            if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
            return "\(max(minutes, 1))m"
        }
    }

    /// 今日なら時刻だけ、それ以外は日付つきで返す。書式は言語ごとの慣習に従う（日本語は 24 時間表記）。
    static func moment(_ date: Date, now: Date, language: AppLanguage, calendar: Calendar = .current) -> String {
        let sameDay = calendar.isDate(date, inSameDayAs: now)
        let formatter = DateFormatter()
        formatter.locale = language.locale
        switch language {
        case .ja: formatter.dateFormat = sameDay ? "H:mm" : "M/d(E) H:mm"
        case .en: formatter.setLocalizedDateFormatFromTemplate(sameDay ? "jmm" : "EEEMMMdjmm")
        }
        return formatter.string(from: date)
    }

    static func weekday(_ date: Date, language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }
}
