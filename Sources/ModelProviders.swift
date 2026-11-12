import Foundation
import Security
import CryptoKit

 enum ModelProvider: String, CaseIterable, Identifiable {
    case unconfigured, local, openai, deepseek, custom
    var id: String { rawValue }
    var title: String {
        switch self { case .unconfigured: return "Choose a model…"; case .local: return "On This Mac"; case .openai: return "OpenAI"; case .deepseek: return "DeepSeek"; case .custom: return "Custom API" }
    }
    var baseURL: String { switch self { case .openai: return "https://api.openai.com/v1"; case .deepseek: return "https://api.deepseek.com"; default: return "" } }
}
enum ModelPurpose: String { case translation, conversation }
enum TranslationResponseMode: String, CaseIterable, Identifiable {
    case fast, modelDefault
    var id: String { rawValue }
    var title: String { self == .fast ? "Fast" : "Model default" }
    static func load(defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: "translationResponseMode") ?? "") ?? .fast
    }
    func reasoningEffort(provider: ModelProvider, model: String) -> String? {
        guard self == .fast, provider == .openai else { return nil }
        // Only send overrides to documented model families. Unknown/custom models retain
        // their provider defaults. Preserve the user's model and paid service tier.
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ name: String) -> Bool {
            model == name || model.range(of: "^" + NSRegularExpression.escapedPattern(for: name) + "-\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil
        }
        if ["gpt-6.1-terra", "gpt-6-sol", "gpt-6-luna"].contains(where: matches) { return "none" }
        if ["gpt-6-astra", "gpt-6.1-sol"].contains(where: matches) { return "low" }
        return nil
    }
}
struct APIProfile: Equatable {
    let provider: ModelProvider
    var baseURL: String
    var model: String
    var account: String { provider.rawValue + ":" + SHA256.hash(data: Data(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).utf8)).map { String(format: "%02x", $0) }.joined() }
    static func load(_ provider: ModelProvider, defaults: UserDefaults = .standard) -> APIProfile {
        APIProfile(provider: provider, baseURL: defaults.string(forKey: "api.\(provider.rawValue).url") ?? provider.baseURL,
                   model: defaults.string(forKey: "api.\(provider.rawValue).model") ?? "")
    }
    func save() { UserDefaults.standard.set(baseURL, forKey: "api.\(provider.rawValue).url"); UserDefaults.standard.set(model, forKey: "api.\(provider.rawValue).model") }
    func endpoint() throws -> URL {
        guard var parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else {
            throw ModelError.message("Enter an HTTPS API base URL (HTTP is allowed only for localhost).")
        }
        if provider != .custom && host != (provider == .openai ? "api.openai.com" : "api.deepseek.com") { throw ModelError.message("Use Custom API for a different server.") }
        var path = parts.path; while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        parts.path = path
        guard let url = parts.url else { throw ModelError.message("Invalid API URL.") }; return url
    }
    func request(messages: [[String: String]], key: String, purpose: ModelPurpose? = nil,
                 responseMode: TranslationResponseMode = .load()) throws -> URLRequest {
        try makeRequest(messages: messages.map { $0.mapValues { $0 as Any } }, key: key,
                        reasoningEffort: purpose == .translation ? responseMode.reasoningEffort(provider: provider, model: model) : nil)
    }
    func multimodalRequest(messages: [[String: Any]], key: String) throws -> URLRequest {
        guard provider == .openai || provider == .custom else {
            throw ModelError.message("Choose OpenAI or a Custom API with an image-capable model in Settings → Models.")
        }
        return try makeRequest(messages: messages, key: key, reasoningEffort: nil)
    }
    private func makeRequest(messages: [[String: Any]], key: String, reasoningEffort: String?) throws -> URLRequest {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelError.message("Enter a model ID in Settings → Models.") }
        guard !key.isEmpty else { throw ModelError.message("Save an API key in Settings → Models.") }
        var request = URLRequest(url: try endpoint(), timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
        if provider == .deepseek { body["thinking"] = ["type": "disabled"]; body["max_tokens"] = 4096 }
        else if provider == .openai { body["max_completion_tokens"] = 4096; body["store"] = false }
        if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
enum APIKeyStore {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.nous.translator.api", kSecAttrAccount as String: account]
    }
    static func read(_ account: String) throws -> String {
        var q = query(account); q[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8) else { throw ModelError.message("Unable to read the API key from Keychain (\(status)).") }
        return key
    }
    static func save(_ key: String, account: String) throws {
        let q = query(account)
        let data = Data(key.utf8)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ModelError.message("Could not save the API key to Keychain (\(status)).") }
    }
    static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ModelError.message("Could not remove the API key (\(status)).") }
    }
}
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor enum ModelRouter {
    static func provider(for purpose: ModelPurpose) -> ModelProvider {
        ModelProvider(rawValue: UserDefaults.standard.string(forKey: purpose.rawValue + "Provider") ?? "") ?? (purpose == .translation ? .local : .unconfigured)
    }
    static func validate(_ purpose: ModelPurpose) throws {
        let provider = provider(for: purpose)
        if provider == .unconfigured { throw ModelError.message("请在 Settings → Models 中选择对话模型。Index-Translate 是翻译专用模型，不能代替通用对话模型。") }
        if provider == .local && purpose == .conversation {
            guard let path = UserDefaults.standard.string(forKey: "conversationModelPath"), !path.isEmpty,
                  !path.lowercased().contains("index-translate"), FileManager.default.fileExists(atPath: path) else {
                throw ModelError.message("请选择一个本地通用对话 GGUF 模型，或在 Settings → Models 配置 OpenAI / DeepSeek。")
            }
        }
    }
    private static let delegate = NoRedirects()
    private static let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    static func stream(messages: [[String: String]], purpose: ModelPurpose,
                       progress: ((LocalModel.Progress) -> Void)? = nil) async throws -> URLSession.AsyncBytes {
        try validate(purpose)
        let provider = provider(for: purpose)
        if provider == .local { return try await (purpose == .translation ? LocalModel.shared : LocalModel.conversation).stream(messages: messages, progress: progress) }
        let profile = APIProfile.load(provider)
        progress?(.waitingForFirstToken)
        return try await remoteStream(profile: profile, messages: messages, purpose: purpose)
    }
    static func remoteStream(profile: APIProfile, messages: [[String: String]], purpose: ModelPurpose? = nil) async throws -> URLSession.AsyncBytes {
        let request = try profile.request(messages: messages, key: APIKeyStore.read(profile.account), purpose: purpose)
        return try await remoteStream(request: request, provider: profile.provider)
    }
    static func remoteStream(request: URLRequest, provider: ModelProvider) async throws -> URLSession.AsyncBytes {
        try Task.checkCancellation()
        let host = request.url?.host ?? ""
        try await CloudAIConsent.ensureAllowed(provider: provider, host: host)
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            bytes.task.cancel()
            let detail: String
            switch code { case 401,403: detail = "Check the API key and model access."; case 429: detail = "Rate limit or quota exceeded."; case 400,404,422: detail = "Check the base URL and model ID."; default: detail = "Please try again." }
            throw ModelError.message("\(provider.title) returned HTTP \(code). \(detail)")
        }
        return bytes
    }
}
struct CompletionAccumulator {
    var rejectRefusal = false
    var text = ""
    var finished = false
    mutating func receive(_ line: String) throws {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { finished = true; return }
        guard let data = payload.data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if json["error"] != nil { throw ModelError.message("The model returned a streaming error. Please try again.") }
        guard let choice = (json["choices"] as? [[String: Any]])?.first else { return }
        if let delta = choice["delta"] as? [String: Any] {
            if rejectRefusal, let refusal = delta["refusal"] as? String,
               !refusal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ModelError.message("The model declined this image recognition request. Try another image or recognition model.")
            }
            text += delta["content"] as? String ?? delta["refusal"] as? String ?? ""
        }
        if let reason = choice["finish_reason"] as? String {
            if reason == "length" { throw ModelError.message("The response reached the model's output limit. Please ask for a shorter response.") }
            if reason == "content_filter" { throw ModelError.message("The provider filtered this response.") }
            finished = true
        }
    }
    func result() throws -> String {
        guard finished else { throw ModelError.message("The response was interrupted. Please retry.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelError.message("No response was returned. Check the selected model.") }
        return text
    }
}
@MainActor enum CompletionReader {
    static func read(_ bytes: URLSession.AsyncBytes, rejectRefusal: Bool = false, update: (String) -> Void) async throws -> String {
        defer { bytes.task.cancel() }
        var accumulator = CompletionAccumulator(rejectRefusal: rejectRefusal); var paint = Date.distantPast
        for try await line in bytes.lines {
            try Task.checkCancellation(); try accumulator.receive(line)
            if Date().timeIntervalSince(paint) >= 0.05 { update(accumulator.text); paint = Date() }
            if line.trimmingCharacters(in: .whitespaces) == "data: [DONE]" { break }
        }
        try Task.checkCancellation()
        let result = try accumulator.result(); update(result); return result
    }
}
