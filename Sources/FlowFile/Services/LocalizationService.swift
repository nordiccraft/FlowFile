import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case norwegian = "nb"
    case english = "en"
    case swedish = "sv"
    case danish = "da"
    case german = "de"

    var id: String { rawValue }

    var resolvedCode: String {
        switch self {
        case .norwegian: return "nb"
        case .english: return "en"
        case .swedish: return "sv"
        case .danish: return "da"
        case .german: return "de"
        case .system:
            for preferred in Locale.preferredLanguages {
                let lower = preferred.lowercased()
                if lower.hasPrefix("nb") || lower.hasPrefix("nn") || lower.hasPrefix("no") {
                    return "nb"
                } else if lower.hasPrefix("sv") {
                    return "sv"
                } else if lower.hasPrefix("da") {
                    return "da"
                } else if lower.hasPrefix("de") {
                    return "de"
                } else if lower.hasPrefix("en") {
                    return "en"
                }
            }
            return "en"
        }
    }

    var resolvedIsNorwegian: Bool {
        resolvedCode == "nb"
    }

    var locale: Locale {
        switch resolvedCode {
        case "nb": return Locale(identifier: "nb_NO")
        case "sv": return Locale(identifier: "sv_SE")
        case "da": return Locale(identifier: "da_DK")
        case "de": return Locale(identifier: "de_DE")
        default: return Locale(identifier: "en_US")
        }
    }

    func displayName(in current: AppLanguage) -> String {
        switch self {
        case .system:
            return LocalizationCenter.shared.localized(
                "Automatic (follow macOS)",
                fallback: current.resolvedIsNorwegian ? "Automatisk (følg macOS)" : "Automatic (follow macOS)"
            )
        case .norwegian:
            return "Norsk (Bokmål)"
        case .english:
            return "English"
        case .swedish:
            return "Svenska"
        case .danish:
            return "Dansk"
        case .german:
            return "Deutsch"
        }
    }
}

@Observable
final class LocalizationCenter {
    static let shared = LocalizationCenter()

    var currentLanguage: AppLanguage = {
        let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: raw) ?? .system
    }() {
        didSet {
            revision &+= 1
        }
    }

    private(set) var revision: Int = 0

    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var cachedBundles: [String: Bundle] = [:]

    var isNorwegian: Bool {
        currentLanguage.resolvedIsNorwegian
    }

    var locale: Locale {
        currentLanguage.locale
    }

    /// Safe lookup of `<code >.lproj` supporting both packaged `FlowFile.app` bundles and `swift test`.
    private func languageBundle(for code: String) -> Bundle? {
        lock.lock()
        if let cached = cachedBundles[code] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var found: Bundle?

        // 1. Direct .lproj in Bundle.main (e.g. FlowFile.app/Contents/Resources/sv.lproj)
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let b = Bundle(path: path) {
            found = b
        }

        // 2. SwiftPM resource bundle copied into FlowFile.app/Contents/Resources/FlowFile_FlowFile.bundle
        if found == nil,
           let resBundleURL = Bundle.main.resourceURL?.appendingPathComponent("FlowFile_FlowFile.bundle"),
           let resBundle = Bundle(url: resBundleURL),
           let path = resBundle.path(forResource: code, ofType: "lproj"),
           let b = Bundle(path: path) {
            found = b
        }

        // 3. SwiftPM resource bundle next to main bundle (e.g. CLI executable dir)
        if found == nil {
            let siblingURL = Bundle.main.bundleURL.appendingPathComponent("FlowFile_FlowFile.bundle")
            if let resBundle = Bundle(url: siblingURL),
               let path = resBundle.path(forResource: code, ofType: "lproj"),
               let b = Bundle(path: path) {
                found = b
            }
        }

        // 4. Fallback to SwiftPM Bundle.module (for `swift test` / `swift run`)
        if found == nil {
            // Only touch Bundle.module when not running inside a packaged .app bundle without sibling resource bundle
            let isAppBundle = Bundle.main.bundleURL.pathExtension == "app"
            if !isAppBundle,
               let path = Bundle.module.path(forResource: code, ofType: "lproj"),
               let b = Bundle(path: path) {
                found = b
            }
        }

        if let found {
            lock.lock()
            cachedBundles[code] = found
            lock.unlock()
        }
        return found
    }

    private static let missingSentinel = "\u{0000}__FLOWFILE_L10N_MISSING__\u{0000}"

    /// Looks up a key in the active language's `Localizable.strings`, falling back to `fallback` (or `key`).
    func localized(_ key: String, fallback: String? = nil) -> String {
        _ = revision
        let code = currentLanguage.resolvedCode
        if let bundle = languageBundle(for: code) {
            let value = bundle.localizedString(forKey: key, value: Self.missingSentinel, table: nil)
            if value != Self.missingSentinel {
                return value
            }
        }
        return fallback ?? key
    }

    /// Multi-language translation helper.
    /// - For `nb`: returns `nb` (or `nb.lproj` override if present).
    /// - For `en`: returns `en`.
    /// - For `sv`, `da`, `de`: looks up `en` in `<lang>.lproj/Localizable.strings`, falling back to `en`.
    func tr(_ nb: String, _ en: String) -> String {
        _ = revision
        let code = currentLanguage.resolvedCode
        if code == "nb" {
            return nb
        }
        if code == "en" {
            return en
        }
        if let bundle = languageBundle(for: code) {
            let value = bundle.localizedString(forKey: en, value: Self.missingSentinel, table: nil)
            if value != Self.missingSentinel {
                return value
            }
        }
        return en
    }

    /// Formatted multi-language translation helper using printf-style format strings.
    func trFormat(_ nbFormat: String, _ enFormat: String, _ args: CVarArg...) -> String {
        let format = tr(nbFormat, enFormat)
        return String(format: format, locale: locale, arguments: args)
    }
}

/// Global shorthand for multi-language strings used in models, services, and AppKit views.
@inline(__always)
func tr(_ nb: String, _ en: String) -> String {
    LocalizationCenter.shared.tr(nb, en)
}
