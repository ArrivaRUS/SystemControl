import AppKit
import Foundation
import IOKit.ps

// Режим электропитания (Energy Mode) и состояние удержания заряда.
//
// Чтение — бесплатное и без root:
//   • powermode  — из IOPMCopyActivePMPreferences (dlsym, символ не экспортирован в Swift).
//     ГРАБЛЯ: ключ материализуется, только если значение ОТЛИЧАЕТСЯ от дефолта,
//     поэтому его отсутствие означает .automatic, а не «не смогли прочитать».
//   • LPM Active / Optimized Battery Charging Engaged — из IOPSCopyPowerSourcesInfo.
//
// Запись — только root: «pmset must be run as root in order to modify any settings»,
// поэтому смена режима идёт через системный диалог авторизации (см. PowerModeControl).

enum PowerModeKind: Int, CaseIterable, Equatable {
    case automatic = 0
    case low = 1
    case high = 2

    /// Дословно как в System Settings → Аккумулятор → «Режим энергопотребления»,
    /// чтобы пользователь видел ровно те же слова, что и в системе.
    var title: String {
        switch self {
        case .automatic: return tr("Automatic", "Автоматически")
        case .low:       return tr("Low Power", "Энергосбережение")
        case .high:      return tr("High Power", "Высокая мощность")
        }
    }

    /// Иконки тоже системные: полная батарея / подсевшая батарея / перемотка.
    var icon: String {
        switch self {
        case .automatic: return "battery.100percent"
        case .low:       return "battery.25percent"
        case .high:      return "forward.fill"
        }
    }
}

struct PowerModeState: Equatable {
    var mode: PowerModeKind = .automatic
    /// Живое состояние экономии: система может включить её сама (низкий заряд).
    var lpmActive = false
    /// macOS придерживает зарядку (оптимизированная зарядка / лимит 80%).
    var optimizedCharging = false
    /// High Power Mode есть только на MacBook Pro с чипами Pro/Max.
    var highSupported = false
}

enum PowerModeReader {

    private typealias CopyPrefsFn = @convention(c) () -> Unmanaged<CFDictionary>?

    private static let copyPrefs: CopyPrefsFn? = {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let sym = dlsym(h, "IOPMCopyActivePMPreferences") else { return nil }
        return unsafeBitCast(sym, to: CopyPrefsFn.self)
    }()

    /// High Power Mode доступен на ноутбуках с чипами Pro/Max (base-чипы его не имеют).
    static let highSupported: Bool = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return false }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let chip = String(cString: buf)
        return chip.contains("Max") || chip.contains("Pro")
    }()

    static func read(onBattery: Bool) -> PowerModeState {
        var st = PowerModeState()
        st.highSupported = highSupported

        // powermode для активного источника питания
        if let dict = copyPrefs?()?.takeRetainedValue() as? [String: Any] {
            let source = onBattery ? "Battery Power" : "AC Power"
            if let sub = dict[source] as? [String: Any] {
                // Ключ отсутствует = дефолт = Automatic
                let raw = (sub["powermode"] as? Int) ?? (sub["lowpowermode"] as? Int) ?? 0
                st.mode = PowerModeKind(rawValue: raw) ?? .automatic
            }
        }

        // Живые флаги из IOPS
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                      (d["Type"] as? String) == kIOPSInternalBatteryType else { continue }
                st.lpmActive = (d["LPM Active"] as? Int).map { $0 != 0 }
                    ?? (d["LPM Active"] as? Bool) ?? false
                let opt = (d["Optimized Battery Charging Engaged"] as? Bool) ?? false
                let dyn = (d["Dynamic End of Charging Engaged"] as? Bool) ?? false
                st.optimizedCharging = opt || dyn
            }
        }
        return st
    }
}

// MARK: - Смена режима (нужен root → системный диалог авторизации)

enum PowerModeControl {

    enum Result: Equatable {
        case ok
        case cancelled   // пользователь закрыл диалог авторизации
        case failed(String)
    }

    /// Меняет Energy Mode для обоих источников питания (`pmset -a`).
    /// Пароль вводится в СИСТЕМНОМ диалоге macOS — приложение его не видит
    /// и не хранит (osascript передаёт запрос Authorization Services).
    static func set(_ mode: PowerModeKind) -> Result {
        let script = "do shell script \"/usr/bin/pmset -a powermode \(mode.rawValue)\" "
                   + "with prompt \"System Control needs administrator rights to change the energy mode.\" "
                   + "with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = Pipe()
        do { try p.run() } catch { return .failed(error.localizedDescription) }
        p.waitUntilExit()
        if p.terminationStatus == 0 { return .ok }
        let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // -128 = User canceled: штатная отмена, не ошибка
        if err.contains("-128") || err.localizedCaseInsensitiveContains("cancel") { return .cancelled }
        return .failed(err.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Открывает System Settings → Аккумулятор.
    /// Там же живёт штатная кнопка «Зарядить полностью» — публичного API у неё нет.
    static func openBatterySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}
