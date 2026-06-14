import AppKit

// Рендер лейбла menu bar в NSImage точно по высоте строки меню.
// SwiftUI-текст (тем более многострочный) в MenuBarExtra не масштабируется
// под толщину бара и обрезается; NSImage нужной высоты решает это — мы сами
// раскладываем одну или две строки внутри известной высоты.
//
// Energy-режим — template (монохром, тинтуется системой под тему бара).
// Battery-режим — цветной (non-template): батарейка зелёная/жёлтая/красная,
// молния жёлтая; текст в адаптивном labelColor, чтобы читался на любой теме.
enum MenuBarRenderer {

    private enum Seg {
        // colors: [] → монохром (template); [c] → единый цвет;
        // [контур, заливка] → двухслойная палитра (напр. белый ободок + цветной бар)
        case symbol(String, [NSColor])
        case text(String, NSColor?)
    }

    private static var barHeight: CGFloat {
        let t = NSStatusBar.system.thickness
        return t > 1 ? t : 22
    }

    // MARK: - Energy: температура CPU и (на питании) ваты от адаптера

    static func image(temp: String?, watts: String?) -> NSImage {
        let H = barHeight
        let lines: [NSAttributedString]
        if let temp, let watts {
            let size = (H / 2) * 0.80
            lines = [
                line([.symbol("flame.fill", []), .text(temp, nil)], size: size),
                line([.symbol("bolt.fill", []), .text(watts, nil)], size: size),
            ]
        } else if let temp {
            lines = [line([.symbol("flame.fill", []), .text(temp, nil)], size: H * 0.66)]
        } else if let watts {
            lines = [line([.symbol("flame.fill", []), .symbol("bolt.fill", []), .text(watts, nil)], size: H * 0.64)]
        } else {
            lines = [line([.symbol("flame.fill", [])], size: H * 0.64)]
        }
        return layout(lines, centered: false, template: true)
    }

    // MARK: - Battery: процент сверху, время снизу

    static func batteryImage(_ b: MenuBatterySummary) -> NSImage {
        let H = barHeight
        // На пункт крупнее energy-режима + увеличенные иконки
        let size = (H / 2) * 0.84

        // Батарейка: палитра символа — [заливка, контур] (проверено: palette[0]
        // красит бар внутри, palette[1] — корпус). Контур — адаптивный
        // labelColor (белый на тёмном баре), цветной только бар-заливка.
        let fill = batteryColor(percent: b.percent)
        let top = line([.symbol(batteryGlyph(percent: b.percent), [fill, .labelColor]),
                        .text("\(b.percent)%", .labelColor)],
                       size: size, symbolScale: 1.12)

        let bottomText: String
        if b.plugged {
            bottomText = b.fullyCharged ? "Full" : (b.timeMinutes.map(hhmm) ?? "—")
        } else {
            bottomText = b.timeMinutes.map(hhmm) ?? "—"
        }
        let bottomGlyph = b.plugged ? "bolt.fill" : "hourglass"
        let glyphColor: NSColor = b.plugged
            ? (b.fullyCharged ? .systemGreen : .systemYellow)   // молния жёлтая, на полном — зелёная
            : (b.percent < 20 ? .systemRed : .secondaryLabelColor)
        let bottom = line([.symbol(bottomGlyph, [glyphColor]), .text(bottomText, .labelColor)],
                          size: size, symbolScale: 1.12)

        return layout([top, bottom], centered: true, template: false)
    }

    // MARK: - Раскладка строк в NSImage точно по высоте бара

    private static func layout(_ lines: [NSAttributedString], centered: Bool, template: Bool) -> NSImage {
        let H = barHeight
        let sizes = lines.map { $0.size() }
        let width = ceil((sizes.map(\.width).max() ?? 8)) + 2

        let image = NSImage(size: NSSize(width: width, height: H), flipped: false) { _ in
            if lines.count == 2 {
                let band = H / 2
                for (i, ln) in lines.enumerated() {
                    let s = sizes[i]
                    let bandY = (i == 0) ? band : 0           // строка 0 — верхняя
                    let x = centered ? (width - s.width) / 2 : (width - s.width)
                    let y = bandY + (band - s.height) / 2
                    ln.draw(at: NSPoint(x: x, y: y))
                }
            } else {
                let s = sizes[0]
                lines[0].draw(at: NSPoint(x: (width - s.width) / 2, y: (H - s.height) / 2))
            }
            return true
        }
        image.isTemplate = template
        return image
    }

    private static func hhmm(_ minutes: Int) -> String {
        "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }

    private static func batteryGlyph(percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    // Цвет заливки — по СТЕПЕНИ заряда, не по процессу зарядки
    private static func batteryColor(percent: Int) -> NSColor {
        switch percent {
        case ..<20: return .systemRed        // низкий заряд
        case ..<50: return .systemYellow     // средний
        default: return .systemGreen         // высокий
        }
    }

    // MARK: -

    private static func roundedFont(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        if let desc = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: desc, size: size) ?? base
        }
        return base
    }

    private static func line(_ segs: [Seg], size: CGFloat, symbolScale: CGFloat = 0.95) -> NSAttributedString {
        let font = roundedFont(size)
        let out = NSMutableAttributedString()
        for seg in segs {
            switch seg {
            case .text(let t, let color):
                out.append(NSAttributedString(string: t, attributes: [
                    .font: font,
                    .foregroundColor: color ?? NSColor.black,
                ]))
            case .symbol(let name, let colors):
                var cfg = NSImage.SymbolConfiguration(pointSize: size * symbolScale, weight: .semibold)
                if !colors.isEmpty {
                    cfg = cfg.applying(.init(paletteColors: colors))
                }
                guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(cfg) else { continue }
                let att = NSTextAttachment()
                att.image = img
                let h = img.size.height
                att.bounds = CGRect(x: 0, y: (font.capHeight - h) / 2,
                                    width: img.size.width, height: h)
                out.append(NSAttributedString(attachment: att))
                out.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
        }
        return out
    }
}
