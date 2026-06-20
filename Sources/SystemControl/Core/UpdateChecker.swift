import Foundation
import AppKit

// Проверка обновлений через GitHub Releases API.
// Берём последний релиз, сравниваем версии; если новее — даём ссылку на DMG.
@MainActor
final class UpdateChecker: ObservableObject {

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case downloading
        case failed
    }

    private enum UpdateError: Error { case http, process(String), noApp }

    @Published var status: Status = .idle

    private static let repo = "ArrivaRUS/SystemControl"

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    func check() {
        if case .checking = status { return }
        status = .checking
        Task {
            do {
                // Список релизов, а не /releases/latest: последний эндпоинт
                // у GitHub иногда отвечает 504, а /releases стабилен.
                var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=10")!)
                req.setValue("SystemControl", forHTTPHeaderField: "User-Agent") // GitHub требует UA
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { status = .failed; return }
                let releases = try JSONDecoder().decode([Release].self, from: data)

                // Первый опубликованный (не черновик и не pre-release)
                guard let rel = releases.first(where: { !$0.draft && !$0.prerelease }) else {
                    status = .upToDate; return
                }
                let latest = rel.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let dmg = rel.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
                let target = dmg.flatMap { URL(string: $0.browser_download_url) }
                    ?? URL(string: rel.html_url)!

                status = Self.isNewer(latest, than: currentVersion)
                    ? .available(version: latest, url: target)
                    : .upToDate
            } catch {
                status = .failed
            }
        }
    }

    // Открывает загрузку DMG (или страницу релиза) в браузере по умолчанию
    func download(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: - Self-update «в один клик»
    // Приложение само качает DMG (без флага карантина → Gatekeeper молчит),
    // извлекает новый бандл, и отсоединённый скрипт после выхода приложения
    // подменяет бандл и перезапускает его.
    func installUpdate(_ dmgURL: URL) {
        if case .downloading = status { return }
        status = .downloading
        let installedBundle = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        Task {
            do {
                // 1) Скачать DMG (URLSession не ставит com.apple.quarantine)
                var req = URLRequest(url: dmgURL)
                req.setValue("SystemControl", forHTTPHeaderField: "User-Agent")
                let (tmp, resp) = try await URLSession.shared.download(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.http }

                let dmgPath = NSTemporaryDirectory() + "sc-update.dmg"
                try? FileManager.default.removeItem(atPath: dmgPath)
                try FileManager.default.moveItem(at: tmp, to: URL(fileURLWithPath: dmgPath))

                // 2) Смонтировать, извлечь .app, отмонтировать (в фоне — блокирующие вызовы)
                let staged = try await Task.detached(priority: .userInitiated) {
                    try Self.stageNewApp(dmgPath: dmgPath)
                }.value

                // 3) Запустить отсоединённый помощник и выйти — он подменит и перезапустит
                try Self.launchSwapHelper(stagedApp: staged, installedBundle: installedBundle,
                                          pid: pid, dmgPath: dmgPath)
                NSApp.terminate(nil)
            } catch {
                status = .failed
            }
        }
    }

    // Монтирует DMG, копирует .app в staging, отмонтирует. Возвращает путь к копии.
    private nonisolated static func stageNewApp(dmgPath: String) throws -> String {
        let fm = FileManager.default
        let mount = NSTemporaryDirectory() + "sc-update-mnt"
        try? fm.removeItem(atPath: mount)
        try fm.createDirectory(atPath: mount, withIntermediateDirectories: true)

        try run("/usr/bin/hdiutil", ["attach", dmgPath, "-nobrowse", "-readonly", "-mountpoint", mount])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount, "-force"]) }

        guard let appName = (try fm.contentsOfDirectory(atPath: mount)).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.noApp
        }
        let srcApp = mount + "/" + appName
        // Новый бандл реально извлёкся?
        guard fm.fileExists(atPath: srcApp + "/Contents/Info.plist") else { throw UpdateError.noApp }

        let stageDir = NSTemporaryDirectory() + "sc-update-stage"
        try? fm.removeItem(atPath: stageDir)
        try fm.createDirectory(atPath: stageDir, withIntermediateDirectories: true)
        let staged = stageDir + "/" + appName
        try run("/bin/cp", ["-R", srcApp, staged])
        return staged
    }

    // Скрипт-помощник: ждёт выхода приложения, безопасно подменяет бандл, перезапускает
    private nonisolated static func launchSwapHelper(stagedApp: String, installedBundle: String,
                                                     pid: Int32, dmgPath: String) throws {
        let stageDir = (stagedApp as NSString).deletingLastPathComponent
        let script = """
        #!/bin/sh
        APP="\(installedBundle)"
        SRC="\(stagedApp)"
        # дождаться выхода приложения
        for i in $(seq 1 100); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done
        sleep 0.3
        # сперва скопировать рядом — если не выйдет, старый бандл цел
        NEW="$APP.new"
        rm -rf "$NEW"
        if /bin/cp -R "$SRC" "$NEW"; then
          rm -rf "$APP"
          /bin/mv "$NEW" "$APP"
          /usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null
        fi
        rm -rf "\(stageDir)" "\(dmgPath)"
        open "$APP"
        """
        let scriptPath = NSTemporaryDirectory() + "sc-update.sh"
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        // Полностью отсоединяем worker, чтобы пережил выход приложения
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "nohup /bin/sh '\(scriptPath)' >/dev/null 2>&1 &"]
        try p.run()
    }

    @discardableResult
    private nonisolated static func run(_ launch: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else { throw UpdateError.process(out) }
        return out
    }

    // Семантическое сравнение "1.2.10" > "1.2.9"
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browser_download_url: String }
    }
}
