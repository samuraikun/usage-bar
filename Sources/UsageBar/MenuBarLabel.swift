import AppKit
import SwiftUI
import UsageCore

/// メニューバーに出すアイコンと数値。
/// アイコンは 2 本のメーターで、上が Claude、下が Codex の使用率（それぞれ最も上限に近い枠）。
struct MenuBarLabel: View {
    let claudePercent: Double?
    let codexPercent: Double?
    let showPercent: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MeterIcon.image(top: claudePercent, bottom: codexPercent))
            if showPercent {
                Text("Cl \(text(claudePercent))  Cx \(text(codexPercent))")
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Claude \(text(claudePercent))、Codex \(text(codexPercent))")
    }

    private func text(_ percent: Double?) -> String {
        percent.map(Format.percent) ?? "–"
    }
}

enum MeterIcon {
    static func image(top: Double?, bottom: Double?) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let barHeight: CGFloat = 5
            let gap: CGFloat = 3
            let originY = (rect.height - barHeight * 2 - gap) / 2
            drawBar(percent: top, in: NSRect(x: 0.5, y: originY + barHeight + gap, width: rect.width - 1, height: barHeight))
            drawBar(percent: bottom, in: NSRect(x: 0.5, y: originY, width: rect.width - 1, height: barHeight))
            return true
        }
        // テンプレート画像にして、ライト／ダークどちらのメニューバーでも見えるようにする。
        image.isTemplate = true
        return image
    }

    private static func drawBar(percent: Double?, in rect: NSRect) {
        let radius = rect.height / 2
        let track = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(0.35).setStroke()
        track.lineWidth = 1
        track.stroke()

        guard let percent else { return }
        let fraction = min(max(percent / 100, 0), 1)
        guard fraction > 0 else { return }
        let width = max(rect.height, rect.width * fraction)
        let fill = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height), xRadius: radius, yRadius: radius)
        NSColor.black.setFill()
        fill.fill()
    }
}
