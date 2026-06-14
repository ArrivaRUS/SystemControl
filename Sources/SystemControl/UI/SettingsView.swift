import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var state: AppState

    @State private var launchAtLogin = false
    @State private var loginError: String?
    @State private var sensorsExpanded = false

    private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    // ImageRenderer (--snapshot) не отрисовывает содержимое ScrollView
    private static let snapshotMode = ProcessInfo.processInfo.arguments.contains("--snapshot")

    private var intervalBinding: Binding<Int> {
        Binding(
            get: {
                AppState.intervalChoices.firstIndex { $0.seconds == state.updateInterval } ?? 1
            },
            set: { state.updateInterval = AppState.intervalChoices[$0].seconds }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Шапка настроек
            HStack(spacing: 8) {
                IconButton(systemName: "chevron.left", help: "Back") {
                    isPresented = false
                }
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            scrollContainer {
                VStack(spacing: 10) {
                    settingsCard {
                        toggleRow(
                            icon: "sparkles",
                            title: "Launch at login",
                            isOn: Binding(
                                get: { launchAtLogin },
                                set: { setLaunchAtLogin($0) }
                            ),
                            disabled: !isBundled
                        )
                        if !isBundled {
                            hint("Available when running as SystemControl.app")
                        }
                        if let loginError {
                            hint(loginError, color: Theme.red)
                        }
                        divider
                        toggleRow(
                            icon: "thermometer.medium",
                            title: "Temperature in menu bar",
                            isOn: $state.menuBarShowsTemp
                        )
                        divider
                        toggleRow(
                            icon: "bolt.fill",
                            title: "Power draw in menu bar (on AC)",
                            isOn: $state.menuBarShowsPower
                        )
                        divider
                        HStack {
                            rowLabel(icon: "arrow.triangle.2.circlepath", title: "Refresh rate")
                            Spacer()
                            PillPicker(
                                options: AppState.intervalChoices.map(\.label),
                                selection: intervalBinding,
                                fontSize: 9.5
                            )
                        }
                        .padding(.vertical, 2)
                    }

                    // Все сенсоры
                    settingsCard {
                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                sensorsExpanded.toggle()
                            }
                            state.setSensorListVisible(sensorsExpanded)
                        } label: {
                            HStack {
                                rowLabel(
                                    icon: "sensor.fill",
                                    title: sensorsExpanded
                                        ? "All thermal sensors (\(state.sensors.count))"
                                        : "All thermal sensors"
                                )
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(sensorsExpanded ? 0 : -90))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if sensorsExpanded {
                            divider
                            if state.sensors.isEmpty {
                                hint("No sensors detected")
                            }
                            ForEach(state.sensors) { sensor in
                                HStack {
                                    Text(sensor.name)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text(String(format: "%.1f°", sensor.value))
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Theme.tempColor(sensor.value))
                                }
                                .padding(.vertical, 1)
                            }
                        }
                    }

                    VStack(spacing: 2) {
                        HStack(spacing: 0) {
                            Text("System Control 1.2.2 · by Alex Kovalev · ")
                            GitHubLink()
                        }
                        Text("Energy is CPU time averaged over the window")
                    }
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panelBackground)
        .onAppear { refreshLoginStatus() }
        .onDisappear { state.setSensorListVisible(false) }
    }

    // MARK: - Строительные блоки

    @ViewBuilder
    private func scrollContainer(@ViewBuilder content: () -> some View) -> some View {
        if Self.snapshotMode {
            content().frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView(showsIndicators: false) { content() }
        }
    }

    @ViewBuilder
    private func settingsCard(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.cardStroke, lineWidth: 1)
            )
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    private func rowLabel(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.amber)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
        }
    }

    private func toggleRow(icon: String, title: String, isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        HStack {
            rowLabel(icon: icon, title: title)
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.ember)
                .labelsHidden()
                .disabled(disabled)
        }
        .opacity(disabled ? 0.5 : 1)
    }

    private func hint(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(color.opacity(0.85))
    }

    // MARK: - Launch at login

    private func refreshLoginStatus() {
        guard isBundled else { return }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        loginError = nil
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enable
        } catch {
            loginError = error.localizedDescription
            refreshLoginStatus()
        }
    }
}

// Кликабельная ссылка «GitHub» в футере — открывает репозиторий в браузере
private struct GitHubLink: View {
    static let url = URL(string: "https://github.com/ArrivaRUS/SystemControl")!
    @State private var hovered = false

    var body: some View {
        Text("GitHub")
            .foregroundStyle(hovered ? Theme.sky : Theme.sky.opacity(0.85))
            .underline(hovered)
            .onHover { h in
                hovered = h
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onTapGesture { NSWorkspace.shared.open(Self.url) }
            .help("Open the project on GitHub")
    }
}
