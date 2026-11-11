// アプリのアイコン（Resources/AppIcon.icns）を描く。
//
//   swift scripts/make-icon.swift Resources/AppIcon.icns
//
// 2 本のメーター（上が Claude、下が Codex）を、メニューバーの表示と同じ並びで描く。
// 各社のロゴは使わない。外部のツールは使わず、AppKit で描いて iconutil でまとめる。
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("使い方: swift scripts/make-icon.swift <出力先.icns>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// 1024px の正方形に描く。macOS のアイコンの決まりに合わせ、本体は中央の 824px に収めて周りに影の余白を取る。
func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = size / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // 影
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x111827).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 背景
    NSGradient(starting: color(0x2B3445), ending: color(0x0F141C))!.draw(in: shape, angle: -90)
    // 上端のハイライト
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.10), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    color(0xFFFFFF, 0.08).setStroke()
    shape.lineWidth = 4
    shape.stroke()

    // メーター
    let barWidth: CGFloat = 584
    let barHeight: CGFloat = 112
    let barX = body.midX - barWidth / 2
    let gap: CGFloat = 92
    let bars: [(y: CGFloat, fill: CGFloat, top: UInt32, bottom: UInt32)] = [
        (body.midY + gap / 2, 0.72, 0xF0A07A, 0xD9673F),   // Claude（上）
        (body.midY - gap / 2 - barHeight, 0.46, 0x6FA8FF, 0x2F6FE4),  // Codex（下）
    ]
    for bar in bars {
        let track = NSRect(x: barX, y: bar.y, width: barWidth, height: barHeight)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2)
        color(0xFFFFFF, 0.10).setFill()
        trackPath.fill()
        color(0xFFFFFF, 0.14).setStroke()
        trackPath.lineWidth = 3
        trackPath.stroke()

        let fillRect = NSRect(x: barX, y: bar.y, width: max(barHeight, barWidth * bar.fill), height: barHeight)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
        NSGradient(starting: color(bar.top), ending: color(bar.bottom))!.draw(in: fillPath, angle: -90)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("usagebar-icon-\(UUID().uuidString)")
let iconset = workDirectory.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDirectory) }

for base in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let pixels = base * multiplier
        let name = multiplier == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = drawIcon(size: CGFloat(pixels)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: output.deletingPathExtension().appendingPathExtension("png"))

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
print("wrote \(output.path)")
