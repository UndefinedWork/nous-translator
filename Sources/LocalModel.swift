import Foundation
import Combine
import Darwin

@MainActor final class LocalModel: ObservableObject {
    enum State: Equatable { case stopped, loading, ready }
    enum Progress: Equatable { case loadingModel, waitingForFirstToken }
    static let keepReadyPreference = "keepLocalTranslationReady"
    static let shared = LocalModel()
    static let conversation = LocalModel(conversation: true)
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nous Translator")
    static var defaultModelURL: URL { directory.appendingPathComponent("Index-Translate-2B.Q4_K_M.gguf") }

    /// Injectable paths and short timeouts allow lifecycle tests without loading model weights.
    struct Configuration {
        var binary: URL
        var defaultModel: URL
        var port: Int
        var log: URL
        var idleTimeout: TimeInterval = 300
        var startupTimeout: TimeInterval = 120
        var observeMemoryPressure = true
    }
    @Published private(set) var state: State = .stopped
    private let isConversation: Bool
    private let defaults: UserDefaults
    private let configuration: Configuration
    private var process: Process?
    private var retiredProcesses: [Process] = []
    private var generation = UUID()
    private var startup: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var prewarmTask: Task<Void, Never>?
    private var prewarmID: UUID?
    private var idleTask: Task<Void, Never>?
    private var activeRequests: Set<UUID> = []
    private var requestTasks: [UUID: URLSessionDataTask] = [:]
    private var requestObservations: [UUID: NSKeyValueObservation] = [:]
    private var pressureSource: DispatchSourceMemoryPressure?
    private let key = UUID().uuidString
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 300
        return URLSession(configuration: config)
    }()

    init(conversation: Bool = false, defaults: UserDefaults = .standard, configuration: Configuration? = nil) {
        isConversation = conversation
        self.defaults = defaults
        self.configuration = configuration ?? Configuration(
            binary: (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("Runtime/llama-server"),
            defaultModel: Self.defaultModelURL, port: conversation ? 18764 : 18763,
            log: Self.directory.appendingPathComponent(conversation ? "conversation-runtime.log" : "runtime.log"))
        if self.configuration.observeMemoryPressure {
            let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            pressure.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self, self.activeRequests.isEmpty else { return }
                    self.stop()
                }
            }
            pressure.resume()
            pressureSource = pressure
        }
    }

    static func needsInitialModelSetup(defaults: UserDefaults = .standard, defaultModel: URL? = nil) -> Bool {
        guard (defaults.string(forKey: "translationProvider") ?? "local") == "local" else { return false }
        let custom = defaults.string(forKey: "modelPath").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return !LocalModelFile.hasGGUFHeader(at: custom ?? defaultModel ?? defaultModelURL,
                                             minimumBytes: custom == nil ? 1_000_000_000 : 24)
    }
    private var selectedModel: URL {
        defaults.string(forKey: isConversation ? "conversationModelPath" : "modelPath")
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? configuration.defaultModel
    }
    private var keepReadyEnabled: Bool {
        defaults.object(forKey: Self.keepReadyPreference) == nil || defaults.bool(forKey: Self.keepReadyPreference)
    }
    private var mayPrewarm: Bool {
        !isConversation && keepReadyEnabled && (defaults.string(forKey: "translationProvider") ?? "local") == "local"
            && LocalModelFile.hasGGUFHeader(at: selectedModel,
                minimumBytes: (defaults.string(forKey: "modelPath") ?? "").isEmpty ? 1_000_000_000 : 24)
    }

    /// Call at launch, after a model download/selection, or when local translation is selected.
    /// Loads only the existing local translation model; never downloads or sends a prompt.
    func prewarmIfNeeded() {
        guard mayPrewarm, prewarmTask == nil else { return }
        if state == .ready, process?.isRunning == true { scheduleIdleRelease(); return }
        let id = UUID()
        prewarmID = id
        prewarmTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.ready() } catch { /* Foreground requests surface actionable errors. */ }
            guard self.prewarmID == id else { return }
            self.prewarmTask = nil
            self.prewarmID = nil
            self.scheduleIdleRelease()
        }
    }

    /// Reevaluate after changing the provider or the keep-ready preference.
    func refreshPrewarming() {
        if mayPrewarm { prewarmIfNeeded() }
        else {
            prewarmID = nil
            prewarmTask?.cancel(); prewarmTask = nil
            if activeRequests.isEmpty { stop() }
        }
    }

    func stop() {
        generation = UUID()
        idleTask?.cancel(); idleTask = nil
        prewarmID = nil
        prewarmTask?.cancel(); prewarmTask = nil
        startup?.cancel(); startup = nil
        let waiting = waiters.values
        waiters.removeAll()
        for waiter in waiting { waiter.resume(throwing: CancellationError()) }
        if let process, process.isRunning {
            process.terminate()
            retiredProcesses.append(process)
        }
        process = nil
        for task in requestTasks.values { task.cancel() }
        requestTasks.removeAll()
        for observation in requestObservations.values { observation.invalidate() }
        requestObservations.removeAll()
        activeRequests.removeAll()
        state = .stopped
    }

    private func ready(progress: ((Progress) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        idleTask?.cancel(); idleTask = nil
        if state == .ready, process?.isRunning == true { return }
        progress?(.loadingModel)
        if startup == nil {
            let token = UUID()
            generation = token
            state = .loading
            startup = Task { [weak self] in
                guard let self else { return }
                do { try await self.launch(token: token); self.finishStartup(token: token, error: nil) }
                catch { self.finishStartup(token: token, error: error) }
            }
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[waiterID] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.waiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
            }
        }
        try Task.checkCancellation()
    }

    private func finishStartup(token: UUID, error: Error?) {
        guard generation == token else { return }
        startup = nil
        state = error == nil ? .ready : .stopped
        let waiting = waiters.values
        waiters.removeAll()
        for waiter in waiting {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
        if error == nil { scheduleIdleRelease() }
    }

    private func launch(token: UUID) async throws {
        // stop() is synchronous, but SIGTERM is not. Reuse the port only after our old
        // process exits; a cancelled generation must never clear a newer startup.
        let retired = retiredProcesses
        for old in retired {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while old.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if old.isRunning {
                kill(old.processIdentifier, SIGKILL)
                let killedDeadline = ProcessInfo.processInfo.systemUptime + 1
                while old.isRunning && ProcessInfo.processInfo.systemUptime < killedDeadline {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                guard !old.isRunning else { throw ModelError.message("本地模型仍在退出，请稍后重试。") }
            }
        }
        retiredProcesses.removeAll { !($0.isRunning) }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        let binary = configuration.binary
        let model = selectedModel
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw ModelError.message(isConversation
                ? "未找到本地对话模型。请在 Settings → Models 中重新选择 GGUF 文件。"
                : "本地翻译模型尚未安装。请打开 Settings → Models，在 On This Mac 中点击 Download，或选择已有的 GGUF 文件。")
        }
        guard LocalModelFile.hasGGUFHeader(at: model) else {
            throw ModelError.message("模型文件不完整或格式不受支持。请在 Settings → Models 中重新下载模型，或选择有效的 GGUF 文件。")
        }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw ModelError.message("应用缺少本地运行组件。请重新下载并安装 Nous Translator。") }
        try FileManager.default.createDirectory(at: configuration.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let p = Process(); p.executableURL = binary
        p.environment = ProcessInfo.processInfo.environment.merging(["GGML_BACKEND_PATH": binary.deletingLastPathComponent().path]) { _, new in new }
        p.arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", String(configuration.port), "--alias", "Index-Translate-2B", "--api-key", key, "-ngl", "99", "-c", "16384", "--parallel", "1", "--jinja", "--chat-template-kwargs", "{\"enable_thinking\":false}"]
        FileManager.default.createFile(atPath: configuration.log.path, contents: nil)
        let output = try FileHandle(forWritingTo: configuration.log)
        defer { try? output.close() }
        p.standardOutput = output; p.standardError = output
        p.terminationHandler = { [weak self] owned in
            Task { @MainActor in
                guard let self, self.generation == token, self.process === owned else { return }
                self.process = nil
                if self.startup == nil { self.state = .stopped }
            }
        }
        try p.run(); process = p
        do {
            let started = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - started < configuration.startupTimeout {
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                guard p.isRunning else { throw ModelError.message("本地模型启动失败，请查看 runtime.log。") }
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(configuration.port)/health")!)
                request.timeoutInterval = 0.5
                request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                if let (_, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 {
                    try Task.checkCancellation()
                    guard generation == token, p.isRunning else { throw CancellationError() }
                    return
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                try await Task.sleep(nanoseconds: elapsed < 2 ? 50_000_000 : 150_000_000)
            }
            throw ModelError.message("本地模型加载超时，请重试。")
        } catch {
            if p.isRunning {
                p.terminate()
                if !retiredProcesses.contains(where: { $0 === p }) { retiredProcesses.append(p) }
            }
            if process === p { process = nil }
            throw error
        }
    }

    private func scheduleIdleRelease() {
        idleTask?.cancel(); idleTask = nil
        guard activeRequests.isEmpty, state == .ready else { return }
        // An explicitly used conversation model also releases its memory after inactivity.
        let keepTranslationReady = keepReadyEnabled && (defaults.string(forKey: "translationProvider") ?? "local") == "local"
        let delay = isConversation || keepTranslationReady ? configuration.idleTimeout : 0
        let token = generation
        idleTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000)) }
            catch { return }
            guard let self, self.generation == token, self.activeRequests.isEmpty else { return }
            self.stop()
        }
    }
    private func requestFinished(_ id: UUID) {
        guard activeRequests.remove(id) != nil else { return }
        requestTasks.removeValue(forKey: id)
        requestObservations.removeValue(forKey: id)?.invalidate()
        scheduleIdleRelease()
    }

    /// Reports loading separately from awaiting model output. The consumer should switch
    /// to generating only when it receives the first nonempty SSE content delta.
    func stream(messages: [[String: String]], progress: ((Progress) -> Void)? = nil) async throws -> URLSession.AsyncBytes {
        let requestID = UUID()
        activeRequests.insert(requestID)
        idleTask?.cancel(); idleTask = nil
        do {
            try await ready(progress: progress)
            try Task.checkCancellation()
            guard activeRequests.contains(requestID) else { throw CancellationError() }
            let token = generation
            progress?(.waitingForFirstToken)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(configuration.port)/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model":"Index-Translate-2B", "messages":messages, "stream":true, "temperature":0, "max_tokens":4096, "chat_template_kwargs":["enable_thinking":false]])
            let (bytes, response) = try await session.bytes(for: request)
            guard generation == token, activeRequests.contains(requestID), !Task.isCancelled else {
                bytes.task.cancel()
                throw CancellationError()
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                bytes.task.cancel()
                throw ModelError.message("本地模型请求失败，请缩短文本后重试。")
            }
            requestTasks[requestID] = bytes.task
            // Async URLSession methods own their completion handler, so task-delegate
            // didComplete is not a reliable lease boundary. Observe the actual task.
            requestObservations[requestID] = bytes.task.observe(\.state, options: [.initial, .new]) { [weak self] task, _ in
                guard task.state == .completed else { return }
                Task { @MainActor in self?.requestFinished(requestID) }
            }
            return bytes
        } catch {
            requestFinished(requestID)
            throw error
        }
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
