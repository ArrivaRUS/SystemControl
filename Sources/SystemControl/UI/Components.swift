import SwiftUI

// MARK: - Кнопка-иконка с ховером

struct IconButton: View {
    let systemName: String
    var help: String = ""
    var tint: Color = .secondary
    var size: CGFloat = 11.5
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(hovered ? Color.primary : tint)
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(Color.white.opacity(hovered ? 0.10 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

// MARK: - Пилюля-переключатель (сегменты)

struct PillPicker: View {
    let options: [String]
    @Binding var selection: Int
    var fontSize: CGFloat = 10

    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                Text(options[i])
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(selection == i ? Color.primary : Color.secondary.opacity(0.85))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background {
                        if selection == i {
                            Capsule()
                                .fill(Color.white.opacity(0.13))
                                .matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                            selection = i
                        }
                    }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().stroke(Theme.cardStroke, lineWidth: 1))
    }
}

// MARK: - Кольцевой гейдж (дуга повёрнута, текст накладывается снаружи)

struct GaugeRing: View {
    let progress: Double
    let color: Color
    var lineWidth: CGFloat = 5

    private let span: CGFloat = 0.76

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: span)
                .stroke(Color.white.opacity(0.08),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: span * max(0.015, min(1, progress)))
                .stroke(
                    AngularGradient(
                        colors: [color.opacity(0.45), color],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * span)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .shadow(color: color.opacity(0.5), radius: 4)
        }
        .rotationEffect(.degrees(90 + (1 - span) * 360 / 2))
    }
}

// MARK: - Спарклайн со сглаживанием и градиентной заливкой

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var fixedRange: ClosedRange<Double>? = nil

    var body: some View {
        GeometryReader { geo in
            let points = normalizedPoints(in: geo.size)
            if points.count > 1 {
                ZStack {
                    fillPath(points, size: geo.size)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.28), color.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    linePath(points)
                        .stroke(color.opacity(0.95),
                                style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            } else {
                Capsule()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1.5)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        var lo: Double, hi: Double
        if let r = fixedRange {
            lo = r.lowerBound; hi = r.upperBound
        } else {
            lo = values.min() ?? 0; hi = values.max() ?? 1
            let pad = max(0.6, (hi - lo) * 0.18)
            lo -= pad; hi += pad
        }
        guard hi > lo else { return [] }
        let stepX = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            let f = (v - lo) / (hi - lo)
            return CGPoint(
                x: CGFloat(i) * stepX,
                y: size.height * (1 - CGFloat(max(0, min(1, f))))
            )
        }
    }

    // Плавная кривая через середины отрезков
    private func linePath(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard pts.count > 1 else { return p }
        p.move(to: pts[0])
        for i in 1..<pts.count {
            let prev = pts[i - 1]
            let cur = pts[i]
            let mid = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
            p.addQuadCurve(to: mid, control: prev)
        }
        p.addLine(to: pts[pts.count - 1])
        return p
    }

    private func fillPath(_ pts: [CGPoint], size: CGSize) -> Path {
        var p = linePath(pts)
        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height))
        p.addLine(to: CGPoint(x: pts[0].x, y: size.height))
        p.closeSubpath()
        return p
    }
}
