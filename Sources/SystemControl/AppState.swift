import SwiftUI
import AppKit
import Combine

// Координатор: фоновый цикл сэмплирования + публикация данных для UI.
@MainActor
final class AppState: ObservableObject {

    static let shared = AppState()

    // MARK: - Данные для UI

    @Published var entries: [EnergyEntry] = []
    @Published var cpuTemp: Double?
    @Published var gpuTemp: Double?
    @Published var cpuTempHistory: [Double] = []
    @Published var gpuTempHistory: [Double] = []
    @Published var cpuLoad: Double = 0
    @Published var cpuLoadHistory: [Double] = []
    @Published var gpuLoad: Double?
    @Published var gpuLoadHistory: [Double] = []
    @Published var sensors: [ThermalSensor] = []
    @Published var battery: BatteryInfo?
    @Published var menuBattery: MenuBatterySummary?
    @Published var processCount: Int = 0
    @Published var historyDepth: TimeInterval = 0
    @Published var killMessage: String?

    // Выбранная вкладка панели. Лежит в AppState (а не в @State панели),
    // чтобы её разделяли всплывающая и плавающая панели И чтобы от неё
    // зависел вид иконки в трее (energy → темп/ваты, battery → %/время).
    @Published var tab: PanelTab = .energy {
        didSet { defaults.set(tab == .battery ? "battery" : "energy", forKey: "selectedTab") }
    }

    // MARK: - Настройки (персистентные)

    @Published var groupByApps: Bool {
        didSet { defaults.set(groupByApps, forKey: "groupByApps"); recompute() }
    }
    @Published var windowSeconds: Double {
        didSet { defaults.set(windowSeconds, forKey: "windowSeconds"); recompute() }
    }
    @Published var updateInterval: Double {
        didSet { defaults.set(updateInterval, forKey: "updateInterval"); restartTimer() }
    }
    // Что показывать в трее на вкладке Energy
    @Published var menuBarEnergyMode: MenuBarEnergyMode {
        didSet { defaults.set(menuBarEnergyMode.rawValue, forKey: "menuBarEnergyMode") }
    }
    @Published var menuBarShowsPower: Bool {
        didSet { defaults.set(menuBarShowsPower, forKey: "menuBarShowsPower") }
    }

    static let windowChoices: [(label: String, seconds: Double)] = [
        ("10s", 10), ("30s", 30), ("1m", 60),
    ]
    static let energyModeChoices: [(label: String, mode: MenuBarEnergyMode)] = [
        ("Temp", .temperature), ("CPU", .cpu), ("GPU", .gpu), ("Both", .cpuGpu),
    ]
    static let intervalChoices: [(label: String, seconds: Double)] = [
        ("1s", 1), ("2s", 2), ("5s", 5), ("10s", 10),
    ]

    // MARK: - Внутренности

