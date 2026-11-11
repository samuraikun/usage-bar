import AppKit
import SwiftUI
import UsageCore

/// 開発時の見た目の確認用。実際のログを集計し、ポップオーバーとメニューバーの表示を PNG に書き出す。
/// App Sandbox の中では書き出し先に書けないため、署名前の `swift run` で使う。
@MainActor
enum PreviewRenderer {
    static func renderAndExit(to directory: String) -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        var result: UsageSummary?
        Task.detached {
            let engine = UsageEngine()
            await engine.scanAll()
            result = await engine.summary()
            semaphore.signal()
        }
        semaphore.wait()
        guard let summary = result else { exit(1) }

        let store = UsageStore(fixedSummary: summary, now: summary.generatedAt, language: .fromSystem())
        for scheme in [ColorScheme.light, .dark] {
            let popover = PopoverView()
                .environmentObject(store)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
                .environment(\.colorScheme, scheme)
            write(popover, to: "\(directory)/popover-\(scheme == .dark ? "dark" : "light").png")
        }
        let label = MenuBarLabel(
            claudePercent: store.menuBarPercent(for: .claude),
            codexPercent: store.menuBarPercent(for: .codex),
            showPercent: true,
            language: store.language
        )
        .padding(4)
        .background(Color(white: 0.9))
        write(label, to: "\(directory)/menubar.png")
        exit(0)
    }

    /// README 用の画面。値はすべて架空のもので、手元のログは読まない。
    /// ボタンやチェックボックスも描けるよう、ImageRenderer ではなく実際のウインドウと同じ NSHostingView で描く。
    static func renderDemoAndExit(to directory: String) -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        // 表示が毎回同じになるよう、基準の時刻を固定する。
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 10, minute: 24)) ?? Date()
        for language in AppLanguage.allCases {
            let store = UsageStore(fixedSummary: DemoData.summary(now: now), now: now, language: language)
            for (scheme, name) in [(ColorScheme.dark, "dark"), (.light, "light")] {
                let screen = DemoScreen(scheme: scheme).environmentObject(store)
                snapshot(screen, dark: scheme == .dark, to: "\(directory)/screenshot-\(language.rawValue)-\(name).png")
            }
        }
        exit(0)
    }

    private static func snapshot<V: View>(_ view: V, dark: Bool, to path: String) {
        let hosting = NSHostingView(rootView: view)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }

    private static func write<V: View>(_ view: V, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed: \(path)\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
