import Foundation

/// 使用イベントを、今日・直近 5 時間・過去 7 日・モデル別に集計する。
public enum UsageAggregator {
    public struct Result: Equatable {
        public var today: TokenCounts
        public var rolling5Hours: TokenCounts
        public var last7Days: [DailyTokens]
        public var todayByModel: [ModelTokens]
        public var lastActivity: Date?
    }

    public static func summarize<S: Sequence>(_ events: S, now: Date, calendar: Calendar) -> Result where S.Element == UsageEvent {
        let startOfToday = calendar.startOfDay(for: now)
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        // 日付を足し引きした結果をもう一度 startOfDay に通す。夏時間の切り替えで 0 時が無い日でも、
        // 各イベントを振り分けるときと同じ区切りになる。
        let days: [Date] = (0..<7).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: startOfToday).map { calendar.startOfDay(for: $0) }
        }
        let firstDay = days.first ?? startOfToday

        var today = TokenCounts.zero
        var rolling = TokenCounts.zero
        var perDay: [Date: TokenCounts] = [:]
        var perModel: [String: TokenCounts] = [:]
        var lastActivity: Date?

        for event in events {
            if event.timestamp > now.addingTimeInterval(300) { continue }
            if lastActivity == nil || event.timestamp > lastActivity! { lastActivity = event.timestamp }
            if event.timestamp >= fiveHoursAgo { rolling += event.tokens }
            guard event.timestamp >= firstDay else { continue }
            let day = calendar.startOfDay(for: event.timestamp)
            perDay[day, default: .zero] += event.tokens
            if day == startOfToday {
                today += event.tokens
                perModel[event.model, default: .zero] += event.tokens
            }
        }

        return Result(
            today: today,
            rolling5Hours: rolling,
            last7Days: days.map { DailyTokens(day: $0, tokens: perDay[$0] ?? .zero) },
            todayByModel: perModel
                .map { ModelTokens(model: $0.key, tokens: $0.value) }
                .sorted { $0.tokens.total > $1.tokens.total },
            lastActivity: lastActivity
        )
    }
}
