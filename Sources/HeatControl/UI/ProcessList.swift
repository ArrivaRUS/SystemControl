import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProcessListView: View {
    @EnvironmentObject var state: AppState
    @State private var hoveredID: String?
    @State private var confirmID: String?
    @State private var confirmTimeout: Task<Void, Never>?

    // ImageRenderer (режим --snapshot) не отрисовывает содержимое ScrollView —
    // для оффскрин-рендера используем обычный VStack
    private static let snapshotMode = ProcessInfo.processInfo.arguments.contains("--snapshot")

    var body: some View {
        Group {
            if Self.snapshotMode {
                listContent.frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView(showsIndicators: false) { listContent }
            }
        }
        // Анимируем список только при смене СОСТАВА/ПОРЯДКА строк, а не на
        // каждом тике с новыми процентами — иначе панель почти постоянно
        // рендерит пружины на 120 Гц и греет сама себя
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: state.entries.map(\.id))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: confirmID)
    }

    private var listContent: some View {
            VStack(spacing: 1) {
                if state.entries.isEmpty {
                    EmptyListState()
                        .padding(.top, 70)
                } else {
                    let maxCpu = state.entries.map(\.cpuPercent).max() ?? 1
                    ForEach(Array(state.entries.enumerated()), id: \.element.id) { index, entry in
                        ProcessRow(
                            entry: entry,
                            rank: index + 1,
                            fraction: entry.cpuPercent / max(maxCpu, 0.001),
                            hovered: hoveredID == entry.id,
                            confirming: confirmID == entry.id,
                            onHover: { inside in
                                hoveredID = inside ? entry.id : (hoveredID == entry.id ? nil : hoveredID)
                            },
                            onAskKill: { askKill(entry.id) },
                            onKill: { force in
                                confirmID = nil
                                state.kill(entry, force: force)
                            },
                            onCancel: { confirmID = nil }
                        )
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
    }

    private func askKill(_ id: String) {
        confirmID = id
        confirmTimeout?.cancel()
        confirmTimeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { confirmID = nil }
        }
    }
}

// MARK: - Строка

private struct ProcessRow: View {
    let entry: EnergyEntry
    let rank: Int
    let fraction: Double
    let hovered: Bool
    let confirming: Bool
    let onHover: (Bool) -> Void
    let onAskKill: () -> Void
    let onKill: (_ force: Bool) -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Text("\(rank)")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(rank <= 3 ? Theme.amber.opacity(0.9) : Color.secondary.opacity(0.55))
                .frame(width: 13, alignment: .trailing)

            Image(nsImage: AppIconCache.shared.icon(for: entry))
                .resizable()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(AppIconCache.shared.displayName(for: entry))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary.opacity(0.8))
            }

            Spacer(minLength: 6)

            if confirming {
                ConfirmCluster(onKill: onKill, onCancel: onCancel)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            } else {
                if hovered {
                    KillButton(action: onAskKill)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                VStack(alignment: .trailing, spacing: 3.5) {
                    Text(percentText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(percentColor)
                    EnergyBar(fraction: fraction)
                        .frame(width: 64, height: 3.5)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(confirming ? Theme.red.opacity(0.07) : Color.white.opacity(hovered ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .help(entry.path.isEmpty ? entry.name : entry.path)
    }

    private var subtitle: String {
        if entry.isGroup { return "\(entry.processCount) processes" }
        return "pid \(entry.pid)"
    }

    private var percentText: String {
        entry.cpuPercent >= 99.95
            ? "\(Int(entry.cpuPercent.rounded()))%"
            : String(format: "%.1f%%", entry.cpuPercent)
    }

    private var percentColor: Color {
        if entry.cpuPercent >= 120 { return Theme.red }
        if entry.cpuPercent >= 50 { return Theme.amber }
        return Color.primary.opacity(0.88)
    }
}

private struct EnergyBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.075))
                Capsule()
                    .fill(Theme.flameGradient)
                    .frame(width: max(3, geo.size.width * CGFloat(max(0, min(1, fraction)))))
            }
        }
        // Короткая локальная анимация ширины — вместо пружины на всю строку
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

private struct KillButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .heavy))
                .foregroundStyle(hovered ? .white : Theme.red)
                .frame(width: 21, height: 21)
                .background(Circle().fill(Theme.red.opacity(hovered ? 0.85 : 0.16)))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Terminate")
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

private struct ConfirmCluster: View {
    let onKill: (_ force: Bool) -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            CapsuleButton(label: "Quit", fill: Color.white.opacity(0.12), textColor: .primary) {
                onKill(false)
            }
            CapsuleButton(label: "Force", fill: Theme.red.opacity(0.88), textColor: .white) {
                onKill(true)
            }
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .heavy))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
    }
}

private struct CapsuleButton: View {
    let label: String
    let fill: Color
    let textColor: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(textColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(Capsule().fill(fill).brightness(hovered ? 0.12 : 0))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

// MARK: - Пустое состояние

private struct EmptyListState: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: state.historyDepth < 3 ? "hourglass" : "leaf.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(state.historyDepth < 3 ? Color.secondary : Theme.mint.opacity(0.8))
            Text(state.historyDepth < 3 ? "Warming up…" : "All quiet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if state.historyDepth >= 3 {
                Text("Nothing is burning energy right now")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
    }
}

// MARK: - Кэш иконок

final class AppIconCache {
    static let shared = AppIconCache()

    private var cache: [String: NSImage] = [:]
    private var nameCache: [String: String] = [:]

    /// Человекочитаемое имя: localizedName приложения,
    /// иначе последний компонент reverse-DNS ("com.apple.WebKit.WebContent" → "WebContent").
    func displayName(for entry: EnergyEntry) -> String {
        let key = "\(entry.pid)-\(entry.name)"
        if let cached = nameCache[key] { return cached }

        var name = entry.name
        if let app = NSRunningApplication(processIdentifier: entry.pid),
           let localized = app.localizedName, !localized.isEmpty {
            name = localized
        } else if name.contains("."), name.lowercased().hasPrefix("com.") || name.lowercased().hasPrefix("org.") {
            name = name.components(separatedBy: ".").last ?? name
        }
        if nameCache.count > 600 { nameCache.removeAll() }
        nameCache[key] = name
        return name
    }
    private let genericIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .unixExecutable)
        icon.size = NSSize(width: 24, height: 24)
        return icon
    }()

    func icon(for entry: EnergyEntry) -> NSImage {
        let key = entry.path.isEmpty ? "pid-fallback" : entry.path
        if let cached = cache[key] { return cached }

        var icon: NSImage?
        if let app = NSRunningApplication(processIdentifier: entry.pid), let appIcon = app.icon {
            icon = appIcon
        } else if !entry.path.isEmpty {
            // Для бинарей внутри .app берём иконку бандла
            if let range = entry.path.range(of: ".app/") {
                let bundlePath = String(entry.path[..<range.lowerBound]) + ".app"
                icon = NSWorkspace.shared.icon(forFile: bundlePath)
            } else if FileManager.default.fileExists(atPath: entry.path) {
                icon = NSWorkspace.shared.icon(forFile: entry.path)
            }
        }

        let result = icon ?? genericIcon
        result.size = NSSize(width: 24, height: 24)
        if cache.count > 400 { cache.removeAll() }
        cache[key] = result
        return result
    }
}