    private let defaults = UserDefaults.standard
    nonisolated private let sampler = ProcessSampler()
    nonisolated private let thermals = ThermalReader()
    nonisolated private let load = SystemLoad()
    nonisolated private let gpuMeter = GPULoad()
    nonisolated private let batteryReader = BatteryReader()
    nonisolated private let queue = DispatchQueue(label: "systemcontrol.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var killMessageTask: Task<Void, Never>?

    private nonisolated static let historyPoints = 90
    private nonisolated static let listLimit = 9

    // MARK: - Видимость UI
    // Окно MenuBarExtra после закрытия остаётся жить вместе со всем
    // SwiftUI-деревом, и любая публикация заставляет его пересчитываться
    // за кадром. Поэтому данные уходят в @Published только пока панель
    // реально видима; в фоне копятся внутренние буферы, а наружу идёт
    // лишь температура для menu bar.

    private var visiblePanels = 0
    private var uiVisible: Bool { visiblePanels > 0 }

    private var smCpuTemp: Double?
    private var smGpuTemp: Double?
    private var smCpuLoad: Double?
    private var smGpuLoad: Double?
    private var smBattery: BatteryInfo?
    private var bufCpuTempHistory: [Double] = []
    private var bufGpuTempHistory: [Double] = []
    private var bufCpuLoadHistory: [Double] = []
    private var bufGpuLoadHistory: [Double] = []

    func panelAppeared() {
        visiblePanels += 1
        hcDebugLog("panelAppeared, visible=\(visiblePanels)")
        guard visiblePanels == 1 else { return }
        // Мгновенно отдаём накопленное и просим свежий срез вне расписания
        cpuTempHistory = bufCpuTempHistory
        gpuTempHistory = bufGpuTempHistory
        cpuLoadHistory = bufCpuLoadHistory
        gpuLoadHistory = bufGpuLoadHistory
        if let v = smGpuTemp, gpuTemp != v { gpuTemp = v }
        if let v = smCpuLoad, cpuLoad != v { cpuLoad = v }
        if let v = smGpuLoad, gpuLoad != v { gpuLoad = v }
        if battery != smBattery { battery = smBattery }
        queue.async { [weak self] in self?.tick() }
    }

    func panelDisappeared() {
        visiblePanels = max(0, visiblePanels - 1)
        hcDebugLog("panelDisappeared, visible=\(visiblePanels)")
    }

    private init() {
        // Миграция настроек со старого bundle id (com.arrivarus.heatcontrol)
        if defaults.object(forKey: "windowSeconds") == nil,
           let old = UserDefaults(suiteName: "com.arrivarus.heatcontrol") {
            for key in ["groupByApps", "windowSeconds", "updateInterval", "menuBarShowsTemp"] {
                if let v = old.object(forKey: key), defaults.object(forKey: key) == nil {
                    defaults.set(v, forKey: key)
                }
            }
        }

        groupByApps = defaults.object(forKey: "groupByApps") as? Bool ?? true
        let w = defaults.double(forKey: "windowSeconds")
        // Миграция: сохранённое окно, которого больше нет в списке → дефолт 30s
        if Self.windowChoices.contains(where: { $0.seconds == w }) {
            windowSeconds = w
        } else {
            windowSeconds = 30
            defaults.set(30.0, forKey: "windowSeconds")
        }
        let i = defaults.double(forKey: "updateInterval")
        updateInterval = i > 0 ? i : 2
        menuBarEnergyMode = (defaults.string(forKey: "menuBarEnergyMode"))
            .flatMap(MenuBarEnergyMode.init) ?? .temperature
        menuBarShowsPower = defaults.object(forKey: "menuBarShowsPower") as? Bool ?? true
        tab = defaults.string(forKey: "selectedTab") == "battery" ? .battery : .energy
        restartTimer()
    }

    private func restartTimer() {
        timer?.cancel()
        let interval = max(1, min(10, updateInterval))
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // Выполняется на фоновой очереди
    nonisolated private func tick() {
        sampler.sample()
        let loadValue = load.sample()
        let gpuLoadValue = gpuMeter.sample()
        // Подсказка для переобнаружения динамических GPU-ключей SMC
        thermals.gpuActiveHint = (gpuLoadValue ?? 0) > 5
        let sensorList = thermals.readAll()
        let (cpu, gpu) = thermals.summary(from: sensorList)
        let defaults = UserDefaults.standard
        let storedWindow = defaults.double(forKey: "windowSeconds")
        let window = storedWindow > 0 ? storedWindow : 30
        let grouping = defaults.object(forKey: "groupByApps") as? Bool ?? true
        let top = sampler.top(window: window, groupByApps: grouping, limit: Self.listLimit)
        let count = sampler.processCount
        let depth = sampler.historyDepth
        let batteryInfo = batteryReader.sample()

        Task { @MainActor [weak self] in
            self?.publish(top: top, count: count, depth: depth,
                          sensors: sensorList, cpu: cpu, gpu: gpu,
                          load: loadValue, gpuLoad: gpuLoadValue,
                          battery: batteryInfo)
        }
    }

    // Сбор данных идёт каждый тик. В фоне обновляются только буферы и
    // температура для menu bar; видимые @Published-свойства получают значения
    // лишь при открытой панели — и только если ВИДИМОЕ значение реально
    // изменилось (квантование до точности отображения), иначе каждый тик
    // запускал бы анимации ради невидимых сдвигов на 0.1°.
    private func publish(top: [EnergyEntry], count: Int, depth: TimeInterval,
                         sensors: [ThermalSensor], cpu: Double?, gpu: Double?,
                         load: Double?, gpuLoad gpuLoadValue: Double?,
                         battery batteryInfo: BatteryInfo?) {
        // Всегда: сглаживание и лента истории
        if let batteryInfo { smBattery = batteryInfo }

        // Сводка для menu bar нужна и при скрытой панели
        let summary = smBattery.map(MenuBatterySummary.init)
        if menuBattery != summary { menuBattery = summary }
        if let cpu { smCpuTemp = Self.smoothQ(smCpuTemp, cpu, step: 0.5) }
        if let gpu { smGpuTemp = Self.smoothQ(smGpuTemp, gpu, step: 0.5) }
        if let load { smCpuLoad = Self.smoothQ(smCpuLoad, load, step: 1) }
        if let gpuLoadValue { smGpuLoad = Self.smoothQ(smGpuLoad, gpuLoadValue, step: 1) }
        Self.push(&bufCpuTempHistory, smCpuTemp)
        Self.push(&bufGpuTempHistory, smGpuTemp)
        Self.push(&bufCpuLoadHistory, load == nil ? nil : smCpuLoad)
        Self.push(&bufGpuLoadHistory, gpuLoadValue == nil ? nil : smGpuLoad)

        // Температура и загрузка CPU/GPU нужны и при скрытой панели —
        // их показывает иконка в трее (режимы Energy: Temp/CPU/GPU/Both)
        if let v = smCpuTemp, cpuTemp != v { cpuTemp = v }
        if let v = smCpuLoad, cpuLoad != v { cpuLoad = v }
        if let v = smGpuLoad, gpuLoad != v { gpuLoad = v }

        guard uiVisible else { return }

        setEntries(top)
        if processCount != count { processCount = count }

        // Глубина истории нужна UI только для плашки "collecting …" —
        // выше порога текущего окна перестаём её публиковать
        let depthCap = min(windowSeconds + 2, ProcessSampler.maxHistory)
        let depthQ = min(depth.rounded(), depthCap)
        if historyDepth != depthQ { historyDepth = depthQ }

        let sensorsQ = sensors.map {
            ThermalSensor(id: $0.id, name: $0.name, value: Self.quantize($0.value, step: 0.1))
        }
        if self.sensors != sensorsQ { self.sensors = sensorsQ }

        // cpuLoad/gpuLoad уже опубликованы выше (нужны трею); тут только gpuTemp
        if let v = smGpuTemp, gpuTemp != v { gpuTemp = v }
        if battery != smBattery { battery = smBattery }

        cpuTempHistory = bufCpuTempHistory
        gpuTempHistory = bufGpuTempHistory
        cpuLoadHistory = bufCpuLoadHistory
        gpuLoadHistory = bufGpuLoadHistory
    }

    private func setEntries(_ top: [EnergyEntry]) {
        let q = top.map { e in
            EnergyEntry(
                id: e.id, pid: e.pid, name: e.name, path: e.path,
                cpuPercent: Self.quantize(e.cpuPercent, step: 0.1),
                processCount: e.processCount, isGroup: e.isGroup
            )
        }
        if entries != q { entries = q }
    }

    private static func smoothQ(_ old: Double?, _ new: Double, step: Double) -> Double {
        quantize(smooth(old, new), step: step)
    }

    private static func quantize(_ v: Double, step: Double) -> Double {
        (v / step).rounded() * step
    }

    private static func push(_ array: inout [Double], _ value: Double?) {
        guard let value else { return }
        array.append(value)
        if array.count > historyPoints {
            array.removeFirst(array.count - historyPoints)
        }
    }

    private static func smooth(_ old: Double?, _ new: Double) -> Double {
        guard let old else { return new }
        return old + (new - old) * 0.45
    }

    /// Пока открыт список сенсоров в настройках — читаем все SMC-ключи
    /// (дорого), иначе только нужные для сводки.
    func setSensorListVisible(_ visible: Bool) {
        thermals.fullSensorList = visible
        if visible { refreshSensorsNow() }
    }

    /// Немедленный опрос сенсоров вне расписания таймера (при раскрытии списка).
    private func refreshSensorsNow() {
        queue.async { [weak self] in
            guard let self else { return }
            let list = self.thermals.readAll()
            Task { @MainActor in self.sensors = list }
        }
    }

    /// Мгновенный пересчёт топа при смене окна/группировки.
    func recompute() {
        let window = windowSeconds
        let grouping = groupByApps
        queue.async { [weak self] in
            guard let self else { return }
            let top = self.sampler.top(window: window, groupByApps: grouping, limit: Self.listLimit)
            Task { @MainActor in self.setEntries(top) }
        }
    }

    // MARK: - Завершение процессов

    func kill(_ entry: EnergyEntry, force: Bool) {
        // Для приложений сперва пробуем вежливый terminate через AppKit
        if !force, let app = NSRunningApplication(processIdentifier: entry.pid),
           app.activationPolicy == .regular || app.activationPolicy == .accessory {
            if app.terminate() {
                flash("Sent quit to \(entry.name)")
                return
            }
        }
        let signal: Int32 = force ? SIGKILL : SIGTERM
        if Darwin.kill(entry.pid, signal) == 0 {
            flash(force ? "Force killed \(entry.name)" : "Terminated \(entry.name)")
        } else {
            switch errno {
            case EPERM: flash("No permission — \(entry.name) is a system process")
            case ESRCH: flash("\(entry.name) already exited")
            default: flash("Failed to kill \(entry.name)")
            }
        }
    }

    private func flash(_ message: String) {
        killMessage = message
        killMessageTask?.cancel()
        killMessageTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if !Task.isCancelled { self.killMessage = nil }
        }
    }

    var thermalsAvailable: Bool { thermals.isAvailable }
}
