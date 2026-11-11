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

        let store = UsageStore(fixedSummary: summary, now: summary.generatedAt)
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
            showPercent: true
        )
        .padding(4)
        .background(Color(white: 0.9))
        write(label, to: "\(directory)/menubar.png")
        exit(0)
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
