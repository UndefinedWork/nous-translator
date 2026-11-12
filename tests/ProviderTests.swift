import Foundation
import AppKit
import SwiftUI

@main struct ProviderTests {
    @MainActor static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
        func rejects(_ body: () throws -> Void) { do { try body(); fatalError("Expected rejection") } catch {} }
        let openai = APIProfile(provider: .openai, baseURL: "https://api.openai.com/v1/", model: "user-selected-model")
        let request = try openai.request(messages: [["role": "user", "content": "Hello"]], key: "test-only-placeholder")
        check(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions", "OpenAI path")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        check(body["model"] as? String == "user-selected-model", "Preserve user model")
        check(body["temperature"] == nil && body["max_tokens"] == nil && body["max_completion_tokens"] != nil, "Compatible OpenAI parameters")
        func requestBody(_ model: String, purpose: ModelPurpose?, mode: TranslationResponseMode = .fast, provider: ModelProvider = .openai) throws -> [String: Any] {
            let p = APIProfile(provider: provider, baseURL: provider == .custom ? "https://example.com/v1" : provider.baseURL, model: model)
            return try JSONSerialization.jsonObject(with: p.request(messages: [], key: "test-only-placeholder", purpose: purpose, responseMode: mode).httpBody!) as! [String: Any]
        }
        for model in ["gpt-6.1-terra", "gpt-6.1-terra-2026-10-01", "gpt-6-sol", "gpt-6-luna"] {
            let fast = try requestBody(model, purpose: .translation)
            check(fast["reasoning_effort"] as? String == "none", "Fast translation avoids unnecessary reasoning on supported models")
            check(fast["model"] as? String == model && fast["service_tier"] == nil, "Keep model choice and do not select a paid priority tier")
            check(tryValue { try requestBody(model, purpose: .conversation) }["reasoning_effort"] == nil, "Conversation keeps its existing reasoning")
            check(tryValue { try requestBody(model, purpose: .translation, mode: .modelDefault) }["reasoning_effort"] == nil, "User can restore model default reasoning")
        }
        for model in ["gpt-6-astra", "gpt-6.1-sol"] {
            check(tryValue { try requestBody(model, purpose: .translation) }["reasoning_effort"] as? String == "low", "Models without none use supported low effort")
        }
        for model in ["unknown", "gpt-6.1-terra-custom", "gpt-4o", "gpt-6.1-terra-2026-01-01-preview"] {
            check(tryValue { try requestBody(model, purpose: .translation) }["reasoning_effort"] == nil, "Do not guess unsupported parameters")
        }
        check(tryValue { try requestBody("gpt-6.1-terra", purpose: .translation, provider: .custom) }["reasoning_effort"] == nil, "Custom servers retain defaults")
        let ds = APIProfile(provider: .deepseek, baseURL: "https://api.deepseek.com", model: "chosen-model")
        let dsRequest = try ds.request(messages: [], key: "test-only-placeholder")
        let dsBody = try JSONSerialization.jsonObject(with: dsRequest.httpBody!) as! [String: Any]
        check((dsBody["thinking"] as? [String: String])?["type"] == "disabled", "Disable DeepSeek thinking for fast responses")
        check(tryValue { try ds.endpoint().path } == "/chat/completions", "DeepSeek path")
        let custom = APIProfile(provider: .custom, baseURL: "http://127.0.0.1:1234/v1/chat/completions", model: "local")
        check(tryValue { try custom.endpoint().path } == "/v1/chat/completions", "Do not duplicate path")
        rejects { _ = try APIProfile(provider: .custom, baseURL: "http://example.com", model: "x").endpoint() }
        rejects { _ = try APIProfile(provider: .openai, baseURL: "https://example.com", model: "x").endpoint() }
        rejects { _ = try APIProfile(provider: .custom, baseURL: "https://user:secret@example.com/v1", model: "x").endpoint() }
        rejects { _ = try openai.request(messages: [], key: "") }
        check(custom.account != APIProfile(provider: .custom, baseURL: "http://127.0.0.1:4321/v1", model: "local").account, "Credentials scoped to endpoint")
        var stream = CompletionAccumulator()
        try stream.receive(": keepalive")
        try stream.receive("data: {\"choices\":[{\"delta\":{\"content\":\"你好\"},\"finish_reason\":null}]}")
        try stream.receive("data: {\"choices\":[{\"delta\":{\"content\":null},\"finish_reason\":\"stop\"}]}")
        check(tryValue { try stream.result() } == "你好", "SSE Unicode and null delta")
        rejects { _ = try CompletionAccumulator().result() }
        rejects { var s = CompletionAccumulator(); try s.receive("data: {\"choices\":[{\"finish_reason\":\"length\"}]}") }
        rejects { var s = CompletionAccumulator(); try s.receive("data: {\"error\":{\"message\":\"private server detail\"}}") }
        rejects { var s = CompletionAccumulator(rejectRefusal: true); try s.receive("data: {\"choices\":[{\"delta\":{\"refusal\":\"refused\"},\"finish_reason\":null}]}") }
        let history = [ChatMessage(role: "user", text: "你的心情呢？"), ChatMessage(role: "assistant", text: "", pending: true)]
        let messages = ConversationPrompt.messages(context: "A previous translation", history: history)
        check(messages.count == 2 && messages.last?["content"] == "你的心情呢？", "Keep latest user question; omit pending response")
        check(messages[0]["content"]!.contains("Only translate"), "Do not translate every conversation turn")
        _ = NSApplication.shared
        let before = NSHostingView(rootView: CopyGlyph(copied: false)).fittingSize
        let after = NSHostingView(rootView: CopyGlyph(copied: true)).fittingSize
        check(before == after && before == NSSize(width: 24, height: 24), "Copy glyph must never change layout")
        let controller = SettingsController()
        check(controller.tabs.tabStyle == .toolbar, "Native toolbar tabs")
        check(controller.tabs.tabViewItems.count == 6, "General, Models, Images, Permissions, Privacy and History tabs present")
        check(controller.window?.toolbarStyle == .preference, "Native preferences toolbar")
        print("PASS: provider requests, endpoint isolation, SSE error/truncation handling, conversational context, copy geometry and native preferences")
    }
    static func tryValue<T>(_ body: () throws -> T) -> T { try! body() }
}
