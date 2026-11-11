import Foundation
import SwiftUI
import UsageCore

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--print-summary") {
            DiagnosticSummary.printAndExit()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
           CommandLine.arguments.indices.contains(index + 1) {
            MainActor.assumeIsolated {
                PreviewRenderer.renderAndExit(to: CommandLine.arguments[index + 1])
            }
        }
        UsageBarApp.main()
    }
}

struct UsageBarApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(store)
        } label: {
            MenuBarLabel(
                claudePercent: store.menuBarPercent(for: .claude),
                codexPercent: store.menuBarPercent(for: .codex),
                showPercent: store.showPercentInMenuBar
            )
        }
        .menuBarExtraStyle(.window)
    }
}

/// 画面を出さずに集計結果を標準出力へ書く。サンドボックスの中で読めているかの確認に使う。
enum DiagnosticSummary {
    static func printAndExit() -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        let started = Date()
        Task.detached {
            let engine = UsageEngine()
            await engine.scanAll()
            let summary = await engine.summary()
            let elapsed = Date().timeIntervalSince(started)
            for provider in [summary.claude, summary.codex] {
                print("[\(provider.provider.displayName)] files=\(provider.trackedFiles)")
                if let limits = provider.rateLimits {
                    print("  rate limits observed \(Format.ago(limits.observedAt, now: summary.generatedAt)) plan=\(limits.planType ?? "-")")
                    for window in limits.windows {
                        let reset = window.resetsAt.map { Format.remaining(until: $0, now: summary.generatedAt) } ?? "-"
                        print("  \(window.label): \(Format.percent(window.currentPercent(at: summary.generatedAt))) (\(reset))")
                    }
                } else {
                    print("  rate limits: なし")
                }
                print("  today total=\(Format.tokens(provider.today.total)) in=\(Format.tokens(provider.today.input)) out=\(Format.tokens(provider.today.output)) cacheRead=\(Format.tokens(provider.today.cacheRead)) cacheWrite=\(Format.tokens(provider.today.cacheWrite))")
                print("  last5h total=\(Format.tokens(provider.rolling5Hours.total))")
                print("  7days=" + provider.last7Days.map { Format.tokens($0.tokens.total) }.joined(separator: ","))
                for model in provider.todayByModel.prefix(3) {
                    print("  model \(model.model): \(Format.tokens(model.tokens.total))")
                }
                for note in provider.notes { print("  note: \(note)") }
            }
            print(String(format: "scan took %.2fs", elapsed))
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }
}
