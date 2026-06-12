import Foundation
import Darwin

// Общая загрузка CPU по дельтам тиков host_statistics.
// Доступ только с очереди сэмплера.
final class SystemLoad: @unchecked Sendable {

    private var previous: host_cpu_load_info_data_t?

    func sample() -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reb, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        defer { previous = info }
        guard let prev = previous else { return nil }

        func delta(_ idx: Int) -> Double {
            let now = tick(info, idx)
            let before = tick(prev, idx)
            return Double(now &- before)
        }
        let user = delta(Int(CPU_STATE_USER))
        let system = delta(Int(CPU_STATE_SYSTEM))
        let nice = delta(Int(CPU_STATE_NICE))
        let idle = delta(Int(CPU_STATE_IDLE))
        let total = user + system + nice + idle
        guard total > 0 else { return nil }
        return (user + system + nice) / total * 100
    }

    private func tick(_ info: host_cpu_load_info_data_t, _ idx: Int) -> UInt32 {
        switch idx {
        case Int(CPU_STATE_USER): return info.cpu_ticks.0
        case Int(CPU_STATE_SYSTEM): return info.cpu_ticks.1
        case Int(CPU_STATE_IDLE): return info.cpu_ticks.2
        default: return info.cpu_ticks.3 // nice
        }
    }
}
