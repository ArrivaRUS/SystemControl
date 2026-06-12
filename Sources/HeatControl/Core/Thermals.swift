import Foundation
import CoreFoundation

// Температуры из двух источников:
//  1) HID-сенсоры SoC (usage page 0xff00 / usage 5) — CPU die и др. Быстрые.
//  2) SMC-ключи "T*" — на Apple Silicon дают GPU ("Tg*"), которого нет в HID.
//     SMC медленный (~1мс/ключ), поэтому каждый тик читаются только нужные
//     для сводки ключи, а полный список — лишь пока он открыт в настройках.

struct ThermalSensor: Identifiable, Equatable {
    let id: String
    let name: String
    let value: Double
}

// Доступ только с очереди сэмплера; кэш сервисов неизменяем после init
final class ThermalReader: @unchecked Sendable {

    private var client: UnsafeMutableRawPointer?
    private var hidServices: [(service: UnsafeMutableRawPointer, name: String)] = []
    private var hidServicesArray: CFArray? // удерживает service-указатели живыми
    private let smc = SMCReader()
    private var smcSummaryKeys: [SMCReader.TempKey] = []

    private let stateLock = NSLock()
    private var _fullSensorList = false
    private var _gpuActiveHint = false
    private var lastDiscovery = Date()
    private static let rediscoverCooldown: TimeInterval = 60

    /// Полный (дорогой) опрос всех SMC-ключей — включается, пока пользователь
    /// смотрит список сенсоров в настройках.
    var fullSensorList: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _fullSensorList }
        set { stateLock.lock(); _fullSensorList = newValue; stateLock.unlock() }
    }

    /// Подсказка от IOAccelerator: GPU сейчас работает. Если при этом его
    /// датчиков нет среди ключей — набор ключей устарел, надо переобнаружить.
    var gpuActiveHint: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _gpuActiveHint }
        set { stateLock.lock(); _gpuActiveHint = newValue; stateLock.unlock() }
    }

    init() {
        setupHID()
        recomputeSummaryKeys()
    }

    // Ключи для сводки: GPU (Tg*) всегда; CPU из SMC (Tp*/Tc*) — только
    // как фолбэк, если HID недоступен.
    private func recomputeSummaryKeys() {
        guard let smc else { return }
        smcSummaryKeys = smc.tempKeys.filter { $0.name.hasPrefix("Tg") }
        if client == nil {
            smcSummaryKeys += smc.tempKeys.filter {
                $0.name.hasPrefix("Tp") || $0.name.hasPrefix("Tc")
            }
        }
    }

    private func setupHID() {
        guard let create = PrivateAPI.hidClientCreate,
              let setMatching = PrivateAPI.hidSetMatching,
              let copyServices = PrivateAPI.hidCopyServices,
              let copyProperty = PrivateAPI.hidCopyProperty,
              let client = create(kCFAllocatorDefault) else { return }
        // AppleARMIODevice temperature sensors
        let matching: [String: Int] = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 5,
        ]
        _ = setMatching(client, matching as CFDictionary)

        // Кэшируем сервисы и их имена один раз — CopyServices/CopyProperty
        // на каждом тике не нужны
        guard let services = copyServices(client)?.takeRetainedValue() else { return }
        var list: [(UnsafeMutableRawPointer, String)] = []
        for i in 0..<CFArrayGetCount(services) {
            guard let raw = CFArrayGetValueAtIndex(services, i) else { continue }
            let service = UnsafeMutableRawPointer(mutating: raw)
            guard let nameRef = copyProperty(service, "Product" as CFString)?.takeRetainedValue(),
                  let name = nameRef as? String else { continue }
            list.append((service, name))
        }
        self.client = client
        self.hidServicesArray = services
        self.hidServices = list
    }

    var isAvailable: Bool { client != nil || smc != nil }

    func readAll() -> [ThermalSensor] {
        var raw: [(name: String, value: Double)] = readHID()
        if let smc {
            let smcValues = fullSensorList
                ? smc.readAll()
                : smc.read(keys: smcSummaryKeys)
            raw += smcValues.map { ("SMC \($0.name)", $0.value) }

            // GPU работает, а правдоподобных GPU-датчиков нет — набор
            // динамических SMC-ключей устарел, переобнаруживаем (с кулдауном)
            let gpuPlausible = smcValues.contains {
                $0.name.hasPrefix("Tg") && Self.plausible($0.value)
            }
            if gpuActiveHint, !gpuPlausible,
               Date().timeIntervalSince(lastDiscovery) > Self.rediscoverCooldown {
                smc.rediscover()
                recomputeSummaryKeys()
                lastDiscovery = Date()
            }
        }
        raw.sort { $0.name < $1.name }

        // Уникальные id для дубликатов имён (у HID бывает по два клиента на сенсор)
        var seen: [String: Int] = [:]
        return raw.map { item in
            let n = (seen[item.name] ?? 0) + 1
            seen[item.name] = n
            return ThermalSensor(
                id: n == 1 ? item.name : "\(item.name)#\(n)",
                name: item.name,
                value: item.value
            )
        }
    }

    private func readHID() -> [(name: String, value: Double)] {
        guard let copyEvent = PrivateAPI.hidCopyEvent,
              let getFloat = PrivateAPI.hidGetFloatValue else { return [] }

        var result: [(String, Double)] = []
        result.reserveCapacity(hidServices.count)
        for (service, name) in hidServices {
            guard let event = copyEvent(service, PrivateAPI.kIOHIDEventTypeTemperature, 0, 0) else { continue }
            let value = getFloat(event, PrivateAPI.temperatureField)
            // Балансируем +1 retain от Copy-функции
            Unmanaged<AnyObject>.fromOpaque(event).release()

            // Отсекаем мусорные показания
            guard value > 0, value < 130 else { continue }
            result.append((name, value))
        }
        return result
    }

    /// Температура похожа на реальную температуру кристалла. Датчики
    /// обесточенных доменов читают ~1.5°C — отсекаем.
    private static func plausible(_ v: Double) -> Bool {
        v >= 10 && v <= 125
    }

    /// Сводка: горячая точка CPU и GPU по паттернам имён сенсоров.
    func summary(from sensors: [ThermalSensor]) -> (cpu: Double?, gpu: Double?) {
        var cpuValues: [Double] = []
        var gpuValues: [Double] = []

        for s in sensors where Self.plausible(s.value) {
            let n = s.name.lowercased()
            if n.contains("gpu") || n.hasPrefix("smc tg") {
                gpuValues.append(s.value)
            } else if n.contains("tdie") || n.contains("cpu")
                        || n.hasPrefix("pacc") || n.hasPrefix("eacc")
                        || n.contains("soc mtr temp") {
                cpuValues.append(s.value)
            }
        }

        // Фолбэки, если основные паттерны не нашлись на этом чипе
        if cpuValues.isEmpty {
            cpuValues = sensors
                .filter { Self.plausible($0.value) }
                .filter { $0.name.lowercased().hasPrefix("smc tp") || $0.name.lowercased().hasPrefix("smc tc") }
                .map(\.value)
        }
        if cpuValues.isEmpty {
            cpuValues = sensors
                .filter { Self.plausible($0.value) }
                .filter {
                    let n = $0.name.lowercased()
                    return !n.contains("battery") && !n.contains("nand") && !n.contains("gas gauge")
                }
                .map(\.value)
        }
        return (cpuValues.max(), gpuValues.max())
    }
}
