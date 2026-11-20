import Foundation
import AppKit

@main struct CloudAIConsentTests {
    @MainActor static func main() async throws {
        let suite = "nous-consent-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let previousStore = CloudAIConsent.store
        let previousPrompt = CloudAIConsent.prompt
        CloudAIConsent.store = defaults
        defer {
            CloudAIConsent.store = previousStore
            CloudAIConsent.prompt = previousPrompt
            defaults.removePersistentDomain(forName: suite)
        }
        CloudAIConsent.prompt = { _, _ in true }
        precondition(CloudAIConsent.allows("127.0.0.1", defaults: defaults), "Localhost does not need a prompt")
        precondition(CloudAIConsent.allows("localhost", defaults: defaults), "localhost alias is local")
        precondition(CloudAIConsent.allows("::1", defaults: defaults), "IPv6 loopback is local")
        precondition(CloudAIConsent.allows("[::1]", defaults: defaults), "Bracketed IPv6 loopback is local")
        precondition(!CloudAIConsent.allows("api.openai.com", defaults: defaults), "Cloud hosts start denied")
        precondition(!CloudAIConsent.allows("", defaults: defaults), "An empty host is never allowed")
        precondition(!CloudAIConsent.allows("   ", defaults: defaults), "Whitespace is not a host")
        var prompted = false
        CloudAIConsent.prompt = { _, _ in prompted = true; return false }
        try await CloudAIConsent.ensureAllowed(provider: .custom, host: "127.0.0.1", defaults: defaults)
        precondition(!prompted, "Localhost must not show a cloud-AI prompt")
        do {
            try await CloudAIConsent.ensureAllowed(provider: .openai, host: "  ", defaults: defaults)
            fatalError("A missing host must not send")
        } catch { }
        CloudAIConsent.prompt = { _, _ in true }
        try await CloudAIConsent.ensureAllowed(provider: .openai, host: "api.openai.com", defaults: defaults)
        precondition(CloudAIConsent.allows("api.openai.com", defaults: defaults), "An accepted prompt is remembered")
        prompted = false
        CloudAIConsent.prompt = { _, _ in prompted = true; return false }
        try await CloudAIConsent.ensureAllowed(provider: .openai, host: "API.OpenAI.com")
        precondition(!prompted && CloudAIConsent.allows("api.openai.com"), "Remembered hosts match case-insensitively via store")
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
        print("PASS: cloud AI consent local auto-allow, empty host, prompt remember/deny and revoke")
    }
}
