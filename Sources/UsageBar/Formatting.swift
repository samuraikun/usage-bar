import Foundation

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

    /// 「あと 2時間10分」のような残り時間。
    static func remaining(until date: Date, now: Date) -> String {
        let seconds = safeSeconds(date.timeIntervalSince(now))
        guard seconds > 0 else { return "リセット済み" }
        return "あと" + duration(seconds)
    }

    /// 「3分前」のような経過時間。
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = safeSeconds(now.timeIntervalSince(date))
        if seconds < 60 { return "たった今" }
        return duration(seconds) + "前"
    }

    /// 秒数を整数に直す。範囲外や非有限値でもあふれないよう、±100 年に収める。
    static func safeSeconds(_ interval: TimeInterval) -> Int {
        guard interval.isFinite else { return 0 }
        return Int(min(max(interval, -3_155_760_000), 3_155_760_000))
    }

    static func duration(_ seconds: Int) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return hours > 0 ? "\(days)日\(hours)時間" : "\(days)日" }
        if hours > 0 { return minutes > 0 ? "\(hours)時間\(minutes)分" : "\(hours)時間" }
        return "\(max(minutes, 1))分"
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "H:mm"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d(E) H:mm"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "E"
        return formatter
    }()

    /// 今日なら時刻だけ、それ以外は日付つきで返す。
    static func moment(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now) ? clockFormatter.string(from: date) : dateTimeFormatter.string(from: date)
    }

    static func weekday(_ date: Date) -> String {
        weekdayFormatter.string(from: date)
    }
}
