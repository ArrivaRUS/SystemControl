// Фон для окна DMG-инсталлятора: тёмная тема утилиты, стрелка
// "перетащи в Applications". Использование: swift scripts/make_dmg_background.swift <outdir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let size = NSSize(width: 660, height: 400)

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let px = NSSize(width: size.width * scale, height: size.height * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = size // логический размер → корректный dpi для retina

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

    let rect = NSRect(origin: .zero, size: size)

    // Тёмный фон с лёгким вертикальным градиентом
    NSGradient(
        starting: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.125, alpha: 1),
        ending: NSColor(calibratedRed: 0.055, green: 0.055, blue: 0.07, alpha: 1)
    )?.draw(in: rect, angle: -90)

    // Тёплое свечение сверху слева — фирменная атмосфера
    let glow = [
        NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.16, alpha: 0.18).cgColor,
        NSColor.clear.cgColor,
    ] as CFArray
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glow, locations: [0, 1]) {
        ctx.drawRadialGradient(
            g,
            startCenter: CGPoint(x: 120, y: size.height - 20), startRadius: 0,
            endCenter: CGPoint(x: 120, y: size.height - 20), endRadius: 320,
            options: []
        )
    }

    // Логотип: сквиркл с пламенем + название
    let logoRect = NSRect(x: 26, y: size.height - 64, width: 38, height: 38)
    let logoPath = NSBezierPath(roundedRect: logoRect, xRadius: 9.5, yRadius: 9.5)
    NSGradient(
        starting: NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.20, alpha: 1),
        ending: NSColor(calibratedRed: 1.0, green: 0.25, blue: 0.21, alpha: 1)
    )?.draw(in: logoPath, angle: -90)
    let flameConfig = NSImage.SymbolConfiguration(pointSize: 19, weight: .bold)
    if let flame = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(flameConfig) {
        let tinted = NSImage(size: flame.size, flipped: false) { r in
            NSColor.white.set()
            r.fill(using: .sourceOver)
            flame.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        tinted.draw(in: NSRect(
            x: logoRect.midX - flame.size.width / 2,
            y: logoRect.midY - flame.size.height / 2,
            width: flame.size.width, height: flame.size.height
        ))
    }

    func text(_ s: String, size fs: CGFloat, weight: NSFont.Weight,
              color: NSColor, at point: NSPoint, centered: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fs, weight: weight),
            .foregroundColor: color,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        var p = point
        if centered {
            p.x -= str.size().width / 2
        }
        str.draw(at: p)
    }

    text("System Control", size: 19, weight: .semibold,
         color: NSColor.white.withAlphaComponent(0.92),
         at: NSPoint(x: 76, y: size.height - 53))
    text("Energy · Temperatures · Battery", size: 10.5, weight: .medium,
         color: NSColor.white.withAlphaComponent(0.38),
         at: NSPoint(x: 77, y: size.height - 71))

    // Стрелка между местами иконок (165, 195) → (495, 195) в координатах Finder
    // (origin сверху); в нашей системе y снизу: иконки по центру ~ y=205
    let arrowY: CGFloat = 205
    let arrowColor = NSColor.white.withAlphaComponent(0.22)
    arrowColor.setStroke()
    let line = NSBezierPath()
    line.lineWidth = 5
    line.lineCapStyle = .round
    line.move(to: NSPoint(x: 262, y: arrowY))
    line.line(to: NSPoint(x: 380, y: arrowY))
    line.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 372, y: arrowY + 16))
    head.line(to: NSPoint(x: 398, y: arrowY))
    head.line(to: NSPoint(x: 372, y: arrowY - 16))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // Подпись снизу
    text("Drag System Control to the Applications folder to install",
         size: 12, weight: .medium,
         color: NSColor.white.withAlphaComponent(0.45),
         at: NSPoint(x: size.width / 2, y: 38), centered: true)
    text("First launch: right-click → Open (app is not notarized)",
         size: 10, weight: .regular,
         color: NSColor.white.withAlphaComponent(0.28),
         at: NSPoint(x: size.width / 2, y: 20), centered: true)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (scale, name) in [(CGFloat(1), "dmg-bg.png"), (CGFloat(2), "dmg-bg@2x.png")] {
    let rep = draw(scale: scale)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    }
}
print("dmg background written to \(outDir)")
