import Foundation

// Диагностический режим: `SystemControl --probe`
// Печатает все термосенсоры и топ процессов — для проверки ядра без UI.
func runProbe() {
    print("SystemControl probe — \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print()

    let thermals = ThermalReader()
    thermals.fullSensorList = true
    print("== Thermal sensors (HID + SMC) ==")
    if !thermals.isAvailable {
        print("  !! IOHIDEventSystemClient unavailable")
    }
    let sensors = thermals.readAll()
    if sensors.isEmpty {
        print("  (none found)")
    }
    for s in sensors {
        print(String(format: "  %-38s %6.2f °C", (s.name as NSString).utf8String!, s.value))
    }
    let (cpu, gpu) = thermals.summary(from: sensors)
    print(String(format: "  >> CPU max: %@   GPU max: %@",
                 cpu.map { String(format: "%.1f°C", $0) } ?? "n/a",
                 gpu.map { String(format: "%.1f°C", $0) } ?? "n/a"))
    print()

    print("== Sampling processes (3s) ==")
    let sampler = ProcessSampler()
    let loadMeter = SystemLoad()
    let gpuMeter = GPULoad()
    _ = loadMeter.sample()
    for _ in 0..<4 {
        sampler.sample()
        Thread.sleep(forTimeInterval: 1.0)
    }
    sampler.sample()
    let cpuLoad = loadMeter.sample() ?? 0
    let gpuLoad = gpuMeter.sample()
    print(String(format: "  total CPU load: %.1f%%   GPU load: %@   processes: %d",
                 cpuLoad,
                 gpuLoad.map { String(format: "%.1f%%", $0) } ?? "n/a",
                 sampler.processCount))
    print()

    print("== Battery ==")
    if let b = BatteryReader().sample() {
        print(String(format: "  charge: %d%%  health: %.1f%% (%d/%d mAh)  cycles: %d",
                     b.percent, b.healthPercent, b.fullChargeCapacitymAh, b.designCapacitymAh, b.cycleCount))
        print(String(format: "  temp: %.1f°C  voltage: %.2fV  amperage: %+.2fA  battery: %+.1fW  system: %@",
                     b.temperature, b.voltage, b.amperage, b.batteryWatts,
                     b.systemWatts.map { String(format: "%.1fW", $0) } ?? "n/a"))
        if b.externalConnected {
            print("  adapter: \(b.adapterName ?? "?") · \(b.adapterWatts ?? 0)W")
        }
        print("  manufactured: \(b.manufactureText ?? "n/a")   vendor: \(b.vendorText ?? "n/a")")
        print(String(format: "  load (EMA): %@   est. runtime: %@   smc timer: %@",
                     b.systemLoadWatts.map { String(format: "%.1fW", $0) } ?? "n/a",
                     b.estEmptyMinutes.map { "\($0 / 60):" + String(format: "%02d", $0 % 60) } ?? "n/a",
                     b.timeRemainingMinutes.map { "\($0 / 60):" + String(format: "%02d", $0 % 60) } ?? "n/a"))
    } else {
        print("  (no battery)")
    }
    print()

    print("== Top apps (grouped) ==")
    for e in sampler.top(window: 10, groupByApps: true, limit: 8) {
        print(String(format: "  %6.1f%%  %-30s pid %d  (%d proc)",
                     e.cpuPercent, (e.name as NSString).utf8String!, e.pid, e.processCount))
    }
    print()
    print("== Top processes ==")
    for e in sampler.top(window: 10, groupByApps: false, limit: 8) {
        print(String(format: "  %6.1f%%  %-30s pid %d",
                     e.cpuPercent, (e.name as NSString).utf8String!, e.pid))
    }
}
