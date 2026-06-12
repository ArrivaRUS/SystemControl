import Foundation
import IOKit

// Параметры батареи из реестра AppleSmartBattery — тот же источник,
// что у coconutBattery. Читается без root.

struct BatteryInfo: Equatable {
    var percent: Int                 // заряд, %
    var isCharging: Bool
    var externalConnected: Bool
    var fullyCharged: Bool
    var timeRemainingMinutes: Int?   // до полного / до пустого, по состоянию

    var currentCapacitymAh: Int      // AppleRawCurrentCapacity
    var fullChargeCapacitymAh: Int   // NominalChargeCapacity (фактическая ёмкость)
    var designCapacitymAh: Int
    var cycleCount: Int

    var temperature: Double          // °C
    var voltage: Double              // V
    var amperage: Double             // A, знак: + заряд, − разряд
    var batteryWatts: Double         // V × A, знаковая мощность батареи
    var systemWatts: Double?         // потребление системы (телеметрия SMC)

    var adapterWatts: Int?
    var adapterName: String?
    var adapterVolts: Double?
    var adapterAmps: Double?

    var systemLoadWatts: Double?     // потребление самой системы (без заряда батареи)
    var estEmptyMinutes: Int?        // прогноз до разряда при текущем потреблении

    var manufactureText: String?     // декодированная дата производства
    var vendorText: String?          // производитель ячеек

    var serial: String
    var deviceName: String

    var healthPercent: Double {
        designCapacitymAh > 0
            ? Double(fullChargeCapacitymAh) / Double(designCapacitymAh) * 100
            : 0
    }
}

// Грубая сводка для menu bar: сильное квантование, чтобы скрытое UI-дерево
// не перерисовывалось из-за мелких колебаний значений на каждом тике.
// На внешнем питании watts = потребление от адаптера (включая зарядку батареи).
struct MenuBatterySummary: Equatable {
    var plugged: Bool
    var watts: Int?

    init(_ b: BatteryInfo) {
        plugged = b.externalConnected
        watts = b.externalConnected
            ? b.systemWatts.map { max(1, Int($0.rounded())) }
            : nil
    }
}

// Доступ только с очереди сэмплера; сервис неизменяем после init
final class BatteryReader: @unchecked Sendable {

    private var service: io_registry_entry_t = 0
    // Сглаженное потребление системы — чтобы прогноз времени не скакал
    private var emaLoadWatts: Double?

    init() {
        service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    var isAvailable: Bool { service != 0 }

    func sample() -> BatteryInfo? {
        guard service != 0 else { return nil }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }

        func int(_ key: String) -> Int? { dict[key] as? Int }
        func bool(_ key: String) -> Bool { dict[key] as? Bool ?? false }

        guard dict["BatteryInstalled"] as? Bool ?? true else { return nil }

        let percent = int("CurrentCapacity") ?? 0
        let isCharging = bool("IsCharging")
        let external = bool("ExternalConnected")
        let fullyCharged = bool("FullyCharged")

        // 65535 — сентинел "неизвестно/вычисляется"
        func minutes(_ key: String) -> Int? {
            guard let v = int(key), v > 0, v < 65535 else { return nil }
            return v
        }
        let timeRemaining = isCharging
            ? (minutes("AvgTimeToFull") ?? minutes("TimeRemaining"))
            : (external ? nil : (minutes("AvgTimeToEmpty") ?? minutes("TimeRemaining")))

        let rawCurrent = int("AppleRawCurrentCapacity") ?? 0
        let rawMax = int("AppleRawMaxCapacity") ?? 0
        let nominal = int("NominalChargeCapacity") ?? rawMax
        let design = int("DesignCapacity") ?? 0
        let cycles = int("CycleCount") ?? 0

        let temperature = Double(int("Temperature") ?? 0) / 100.0
        let voltage = Double(int("Voltage") ?? 0) / 1000.0
        let amperage = Double(int("Amperage") ?? 0) / 1000.0
        let batteryWatts = voltage * amperage

        // Телеметрия SMC: реальное потребление системы.
        // На питании — от адаптера (SystemPowerIn), на батарее — BatteryPower.
        // SystemLoad — потребление самой системы без учёта зарядки батареи.
        var systemWatts: Double?
        var systemLoad: Double?
        if let telemetry = dict["PowerTelemetryData"] as? [String: Any] {
            let key = external ? "SystemPowerIn" : "BatteryPower"
            if let mw = telemetry[key] as? Int, mw > 0 {
                systemWatts = Double(mw) / 1000.0
            }
            if let mw = telemetry["SystemLoad"] as? Int, mw > 0 {
                systemLoad = Double(mw) / 1000.0
            }
        }
        if systemWatts == nil, !external, batteryWatts < 0 {
            systemWatts = -batteryWatts
        }
        if systemLoad == nil { systemLoad = systemWatts }

        // Прогноз до разряда при текущем (сглаженном) потреблении.
        // На батарее SMC сам ведёт оценку; на питании считаем гипотетический
        // запас хода из текущего заряда и нагрузки системы.
        if let load = systemLoad, load > 0.3 {
            emaLoadWatts = emaLoadWatts.map { $0 + (load - $0) * 0.25 } ?? load
        }
        var estEmpty: Int? = external ? nil : minutes("AvgTimeToEmpty")
        if estEmpty == nil, let load = emaLoadWatts, load > 0.3, rawCurrent > 0, voltage > 0 {
            let wattHours = Double(rawCurrent) / 1000.0 * voltage
            let est = wattHours / load * 60.0
            if est.isFinite, est > 0 {
                estEmpty = min(Int(est), 99 * 60)
            }
        }

        let (manufactureText, vendorText) = Self.parseManufacturing(dict)

        var adapterWatts: Int?
        var adapterName: String?
        var adapterVolts: Double?
        var adapterAmps: Double?
        if external, let adapter = dict["AdapterDetails"] as? [String: Any] {
            adapterWatts = adapter["Watts"] as? Int
            if let desc = adapter["Description"] as? String, !desc.isEmpty {
                adapterName = desc
            } else if let name = adapter["Name"] as? String, !name.isEmpty {
                adapterName = name
            }
            if let mv = adapter["AdapterVoltage"] as? Int { adapterVolts = Double(mv) / 1000.0 }
            if let ma = adapter["Current"] as? Int { adapterAmps = Double(ma) / 1000.0 }
        }

        return BatteryInfo(
            percent: percent,
            isCharging: isCharging,
            externalConnected: external,
            fullyCharged: fullyCharged,
            timeRemainingMinutes: timeRemaining,
            currentCapacitymAh: rawCurrent,
            fullChargeCapacitymAh: nominal,
            designCapacitymAh: design,
            cycleCount: cycles,
            temperature: (temperature * 10).rounded() / 10,
            voltage: (voltage * 100).rounded() / 100,
            amperage: (amperage * 100).rounded() / 100,
            batteryWatts: (batteryWatts * 10).rounded() / 10,
            systemWatts: systemWatts.map { ($0 * 10).rounded() / 10 },
            adapterWatts: adapterWatts,
            adapterName: adapterName,
            adapterVolts: adapterVolts,
            adapterAmps: adapterAmps,
            systemLoadWatts: emaLoadWatts.map { ($0 * 10).rounded() / 10 },
            estEmptyMinutes: estEmpty,
            manufactureText: manufactureText,
            vendorText: vendorText,
            serial: dict["Serial"] as? String ?? "—",
            deviceName: dict["DeviceName"] as? String ?? "—"
        )
    }

