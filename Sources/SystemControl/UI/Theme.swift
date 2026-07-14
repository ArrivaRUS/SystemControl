import SwiftUI

enum Theme {

    // MARK: - Палитра

    static let bgBase = Color(red: 0.071, green: 0.071, blue: 0.086)
    static let bgGlow = Color(red: 1.0, green: 0.42, blue: 0.16)

    static let amber = Color(red: 1.0, green: 0.72, blue: 0.20)
    static let ember = Color(red: 1.0, green: 0.44, blue: 0.12)
    static let red = Color(red: 1.0, green: 0.25, blue: 0.21)
    static let bordeaux = Color(red: 0.80, green: 0.08, blue: 0.20) // тревожный винно-красный — критически низкий заряд
    static let mint = Color(red: 0.26, green: 0.83, blue: 0.71)
    static let sky = Color(red: 0.36, green: 0.66, blue: 1.0)
    static let violet = Color(red: 0.69, green: 0.51, blue: 1.0)

    static let cardFill = Color.white.opacity(0.040)
    static let cardStroke = Color.white.opacity(0.065)
    static let hairline = Color.white.opacity(0.07)

    static let flameGradient = LinearGradient(
        colors: [amber, ember, red],
        startPoint: .leading, endPoint: .trailing
    )
    static let flameGradientV = LinearGradient(
        colors: [amber, ember, red],
        startPoint: .top, endPoint: .bottom
    )
    // MARK: - Цвет по температуре (плавная интерполяция между стопами)

    private static let tempStops: [(t: Double, c: (Double, Double, Double))] = [
        (40, (0.26, 0.83, 0.71)),  // прохладно — мята
        (58, (1.00, 0.80, 0.25)),  // тепло — янтарь
        (74, (1.00, 0.55, 0.15)),  // горячо — оранжевый
        (90, (1.00, 0.27, 0.21)),  // очень горячо — красный
        (105, (0.96, 0.12, 0.34)), // критично — малиновый
    ]

    static func tempColor(_ t: Double) -> Color {
        let stops = tempStops
        if t <= stops[0].t { return rgb(stops[0].c) }
        for i in 1..<stops.count where t <= stops[i].t {
            let a = stops[i - 1], b = stops[i]
            let f = (t - a.t) / (b.t - a.t)
            return rgb((
                a.c.0 + (b.c.0 - a.c.0) * f,
                a.c.1 + (b.c.1 - a.c.1) * f,
                a.c.2 + (b.c.2 - a.c.2) * f
            ))
        }
        return rgb(stops[stops.count - 1].c)
    }

    private static func rgb(_ c: (Double, Double, Double)) -> Color {
        Color(red: c.0, green: c.1, blue: c.2)
    }

    // MARK: - Фон панели

    @ViewBuilder
    static var panelBackground: some View {
        ZStack {
            bgBase
            // Тёплое свечение сверху — фирменная "жаровая" атмосфера
            RadialGradient(
                colors: [bgGlow.opacity(0.16), .clear],
                center: .init(x: 0.18, y: -0.08),
                startRadius: 8, endRadius: 360
            )
            RadialGradient(
                colors: [Color(red: 0.42, green: 0.20, blue: 0.85).opacity(0.10), .clear],
                center: .init(x: 1.05, y: 0.05),
                startRadius: 8, endRadius: 320
            )
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.25)],
                startPoint: .center, endPoint: .bottom
            )
        }
    }
}

// Метка температуры: "64°" или "—"
func tempLabel(_ t: Double?) -> String {
    guard let t else { return "—" }
    return "\(Int(t.rounded()))°"
}
