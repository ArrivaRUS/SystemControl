// Баннер социального превью GitHub (1280×640): иконка приложения слева,
// название и тэглайн справа, тёмный фон в стиле утилиты.
// Использование: swift scripts/make_social.swift
import AppKit

let W = 1280.0, H = 640.0
let iconPath = "assets/icon.png"
let outPath = "assets/social-preview.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let full = NSRect(x: 0, y: 0, width: W, height: H)

// Фон — тёмный градиент
NSGradient(
    starting: NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.14, alpha: 1),
    ending: NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)
)?.draw(in: full, angle: -90)

// Тёплое свечение слева
let glow = [
    NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.16, alpha: 0.20).cgColor,
    NSColor.clear.cgColor,
] as CFArray
if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glow, locations: [0, 1]) {
    ctx.drawRadialGradient(
        g, startCenter: CGPoint(x: 330, y: H / 2), startRadius: 0,
        endCenter: CGPoint(x: 330, y: H / 2), endRadius: 520, options: []
    )
}

// Иконка приложения
let iconSize = 300.0
if let icon = NSImage(contentsOfFile: iconPath) {
    icon.draw(in: NSRect(x: 150, y: (H - iconSize) / 2, width: iconSize, height: iconSize))
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at p: NSPoint) {
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if let d = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: d, size: size) ?? font }
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        .draw(at: p)
}

let textX = 540.0
text("System Control", size: 86, weight: .bold,
     color: NSColor.white.withAlphaComponent(0.96), at: NSPoint(x: textX, y: 372))
text("Energy · Temperatures · Battery", size: 36, weight: .medium,
     color: NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.26, alpha: 1), at: NSPoint(x: textX + 2, y: 312))
text("macOS menu bar utility · native SwiftUI · no root", size: 27, weight: .regular,
     color: NSColor.white.withAlphaComponent(0.45), at: NSPoint(x: textX + 2, y: 262))

NSGraphicsContext.restoreGraphicsState()
if let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: outPath))
    print("social preview written to \(outPath)")
}
