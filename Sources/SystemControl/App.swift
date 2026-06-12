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

// Лейбл в menu bar: 🔥62° ⚡96W
//  • температура CPU — всегда (если включена)
//  • на внешнем питании — мощность, потребляемая от адаптера
// Всё собрано в ОДИН составной Text: статус-айтем MenuBarExtra не
// пересчитывает ширину для появившихся позже соседних view (контент
// обрезается при переходе батарея → провод), а одиночный Text — ресайзит.
struct MenuBarLabel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        composed
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
    }

    private var composed: Text {
        var result = Text(Image(systemName: "flame.fill"))
        if state.menuBarShowsTemp, let t = state.cpuTemp {
            result = result + Text(" \(Int(t.rounded()))°")
        }
        if state.menuBarShowsPower, let b = state.menuBattery,
           b.plugged, let w = b.watts {
            result = result + Text("  ") + Text(Image(systemName: "bolt.fill")) + Text("\(w)W")
        }
        return result
    }
}
