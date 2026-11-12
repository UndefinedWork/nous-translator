import AppKit
import Foundation

/// Records explicit permission before sending user text or images to a non-local model host.
/// Localhost endpoints used for a Custom API on this Mac do not prompt.
enum CloudAIConsent {
    static let hostsKey = "nous.allowedCloudAIHosts"
    /// Tests replace this to avoid panels. Production uses an AppKit confirmation.
    static var prompt: (@MainActor (String, String) async -> Bool) = confirmInAlert

    static func isLocalHost(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }

    static func allowedHosts(defaults: UserDefaults = .standard) -> [String] {
        (defaults.array(forKey: hostsKey) as? [String] ?? []).map { $0.lowercased() }
    }

    static func allows(_ host: String, defaults: UserDefaults = .standard) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return false }
        if isLocalHost(normalized) { return true }
        return allowedHosts(defaults: defaults).contains(normalized)
    }

    static func allow(_ host: String, defaults: UserDefaults = .standard) {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, !isLocalHost(normalized) else { return }
        var hosts = allowedHosts(defaults: defaults)
        if !hosts.contains(normalized) { hosts.append(normalized) }
        defaults.set(hosts, forKey: hostsKey)
    }

    static func revoke(_ host: String, defaults: UserDefaults = .standard) {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        defaults.set(allowedHosts(defaults: defaults).filter { $0 != normalized }, forKey: hostsKey)
    }

    static func revokeAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: hostsKey)
    }

    static func ensureAllowed(provider: ModelProvider, host: String,
                              defaults: UserDefaults = .standard) async throws {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { throw ModelError.message("The API address is missing a host.") }
        if allows(normalized, defaults: defaults) { return }
        let confirmed = await prompt(provider.title, normalized)
        if confirmed {
            allow(normalized, defaults: defaults)
            return
        }
        throw ModelError.message("Text was not sent. Allow \(provider.title) (\(normalized)) in Settings → Privacy to use this online model.")
    }

    @MainActor static func confirmInAlert(provider: String, host: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Send this text to \(provider)?"
        alert.informativeText = """
        The current request, including the text or image being processed and the app’s prompts, will be sent to \(host). That service is not operated by Nous Translator and may keep logs according to its own rules.

        This confirmation is remembered for \(host) until you revoke it in Settings → Privacy. Local models and Apple Vision stay on this Mac.
        """
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
