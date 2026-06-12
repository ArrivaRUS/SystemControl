import SwiftUI
import AppKit

// Диагностический режим: `SystemControl --snapshot [path]`
// Собирает данные несколько секунд и рендерит панель оффскрин в PNG.
@MainActor
func runSnapshot(to path: String) {
    _ = NSApplication.shared // инициализация AppKit для иконок/рендера
    let state = AppState.shared
    state.panelAppeared() // оффскрин-рендер = «видимый» UI, иначе публикации заглушены

    print("collecting samples…")
    RunLoop.main.run(until: Date().addingTimeInterval(7))
    print("entries: \(state.entries.count), cpu: \(state.cpuTemp ?? -1), gpu: \(state.gpuTemp ?? -1)")

    let main = MainPanelView(isFloating: true)
        .environmentObject(state)
        .environment(\.colorScheme, .dark)
    render(main, to: path)

    let battery = MainPanelView(isFloating: true, initialTab: .battery)
        .environmentObject(state)
        .environment(\.colorScheme, .dark)
    render(battery, to: (path as NSString).deletingPathExtension + "_battery.png")

    let settings = SettingsView(isPresented: .constant(true))
        .frame(width: MainPanelView.panelSize.width, height: MainPanelView.panelSize.height)
        .environmentObject(state)
        .environment(\.colorScheme, .dark)
    render(settings, to: (path as NSString).deletingPathExtension + "_settings.png")

    // Лейбл menu bar — что именно увидит пользователь в статус-баре
    print("menuBattery: \(String(describing: state.menuBattery))")
    let label = MenuBarLabel()
        .environmentObject(state)
        .environment(\.colorScheme, .dark)
        .padding(8)
        .background(Color.black)
    render(label, to: (path as NSString).deletingPathExtension + "_label.png")
}

@MainActor
private func render(_ view: some View, to path: String) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2

    guard let nsImage = renderer.nsImage,
          let tiff = nsImage.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("snapshot failed for \(path)")
        return
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("snapshot written to \(path)")
    } catch {
        print("write failed: \(error)")
    }
}
