import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case norwegian = "nb"
    case english = "en"

    var id: String { rawValue }

    var resolvedIsNorwegian: Bool {
        switch self {
        case .norwegian:
            return true
        case .english:
            return false
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return preferred.hasPrefix("nb") || preferred.hasPrefix("nn") || preferred.hasPrefix("no")
        }
    }

    func displayName(in current: AppLanguage) -> String {
        let nb = current.resolvedIsNorwegian
        switch self {
        case .system:
            return nb ? "Automatisk (følg macOS)" : "Automatic (follow macOS)"
        case .norwegian:
            return "Norsk (Bokmål)"
        case .english:
            return "English"
        }
    }
}

final class LocalizationCenter {
    static let shared = LocalizationCenter()

    var currentLanguage: AppLanguage = {
        let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: raw) ?? .system
    }()

    var isNorwegian: Bool {
        currentLanguage.resolvedIsNorwegian
    }

    func tr(_ nb: String, _ en: String) -> String {
        isNorwegian ? nb : en
    }
}

/// Global shorthand for bilingual strings (Norwegian / English) used in models and AppKit views.
@inline(__always)
func tr(_ nb: String, _ en: String) -> String {
    LocalizationCenter.shared.isNorwegian ? nb : en
}
