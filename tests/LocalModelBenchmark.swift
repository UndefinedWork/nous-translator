import Foundation
import Darwin

/// Real on-device timing for LocalModel's request and prewarm paths. Uses an isolated
/// preferences suite, log directory and port; never touches an online provider.
@main struct LocalModelBenchmark {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Usage: benchmark <llama-server> <model.gguf>") }
        let binary = URL(fileURLWithPath: CommandLine.arguments[1])
        let modelURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nous-model-benchmark-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "nous-model-benchmark-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(modelURL.path, forKey: "modelPath")
        defaults.set("local", forKey: "translationProvider")
        defaults.set(true, forKey: LocalModel.keepReadyPreference)
        var configuration = LocalModel.Configuration(binary: binary, defaultModel: modelURL,
            port: unusedPort(), log: folder.appendingPathComponent("runtime.log"))
        configuration.observeMemoryPressure = false
        let local = LocalModel(defaults: defaults, configuration: configuration)
        defer { local.stop() }
        let prompt = "请将以下文本翻译为英语，直接输出翻译结果，不要进行任何解释。\n\n我们明天下午三点开会。"
        func request(_ label: String) async throws -> [String: Any] {
            let start = ProcessInfo.processInfo.systemUptime
            var phases: [[String: Any]] = []
            let bytes = try await local.stream(messages: [["role": "user", "content": prompt]]) { phase in
                phases.append(["phase": phase == .loadingModel ? "loadingModel" : "waitingForFirstToken",
                               "seconds": ProcessInfo.processInfo.systemUptime - start])
            }
            var first: Double?
            var text = ""
            for try await line in bytes.lines {
                guard line.hasPrefix("data: "), let data = String(line.dropFirst(6)).data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choice = (event["choices"] as? [[String: Any]])?.first,
                      let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String,
                      !content.isEmpty else { continue }
                if first == nil { first = ProcessInfo.processInfo.systemUptime - start }
                text += content
            }
            precondition(text.contains("tomorrow"))
            return ["request": label, "first_token_seconds": first!,
                    "total_seconds": ProcessInfo.processInfo.systemUptime - start, "phases": phases, "text": text]
        }
        var result: [String: Any] = ["binary": binary.path, "context_tokens": 16384]
        result["cold_request"] = try await request("new process, existing system caches")
        result["warm_request"] = try await request("already ready")
        local.stop()
        let prewarmStarted = ProcessInfo.processInfo.systemUptime
        local.prewarmIfNeeded()
        while local.state != .ready {
            guard ProcessInfo.processInfo.systemUptime - prewarmStarted < 120 else { throw NSError(domain: "BenchmarkTimeout", code: 1) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        result["prewarm_seconds"] = ProcessInfo.processInfo.systemUptime - prewarmStarted
        result["prewarmed_request"] = try await request("after prewarm")
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
    private static func unusedPort() -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        precondition(descriptor >= 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress -> Int32 in
                guard bind(descriptor, socketAddress, size) == 0 else { return -1 }
                return getsockname(descriptor, socketAddress, &size)
            }
        }
        precondition(result == 0)
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
