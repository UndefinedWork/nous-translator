import Foundation
import Combine
import Darwin

@_silgen_name("proc_pidpath")
private func nousProcPidPath(_ pid: pid_t, _ buffer: UnsafeMutableRawPointer, _ buffersize: UInt32) -> Int32

@MainActor final class LocalModel: ObservableObject {
    enum State: Equatable { case stopped, loading, ready }
    enum Progress: Equatable { case loadingModel, waitingForFirstToken }
    static let keepReadyPreference = "keepLocalTranslationReady"
    static let shared = LocalModel()
    static let conversation = LocalModel(conversation: true)
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nous Translator")
    static var defaultModelURL: URL { directory.appendingPathComponent("Index-Translate-2B.Q4_K_M.gguf") }

    /// Injectable paths and short timeouts allow lifecycle tests without loading model weights.
    /// Setting `port` to `0` dynamically allocates a free loopback port on each launch.
    struct Configuration {
        var binary: URL
        var defaultModel: URL
        var port: Int = 0
        var log: URL
        var idleTimeout: TimeInterval = 300
        var startupTimeout: TimeInterval = 120
        var observeMemoryPressure = true
        var pidFile: URL? = nil
        var contextLength: Int? = nil
    }
    @Published private(set) var state: State = .stopped
    private let isConversation: Bool
    private let defaults: UserDefaults
    private let configuration: Configuration
    private var process: Process?
    private var activePort: Int = 0
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

    var currentPort: Int { activePort }

    private var resolvedContextLength: Int {
        configuration.contextLength ?? (isConversation ? 16384 : 8192)
    }

    private var modelAlias: String {
        isConversation ? "nous-conversation" : "Index-Translate-2B"
    }

