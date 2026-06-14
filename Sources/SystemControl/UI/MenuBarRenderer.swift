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

    static func image(temp: String?, watts: String?) -> NSImage {
        let thickness = NSStatusBar.system.thickness
        let H = thickness > 1 ? thickness : 22

        let lines: [NSAttributedString]
        if let temp, let watts {
            // Две строки: градусы сверху, ваты снизу — шрифт под половину высоты
            let size = (H / 2) * 0.80
            lines = [
                line([.symbol("flame.fill"), .text(temp)], size: size),
                line([.symbol("bolt.fill"), .text(watts)], size: size),
            ]
        } else if let temp {
            lines = [line([.symbol("flame.fill"), .text(temp)], size: H * 0.50)]
        } else if let watts {
            lines = [line([.symbol("flame.fill"), .symbol("bolt.fill"), .text(watts)], size: H * 0.50)]
        } else {
            lines = [line([.symbol("flame.fill")], size: H * 0.52)]
        }

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
