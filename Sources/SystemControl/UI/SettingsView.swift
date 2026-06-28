import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var state: AppState

    @State private var launchAtLogin = false
    @State private var loginError: String?
    @State private var sensorsExpanded = false
    @State private var notesExpanded = false
    @ObservedObject private var updater = UpdateChecker.shared

    private var langBinding: Binding<Int> {
        Binding(get: { state.lang == .en ? 0 : 1 },
                set: { state.lang = $0 == 0 ? .en : .ru })
    }

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

    private var energyModeBinding: Binding<Int> {
        Binding(
            get: {
                AppState.energyModeChoices.firstIndex { $0.mode == state.menuBarEnergyMode } ?? 0
            },
            set: { state.menuBarEnergyMode = AppState.energyModeChoices[$0].mode }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Шапка настроек
            HStack(spacing: 8) {
                IconButton(systemName: "chevron.left", help: tr("Back", "Назад")) {
                    isPresented = false
                }
                Text(tr("Settings", "Настройки"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            scrollContainer {
                VStack(spacing: 10) {
                    settingsCard {
                        HStack {
                            rowLabel(icon: "globe", title: tr("Language", "Язык"))
                            Spacer()
                            PillPicker(options: ["EN", "RU"], selection: langBinding, fontSize: 9.5)
                        }
                        .padding(.vertical, 2)
                        divider
                        toggleRow(
                            icon: "sparkles",
                            title: tr("Launch at login", "Запуск при входе"),
                            isOn: Binding(
                                get: { launchAtLogin },
                                set: { setLaunchAtLogin($0) }
                            ),
                            disabled: !isBundled
                        )
                        if !isBundled {
                            hint(tr("Available when running as System Control.app",
                                    "Доступно при запуске как System Control.app"))
                        }
                        if let loginError {
                            hint(loginError, color: Theme.red)
                        }
                        divider
                        HStack {
                            rowLabel(icon: "menubar.rectangle", title: tr("Menu bar (Energy)", "В трее (Energy)"))
                            Spacer()
                            PillPicker(
                                options: AppState.energyModeChoices.map {
                                    $0.mode == .temperature ? tr("Temp", "Темп") : $0.label
                                },
                                selection: energyModeBinding,
                                fontSize: 9.5
                            )
                        }
                        .padding(.vertical, 2)
                        divider
                        toggleRow(
                            icon: "bolt.fill",
                            title: tr("Power draw in menu bar (on AC)", "Мощность в трее (на питании)"),
                            isOn: $state.menuBarShowsPower
                        )
                        divider
                        HStack {
                            rowLabel(icon: "arrow.triangle.2.circlepath", title: tr("Refresh rate", "Частота обновления"))
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
                                        ? tr("All thermal sensors", "Все термосенсоры") + " (\(state.sensors.count))"
                                        : tr("All thermal sensors", "Все термосенсоры")
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
                                hint(tr("No sensors detected", "Сенсоры не найдены"))
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

                    // Версия + проверка обновлений + release notes
                    settingsCard {
                        updateRow
                        if updater.updateAvailable, !updater.notes.isEmpty {
                            divider
                            releaseNotesView
                        }
                    }

                    HStack(spacing: 0) {
                        Text("System Control \(updater.currentVersion) · by Alex Kovalev · ")
                        GitHubLink()
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
        .onAppear {
            refreshLoginStatus()
            // Тихо проверить обновления при открытии настроек — апдейт всплывёт сам
            if case .idle = updater.status { updater.check(silent: true) }
        }
        .onDisappear { state.setSensorListVisible(false) }
    }

    // MARK: - Обновления

    @ViewBuilder
    private var updateRow: some View {
        HStack(spacing: 8) {
            rowLabel(icon: "arrow.down.circle", title: tr("Version", "Версия") + " \(updater.currentVersion)")
            Spacer()
            switch updater.status {
            case .checking:
                Text(tr("Checking…", "Проверка…"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            case .downloading(let p):
                Text(tr("Downloading", "Загрузка") + " \(Int(p * 100))%")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            case .available(let v, let url):
                updateButton(tr("Update to", "Обновить до") + " \(v)", fill: Theme.ember) {
                    updater.installUpdate(url)
                }
            case .upToDate:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.mint)
                    Text(tr("Up to date", "Последняя версия"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            default:
                updateButton(updater.status == .failed ? tr("Retry", "Повторить")
                                                       : tr("Check for Updates", "Проверить обновления"),
                             fill: Color.white.opacity(0.12), textColor: .primary) { updater.check() }
            }
        }
        .animation(.easeOut(duration: 0.18), value: updater.status)
    }

    // Накопленные release notes (за все пропущенные версии), сворачиваемые
    @ViewBuilder
    private var releaseNotesView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { notesExpanded.toggle() }
            } label: {
                HStack {
                    rowLabel(icon: "sparkles.rectangle.stack", title: tr("What's new", "Что нового"))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(notesExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if notesExpanded {
                ForEach(updater.notes) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(note.version)" + (note.date.isEmpty ? "" : "  ·  \(note.date)"))
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.amber)
                        let body = tidyReleaseNotes(localizedReleaseBody(note.body, state.lang))
                        Text(body.isEmpty ? "—" : body)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }
            }
        }
    }

    private func updateButton(_ label: String, fill: Color, textColor: Color = .white,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(textColor)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(fill))
        }
        .buttonStyle(.plain)
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
