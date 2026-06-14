import AppKit

// Рендер лейбла menu bar в NSImage точно по высоте строки меню.
// SwiftUI-текст (тем более многострочный) в MenuBarExtra не масштабируется
// под толщину бара и обрезается; NSImage нужной высоты решает это — мы сами
// раскладываем одну или две строки внутри известной высоты.
enum MenuBarRenderer {

    private enum Seg {
        case symbol(String)
        case text(String)
    }

    private static var barHeight: CGFloat {
        let t = NSStatusBar.system.thickness
        return t > 1 ? t : 22
    }

    // Вкладка Energy: температура CPU и (на питании) ваты от адаптера.
    static func image(temp: String?, watts: String?) -> NSImage {
        let H = barHeight
        let lines: [NSAttributedString]
        if let temp, let watts {
            // Две строки: градусы сверху, ваты снизу — шрифт под половину высоты
            let size = (H / 2) * 0.80
            lines = [
                line([.symbol("flame.fill"), .text(temp)], size: size),
                line([.symbol("bolt.fill"), .text(watts)], size: size),
            ]
        } else if let temp {
            // Одна строка — высота свободна, делаем заметно крупнее
            lines = [line([.symbol("flame.fill"), .text(temp)], size: H * 0.66)]
        } else if let watts {
            lines = [line([.symbol("flame.fill"), .symbol("bolt.fill"), .text(watts)], size: H * 0.64)]
        } else {
            lines = [line([.symbol("flame.fill")], size: H * 0.64)]
        }
        return layout(lines)
    }

    // Вкладка Battery: процент сверху, время снизу (до полного на питании /
    // до разряда на батарее).
    static func batteryImage(_ b: MenuBatterySummary) -> NSImage {
        let H = barHeight
        let size = (H / 2) * 0.80

        let topGlyph = batteryGlyph(percent: b.percent)
        let top = line([.symbol(topGlyph), .text("\(b.percent)%")], size: size)

        let bottomText: String
        if b.plugged {
            bottomText = b.fullyCharged ? "Full" : (b.timeMinutes.map(hhmm) ?? "—")
        } else {
            bottomText = b.timeMinutes.map(hhmm) ?? "—"
        }
        let bottomGlyph = b.plugged ? "bolt.fill" : "hourglass"
        let bottom = line([.symbol(bottomGlyph), .text(bottomText)], size: size)

        return layout([top, bottom])
    }

    // MARK: - Раскладка строк в NSImage точно по высоте бара

    private static func layout(_ lines: [NSAttributedString]) -> NSImage {
        let H = barHeight
        let sizes = lines.map { $0.size() }
        let width = ceil((sizes.map(\.width).max() ?? 8)) + 2

        let image = NSImage(size: NSSize(width: width, height: H), flipped: false) { _ in
            if lines.count == 2 {
                let band = H / 2
                for (i, ln) in lines.enumerated() {
                    let s = sizes[i]
                    let bandY = (i == 0) ? band : 0           // строка 0 — верхняя
                    let x = width - s.width                   // выравнивание по правому краю
                    let y = bandY + (band - s.height) / 2
                    ln.draw(at: NSPoint(x: x, y: y))
                }
            } else {
                let s = sizes[0]
                lines[0].draw(at: NSPoint(x: (width - s.width) / 2, y: (H - s.height) / 2))
            }
            return true
        }
        image.isTemplate = true // тинтуется под светлый/тёмный menu bar
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

    // MARK: -

    private static func roundedFont(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        if let desc = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: desc, size: size) ?? base
        }
        return base
    }

    private static func line(_ segs: [Seg], size: CGFloat) -> NSAttributedString {
        let font = roundedFont(size)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black, // для template важна только альфа
        ]
        let out = NSMutableAttributedString()
        for seg in segs {
            switch seg {
            case .text(let t):
                out.append(NSAttributedString(string: t, attributes: attrs))
            case .symbol(let name):
                let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.95, weight: .semibold)
                guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(cfg) else { continue }
                let att = NSTextAttachment()
                att.image = img
                let h = img.size.height
                // центрируем символ по высоте прописных
                att.bounds = CGRect(x: 0, y: (font.capHeight - h) / 2,
                                    width: img.size.width, height: h)
                out.append(NSAttributedString(attachment: att))
                out.append(NSAttributedString(string: " ", attributes: attrs))
            }
        }
        return out
    }
}
