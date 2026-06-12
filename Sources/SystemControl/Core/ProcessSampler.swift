import Foundation
import Darwin

// Сэмплер CPU-времени всех процессов через libproc.
// Копит снапшоты и отдаёт топ по среднему потреблению за окно времени,
// опционально группируя процессы по ответственному приложению
// (как Activity Monitor группирует хелперы Chrome/Safari).

struct PIDKey: Hashable {
    let pid: pid_t
    let start: UInt64 // время старта процесса — защита от переиспользования pid
}

struct ProcMeta {
    let name: String
    let path: String
    let responsiblePid: pid_t
}

struct EnergyEntry: Identifiable, Equatable {
    let id: String
    let pid: pid_t
    let name: String
    let path: String
    let cpuPercent: Double   // среднее за окно; >100% при многопоточности
    let processCount: Int    // размер группы для режима Apps
    let isGroup: Bool
}

private struct Snapshot {
    let time: TimeInterval
    let cpu: [PIDKey: UInt64] // суммарное CPU-время процесса, наносекунды
}

final class ProcessSampler: @unchecked Sendable {

    static let maxHistory: TimeInterval = 80 // с запасом больше максимального окна в 1 минуту

    private let lock = NSLock()
    private var snapshots: [Snapshot] = []
    private var meta: [PIDKey: ProcMeta] = [:]

    private let timebaseFactor: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    private(set) var processCount: Int = 0

    // MARK: - Сэмплирование

    func sample(at now: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        var pids = allPids()
        guard !pids.isEmpty else { return }

        var cpu: [PIDKey: UInt64] = [:]
        cpu.reserveCapacity(pids.count)
        var seenKeys = Set<PIDKey>()
        seenKeys.reserveCapacity(pids.count)

        for pid in pids where pid > 0 {
            guard let usage = cpuTime(of: pid) else { continue }
            let key = PIDKey(pid: pid, start: usage.start)
            cpu[key] = usage.ns
            seenKeys.insert(key)

            if metaMissing(for: key) {
                let m = readMeta(pid: pid)
                lock.lock(); meta[key] = m; lock.unlock()
            }
        }
        pids.removeAll()

        lock.lock()
        snapshots.append(Snapshot(time: now, cpu: cpu))
        let cutoff = now - Self.maxHistory
        while snapshots.count > 2, snapshots[0].time < cutoff {
            snapshots.removeFirst()
        }
        // Чистим метаданные умерших процессов, чтобы не текла память
        if meta.count > cpu.count * 3 {
            var alive = seenKeys
            for snap in snapshots { alive.formUnion(snap.cpu.keys) }
            meta = meta.filter { alive.contains($0.key) }
        }
        processCount = cpu.count
        lock.unlock()
    }

    // MARK: - Агрегация за окно

