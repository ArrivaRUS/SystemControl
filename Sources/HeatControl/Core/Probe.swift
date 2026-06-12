import Foundation

// Диагностический режим: `HeatControl --probe`
// Печатает все термосенсоры и топ процессов — для проверки ядра без UI.
func runProbe() {
    print("HeatControl probe — \(ProcessInfo.processInfo.operatingSystemVersionString)")
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
    _ = loadMeter.sample()
    for _ in 0..<4 {
        sampler.sample()
        Thread.sleep(forTimeInterval: 1.0)
    }
    sampler.sample()
    let cpuLoad = loadMeter.sample() ?? 0
    print(String(format: "  total CPU load: %.1f%%   processes: %d", cpuLoad, sampler.processCount))
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
