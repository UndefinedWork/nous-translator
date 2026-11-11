import Foundation
import AppKit

@main struct FirstLaunchTests {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nous-first-launch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "nous-first-launch-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let defaultModel = folder.appendingPathComponent("official.gguf")
        let customModel = folder.appendingPathComponent("custom.gguf")
        let header = Data([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0] + Array(repeating: UInt8(0), count: 16))
        precondition(LocalModel.needsInitialModelSetup(defaults: defaults, defaultModel: defaultModel), "A new install opens model setup")
        try header.write(to: customModel)
        defaults.set(customModel.path, forKey: "modelPath")
        precondition(!LocalModel.needsInitialModelSetup(defaults: defaults, defaultModel: defaultModel), "Existing custom model selection is preserved")
        let linkedModel = folder.appendingPathComponent("linked.gguf")
        try FileManager.default.createSymbolicLink(at: linkedModel, withDestinationURL: customModel)
        precondition(LocalModelFile.hasGGUFHeader(at: linkedModel), "Existing model symlinks remain usable")
        try Data("GGUF".utf8).write(to: customModel)
        precondition(LocalModel.needsInitialModelSetup(defaults: defaults, defaultModel: defaultModel), "A truncated custom model offers setup")
        defaults.removeObject(forKey: "modelPath")
        defaults.set("custom", forKey: "translationProvider")
        precondition(!LocalModel.needsInitialModelSetup(defaults: defaults, defaultModel: defaultModel), "Cloud users are not forced to download a local model")
        defaults.set("local", forKey: "translationProvider")
        try header.write(to: defaultModel)
        precondition(LocalModel.needsInitialModelSetup(defaults: defaults, defaultModel: defaultModel), "An incomplete official model does not count as installed")
        let sparse = try FileHandle(forWritingTo: defaultModel)
        try sparse.truncate(atOffset: 1_000_000_000); try sparse.close()
        precondition(!LocalModel.needsInitialModelSetup(defaults: defaults, defaultModel: defaultModel), "An installed official model skips setup")

        // Local fixtures exercise the real URLSession download/progress/cancellation path without
        // downloading model weights, contacting a provider, or changing the user's model/preferences.
        let server = Process(), output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", #"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import struct, time
payload = b'GGUF' + struct.pack('<IQQ', 3, 1, 0) + b'\0' * (512 * 1024)
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        status = 404 if self.path == '/missing' else 200
        body = b'not a model' if self.path == '/bad' else payload
        self.send_response(status)
        self.send_header('Content-Length', str(len(body) + (1024 if self.path == '/short' else 0)))
        self.end_headers()
        try:
            for i in range(0, len(body), 8192):
                self.wfile.write(body[i:i+8192]); self.wfile.flush()
                time.sleep(0.03 if self.path == '/slow' else 0.002)
        except (BrokenPipeError, ConnectionResetError): pass
        self.close_connection = True
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
"""#]
        server.standardOutput = output; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        let port = String(data: output.fileHandleForReading.availableData, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(Int(port) != nil)
        let destination = folder.appendingPathComponent("downloaded/model.gguf")
        func download(_ endpoint: String) -> ModelDownload {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            return ModelDownload(destination: destination, source: URL(string: "http://127.0.0.1:\(port)/\(endpoint)")!, configuration: config, minimumBytes: 24)
        }
        func waitFor(_ predicate: () -> Bool) async throws {
            for _ in 0..<250 {
                if predicate() { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            fatalError("Timed out waiting for the local download fixture")
        }
        let good = download("ok")
        precondition(!good.installed)
        good.start(); try await waitFor { !good.running }
        precondition(good.installed && good.progress == 1 && good.status.hasPrefix("Download complete"), "A first download creates its destination and becomes usable")
        let expected = try Data(contentsOf: destination)
        for endpoint in ["missing", "bad", "short"] {
            let failed = download(endpoint)
            failed.start(); try await waitFor { !failed.running }
            precondition(failed.status.hasPrefix("Download failed:"), "HTTP errors, invalid content and incomplete responses must fail")
            let preserved = try Data(contentsOf: destination)
            precondition(preserved == expected, "A failed download preserves the installed model")
        }
        let cancelled = download("slow")
        cancelled.start(); try await waitFor { (cancelled.progress ?? 0) > 0 }
        precondition(cancelled.running, "A real download reports progress before completion")
        cancelled.cancel(); try await waitFor { !cancelled.running }
        precondition(cancelled.status.hasPrefix("Download cancelled"))
        let preserved = try Data(contentsOf: destination)
        precondition(preserved == expected, "Cancellation preserves the installed model")
        cancelled.start(); try await waitFor { !cancelled.running }
        precondition(cancelled.status.hasPrefix("Download complete"), "A cancelled download can be retried")
        try Data("broken model".utf8).write(to: destination)
        let repair = download("ok")
        precondition(!repair.installed, "A corrupt existing file is not shown as installed")
        repair.start(); try await waitFor { !repair.running }
        let repaired = try Data(contentsOf: destination)
        precondition(repair.installed && repaired == expected, "A successful re-download repairs an existing corrupt file")
        print("PASS: first-launch routing, custom/cloud preferences, GGUF preflight, real download progress, cancellation/retry, invalid HTTP/content rejection and atomic model repair")
    }
}
