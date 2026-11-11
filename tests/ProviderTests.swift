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
        check(controller.tabs.tabViewItems.count == 4, "All settings tabs present")
        check(controller.window?.toolbarStyle == .preference, "Native preferences toolbar")
        print("PASS: provider requests, endpoint isolation, SSE error/truncation handling, conversational context, copy geometry and native preferences")
    }
    static func tryValue<T>(_ body: () throws -> T) -> T { try! body() }
}
