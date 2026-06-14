import SwiftUI
import AppKit

struct SystemControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MainPanelView(isFloating: false)
                .environmentObject(state)
        } label: {
            MenuBarLabel()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.window)
    }
}

// Временная отладка: unified log не показывает NSLog этого приложения
func hcDebugLog(_ message: String) {
    let line = "\(Date()) \(message)\n"
    let path = "/tmp/systemcontrol_debug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) { handle.write(data) }
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: false, encoding: .utf8)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Утилита живёт только в menu bar — без иконки в доке
        NSApp.setActivationPolicy(.accessory)

        // Внешний хук (Shortcuts/CLI): переключить плавающую панель.
        // Селекторный API: block-вариант не задаёт suspensionBehavior,
        // и фоновое accessory-приложение не получает уведомления вовсе.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(togglePanelNotification),
            name: Notification.Name("com.arrivarus.systemcontrol.togglePanel"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        hcDebugLog("launched, toggle observer registered")
    }

    @objc private func togglePanelNotification(_ note: Notification) {
        hcDebugLog("togglePanel notification received")
        Task { @MainActor in PanelController.shared.toggle() }
    }

    // Повторный `open /Applications/SystemControl.app` тоже переключает панель —
    // надёжный хук без XPC-гонок
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        hcDebugLog("reopen — toggling floating panel")
        Task { @MainActor in PanelController.shared.toggle() }
        return false
    }
}

// Лейбл в menu bar:
//   одно значение  →  🔥62°  (одна строка, крупный шрифт)
//   два значения   →  🔥62°  (две строки, мелкий шрифт: градусы сверху,
//                      ⚡96W    ваты снизу)
// Всё собрано в ОДИН составной Text (строки разделены \n): статус-айтем
// MenuBarExtra не пересчитывает ширину для появившихся позже соседних
// view (контент обрезается при переходе батарея → провод), а одиночный
// Text ресайзится корректно — и в одну строку, и в две.
struct MenuBarLabel: View {
    @EnvironmentObject var state: AppState

    private var tempText: String? {
        guard state.menuBarShowsTemp, let t = state.cpuTemp else { return nil }
        return "\(Int(t.rounded()))°"
    }
    private var wattsText: String? {
        guard state.menuBarShowsPower, let b = state.menuBattery,
              b.plugged, let w = b.watts else { return nil }
        return "\(w)W"
    }

    var body: some View {
        let temp = tempText
        let watts = wattsText
        let twoLine = (temp != nil && watts != nil)
        return label(temp: temp, watts: watts, twoLine: twoLine)
            .font(.system(size: twoLine ? 9 : 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }

    private func label(temp: String?, watts: String?, twoLine: Bool) -> Text {
        if let temp, let watts {
            // Две строки одним Text — корректный ресайз ширины
            return Text(Image(systemName: "flame.fill")) + Text(" \(temp)\n")
                 + Text(Image(systemName: "bolt.fill")) + Text(" \(watts)")
        }
        var result = Text(Image(systemName: "flame.fill"))
        if let temp {
            result = result + Text(" \(temp)")
        } else if let watts {
            result = result + Text(" ") + Text(Image(systemName: "bolt.fill")) + Text(" \(watts)")
        }
        return result
    }
}
