import Foundation

@main struct StreamLifecycleTests {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nous-stream-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "StreamLifecycleTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let server = Process(), output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", #"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import pathlib, sys, time
folder = pathlib.Path(sys.argv[1])
class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        route = self.path.strip('/')
        self.send_response(503 if route == 'status' else 200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Transfer-Encoding', 'chunked')
        self.end_headers()
        (folder / (route + '.started')).write_text('started')
        first = {
            'done': b'data: {"choices":[{"delta":{"content":"Hello"}}]}\n\ndata: [DONE]\n\n',
            'parse': b'data: {"choices":\n\n',
            'cancel': b': waiting for a token\n\n',
            'status': b'{"error":"fixture service unavailable"}\n'
        }[route]
        def chunk(body):
            self.wfile.write(('%X\r\n' % len(body)).encode() + body + b'\r\n')
            self.wfile.flush()
        try:
            chunk(first)
            # Deliberately never send the terminating HTTP chunk, even after [DONE].
            # Only client cancellation closes these streams within the test deadline.
            until = time.monotonic() + 15
            while time.monotonic() < until:
                time.sleep(0.03)
                chunk(b': connection still open\n\n')
            (folder / (route + '.expired')).write_text('not cancelled')
        except (BrokenPipeError, ConnectionResetError, OSError):
            (folder / (route + '.closed')).write_text('client closed the response')
        self.close_connection = True
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
"""#, folder.path]
        server.standardOutput = output; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        let port = String(data: output.fileHandleForReading.availableData, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
        try check(Int(port) != nil, "The loopback fixture must provide a port")
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        func request(_ route: String) -> URLRequest {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(route)")!)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            return request
        }
        func waitFor(_ message: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<150 {
                if predicate() { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try check(false, message)
        }
        func assertClosed(_ route: String, task: URLSessionTask? = nil) async throws {
            try await waitFor("\(route): the HTTP response must close even while the server keeps streaming") {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(route + ".closed").path)
                    && (task == nil || task?.state == .completed)
            }
            try check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(route + ".expired").path), "\(route): closure must come from client cancellation")
        }

        let (doneBytes, _) = try await session.bytes(for: request("done"))
        let doneTask = doneBytes.task
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await CompletionReader.read(doneBytes) { _ in }
        try check(result == "Hello", "[DONE] returns the final accumulated text")
        try check(ProcessInfo.processInfo.systemUptime - started < 1, "[DONE] must not wait for the open HTTP response")
        try await assertClosed("done", task: doneTask)

        let (parseBytes, _) = try await session.bytes(for: request("parse"))
        let parseTask = parseBytes.task
        var failedParsing = false
        do { _ = try await CompletionReader.read(parseBytes) { _ in } }
        catch { failedParsing = true }
        try check(failedParsing, "Malformed SSE JSON must surface an error")
        try await assertClosed("parse", task: parseTask)

        let (cancelBytes, _) = try await session.bytes(for: request("cancel"))
        let cancelTask = cancelBytes.task
        let reader = Task { try await CompletionReader.read(cancelBytes) { _ in } }
        try await Task.sleep(nanoseconds: 60_000_000)
        reader.cancel()
        var cancelled = false
        do { _ = try await reader.value }
        catch is CancellationError { cancelled = true }
        catch let error as URLError where error.code == .cancelled { cancelled = true }
        try check(cancelled, "Cancelling the caller must cancel the read, not return a translation")
        try await assertClosed("cancel", task: cancelTask)

        // Use the router's request overload: no saved provider, credential or paid endpoint is read.
        var rejectedStatus = false
        do { _ = try await ModelRouter.remoteStream(request: request("status"), provider: .custom) }
        catch let error as ModelError { rejectedStatus = error.localizedDescription.contains("HTTP 503") }
        try check(rejectedStatus, "A non-200 response must surface its HTTP status")
        try await assertClosed("status")
        print("PASS: real SSE [DONE], parse error, caller cancellation and HTTP error close live loopback responses without waiting for server completion")
    }
}
