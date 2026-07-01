import SwiftUI
import AppKit

enum PanelTab {
    case energy, battery
}

struct MainPanelView: View {
    let isFloating: Bool
    @EnvironmentObject var state: AppState
    @State private var showSettings = false

    static let panelSize = CGSize(width: 376, height: 600)

    init(isFloating: Bool) {
        self.isFloating = isFloating
    }

    // Вкладка живёт в AppState — общая для панелей и трея
    private var tabBinding: Binding<PanelTab> {
        Binding(get: { state.tab }, set: { state.tab = $0 })
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HeaderBar(isFloating: isFloating, showSettings: $showSettings, tab: tabBinding)
                Group {
                    if state.tab == .energy {
                        GaugesRow()
                        SectionHeader()
                        ProcessListView()
                    } else {
                        BatteryView()
                    }
                }
                FooterBar(tab: state.tab)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: state.tab)

            if showSettings {
                SettingsView(isPresented: $showSettings)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: showSettings)
        .overlay(alignment: .bottom) { ToastView() }
        .onAppear { state.panelAppeared() }
        .onDisappear {
            state.panelDisappeared()
            // При закрытии попапа сбрасываем настройки — при следующем
            // открытии из трея пользователь попадёт на основной экран
            showSettings = false
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .background(Theme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: isFloating ? 19 : 0, style: .continuous))
        .overlay {
            if isFloating {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Шапка

private struct HeaderBar: View {
    let isFloating: Bool
    @Binding var showSettings: Bool
    @Binding var tab: PanelTab
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                    .fill(Theme.flameGradientV)
                    .frame(width: 26, height: 26)
                    .shadow(color: Theme.ember.opacity(0.45), radius: 6, y: 1)
                Image(systemName: "flame.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("System Control")
                    .font(.system(size: 13, weight: .semibold))
                Text(Machine.chipName)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            TabSwitcher(tab: $tab)

            if isFloating {
                IconButton(systemName: "pin.slash", help: tr("Unpin floating panel", "Открепить окно")) {
                    PanelController.shared.close()
                }
            } else {
                IconButton(systemName: "pin", help: tr("Pin as floating panel (always on top)", "Закрепить поверх всех окон")) {
                    PanelController.shared.show()
                    closeMenuBarPopup()
                }
            }
            IconButton(systemName: "gearshape", help: tr("Settings", "Настройки")) {
                showSettings.toggle()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

// Переключатель вкладок: энергия / батарея
private struct TabSwitcher: View {
    @Binding var tab: PanelTab
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            tabButton(.energy, icon: "flame.fill", help: tr("Energy & temperatures", "Энергия и температуры"))
            tabButton(.battery, icon: "battery.100percent", help: tr("Battery health & usage", "Здоровье и расход батареи"))
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().stroke(Theme.cardStroke, lineWidth: 1))
    }

    private func tabButton(_ value: PanelTab, icon: String, help: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tab == value ? Color.primary : Color.secondary.opacity(0.7))
            .frame(width: 30, height: 20)
            .background {
                if tab == value {
                    Capsule()
                        .fill(Color.white.opacity(0.13))
                        .matchedGeometryEffect(id: "tab", in: ns)
                }
            }
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    tab = value
                }
            }
            .help(help)
    }
}

func closeMenuBarPopup() {
    for window in NSApp.windows where String(describing: type(of: window)).contains("MenuBarExtra") {
        window.close()
    }
}

enum Machine {
    static let chipName: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }()
}

// MARK: - Ряд гейджей

private struct GaugesRow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            GaugeCard(
                title: "CPU",
                display: tempLabel(state.cpuTemp),
                progress: tempProgress(state.cpuTemp),
                color: state.cpuTemp.map(Theme.tempColor) ?? .gray,
                history: state.cpuTempHistory
            )
            GaugeCard(
                title: "GPU",
                display: tempLabel(state.gpuTemp),
                progress: tempProgress(state.gpuTemp),
                color: state.gpuTemp.map(Theme.tempColor) ?? .gray,
                history: state.gpuTempHistory
            )
            DualLoadCard(
                cpu: state.cpuLoad,
                gpu: state.gpuLoad,
                cpuHistory: state.cpuLoadHistory,
                gpuHistory: state.gpuLoadHistory
            )
        }
        .padding(.horizontal, 16)
    }

    private func tempProgress(_ t: Double?) -> Double {
        guard let t else { return 0 }
        return (t - 30) / (102 - 30)
    }
}

