import Foundation
import AppKit

// Проверка и установка обновлений через GitHub Releases.
//  • фоновая авто-проверка (через 12с после старта, затем каждые 6ч)
//  • накопленные release notes за все пропущенные версии (двуязычные)
//  • скачивание DMG с прогрессом, затем self-update (см. installUpdate)
@MainActor
final class UpdateChecker: ObservableObject {

    static let shared = UpdateChecker()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case downloading(progress: Double)
        case failed
    }

    struct ReleaseNote: Equatable, Identifiable {
        let version: String
        let date: String
        let body: String
        var id: String { version }
    }

    @Published var status: Status = .idle
    @Published var notes: [ReleaseNote] = []   // версии новее текущей, сверху новейшая
    @Published var history: [ReleaseNote] = [] // последние релизы (для просмотра в любой момент)
    @Published var historyLoading = false

    private static let repo = "ArrivaRUS/SystemControl"
    private var timer: Timer?
    private var downloader: UpdateDownloader?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var updateAvailable: Bool {
        if case .available = status { return true }
        return false
    }

    // MARK: - Авто-проверка

    func startAutoChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.check(silent: true) }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(silent: true) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Проверка

    /// silent: не показывать «Checking…»/«Up to date» в UI (для фоновых проверок)
    func check(silent: Bool = false) {
        if case .checking = status { return }
        if case .downloading = status { return }
        if !silent { status = .checking }
        Task {
            do {
                var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=30")!)
                req.setValue("SystemControl", forHTTPHeaderField: "User-Agent")
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    if !silent { status = .failed }; return
                }
                let releases = try JSONDecoder().decode([Release].self, from: data)
                let published = releases.filter { !$0.draft && !$0.prerelease }

                // Накопленные заметки за версии новее текущей
                let newer = published.filter { Self.isNewer(Self.ver($0.tag_name), than: currentVersion) }
                notes = newer.map {
                    ReleaseNote(version: Self.ver($0.tag_name),
                                date: String($0.published_at?.prefix(10) ?? ""),
                                body: $0.body ?? "")
                }.sorted { Self.isNewer($0.version, than: $1.version) }

                if let top = published.first, Self.isNewer(Self.ver(top.tag_name), than: currentVersion) {
                    let dmg = top.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
                    let url = dmg.flatMap { URL(string: $0.browser_download_url) }
                        ?? URL(string: top.html_url)!
                    status = .available(version: Self.ver(top.tag_name), url: url)
                } else if !silent {
                    status = .upToDate
                }
            } catch {
                if !silent { status = .failed }
            }
        }
    }

    // Загрузка последних релизов для просмотра notes в любой момент (даже на свежей)
    func loadHistory() {
        if historyLoading || !history.isEmpty { return }
        historyLoading = true
        Task {
            do {
                var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=10")!)
                req.setValue("SystemControl", forHTTPHeaderField: "User-Agent")
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { historyLoading = false; return }
                let releases = try JSONDecoder().decode([Release].self, from: data)
                history = releases.filter { !$0.draft && !$0.prerelease }.prefix(6).map {
                    ReleaseNote(version: Self.ver($0.tag_name),
                                date: String($0.published_at?.prefix(10) ?? ""),
                                body: $0.body ?? "")
                }
            } catch { }
            historyLoading = false
        }
    }

    // MARK: - Установка (скачать с прогрессом → подменить → перезапустить)

    func installUpdate(_ dmgURL: URL) {
        if case .downloading = status { return }
        status = .downloading(progress: 0)
        let installedBundle = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier

        let dl = UpdateDownloader()
        dl.onProgress = { [weak self] p in self?.status = .downloading(progress: p) }
        dl.onDone = { [weak self] fileURL in
            guard let self else { return }
            self.downloader = nil
            guard let dmg = fileURL,
                  let sz = try? FileManager.default.attributesOfItem(atPath: dmg.path)[.size] as? Int,
                  sz > 100_000 else { self.status = .failed; return }
            Task {
                do {
                    let staged = try await Task.detached(priority: .userInitiated) {
                        try Self.stageNewApp(dmgPath: dmg.path)
                    }.value
                    try Self.launchSwapHelper(stagedApp: staged, installedBundle: installedBundle,
                                              pid: pid, dmgPath: dmg.path)
                    NSApp.terminate(nil)
                } catch {
                    self.status = .failed
                }
            }
        }
        downloader = dl
        dl.start(dmgURL)
    }

    // MARK: - Извлечение и подмена бандла

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
        guard fm.fileExists(atPath: srcApp + "/Contents/Info.plist") else { throw UpdateError.noApp }

        let stageDir = NSTemporaryDirectory() + "sc-update-stage"
        try? fm.removeItem(atPath: stageDir)
        try fm.createDirectory(atPath: stageDir, withIntermediateDirectories: true)
        let staged = stageDir + "/" + appName
        try run("/bin/cp", ["-R", srcApp, staged])
        return staged
    }

    private nonisolated static func launchSwapHelper(stagedApp: String, installedBundle: String,
                                                     pid: Int32, dmgPath: String) throws {
        let stageDir = (stagedApp as NSString).deletingLastPathComponent
        let script = """
        #!/bin/sh
        APP="\(installedBundle)"
        SRC="\(stagedApp)"
        for i in $(seq 1 100); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done
        sleep 0.3
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

    // MARK: - Помощники

    private enum UpdateError: Error { case process(String), noApp }

    private static func ver(_ tag: String) -> String {
        tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

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
        let body: String?
        let published_at: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browser_download_url: String }
    }
}

// Тело релиза может нести оба языка, разделённые <!--RU--> / <!--EN-->.
// Возвращает секцию для языка; если маркеров нет — всё тело.
func localizedReleaseBody(_ body: String, _ lang: AppLang) -> String {
    guard let en = body.range(of: "<!--EN-->") else { return body }
    let enPart = String(body[en.upperBound...])
    var ruPart = String(body[..<en.lowerBound])
    if let ru = ruPart.range(of: "<!--RU-->") { ruPart = String(ruPart[ru.upperBound...]) }
    return (lang == .en ? enPart : ruPart).trimmingCharacters(in: .whitespacesAndNewlines)
}

// Лёгкая чистка markdown для показа (заголовки/жирный/код → текст, нормализуем буллеты)
func tidyReleaseNotes(_ s: String) -> String {
    var lines: [String] = []
    for raw in s.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
        var l = raw.trimmingCharacters(in: .whitespaces)
        while l.hasPrefix("#") { l.removeFirst() }
        l = l.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("- ") || l.hasPrefix("* ") { l = "•  " + l.dropFirst(2) }
        l = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        lines.append(l)
    }
    var res: [String] = []
    for l in lines where !(l.isEmpty && (res.last?.isEmpty ?? true)) { res.append(l) }
    return res.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

// Загрузчик с прогрессом; держать сильную ссылку до onDone.
final class UpdateDownloader: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Double) -> Void)?
    var onDone: ((URL?) -> Void)?
    private var session: URLSession?

    func start(_ url: URL) {
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        var req = URLRequest(url: url)
        req.setValue("SystemControl", forHTTPHeaderField: "User-Agent")
        session?.downloadTask(with: req).resume()
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
        guard total > 0 else { return }
        let p = Double(written) / Double(total)
        DispatchQueue.main.async { self.onProgress?(p) }
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = URL(fileURLWithPath: NSTemporaryDirectory() + "sc-update-dl.dmg")
        try? FileManager.default.removeItem(at: dest)
        let ok = (try? FileManager.default.moveItem(at: location, to: dest)) != nil
        let result = ok ? dest : nil
        DispatchQueue.main.async { self.onDone?(result) }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { DispatchQueue.main.async { self.onDone?(nil) } }
        s.finishTasksAndInvalidate()
    }
}