    init(conversation: Bool = false, defaults: UserDefaults = .standard, configuration: Configuration? = nil) {
        isConversation = conversation
        self.defaults = defaults
        self.configuration = configuration ?? Configuration(
            binary: (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("Runtime/llama-server"),
            defaultModel: Self.defaultModelURL,
            port: 0,
            log: Self.directory.appendingPathComponent(conversation ? "conversation-runtime.log" : "runtime.log"),
            pidFile: Self.directory.appendingPathComponent(conversation ? "conversation-runtime.pid" : "runtime.pid"))
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
        if let process {
            retire(process)
        }
        process = nil
        activePort = 0
        clearPIDFile()
        for task in requestTasks.values { task.cancel() }
        requestTasks.removeAll()
        for observation in requestObservations.values { observation.invalidate() }
        requestObservations.removeAll()
        activeRequests.removeAll()
        state = .stopped
    }

    /// Terminate an owned subprocess and guarantee SIGKILL fallback if it ignores SIGTERM.
    private func retire(_ owned: Process) {
        guard owned.isRunning else { return }
        owned.terminate()
        if !retiredProcesses.contains(where: { $0 === owned }) {
            retiredProcesses.append(owned)
        }
        let pid = owned.processIdentifier
        Task.detached(priority: .utility) { [weak self] in
            let deadline = ProcessInfo.processInfo.systemUptime + 2.0
            while owned.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            if owned.isRunning {
                kill(pid, SIGKILL)
                let killDeadline = ProcessInfo.processInfo.systemUptime + 1.0
                while owned.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            await MainActor.run { [weak self] in
                self?.retiredProcesses.removeAll { !$0.isRunning }
            }
        }
    }

    private func recordPIDFile(pid: pid_t, binary: URL) {
        guard let pidFile = configuration.pidFile else { return }
        let resolved = binary.resolvingSymlinksInPath().path
        try? FileManager.default.createDirectory(at: pidFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(pid)\n\(resolved)\n".write(to: pidFile, atomically: true, encoding: .utf8)
    }

    private func clearPIDFile() {
        guard let pidFile = configuration.pidFile else { return }
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// Terminate an orphaned llama-server left over from a previous abrupt crash.
    /// Verifies the executable path via proc_pidpath before sending any signal.
    func cleanupOrphanProcess() async {
        guard let pidFile = configuration.pidFile,
              let contents = try? String(contentsOf: pidFile, encoding: .utf8) else { return }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count >= 2, let pid = pid_t(lines[0]), pid > 0, pid != getpid() else {
            clearPIDFile(); return
        }
        let expectedPath = lines[1]
        if let runningPath = Self.executablePath(for: pid),
           runningPath == expectedPath || runningPath == configuration.binary.resolvingSymlinksInPath().path {
            kill(pid, SIGTERM)
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            while kill(pid, 0) == 0 && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
        clearPIDFile()
    }

    static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = nousProcPidPath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func allocateLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ModelError.message(L10n.text("Unable to allocate a local port for the model server.",
                                               zh: "无法为本地模型服务分配可用端口。"))
        }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress -> Int32 in
                guard bind(descriptor, socketAddress, size) == 0 else { return -1 }
                return getsockname(descriptor, socketAddress, &size)
            }
        }
        guard result == 0 else {
            throw ModelError.message(L10n.text("Unable to bind a local loopback port for the model server.",
                                               zh: "无法绑定本地回环端口以启动模型服务。"))
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func ready(progress: ((Progress) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        idleTask?.cancel(); idleTask = nil
        if state == .ready, process?.isRunning == true, activePort > 0 { return }
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
                self.abortUnusedStartupIfNeeded()
            }
        }
        try Task.checkCancellation()
    }

    private func abortUnusedStartupIfNeeded() {
        if startup != nil, waiters.isEmpty, activeRequests.isEmpty, prewarmTask == nil {
            stop()
        }
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
        await cleanupOrphanProcess()
        // stop() is synchronous, but SIGTERM is not. Wait for any previously owned
        // process before binding an explicit port or starting a replacement.
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
                guard !old.isRunning else {
                    throw ModelError.message(L10n.text("The previous local model process is still exiting. Please retry shortly.",
                                                       zh: "本地模型仍在退出，请稍后重试。"))
                }
            }
        }
        retiredProcesses.removeAll { !($0.isRunning) }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        let binary = configuration.binary
        let model = selectedModel
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw ModelError.message(isConversation
                ? L10n.text("Local conversation model not found. Choose a GGUF file in Settings → Models.",
                            zh: "未找到本地对话模型。请在 Settings → Models 中重新选择 GGUF 文件。")
                : L10n.text("Local translation model is not installed. Open Settings → Models to download it or choose an existing GGUF file.",
                            zh: "本地翻译模型尚未安装。请打开 Settings → Models，在 On This Mac 中点击 Download，或选择已有的 GGUF 文件。"))
        }
        guard LocalModelFile.hasGGUFHeader(at: model) else {
            throw ModelError.message(L10n.text("The model file is incomplete or unsupported. Redownload it or choose a valid GGUF file in Settings → Models.",
                                               zh: "模型文件不完整或格式不受支持。请在 Settings → Models 中重新下载模型，或选择有效的 GGUF 文件。"))
        }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw ModelError.message(L10n.text("The bundled local runtime is missing. Please reinstall Nous Translator.",
                                               zh: "应用缺少本地运行组件。请重新下载并安装 Nous Translator。"))
        }
        let chosenPort = configuration.port > 0 ? configuration.port : try Self.allocateLoopbackPort()
        try FileManager.default.createDirectory(at: configuration.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let p = Process(); p.executableURL = binary
        p.environment = ProcessInfo.processInfo.environment.merging(["GGML_BACKEND_PATH": binary.deletingLastPathComponent().path]) { _, new in new }
        var arguments = [
            "-m", model.path,
            "--host", "127.0.0.1",
            "--port", String(chosenPort),
            "--alias", modelAlias,
            "--api-key", key,
            "-ngl", "99",
            "-c", String(resolvedContextLength),
            "--parallel", "1",
            "--jinja"
        ]
        // Only disable thinking template kwargs on the dedicated local translation runtime.
        if !isConversation {
            arguments += ["--chat-template-kwargs", "{\"enable_thinking\":false}"]
        }
        p.arguments = arguments
        FileManager.default.createFile(atPath: configuration.log.path, contents: nil)
        let output = try FileHandle(forWritingTo: configuration.log)
        defer { try? output.close() }
        p.standardOutput = output; p.standardError = output
        p.terminationHandler = { [weak self] owned in
            Task { @MainActor in
                guard let self, self.generation == token, self.process === owned else { return }
                self.process = nil
                self.activePort = 0
                self.clearPIDFile()
                if self.startup == nil { self.state = .stopped }
            }
        }
        try p.run(); process = p; activePort = chosenPort
        recordPIDFile(pid: p.processIdentifier, binary: binary)
        let logName = configuration.log.lastPathComponent
        do {
            let started = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - started < configuration.startupTimeout {
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                guard p.isRunning else {
                    throw ModelError.message(L10n.text("Local model failed to start. Check \(logName) for details.",
                                                       zh: "本地模型启动失败，请查看 \(logName)。"))
                }
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(chosenPort)/health")!)
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
            throw ModelError.message(L10n.text("Local model loading timed out. Please try again.",
                                               zh: "本地模型加载超时，请重试。"))
        } catch {
            retire(p)
            if process === p { process = nil; activePort = 0; clearPIDFile() }
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
        abortUnusedStartupIfNeeded()
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
            guard activeRequests.contains(requestID), activePort > 0 else { throw CancellationError() }
            let token = generation
            let port = activePort
            progress?(.waitingForFirstToken)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            var body: [String: Any] = [
                "model": modelAlias,
                "messages": messages,
                "stream": true,
                "temperature": isConversation ? 0.7 : 0,
                "max_tokens": 4096
            ]
            if !isConversation {
                body["chat_template_kwargs"] = ["enable_thinking": false]
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (bytes, response) = try await session.bytes(for: request)
            guard generation == token, activeRequests.contains(requestID), !Task.isCancelled else {
                bytes.task.cancel()
                throw CancellationError()
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                bytes.task.cancel()
                throw ModelError.message(L10n.text("Local model request failed. Try shortening the text and retry.",
                                                   zh: "本地模型请求失败，请缩短文本后重试。"))
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
