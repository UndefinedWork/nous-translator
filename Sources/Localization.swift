import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english, chinese
    var id: String { rawValue }
    static let storageKey = "appLanguage"

    var title: String {
        switch self {
        case .system: return L10n.text("System Default", zh: "跟随系统")
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .system
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}

enum L10n {
    private static let lock = NSLock()
    private static var testOverride: AppLanguage?

    static func withOverride<T>(_ language: AppLanguage?, perform: () throws -> T) rethrows -> T {
        lock.lock()
        let previous = testOverride
        testOverride = language
        lock.unlock()
        defer {
            lock.lock()
            testOverride = previous
            lock.unlock()
        }
        return try perform()
    }

    static var isChinese: Bool {
        lock.lock()
        let forced = testOverride
        lock.unlock()
        let selection = forced ?? AppLanguage.load()
        switch selection {
        case .english: return false
        case .chinese: return true
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
            return preferred.hasPrefix("zh")
        }
    }

    static func text(_ english: String, zh chinese: String) -> String {
        isChinese ? chinese : english
    }
}
