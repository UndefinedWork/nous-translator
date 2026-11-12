import Foundation
import AppKit

@main struct CloudAIConsentTests {
    @MainActor static func main() async throws {
        let suite = "nous-consent-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        CloudAIConsent.prompt = { _, _ in true }
        precondition(CloudAIConsent.allows("127.0.0.1", defaults: defaults), "Localhost does not need a prompt")
        precondition(CloudAIConsent.allows("localhost", defaults: defaults), "localhost alias is local")
        precondition(!CloudAIConsent.allows("api.openai.com", defaults: defaults), "Cloud hosts start denied")
        try await CloudAIConsent.ensureAllowed(provider: .openai, host: "api.openai.com", defaults: defaults)
        precondition(CloudAIConsent.allows("api.openai.com", defaults: defaults), "An accepted prompt is remembered")
        CloudAIConsent.prompt = { _, _ in false }
        do {
            try await CloudAIConsent.ensureAllowed(provider: .deepseek, host: "api.deepseek.com", defaults: defaults)
            fatalError("A declined prompt must not send")
        } catch { }
        precondition(!CloudAIConsent.allows("api.deepseek.com", defaults: defaults), "A declined host stays denied")
        CloudAIConsent.revoke("api.openai.com", defaults: defaults)
        precondition(!CloudAIConsent.allows("api.openai.com", defaults: defaults), "Revoke removes a host")
        CloudAIConsent.allow("example.com", defaults: defaults)
        CloudAIConsent.revokeAll(defaults: defaults)
        precondition(CloudAIConsent.allowedHosts(defaults: defaults).isEmpty, "Revoke all clears remembered hosts")
        print("PASS: cloud AI consent local auto-allow, prompt remember/deny and revoke")
    }
}
