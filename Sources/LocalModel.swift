import Foundation

@MainActor final class LocalModel {
    static let shared = LocalModel()
    static let conversation = LocalModel(conversation: true)
    private let isConversation: Bool
    init(conversation: Bool = false) { isConversation = conversation }
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nous Translator")
    static var defaultModelURL: URL { directory.appendingPathComponent("Index-Translate-2B.Q4_K_M.gguf") }
    static func needsInitialModelSetup(defaults: UserDefaults = .standard, defaultModel: URL? = nil) -> Bool {
        guard (defaults.string(forKey: "translationProvider") ?? "local") == "local" else { return false }
        let custom = defaults.string(forKey: "modelPath").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return !LocalModelFile.hasGGUFHeader(at: custom ?? defaultModel ?? defaultModelURL,
                                             minimumBytes: custom == nil ? 1_000_000_000 : 24)
    }
    private var process: Process?
    private var startup: Task<Void, Error>?
    private var port: Int { isConversation ? 18764 : 18763 }
    private let key = UUID().uuidString
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 300
        return URLSession(configuration: config)
    }()
    func stop() { startup?.cancel(); process?.terminate(); process = nil; startup = nil }
    private func ready() async throws {
        if let process, !process.isRunning { startup = nil; self.process = nil }
        if let startup { return try await startup.value }
        let task = Task { try await launch() }; startup = task
        do { try await task.value } catch { startup = nil; throw error }
    }
    private func launch() async throws {
        if process?.isRunning == true { return }
        let resources = Bundle.main.resourceURL!
        let binary = resources.appendingPathComponent("Runtime/llama-server")
        let model = UserDefaults.standard.string(forKey: isConversation ? "conversationModelPath" : "modelPath").flatMap { $0.isEmpty ? nil : $0 }.map { URL(fileURLWithPath: $0) } ?? Self.directory.appendingPathComponent("Index-Translate-2B.Q4_K_M.gguf")
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw ModelError.message(isConversation
                ? "未找到本地对话模型。请在 Settings → Models 中重新选择 GGUF 文件。"
                : "本地翻译模型尚未安装。请打开 Settings → Models，在 On This Mac 中点击 Download，或选择已有的 GGUF 文件。")
        }
        guard LocalModelFile.hasGGUFHeader(at: model) else {
            throw ModelError.message("模型文件不完整或格式不受支持。请在 Settings → Models 中重新下载模型，或选择有效的 GGUF 文件。")
        }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw ModelError.message("应用缺少本地运行组件。请重新下载并安装 Nous Translator。") }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let p = Process(); p.executableURL = binary
        p.environment = ProcessInfo.processInfo.environment.merging(["GGML_BACKEND_PATH": binary.deletingLastPathComponent().path]) { _, new in new }
        p.arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", String(port), "--alias", "Index-Translate-2B", "--api-key", key, "-ngl", "99", "-c", "16384", "--parallel", "1", "--jinja", "--chat-template-kwargs", "{\"enable_thinking\":false}"]
        let log = Self.directory.appendingPathComponent(isConversation ? "conversation-runtime.log" : "runtime.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        p.standardOutput = output; p.standardError = output
        try p.run(); process = p
        for _ in 0..<240 {
            try Task.checkCancellation()
            guard p.isRunning else { throw ModelError.message("本地模型启动失败，请查看 runtime.log。") }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!); request.timeoutInterval = 1
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        p.terminate(); throw ModelError.message("本地模型加载超时，请重试。")
    }
    func stream(messages: [[String: String]]) async throws -> URLSession.AsyncBytes {
        try await ready()
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model":"Index-Translate-2B", "messages":messages, "stream":true, "temperature":0, "max_tokens":4096, "chat_template_kwargs":["enable_thinking":false]])
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ModelError.message("本地模型请求失败，请缩短文本后重试。") }
        return bytes
    }
}

/// A cheap preflight for missing, truncated or wrongly selected files; llama.cpp validates tensor data.
enum LocalModelFile {
    static func hasGGUFHeader(at url: URL, minimumBytes: Int64 = 24) -> Bool {
        // A URL may cache the size of a file that was subsequently replaced by a download.
        var freshURL = url.resolvingSymlinksInPath()
        freshURL.removeAllCachedResourceValues()
        guard let values = try? freshURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, Int64(values.fileSize ?? 0) >= minimumBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8,
              header.prefix(4) == Data("GGUF".utf8) else { return false }
        let version = header.dropFirst(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        return version == 2 || version == 3
    }
}
enum ModelError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
