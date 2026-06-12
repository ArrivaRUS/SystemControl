import Foundation
import IOKit

// Загрузка GPU из PerformanceStatistics акселератора (AGX* конформит
// IOAccelerator). Драйвер сам ведёт счётчик утилизации — читаем без root.
// Доступ только с очереди сэмплера; сервис неизменяем после init.
final class GPULoad: @unchecked Sendable {

    private var service: io_registry_entry_t = 0

    private static let utilizationKeys = [
        "Device Utilization %",
        "GPU Activity(%)",
        "Renderer Utilization %",
    ]

    init() {
        service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator")
        )
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    var isAvailable: Bool { service != 0 }

    func sample() -> Double? {
        guard service != 0 else { return nil }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let perf = dict["PerformanceStatistics"] as? [String: Any] else { return nil }

        for key in Self.utilizationKeys {
            if let v = perf[key] as? Int { return min(100, max(0, Double(v))) }
            if let v = perf[key] as? Double { return min(100, max(0, v)) }
        }
        return nil
    }
}
