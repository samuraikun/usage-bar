import SwiftUI
import UsageCore

/// README の画面に使う架空の値。実際の利用状況とは関係ない。
enum DemoData {
    static func summary(now: Date, calendar: Calendar = .current) -> UsageSummary {
        let today = calendar.startOfDay(for: now)
        func days(_ totals: [Int64], cacheShare: Double) -> [DailyTokens] {
            totals.enumerated().map { index, total in
                let day = calendar.date(byAdding: .day, value: index - (totals.count - 1), to: today) ?? today
                let cache = Int64(Double(total) * cacheShare)
                return DailyTokens(day: day, tokens: TokenCounts(input: (total - cache) * 9 / 10, cacheRead: cache, output: (total - cache) / 10))
            }
        }

        let claude = ProviderSummary(
            provider: .claude,
            rateLimits: RateLimitSnapshot(
                observedAt: now.addingTimeInterval(-40),
                windows: [
                    RateWindow(id: "five_hour", usedPercent: 42, windowMinutes: 300, resetsAt: now.addingTimeInterval(2 * 3600 + 15 * 60)),
                    RateWindow(id: "seven_day", usedPercent: 27, windowMinutes: 10080, resetsAt: now.addingTimeInterval(4 * 86400 + 6 * 3600)),
                ]
            ),
            today: TokenCounts(input: 1_200_000, cacheRead: 48_300_000, cacheWrite: 900_000, output: 286_000),
            rolling5Hours: TokenCounts(input: 800_000, cacheRead: 31_500_000, cacheWrite: 600_000, output: 190_000),
            last7Days: days([62_000_000, 18_000_000, 0, 9_000_000, 74_000_000, 55_000_000, 50_686_000], cacheShare: 0.94),
            todayByModel: [
                ModelTokens(model: "claude-opus-5-5", tokens: TokenCounts(input: 900_000, cacheRead: 36_000_000, output: 210_000)),
                ModelTokens(model: "claude-sonnet-5-5", tokens: TokenCounts(input: 300_000, cacheRead: 12_300_000, output: 76_000)),
            ]
        )

        let codex = ProviderSummary(
            provider: .codex,
            rateLimits: RateLimitSnapshot(
                observedAt: now.addingTimeInterval(-180),
                windows: [
                    RateWindow(id: "primary", usedPercent: 18, windowMinutes: 300, resetsAt: now.addingTimeInterval(3 * 3600 + 40 * 60)),
                    RateWindow(id: "secondary", usedPercent: 63, windowMinutes: 10080, resetsAt: now.addingTimeInterval(2 * 86400 + 9 * 3600)),
                ],
                planType: "plus"
            ),
            today: TokenCounts(input: 640_000, cacheRead: 7_900_000, output: 72_000),
            rolling5Hours: TokenCounts(input: 410_000, cacheRead: 5_200_000, output: 51_000),
            last7Days: days([4_100_000, 11_800_000, 0, 0, 6_300_000, 9_700_000, 8_612_000], cacheShare: 0.9),
            todayByModel: [
                ModelTokens(model: "gpt-6.1", tokens: TokenCounts(input: 640_000, cacheRead: 7_900_000, output: 72_000)),
            ]
        )

        return UsageSummary(claude: claude, codex: codex, generatedAt: now)
    }
}

/// メニューバーと、そこから開いたポップオーバーを並べた README 用の画面。
struct DemoScreen: View {
    @EnvironmentObject private var store: UsageStore
    let scheme: ColorScheme

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 14) {
                Spacer()
                MenuBarLabel(
                    claudePercent: store.menuBarPercent(for: .claude),
                    codexPercent: store.menuBarPercent(for: .codex),
                    showPercent: true,
                    language: store.language
                )
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text(Format.moment(store.now, now: store.now, language: store.language)).font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
            .padding(.horizontal, 12)
            .frame(width: 520, height: 26)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.93))

            PopoverView()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(scheme == .dark ? Color(white: 0.17) : Color(white: 0.98))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                )
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.1)))
                .padding(.trailing, 70)
                .padding(.bottom, 16)
        }
        .background(scheme == .dark ? Color(red: 0.13, green: 0.15, blue: 0.20) : Color(red: 0.86, green: 0.89, blue: 0.94))
        .environment(\.colorScheme, scheme)
    }
}
