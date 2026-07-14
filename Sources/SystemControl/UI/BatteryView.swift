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
                    title: tr("HEALTH", "ЗДОРОВЬЕ"),
                    value: String(format: "%.0f%%", b.healthPercent),
                    subtitle: "\(b.fullChargeCapacitymAh.formatted()) / \(b.designCapacitymAh.formatted()) mAh",
                    color: healthColor(b.healthPercent),
                    barFraction: b.healthPercent / 100
                )
                StatCard(
                    title: tr("CYCLES", "ЦИКЛЫ"),
                    value: "\(b.cycleCount)",
                    subtitle: tr("rated ~1000", "ресурс ~1000"),
                    color: cycleColor(b.cycleCount),
                    barFraction: Double(b.cycleCount) / 1000
                )
                StatCard(
                    title: tr("TEMP", "ТЕМП."),
                    value: String(format: "%.1f°", b.temperature),
                    subtitle: tr("battery", "батарея"),
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
        // Критически мало заряда — тревожный бордово-красный, даже во время зарядки
        if b.percent <= 10 { return Theme.bordeaux }
        if b.isCharging { return Theme.mint }
        if b.percent <= 20 { return Theme.red }
        if b.percent <= 50 { return Theme.amber }
        return Theme.mint
    }

    private var statusLine: String {
        if b.fullyCharged && b.externalConnected { return tr("Fully charged · on AC power", "Полный заряд · от сети") }
        if b.isCharging {
            if let t = b.timeRemainingMinutes { return tr("Charging · ", "Зарядка · ") + hhmm(t) + tr(" to full", " до полного") }
            return tr("Charging", "Зарядка")
        }
        if b.externalConnected { return tr("Plugged in · not charging", "Подключено · не заряжается") }
        if let t = b.timeRemainingMinutes { return tr("On battery · ", "От батареи · ") + hhmm(t) + tr(" left", " осталось") }
        return tr("On battery", "От батареи")
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
                row(icon: "hourglass", label: tr("Runtime at current load", "Работа при текущей нагрузке"),
                    value: b.estEmptyMinutes.map { "\($0 / 60):" + String(format: "%02d", $0 % 60) } ?? "—",
                    valueColor: .primary)
            }
            divider
            row(icon: "bolt.horizontal", label: tr("Voltage · Amperage", "Напряжение · ток"),
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
        var label = b.adapterName?.capitalized ?? tr("Power adapter", "Адаптер питания")
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
            Text(b.externalConnected ? tr("Power draw", "Потребление") : tr("Power · on battery", "Потребление · от батареи"))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
            Spacer()
            if charging {
                Text("\(Int(b.batteryWatts.rounded())) W → " + tr("battery", "батарея"))
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
            detail(tr("Charge now", "Текущий заряд"), "\(b.currentCapacitymAh.formatted()) mAh")
            detail(tr("Full charge capacity", "Полная ёмкость"), "\(b.fullChargeCapacitymAh.formatted()) mAh")
            detail(tr("Design capacity", "Проектная ёмкость"), "\(b.designCapacitymAh.formatted()) mAh")
            if let m = b.manufactureText {
                detail(tr("Manufactured", "Произведена"), m)
            }
            if let v = b.vendorText {
                detail(tr("Cell vendor", "Производитель ячеек"), v)
            }
            // Чип и серийник — в одну строку, чтобы раздел влезал без прокрутки
            detail(tr("Chip · serial", "Чип · серийник"), "\(b.deviceName) · \(b.serial)")
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
            Text(tr("No battery found", "Батарея не найдена"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
