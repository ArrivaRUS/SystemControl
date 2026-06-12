import AppKit
import SwiftUI

// Плавающая панель "поверх всех окон": не активирует приложение,
// видна во всех Spaces и поверх полноэкранных окон, таскается за фон.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        PanelController.shared.close()
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    private var panel: FloatingPanel?

    var isShown: Bool { panel != nil }

    func show() {
        if panel != nil { return }

        let size = MainPanelView.panelSize
        let content = MainPanelView(isFloating: true)
            .environmentObject(AppState.shared)

        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self

        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        // Позиция: под menu bar, у правого края экрана (рядом со статус-иконкой)
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let origin = NSPoint(
                x: vf.maxX - size.width - 14,
                y: vf.maxY - size.height - 10
            )
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()
        self.panel = panel
        hcDebugLog("floating panel shown")
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        // Отцепляем SwiftUI-дерево немедленно: иначе при задержавшемся
        // dealloc окна оно продолжило бы пересчитываться на каждом тике
        panel.contentView = NSView()
        panel.close()
        hcDebugLog("floating panel closed")
    }

    func toggle() {
        isShown ? close() : show()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.panel = nil
        }
    }
}
