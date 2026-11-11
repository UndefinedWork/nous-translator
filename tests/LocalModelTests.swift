import Foundation
import Darwin

@main struct LocalModelTests {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nous-local-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "nous-local-lifecycle-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = folder.appendingPathComponent("fixture.gguf")
        try Data([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0] + Array(repeating: UInt8(0), count: 16)).write(to: model)
        defaults.set(model.path, forKey: "modelPath")
        defaults.set("local", forKey: "translationProvider")
        let binary = folder.appendingPathComponent("fixture-server")
        try #"""
#!/usr/bin/python3
import json, pathlib, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
args = sys.argv[1:]
def value(flag): return args[args.index(flag) + 1]
model = pathlib.Path(value('-m'))
with model.with_suffix('.starts').open('a') as file: file.write('start\n')
started = time.monotonic()
key = value('--api-key')
class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_GET(self):
        body = b'{}'
        self.send_response(200 if time.monotonic() - started > 0.2 else 503)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        self.rfile.read(int(self.headers['Content-Length']))
        if self.headers.get('Authorization') != 'Bearer ' + key:
            self.send_error(401); return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Connection', 'close')
        self.end_headers()
        try:
            time.sleep(0.1)
            self.wfile.write(b'data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n'); self.wfile.flush()
            time.sleep(0.3)
            self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError): pass
        self.close_connection = True
ThreadingHTTPServer(('127.0.0.1', int(value('--port'))), Handler).serve_forever()
"""#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        var config = LocalModel.Configuration(binary: binary, defaultModel: model, port: unusedPort(), log: folder.appendingPathComponent("runtime.log"))
        config.idleTimeout = 0.15
        config.startupTimeout = 3
        config.observeMemoryPressure = false
        let local = LocalModel(defaults: defaults, configuration: config)
        defer { local.stop() }
        func wait(_ label: String = "condition", _ predicate: () -> Bool) async throws {
            for _ in 0..<300 {
                if predicate() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw NSError(domain: "LocalModelTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Lifecycle fixture timed out: \(label), state \(local.state)"])
        }
        func starts() -> Int {
            (try? String(contentsOf: model.deletingPathExtension().appendingPathExtension("starts"), encoding: .utf8))?.split(separator: "\n").count ?? 0
        }
        func translate(_ phases: @escaping (LocalModel.Progress) -> Void = { _ in }) async throws -> String {
            let bytes = try await local.stream(messages: [["role": "user", "content": "hello"]], progress: phases)
            var result = ""
            for try await line in bytes.lines { result += line }
            return result
        }

        // Provider, model availability, and preference gate background loading.
        defaults.set("custom", forKey: "translationProvider")
        local.prewarmIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(starts() == 0 && local.state == .stopped)
        defaults.set("local", forKey: "translationProvider")
        defaults.set(false, forKey: LocalModel.keepReadyPreference)
        local.prewarmIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(starts() == 0)
        defaults.set(true, forKey: LocalModel.keepReadyPreference)
        defaults.set(folder.appendingPathComponent("missing.gguf").path, forKey: "modelPath")
        local.prewarmIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(starts() == 0)
        defaults.set(model.path, forKey: "modelPath")
        let conversation = LocalModel(conversation: true, defaults: defaults, configuration: config)
        conversation.prewarmIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(starts() == 0, "Prewarm must never load a separate conversation model")

        local.prewarmIfNeeded()
        try await wait("prewarm") { local.state == .ready }
        precondition(starts() == 1)
        var warmPhases: [LocalModel.Progress] = []
        let warm = try await translate { warmPhases.append($0) }
        precondition(warm.contains("Hello") && warm.contains("[DONE]"))
        precondition(warmPhases == [.waitingForFirstToken], "Warm request must not claim the model is loading")
        try await wait("prewarm idle release") { local.state == .stopped }
        precondition(starts() == 1, "Idle release must not start a timer that reloads the model")

        // Concurrent callers share one startup; cancelling one waiter returns promptly.
        var coldPhases: [LocalModel.Progress] = []
        let cancelled = Task { try await translate { coldPhases.append($0) } }
        let survivor = Task { try await translate() }
        try await wait { local.state == .loading }
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Expected cancellation") } catch is CancellationError {}
        precondition(ProcessInfo.processInfo.systemUptime - cancelledAt < 0.15, "Cancelling a caller must not wait for model loading")
        let survived = try await survivor.value
        precondition(survived.contains("Hello") && coldPhases == [.loadingModel])
        precondition(starts() == 2, "Concurrent requests must share one model process")

        // stop during loading followed immediately by retry must not inherit stale cleanup.
        local.stop()
        let interrupted = Task { try await translate() }
        try await wait { local.state == .loading }
        try await Task.sleep(nanoseconds: 50_000_000)
        local.stop()
        let retried = Task { try await translate() }
        do { _ = try await interrupted.value; fatalError("Expected stop cancellation") } catch is CancellationError {}
        let retryResult = try await retried.value
        precondition(retryResult.contains("Hello"), "Immediate retry survives the retired process and old startup cleanup")
        try await wait { local.state == .stopped }

        // Turning keep-ready off releases a completed request, not an active stream.
        defaults.set(false, forKey: LocalModel.keepReadyPreference)
        let noRetention = try await translate()
        precondition(noRetention.contains("[DONE]"))
        try await wait { local.state == .stopped }
        let onlyWaiter = Task { try await translate() }
        try await wait { local.state == .loading }
        onlyWaiter.cancel()
        do { _ = try await onlyWaiter.value; fatalError("Expected cancellation") } catch is CancellationError {}
        try await wait("cancelled final waiter releases its startup") { local.state == .stopped }

        var timeoutConfiguration = config
        timeoutConfiguration.port = unusedPort()
        timeoutConfiguration.startupTimeout = 0.04
        let timeoutModel = LocalModel(defaults: defaults, configuration: timeoutConfiguration)
        defer { timeoutModel.stop() }
        do {
            _ = try await timeoutModel.stream(messages: [["role": "user", "content": "hello"]])
            fatalError("Expected startup timeout")
        } catch let error as ModelError {
            precondition(error.localizedDescription.contains("超时"))
        }
        precondition(timeoutModel.state == .stopped)
        print("PASS: local-only prewarm gating, no conversation prewarm, truthful loading phases, shared startup, prompt cancellation, stop/retry race, live-stream retention, finite idle release, startup timeout cleanup")
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