    func top(window: TimeInterval, groupByApps: Bool, limit: Int) -> [EnergyEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard let current = snapshots.last, snapshots.count >= 2 else { return [] }

        let targetTime = current.time - window
        // Базовый снапшот: последний из тех, что не моложе границы окна
        var baseIndex = 0
        for (i, snap) in snapshots.enumerated() {
            if snap.time <= targetTime { baseIndex = i } else { break }
        }
        let base = snapshots[baseIndex]
        guard current.time - base.time > 0.2 else { return [] }

        // Среднее потребление за окно для каждого живого процесса
        var usage: [PIDKey: Double] = [:]
        for (key, nowNS) in current.cpu {
            var deltaNS: Double
            var deltaT: Double
            if let baseNS = base.cpu[key] {
                deltaNS = Double(nowNS) - Double(baseNS)
                deltaT = current.time - base.time
            } else {
                // Процесс появился внутри окна — считаем от его первого снапшота
                guard let first = firstAppearance(of: key, after: baseIndex) else { continue }
                deltaNS = Double(nowNS) - Double(first.ns)
                deltaT = current.time - first.time
                guard deltaT > 0.2 else { continue }
            }
            guard deltaNS > 0 else { continue }
            usage[key] = deltaNS / (deltaT * 1_000_000_000) * 100
        }

        var entries: [EnergyEntry]
        if groupByApps {
            var groups: [pid_t: (cpu: Double, count: Int, topKey: PIDKey, topCpu: Double)] = [:]
            for (key, value) in usage {
                let owner = meta[key]?.responsiblePid ?? key.pid
                if var g = groups[owner] {
                    g.cpu += value
                    g.count += 1
                    if value > g.topCpu { g.topKey = key; g.topCpu = value }
                    groups[owner] = g
                } else {
                    groups[owner] = (value, 1, key, value)
                }
            }
            entries = groups.map { owner, g in
                let ownerKey = meta.keys.first { $0.pid == owner }
                let m = ownerKey.flatMap { meta[$0] } ?? meta[g.topKey]
                return EnergyEntry(
                    id: "app-\(owner)",
                    pid: owner,
                    name: m?.name ?? "pid \(owner)",
                    path: m?.path ?? "",
                    cpuPercent: g.cpu,
                    processCount: g.count,
                    isGroup: g.count > 1
                )
            }
        } else {
            entries = usage.map { key, value in
                let m = meta[key]
                return EnergyEntry(
                    id: "proc-\(key.pid)-\(key.start)",
                    pid: key.pid,
                    name: m?.name ?? "pid \(key.pid)",
                    path: m?.path ?? "",
                    cpuPercent: value,
                    processCount: 1,
                    isGroup: false
                )
            }
        }

        return entries
            .filter { $0.cpuPercent >= 0.01 }
            .sorted { $0.cpuPercent > $1.cpuPercent }
            .prefix(limit)
            .map { $0 }
    }

    /// Фактическая глубина накопленной истории, секунды.
    var historyDepth: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let first = snapshots.first, let last = snapshots.last else { return 0 }
        return last.time - first.time
    }

    private func firstAppearance(of key: PIDKey, after index: Int) -> (ns: UInt64, time: TimeInterval)? {
        for i in (index + 1)..<snapshots.count {
            if let ns = snapshots[i].cpu[key] { return (ns, snapshots[i].time) }
        }
        return nil
    }

    private func metaMissing(for key: PIDKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return meta[key] == nil
    }

    // MARK: - libproc

    private func allPids() -> [pid_t] {
        let bytesNeeded = proc_listallpids(nil, 0)
        guard bytesNeeded > 0 else { return [] }
        let capacity = Int(bytesNeeded) / MemoryLayout<pid_t>.size + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = pids.withUnsafeMutableBytes { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count))
        }
        guard written > 0 else { return [] }
        return Array(pids.prefix(Int(written)))
    }

    /// CPU-время процесса (user+system) в наносекундах + время старта.
    private func cpuTime(of pid: pid_t) -> (ns: UInt64, start: UInt64)? {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) { ptr -> Bool in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reb in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, reb) == 0
            }
        }
        guard ok else { return nil }
        let machTime = info.ri_user_time &+ info.ri_system_time
        let ns = UInt64(Double(machTime) * timebaseFactor)
        return (ns, info.ri_proc_start_abstime)
    }

    private func readMeta(pid: pid_t) -> ProcMeta {
        var pathBuf = [CChar](repeating: 0, count: 4096)
        let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        let path = pathLen > 0 ? String(cString: pathBuf) : ""

        var name: String
        if !path.isEmpty {
            name = (path as NSString).lastPathComponent
        } else {
            var nameBuf = [CChar](repeating: 0, count: 256)
            let nameLen = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            name = nameLen > 0 ? String(cString: nameBuf) : "pid \(pid)"
        }

        var responsible = pid
        if let fn = PrivateAPI.responsiblePid {
            let r = fn(pid)
            if r > 0 { responsible = r }
        }
        return ProcMeta(name: name, path: path, responsiblePid: responsible)
    }
}
