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
        // Фоновая авто-проверка обновлений (через 12с + каждые 6ч)
        UpdateChecker.shared.startAutoChecks()
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

// Лейбл в menu bar. Рисуется как NSImage точно по высоте строки меню
// (см. MenuBarRenderer): многострочный SwiftUI-текст MenuBarExtra не умещает
// в толщину бара и обрезает; NSImage нужной высоты раскладывается ровно.
//  • вкладка Battery → заряд + время (цветной)
//  • вкладка Energy → по выбору: температура / CPU% / GPU% / CPU+GPU
struct MenuBarLabel: View {
    @EnvironmentObject var state: AppState

    private var tempText: String? {
        guard let t = state.cpuTemp else { return nil }
        return "\(Int(t.rounded()))°"
    }
    private var wattsText: String? {
        guard state.menuBarShowsPower, let b = state.menuBattery,
              b.plugged, let w = b.watts else { return nil }
        return "\(w)W"
    }

    var body: some View {
        if state.tab == .battery, let b = state.menuBattery {
            Image(nsImage: MenuBarRenderer.batteryImage(b))
                .renderingMode(.original)
        } else if state.menuBarEnergyMode == .temperature {
            // Температура — монохромный template (адаптируется к теме бара)
            Image(nsImage: MenuBarRenderer.image(temp: tempText, watts: wattsText))
                .renderingMode(.template)
        } else {
            // Загрузка CPU/GPU — мини-графики истории (голубой/фиолетовый)
            Image(nsImage: MenuBarRenderer.loadImage(
                mode: state.menuBarEnergyMode,
                cpuHistory: state.menuCpuLoadHistory,
                gpuHistory: state.menuGpuLoadHistory))
                .renderingMode(.original)
        }
    }
}
