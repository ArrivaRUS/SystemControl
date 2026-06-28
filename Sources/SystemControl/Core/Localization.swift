import Foundation

// Лёгкая локализация без .strings: инлайн tr(en, ru).
// Источник истины — AppState.lang; глобальное зеркало uiLang позволяет
// вызывать tr() и из не-View кода (kill-сообщения, рендер трея).
// SwiftUI-вьюхи наблюдают AppState, поэтому при смене языка перестраиваются сами.

enum AppLang: String, CaseIterable { case en, ru }

var uiLang: AppLang = {
    if let saved = UserDefaults.standard.string(forKey: "lang"), let l = AppLang(rawValue: saved) {
        return l
    }
    // Первый запуск — по системному языку
    let pref = Locale.preferredLanguages.first ?? "en"
    return pref.hasPrefix("ru") ? .ru : .en
}()

/// Строка для текущего языка интерфейса.
func tr(_ en: String, _ ru: String) -> String { uiLang == .ru ? ru : en }