// Один индикатор, две метрики: внешнее кольцо — CPU, внутреннее — GPU
private struct DualLoadCard: View {
    let cpu: Double
    let gpu: Double?
    let cpuHistory: [Double]
    let gpuHistory: [Double]

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                GaugeRing(progress: cpu / 100, color: Theme.sky, lineWidth: 4.5)
                    .frame(width: 58, height: 58)
                GaugeRing(progress: (gpu ?? 0) / 100, color: Theme.violet, lineWidth: 4)
                    .frame(width: 42, height: 42)
                VStack(spacing: -0.5) {
                    Text("\(Int(cpu.rounded()))")
                        .foregroundStyle(Theme.sky)
                    Text(gpu.map { "\(Int($0.rounded()))" } ?? "—")
                        .foregroundStyle(Theme.violet)
                }
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .frame(width: 26)
            }
            .padding(.top, 2)
            .animation(.easeOut(duration: 0.4), value: cpu)
            .animation(.easeOut(duration: 0.4), value: gpu)

            HStack(spacing: 8) {
                legend("CPU", Theme.sky)
                legend("GPU", Theme.violet)
            }

            ZStack {
                Sparkline(values: cpuHistory, color: Theme.sky, fixedRange: 0...100)
                Sparkline(values: gpuHistory, color: Theme.violet, fixedRange: 0...100)
            }
            .frame(height: 22)
            .padding(.horizontal, 2)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.cardStroke, lineWidth: 1)
        )
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 2.5) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text(label)
                .font(.system(size: 7.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
    }
}

private struct GaugeCard: View {
    let title: String
    let display: String
    let progress: Double
    let color: Color
    let history: [Double]
    var historyRange: ClosedRange<Double>? = nil

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                GaugeRing(progress: progress, color: color)
                    .frame(width: 58, height: 58)
                Text(display)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                    .frame(width: 40)
            }
            .padding(.top, 2)
            .animation(.easeOut(duration: 0.4), value: progress)

            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(.secondary)

            Sparkline(values: history, color: color, fixedRange: historyRange)
                .frame(height: 22)
                .padding(.horizontal, 2)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.cardStroke, lineWidth: 1)
        )
    }
}

// MARK: - Заголовок секции списка

private struct SectionHeader: View {
    @EnvironmentObject var state: AppState

    private var groupingBinding: Binding<Int> {
        Binding(
            get: { state.groupByApps ? 0 : 1 },
            set: { state.groupByApps = $0 == 0 }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(tr("TOP ENERGY", "ТОП НАГРУЗКИ"))
                .font(.system(size: 9.5, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(.secondary)
            warmupNote
            Spacer()
            PillPicker(options: [tr("Apps", "Прил."), tr("Procs", "Проц.")], selection: groupingBinding)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 7)
    }

    @ViewBuilder
    private var warmupNote: some View {
        if state.historyDepth + 1 < state.windowSeconds {
            HStack(spacing: 3) {
                Image(systemName: "hourglass")
                    .font(.system(size: 7.5, weight: .bold))
                Text(tr("collecting", "сбор") + " \(Int(state.historyDepth))s / \(Int(state.windowSeconds))s")
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(Theme.amber.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Theme.amber.opacity(0.10)))
        }
    }
}

// MARK: - Футер

private struct FooterBar: View {
    let tab: PanelTab
    @EnvironmentObject var state: AppState

    private var windowBinding: Binding<Int> {
        Binding(
            get: {
                AppState.windowChoices.firstIndex { $0.seconds == state.windowSeconds } ?? 1
            },
            set: { state.windowSeconds = AppState.windowChoices[$0].seconds }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            if tab == .energy {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    PillPicker(
                        options: AppState.windowChoices.map(\.label),
                        selection: windowBinding,
                        fontSize: 9.5
                    )
                }
                Spacer()
                Text("\(state.processCount) " + tr("processes", "процессов"))
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: state.battery?.externalConnected == true
                          ? "powerplug.fill" : "battery.100percent")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(batteryStatus)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            IconButton(systemName: "power", help: tr("Quit System Control", "Выйти из System Control"), size: 11) {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private var batteryStatus: String {
        guard let b = state.battery else { return tr("No battery", "Нет батареи") }
        if b.externalConnected {
            if let w = b.adapterWatts { return tr("AC power", "Питание") + " · \(w)W " + tr("adapter", "адаптер") }
            return tr("AC power", "Питание от сети")
        }
        return tr("On battery", "От батареи")
    }
}

// MARK: - Тост (результат kill)

private struct ToastView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let message = state.killMessage {
            Text(message)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color(red: 0.16, green: 0.16, blue: 0.19).opacity(0.97))
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                )
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                .padding(.bottom, 52)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.killMessage)
        }
    }
}
