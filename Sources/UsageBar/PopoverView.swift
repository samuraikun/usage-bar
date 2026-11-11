import AppKit
import Charts
import SwiftUI
import UsageCore

struct PopoverView: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        content
            .environment(\.appLanguage, store.language)
            .environment(\.locale, store.language.locale)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary = store.summary {
                ProviderSection(summary: summary.claude, now: store.now)
                Divider()
                ProviderSection(summary: summary.codex, now: store.now)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Strings(language: store.language).loading).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            }
            Divider()
            SettingsSection()
        }
        .padding(14)
        .frame(width: 380)
    }
}

// MARK: - プロバイダごとの表示

private struct ProviderSection: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.appLanguage) private var language
    let summary: ProviderSummary
    let now: Date

    private var s: Strings { Strings(language: language) }

    /// この時間より古い値は「最後に取得した値」と明示する。
    private static let staleAfter: TimeInterval = 30 * 60

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let limits = summary.rateLimits, !limits.windows.isEmpty {
                ForEach(limits.windows) { window in
                    RateWindowRow(window: window, now: now)
                }
                if now.timeIntervalSince(limits.observedAt) > Self.staleAfter {
                    Text(s.stale(Format.ago(limits.observedAt, now: now, language: language), provider: summary.provider.displayName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                missingLimits
            }
            TokenSummaryView(summary: summary)
            // 中継コマンドの案内は、値が届いていないときに上で詳しく出しているので重ねない。
            ForEach(summary.notes.filter { $0 != .claudeBridgeNotConfigured }, id: \.self) { note in
                Text(s.note(note)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(summary.provider.displayName).font(.headline)
            if let plan = summary.rateLimits?.planType, !plan.isEmpty {
                Text(plan)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
            if let observed = summary.rateLimits?.observedAt {
                Text(s.observed(Format.ago(observed, now: now, language: language)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var missingLimits: some View {
        switch summary.provider {
        case .claude:
            VStack(alignment: .leading, spacing: 6) {
                Text(s.claudeSetupIntro)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                let command = "\(StatusLineCommand.quoted(store.claudeBridgeExecutablePath)) install"
                HStack(alignment: .top, spacing: 6) {
                    Text(command)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help(s.copyCommand)
                }
                Text(s.claudeSetupAfter)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .codex:
            Text(s.codexMissing)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RateWindowRow: View {
    @Environment(\.appLanguage) private var language
    let window: RateWindow
    let now: Date

    var body: some View {
        let expired = window.isExpired(at: now)
        let percent = window.currentPercent(at: now)
        let s = Strings(language: language)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label(in: language)).font(.subheadline)
                Spacer()
                Text(Format.percent(percent))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(UsageColor.forPercent(percent))
            }
            UsageBarView(fraction: percent / 100)
            if let resetsAt = window.resetsAt {
                Text(expired
                     ? s.resetPassed
                     : s.resets(Format.remaining(until: resetsAt, now: now, language: language),
                                at: Format.moment(resetsAt, now: now, language: language)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct UsageBarView: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(UsageColor.forPercent(fraction * 100))
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
        .frame(height: 6)
    }
}

private enum UsageColor {
    static func forPercent(_ percent: Double) -> Color {
        switch percent {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }
}

// MARK: - トークン数

private struct TokenSummaryView: View {
    @Environment(\.appLanguage) private var language
    let summary: ProviderSummary

    private var s: Strings { Strings(language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    header(s.total)
                    header(s.input)
                    header(s.output)
                    header(s.cacheRead)
                }
                tokenRow(s.today, summary.today)
                tokenRow(s.last5Hours, summary.rolling5Hours)
            }
            .font(.caption.monospacedDigit())

            if summary.last7Days.contains(where: { $0.tokens.total > 0 }) {
                Chart(summary.last7Days) { day in
                    BarMark(
                        x: .value(s.chartDay, day.day, unit: .day),
                        y: .value(s.chartTokens, day.tokens.total)
                    )
                    .foregroundStyle(summary.provider == .claude ? Color.orange.gradient : Color.blue.gradient)
                    .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) { Text(Format.weekday(date, language: language)) }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let tokens = value.as(Int64.self) { Text(Format.tokens(tokens)) }
                        }
                    }
                }
                .frame(height: 64)
                .accessibilityLabel(s.chartAccessibility)
            }

            if !summary.todayByModel.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(summary.todayByModel.prefix(3)) { model in
                        HStack {
                            Text(model.model).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Format.tokens(model.tokens.total)).monospacedDigit()
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func tokenRow(_ label: String, _ tokens: TokenCounts) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(Format.tokens(tokens.total)).fontWeight(.semibold)
            Text(Format.tokens(tokens.input + tokens.cacheWrite))
            Text(Format.tokens(tokens.output))
            Text(Format.tokens(tokens.cacheRead))
        }
    }
}

// MARK: - 設定

private struct SettingsSection: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.appLanguage) private var language

    var body: some View {
        let s = Strings(language: language)
        VStack(alignment: .leading, spacing: 6) {
            Label(s.noNetwork, systemImage: "lock.shield")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(s.showPercent, isOn: $store.showPercentInMenuBar)
            Toggle(s.launchAtLogin, isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))
            if let error = store.launchAtLoginError {
                Text(s.launchAtLoginFailed(error)).font(.caption2).foregroundStyle(.red)
            }
            Picker(s.languageLabel, selection: $store.languagePreference) {
                ForEach(LanguagePreference.allCases) { preference in
                    Text(s.languageOption(preference)).tag(preference)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            HStack {
                Button(s.reload) { store.refreshNow() }
                Spacer()
                Button(s.quit) { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .toggleStyle(.checkbox)
        .font(.callout)
    }
}
