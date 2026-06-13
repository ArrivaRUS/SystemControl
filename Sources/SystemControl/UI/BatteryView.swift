import SwiftUI

// Вкладка батареи: здоровье и использование в духе coconutBattery.
struct BatteryView: View {
    @EnvironmentObject var state: AppState

    private static let snapshotMode = ProcessInfo.processInfo.arguments.contains("--snapshot")

    var body: some View {
        Group {
            if let b = state.battery {
                if Self.snapshotMode {
                    content(b).frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView(showsIndicators: false) { content(b) }
                }
            } else {
                NoBatteryState()
            }
        }
    }

    private func content(_ b: BatteryInfo) -> some View {
        VStack(spacing: 10) {
            ChargeHero(b: b)

            HStack(spacing: 8) {
                StatCard(
                    title: "HEALTH",
                    value: String(format: "%.0f%%", b.healthPercent),
                    subtitle: "\(b.fullChargeCapacitymAh.formatted()) / \(b.designCapacitymAh.formatted()) mAh",
                    color: healthColor(b.healthPercent),
                    barFraction: b.healthPercent / 100
                )
                StatCard(
                    title: "CYCLES",
                    value: "\(b.cycleCount)",
                    subtitle: "rated ~1000",
                    color: cycleColor(b.cycleCount),
                    barFraction: Double(b.cycleCount) / 1000
                )
                StatCard(
                    title: "TEMP",
                    value: String(format: "%.1f°", b.temperature),
                    subtitle: "battery",
                    color: Theme.tempColor(b.temperature + 25), // батарея холоднее SoC — сдвиг шкалы
                    barFraction: b.temperature / 60
                )
            }

            ElectricalCard(b: b)
            DetailsCard(b: b)
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private func healthColor(_ h: Double) -> Color {
        h >= 85 ? Theme.mint : (h >= 70 ? Theme.amber : Theme.red)
    }

    private func cycleColor(_ c: Int) -> Color {
        c < 500 ? Theme.mint : (c < 850 ? Theme.amber : Theme.red)
    }
}

// MARK: - Герой: кольцо заряда

private struct ChargeHero: View {
    let b: BatteryInfo

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                GaugeRing(progress: Double(b.percent) / 100, color: ringColor, lineWidth: 7)
                    .frame(width: 108, height: 108)
                VStack(spacing: 0) {
                    HStack(spacing: 2) {
                        if b.isCharging {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.amber)
                        }
                        Text("\(b.percent)")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    Text("%")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .animation(.easeOut(duration: 0.4), value: b.percent)

            Text(statusLine)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.cardStroke, lineWidth: 1)
        )
    }

    private var ringColor: Color {
        if b.isCharging { return Theme.mint }
        if b.percent <= 20 { return Theme.red }
        if b.percent <= 50 { return Theme.amber }
        return Theme.mint
    }

    private var statusLine: String {
        if b.fullyCharged && b.externalConnected { return "Fully charged · on AC power" }
        if b.isCharging {
            if let t = b.timeRemainingMinutes { return "Charging · \(hhmm(t)) to full" }
            return "Charging"
        }
        if b.externalConnected { return "Plugged in · not charging" }
        if let t = b.timeRemainingMinutes { return "On battery · \(hhmm(t)) left" }
        return "On battery"
    }

    private func hhmm(_ minutes: Int) -> String {
        "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }
}

// MARK: - Маленькая карточка с баром

private struct StatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color
    let barFraction: Double

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(subtitle)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Capsule()
                .fill(Color.white.opacity(0.075))
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(color)
                            .frame(width: max(3, geo.size.width * min(1, max(0, barFraction))))
                    }
                }
                .padding(.top, 2)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.cardStroke, lineWidth: 1)
        )
    }
}

// MARK: - Электрика

private struct ElectricalCard: View {
    let b: BatteryInfo

    var body: some View {
        VStack(spacing: 7) {
            // Потребление системы + (на зарядке) сколько уходит в батарею.
            // На батарее эти две величины совпадают по модулю, поэтому
            // чип показываем только при зарядке, когда числа реально разные.
            powerRow
            // Прогноз времени работы — только когда реально работаем от батареи
            if !b.externalConnected {
                divider
                row(icon: "hourglass", label: "Runtime at current load",
                    value: b.estEmptyMinutes.map { "\($0 / 60):" + String(format: "%02d", $0 % 60) } ?? "—",
                    valueColor: .primary)
            }
            divider
            row(icon: "bolt.horizontal", label: "Voltage · Amperage",
                value: String(format: "%.2f V · %+.2f A", b.voltage, b.amperage),
                valueColor: .primary)
            if b.externalConnected {
                divider
                row(icon: "powerplug.fill", label: adapterLabel,
                    value: b.adapterWatts.map { "\($0) W" } ?? "—",
                    valueColor: Theme.sky)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.cardStroke, lineWidth: 1)
        )
    }

    private var adapterLabel: String {
        var label = b.adapterName?.capitalized ?? "Power adapter"
        if let v = b.adapterVolts, let a = b.adapterAmps {
            label += String(format: " · %.0fV × %.0fA", v, a)
        }
        return label
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    // Объединённая строка мощности: потребление системы + чип зарядки
    private var powerRow: some View {
        let charging = b.externalConnected && b.batteryWatts > 0.5
        return HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.amber)
                .frame(width: 16)
            Text(b.externalConnected ? "Power draw" : "Power · on battery")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
            Spacer()
            if charging {
                Text("\(Int(b.batteryWatts.rounded())) W → battery")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.mint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.mint.opacity(0.13)))
            }
            Text(b.systemWatts.map { String(format: "%.1f W", $0) } ?? "—")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(b.externalConnected ? .primary : Theme.amber)
        }
    }

    private func row(icon: String, label: String, value: String, valueColor: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.amber)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
            Spacer()
            Text(value)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
    }
}

// MARK: - Детали

private struct DetailsCard: View {
    let b: BatteryInfo

    var body: some View {
        VStack(spacing: 6) {
            detail("Charge now", "\(b.currentCapacitymAh.formatted()) mAh")
            detail("Full charge capacity", "\(b.fullChargeCapacitymAh.formatted()) mAh")
            detail("Design capacity", "\(b.designCapacitymAh.formatted()) mAh")
            if let m = b.manufactureText {
                detail("Manufactured", m)
            }
            if let v = b.vendorText {
                detail("Cell vendor", v)
            }
            detail("Gauge chip", b.deviceName)
            detail("Serial", b.serial)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.cardStroke, lineWidth: 1)
        )
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct NoBatteryState: View {
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "battery.slash")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
            Text("No battery found")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
