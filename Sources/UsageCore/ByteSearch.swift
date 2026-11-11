import Foundation

extension Data {
    /// JSON として読む前に、目的の行かどうかをバイト列のまま判定する。
    /// ログの大半は会話本文なので、ここで振り落とすと初回の読み込みが速くなる。
    func containsBytes(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        return withUnsafeBytes { haystack in
            needle.withUnsafeBytes { n in
                memmem(haystack.baseAddress, haystack.count, n.baseAddress, n.count) != nil
            }
        }
    }
}

/// ログやファイルから読んだ時刻の妥当な範囲。範囲外の値は表示の計算で整数に直すときにあふれるため、読む時点で捨てる。
public enum EpochRange {
    /// 2000-01-01
    public static let min: Double = 946_684_800
    /// 2200-01-01
    public static let max: Double = 7_258_118_400
    /// 「何秒後にリセット」として受け付ける最大値（約 3 年）。
    public static let maxInterval: Double = 100_000_000

    public static func isPlausible(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds >= min && seconds <= max
    }
}

/// ログのタイムスタンプ（例: `2026-11-11T07:02:10.723Z`）を読む。
/// 初回読み込みで数万回呼ぶため、Formatter を使わずに数字を直接読む。
/// UTC の `Z` 以外の形式は Foundation の ISO8601 パーサーに任せる。
public enum LogTimestamp {
    public static func parse(_ text: String) -> Date? {
        var utf8 = Array(text.utf8)
        if let date = parseUTC(&utf8) { return date }
        // UTC の形をしていて読めなかったもの（2/31 など）は、寛容な Foundation のパーサーに回さない。
        if utf8.last == UInt8(ascii: "Z") { return nil }
        guard utf8.count >= 10, isExistingDate(utf8) else { return nil }
        return fallback(text)
    }

    /// 先頭の YYYY-MM-DD が実在する日付か。
    private static func isExistingDate(_ s: [UInt8]) -> Bool {
        func number(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for i in start..<(start + length) {
                let c = s[i]
                guard c >= 48, c <= 57 else { return nil }
                value = value * 10 + Int(c - 48)
            }
            return value
        }
        guard s[4] == UInt8(ascii: "-"), s[7] == UInt8(ascii: "-"),
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              (1...12).contains(month), day >= 1 else { return false }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= lengths[month - 1]
    }

    private static func parseUTC(_ s: inout [UInt8]) -> Date? {
        // YYYY-MM-DDTHH:MM:SS[.fraction]Z
        guard s.count >= 20, s.last == UInt8(ascii: "Z"),
              s[4] == UInt8(ascii: "-"), s[7] == UInt8(ascii: "-"),
              s[10] == UInt8(ascii: "T") || s[10] == UInt8(ascii: " "),
              s[13] == UInt8(ascii: ":"), s[16] == UInt8(ascii: ":") else { return nil }
        func number(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for i in start..<(start + length) {
                let c = s[i]
                guard c >= 48, c <= 57 else { return nil }
                value = value * 10 + Int(c - 48)
            }
            return value
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second < 61 else { return nil }

        var fraction = 0.0
        let end = s.count - 1
        if end > 19 {
            guard s[19] == UInt8(ascii: "."), end > 20 else { return nil }
            var scale = 0.1
            for i in 20..<end {
                let c = s[i]
                guard c >= 48, c <= 57 else { return nil }
                fraction += Double(c - 48) * scale
                scale /= 10
            }
        }

        var t = tm()
        t.tm_year = Int32(year - 1900)
        t.tm_mon = Int32(month - 1)
        t.tm_mday = Int32(day)
        t.tm_hour = Int32(hour)
        t.tm_min = Int32(minute)
        t.tm_sec = Int32(second)
        let seconds = timegm(&t)
        // timegm は 2/31 を 3/3 に繰り上げる。繰り上がったら存在しない日付として捨てる。
        guard seconds != -1, t.tm_mday == Int32(day), t.tm_mon == Int32(month - 1),
              EpochRange.isPlausible(Double(seconds)) else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    private static func fallback(_ text: String) -> Date? {
        guard text.utf8.count <= 64 else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = withFraction.date(from: text) ?? plain.date(from: text),
              EpochRange.isPlausible(date.timeIntervalSince1970) else { return nil }
        return date
    }
}