    // MARK: - Дата производства (формат недокументирован — подстраиваемся)

    // Известные коды производителей ячеек в MfgData
    private static let vendors: [String: String] = [
        "COS": "CosMX", "ATL": "ATL", "SUN": "Sunwoda", "SWD": "Sunwoda",
        "SDI": "Samsung SDI", "LGC": "LG Chem", "SMP": "SMP", "DSY": "Desay",
    ]

    /// Источники по убыванию надёжности:
    ///  1) Intel: 16-бит SBS-дата (день|месяц|год-1980) в top-level ManufactureDate.
    ///  2) Apple Silicon: ASCII-коды в BatteryData.MfgData, напр. "3514","00A","COS"
    ///     (наблюдение на M4 Max 2024 г.). "3514" трактуем как WWDY:
    ///     неделя 35, день 1, год …4 → ≈ конец августа 2024 — сходится
    ///     со сроком сборки машины. Если формат изменится — покажем сырой код.
    private static func parseManufacturing(_ dict: [String: Any]) -> (date: String?, vendor: String?) {
        // Intel / SBS
        if let raw = dict["ManufactureDate"] as? Int, raw > 0, raw <= 0xFFFF {
            let year = 1980 + (raw >> 9)
            let month = (raw >> 5) & 0xF
            let day = raw & 0x1F
            if (2000...2040).contains(year), (1...12).contains(month), (1...31).contains(day) {
                return (String(format: "%02d.%02d.%d", day, month, year), nil)
            }
        }

        guard let batteryData = dict["BatteryData"] as? [String: Any],
              let mfg = batteryData["MfgData"] as? Data else { return (nil, nil) }

        // Печатные ASCII-последовательности из блоба
        var strings: [String] = []
        var current = ""
        for byte in mfg {
            if (0x30...0x7A).contains(byte) {
                current.append(Character(UnicodeScalar(byte)))
            } else {
                if current.count >= 3 { strings.append(current) }
                current = ""
            }
        }
        if current.count >= 3 { strings.append(current) }

        let vendor = strings.compactMap { vendors[$0.uppercased()] }.first
        let code = strings.first { $0.count == 4 && $0.allSatisfy(\.isNumber) }
        let date = code.flatMap(decodeWWDY) ?? code.map { "code \($0)" }
        return (date, vendor)
    }

    /// "3514" → неделя 35, день 1, год с последней цифрой 4 (ближайший прошедший)
    private static func decodeWWDY(_ code: String) -> String? {
        let digits = Array(code).compactMap { $0.wholeNumberValue }
        guard digits.count == 4 else { return nil }
        let week = digits[0] * 10 + digits[1]
        let day = digits[2]
        let yearDigit = digits[3]
        guard (1...53).contains(week), (1...7).contains(day) else { return nil }

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let currentYear = calendar.component(.year, from: Date())
        var year = currentYear - (((currentYear - yearDigit) % 10) + 10) % 10
        if year > currentYear { year -= 10 }

        var comps = DateComponents()
        comps.yearForWeekOfYear = year
        comps.weekOfYear = week
        comps.weekday = day == 7 ? 1 : day + 1 // 1=Пн в коде → weekday Calendar
        guard let date = calendar.date(from: comps) else { return nil }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US")
        fmt.dateFormat = "MMM yyyy"
        return "≈ \(fmt.string(from: date)) · wk \(week)"
    }
}
