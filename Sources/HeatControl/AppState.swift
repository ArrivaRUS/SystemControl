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
    @Published var processCount: Int = 0
    @Published var historyDepth: TimeInterval = 0
    @Published var killMessage: String?

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
    @Published var menuBarShowsTemp: Bool {
        didSet { defaults.set(menuBarShowsTemp, forKey: "menuBarShowsTemp") }
    }

    static let windowChoices: [(label: String, seconds: Double)] = [
        ("10s", 10), ("1m", 60), ("5m", 300),
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
    nonisolated private let queue = DispatchQueue(label: "heatcontrol.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var killMessageTask: Task<Void, Never>?

    private nonisolated static let historyPoints = 90
    private nonisolated static let listLimit = 9

    private init() {
        groupByApps = defaults.object(forKey: "groupByApps") as? Bool ?? true
        let w = defaults.double(forKey: "windowSeconds")
        windowSeconds = w > 0 ? w : 60
        let i = defaults.double(forKey: "updateInterval")
        updateInterval = i > 0 ? i : 2
        menuBarShowsTemp = defaults.object(forKey: "menuBarShowsTemp") as? Bool ?? true
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
        let sensorList = thermals.readAll()
        let (cpu, gpu) = thermals.summary(from: sensorList)
        let loadValue = load.sample()
        let gpuLoadValue = gpuMeter.sample()
        let defaults = UserDefaults.standard
        let storedWindow = defaults.double(forKey: "windowSeconds")
        let window = storedWindow > 0 ? storedWindow : 60
        let grouping = defaults.object(forKey: "groupByApps") as? Bool ?? true
        let top = sampler.top(window: window, groupByApps: grouping, limit: Self.listLimit)
        let count = sampler.processCount
        let depth = sampler.historyDepth

        Task { @MainActor [weak self] in
            self?.publish(top: top, count: count, depth: depth,
                          sensors: sensorList, cpu: cpu, gpu: gpu,
                          load: loadValue, gpuLoad: gpuLoadValue)
        }
    }

    private func publish(top: [EnergyEntry], count: Int, depth: TimeInterval,
                         sensors: [ThermalSensor], cpu: Double?, gpu: Double?,
                         load: Double?, gpuLoad gpuLoadValue: Double?) {
        entries = top
        processCount = count
        historyDepth = depth
        self.sensors = sensors
        if let cpu { cpuTemp = Self.smooth(cpuTemp, cpu) }
        if let gpu { gpuTemp = Self.smooth(gpuTemp, gpu) }
        if let load { cpuLoad = Self.smooth(cpuLoad, load) }
        if let gpuLoadValue { gpuLoad = Self.smooth(gpuLoad, gpuLoadValue) }
        Self.push(&cpuTempHistory, cpuTemp)
        Self.push(&gpuTempHistory, gpuTemp)
        Self.push(&cpuLoadHistory, load == nil ? nil : cpuLoad)
        Self.push(&gpuLoadHistory, gpuLoadValue == nil ? nil : gpuLoad)
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
            Task { @MainActor in self.entries = top }
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
