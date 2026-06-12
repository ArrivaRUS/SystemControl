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
struct MenuBarLabel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
            if state.menuBarShowsTemp, let t = state.cpuTemp {
                segment("\(Int(t.rounded()))°")
            }
            if state.menuBarShowsPower, let b = state.menuBattery,
               b.plugged, let w = b.watts {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                segment("\(w)W")
            }
        }
    }

    private func segment(_ text: String) -> Text {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
    }
}
