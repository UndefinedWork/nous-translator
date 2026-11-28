import Foundation
import Security
import CryptoKit

enum ModelProvider: String, CaseIterable, Identifiable {
    case unconfigured, local, openai, deepseek, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unconfigured: return L10n.text("Choose a model…", zh: "选择模型…")
        case .local: return L10n.text("On This Mac", zh: "本机模型")
        case .openai: return "OpenAI"
        case .deepseek: return "DeepSeek"
        case .custom: return L10n.text("Custom API", zh: "自定义 API")
        }
    }
    var baseURL: String { switch self { case .openai: return "https://api.openai.com/v1"; case .deepseek: return "https://api.deepseek.com"; default: return "" } }
}
enum ModelPurpose: String { case translation, conversation }
enum TranslationResponseMode: String, CaseIterable, Identifiable {
    case fast, modelDefault
    var id: String { rawValue }
    var title: String {
        self == .fast
            ? L10n.text("Fast", zh: "快速")
            : L10n.text("Model default", zh: "模型默认")
    }
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
    func save(defaults: UserDefaults = .standard) {
        defaults.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "api.\(provider.rawValue).url")
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "api.\(provider.rawValue).model")
    }
    func endpoint() throws -> URL {
        guard var parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else {
            throw ModelError.message(L10n.text("Enter an HTTPS API base URL (HTTP is allowed only for localhost).",
                                               zh: "请输入 HTTPS 服务地址（仅允许本机 localhost 使用 HTTP）。"))
        }
        if provider != .custom && host != (provider == .openai ? "api.openai.com" : "api.deepseek.com") {
            throw ModelError.message(L10n.text("Use Custom API for a different server.",
                                               zh: "使用其他服务地址请选择“自定义 API”。"))
        }
        var path = parts.path; while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        parts.path = path
        guard let url = parts.url else {
            throw ModelError.message(L10n.text("Invalid API URL.", zh: "无效的 API 地址。"))
        }
        return url
    }
    func request(messages: [[String: String]], key: String, purpose: ModelPurpose? = nil,
                 responseMode: TranslationResponseMode = .load()) throws -> URLRequest {
        try makeRequest(messages: messages.map { $0.mapValues { $0 as Any } }, key: key,
                        reasoningEffort: purpose == .translation ? responseMode.reasoningEffort(provider: provider, model: model) : nil)
    }
    func multimodalRequest(messages: [[String: Any]], key: String) throws -> URLRequest {
        guard provider == .openai || provider == .custom else {
            throw ModelError.message(L10n.text("Choose OpenAI or a Custom API with an image-capable model in Settings → Images.",
                                               zh: "请在 Settings → Images 中选择 OpenAI 或支持图片的自定义 API。"))
        }
        return try makeRequest(messages: messages, key: key, reasoningEffort: nil)
    }
    private func makeRequest(messages: [[String: Any]], key: String, reasoningEffort: String?) throws -> URLRequest {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw ModelError.message(L10n.text("Enter a model ID in Settings → Models.",
                                               zh: "请在 Settings → Models 中填写模型 ID。"))
        }
        guard !key.isEmpty else {
            throw ModelError.message(L10n.text("Save an API key in Settings → Models.",
                                               zh: "请在 Settings → Models 中保存 API Key。"))
        }
        var request = URLRequest(url: try endpoint(), timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["model": trimmedModel, "messages": messages, "stream": true]
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
    /// Checks item existence without fetching secret bytes (avoids triggering Keychain read prompts).
    static func hasSavedKey(_ account: String) -> Bool {
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess
    }
    static func read(_ account: String) throws -> String {
        var q = query(account); q[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8) else {
            throw ModelError.message(L10n.text("Unable to read the API key from Keychain (\(status)).",
                                               zh: "无法从钥匙串读取 API Key（错误码 \(status)）。"))
        }
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
        guard status == errSecSuccess else {
            throw ModelError.message(L10n.text("Could not save the API key to Keychain (\(status)).",
                                               zh: "无法将 API Key 保存到钥匙串（错误码 \(status)）。"))
        }
    }
    static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ModelError.message(L10n.text("Could not remove the API key (\(status)).",
                                               zh: "无法删除 API Key（错误码 \(status)）。"))
        }
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
        if provider == .unconfigured {
            throw ModelError.message(L10n.text("Choose a conversation model in Settings → Models. Index-Translate is translation-only and cannot be used for general conversation.",
                                               zh: "请在 Settings → Models 中选择对话模型。Index-Translate 是翻译专用模型，不能代替通用对话模型。"))
        }
        if provider == .local && purpose == .conversation {
            guard let path = UserDefaults.standard.string(forKey: "conversationModelPath"), !path.isEmpty,
                  !path.lowercased().contains("index-translate"),
                  LocalModelFile.hasGGUFHeader(at: URL(fileURLWithPath: path)) else {
                throw ModelError.message(L10n.text("Select a valid local general-purpose GGUF model, or configure OpenAI / DeepSeek / Custom API in Settings → Models.",
                                                   zh: "请选择一个有效的本地通用对话 GGUF 模型，或在 Settings → Models 配置在线服务。"))
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
        let (bytes, response) = try await session.bytes(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let serverDetail = await readBoundedErrorDetail(from: bytes)
            bytes.task.cancel()
            let detail: String
            switch code {
            case 401, 403: detail = L10n.text("Check the API key and model access.", zh: "请检查 API Key 和模型权限。")
            case 429: detail = L10n.text("Rate limit or quota exceeded.", zh: "请求频率超限或额度不足。")
            case 400, 404, 422: detail = L10n.text("Check the base URL and model ID.", zh: "请检查服务地址、模型 ID 或参数兼容性。")
            default: detail = L10n.text("Please try again.", zh: "请稍后重试。")
            }
            let suffix = serverDetail.map { " (\($0))" } ?? ""
            throw ModelError.message("\(provider.title) HTTP \(code). \(detail)\(suffix)")
        }
        return bytes
    }

    /// Reads a short error snippet without blocking on servers that keep chunked connections open.
    private static func readBoundedErrorDetail(from bytes: URLSession.AsyncBytes) async -> String? {
        let reader = Task<Data, Never> {
            var buffer = Data()
            do {
                for try await byte in bytes {
                    buffer.append(byte)
                    if byte == 0x0A || buffer.count >= 2048 { break }
                }
            } catch {}
            return buffer
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            reader.cancel()
            bytes.task.cancel()
        }
        let data = await reader.value
        timer.cancel()
        return extractErrorDetail(from: data)
    }

    nonisolated static func extractErrorDetail(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return sanitizeDiagnostic(message)
            }
            if let error = json["error"] as? String {
                return sanitizeDiagnostic(error)
            }
            if let message = json["message"] as? String {
                return sanitizeDiagnostic(message)
            }
            if let detail = json["detail"] as? String {
                return sanitizeDiagnostic(detail)
            }
        }
        if let raw = String(data: data, encoding: .utf8) {
            return sanitizeDiagnostic(raw)
        }
        return nil
    }

    nonisolated static func sanitizeDiagnostic(_ raw: String) -> String? {
        let cleaned = raw
            .replacingOccurrences(of: #"[\r\n\t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"Bearer\s+[A-Za-z0-9._\-]+"#, with: "Bearer [redacted]", options: .regularExpression)
            .replacingOccurrences(of: #"sk-[A-Za-z0-9_\-]{12,}"#, with: "sk-[redacted]", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count <= 200 { return cleaned }
        return String(cleaned.prefix(199)) + "…"
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
        if let error = json["error"] {
            let detail: String?
            if let dict = error as? [String: Any], let message = dict["message"] as? String {
                detail = ModelRouter.sanitizeDiagnostic(message)
            } else if let message = error as? String {
                detail = ModelRouter.sanitizeDiagnostic(message)
            } else {
                detail = nil
            }
            if let detail {
                throw ModelError.message(L10n.text("The model returned a streaming error: \(detail)",
                                                   zh: "模型返回流式错误：\(detail)"))
            }
            throw ModelError.message(L10n.text("The model returned a streaming error. Please try again.",
                                               zh: "模型返回流式错误，请重试。"))
        }
        guard let choice = (json["choices"] as? [[String: Any]])?.first else { return }
        if let delta = choice["delta"] as? [String: Any] {
            if rejectRefusal, let refusal = delta["refusal"] as? String,
               !refusal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ModelError.message(L10n.text("The model declined this image recognition request. Try another image or recognition model.",
                                                   zh: "模型拒绝了该图片识别请求，请换一张图片或其他识别模型。"))
            }
            text += delta["content"] as? String ?? delta["refusal"] as? String ?? ""
        }
        if let reason = choice["finish_reason"] as? String {
            if reason == "length" {
                throw ModelError.message(L10n.text("The response reached the model's output limit. Please ask for a shorter response.",
                                                   zh: "回复达到模型输出上限，请尝试缩短内容。"))
            }
            if reason == "content_filter" {
                throw ModelError.message(L10n.text("The provider filtered this response.",
                                                   zh: "服务商过滤了此次回复。"))
            }
            finished = true
        }
    }
    func result() throws -> String {
        guard finished else {
            throw ModelError.message(L10n.text("The response was interrupted. Please retry.",
                                               zh: "回复被中断，请重试。"))
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelError.message(L10n.text("No response was returned. Check the selected model.",
                                               zh: "模型未返回内容，请检查所选模型。"))
        }
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
