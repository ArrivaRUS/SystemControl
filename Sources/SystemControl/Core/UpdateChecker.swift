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
        case failed
    }

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
                var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
                req.setValue("SystemControl", forHTTPHeaderField: "User-Agent") // GitHub требует UA
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { status = .failed; return }
                let rel = try JSONDecoder().decode(Release.self, from: data)

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
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browser_download_url: String }
    }
}
