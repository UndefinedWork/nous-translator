import AppKit
import CryptoKit
import Foundation
#if canImport(NousCore)
@testable import NousCore
#endif

@main struct OptimizationTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nous-opt-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // 1. Localization switching (English & Chinese)
        L10n.withOverride(.english) {
            precondition(L10n.text("Hello", zh: "你好") == "Hello")
        }
        L10n.withOverride(.chinese) {
            precondition(L10n.text("Hello", zh: "你好") == "你好")
        }

        // 2. Prompt routing: local vs online structured prompt + fixed-direction source omission
        let fixed = TranslationLanguageConfiguration(languageA: .chinese, languageB: .english, mode: .bToA)
            .direction(source: .init(.french))
        precondition(fixed.isFixedDirection)
        let localFixedPrompt = fixed.messages(text: "Hello", structured: false)[0]["content"]!
        precondition(!localFixedPrompt.contains("从French"), "Fixed direction must not inject a potentially misdetected source language")
        precondition(localFixedPrompt.contains("翻译为简体中文"))

        let onlineMessages = fixed.messages(text: "Hello world", structured: true, app: "Safari")
        precondition(onlineMessages.count == 2 && onlineMessages[0]["role"] == "system" && onlineMessages[1]["role"] == "user")
        precondition(onlineMessages[0]["content"]!.contains("Chinese (Simplified)"))
        precondition(onlineMessages[1]["content"] == "<text app=\"Safari\">Hello world</text>")

        // 3. Short ASCII Latin word detection in Latin + Non-Latin pairs
        let englishChinese = TranslationLanguageConfiguration(languageA: .english, languageB: .chinese, mode: .automatic)
        for word in ["API", "cache", "defer", "bug"] {
            let resolved = englishChinese.direction(for: word)
            precondition(resolved.source.language == .english && resolved.target == .chinese,
                         "Short ASCII word '\(word)' in English↔Chinese must translate to Chinese, got \(resolved.label)")
        }
        // Compact initial panel sizing
        precondition(SelectionTranslationLayout.initialPanelSize(for: "serendipity").height < SelectionTranslationLayout.panelSize.height)
        precondition(SelectionTranslationLayout.initialPanelSize(for: String(repeating: "a", count: 400)).height == SelectionTranslationLayout.panelSize.height)

        // 4. TaskStore close(id) cancels active work, removes task, and cleans up attachment copies + orphan cleanup
        let attachRoot = folder.appendingPathComponent("Attachments")
        let orphanDir = attachRoot.appendingPathComponent("stale-orphan-folder")
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        let sampleDoc = folder.appendingPathComponent("doc.txt")
        try "hello attachment".write(to: sampleDoc, atomically: true, encoding: .utf8)

        let store = TaskStore(
            attachmentDirectory: attachRoot,
            extractAttachment: { _, _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "should be cancelled"
            },
            validateConversation: {}
        )
        let firstID = store.add("", files: [ComposerFile(name: "doc.txt", path: sampleDoc.path)]) { _ in "" }!
        let secondID = store.add("", files: [ComposerFile(name: "doc.txt", path: sampleDoc.path)]) { _ in "" }!
        precondition(store.tasks.count == 2)
        store.cleanupOrphanAttachments()
        // Close first task while running; second task must remain unaffected (no out-of-bounds crash)
        store.close(firstID)
        precondition(store.tasks.count == 1 && store.tasks[0].id == secondID)
        store.close(secondID)
        precondition(store.tasks.isEmpty)
        for _ in 0..<80 {
            let remaining = (try? FileManager.default.contentsOfDirectory(atPath: attachRoot.path)) ?? []
            if remaining.isEmpty { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let remainingDirs = (try? FileManager.default.contentsOfDirectory(atPath: attachRoot.path)) ?? []
        precondition(remainingDirs.isEmpty, "Closing tasks and orphan cleanup must remove copied attachment directories: \(remainingDirs)")

        // 5. Clipboard snapshot budget & transient markers
        let small = SelectionClipboardSnapshot.capture(from: [[(.string, { Data("hello".utf8) })]], maxBytes: 1024)
        precondition(small?.count == 1 && small?[0].count == 1)
        let oversized = SelectionClipboardSnapshot.capture(from: [[(.tiff, { Data(repeating: 1, count: 2048) })]], maxBytes: 1024)
        precondition(oversized == nil, "Oversized clipboard objects must abort Copy fallback safely")
        let promised = SelectionClipboardSnapshot.capture(from: [[(NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"), { Data("x".utf8) })]])
        precondition(promised == nil, "File promise pasteboard types must not be eagerly materialized")
        let marked = SelectionClipboardSnapshot.withTransientMarkers([(.string, Data("abc".utf8))])
        precondition(marked.contains(where: { $0.0 == SelectionClipboardSnapshot.transientType }))
        precondition(marked.contains(where: { $0.0 == SelectionClipboardSnapshot.autoGeneratedType }))

        // 6. MessageTextCache streaming bypass
        MessageTextCache.cache.removeAllObjects()
        let streamingText = "streaming-unique-\(UUID().uuidString)"
        _ = MessageTextCache.blocks(streamingText, markdown: false, useCache: false)
        precondition(MessageTextCache.cache.object(forKey: ("plain:" + streamingText) as NSString) == nil,
                     "Streaming text must bypass NSCache")
        _ = MessageTextCache.blocks(streamingText, markdown: false, useCache: true)
        precondition(MessageTextCache.cache.object(forKey: ("plain:" + streamingText) as NSString) != nil,
                     "Completed text should be cached")

        // 7. Diagnostic error extraction & secret redaction
        let jsonErr = Data(#"{"error":{"message":"Invalid model id with Bearer secret123 and sk-abcdefghijklmno"}}"#.utf8)
        let extracted = ModelRouter.extractErrorDetail(from: jsonErr) ?? ""
        precondition(extracted.contains("Invalid model id"))
        precondition(!extracted.contains("secret123") && !extracted.contains("sk-abcdefghijklmno"),
                     "Error diagnostics must redact accidental credentials: \(extracted)")

        // 8. GlobalHotKeyConfiguration persistence & formatting
        let suite = "nous-opt-hotkeys-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var hk = GlobalHotKeyConfiguration.load(defaults: defaults)
        precondition(hk.binding(for: .translateClipboard).displayString == "⌃⌥T")
        precondition(hk.binding(for: .quickTranslate).displayString == "⌃⌥N")
        precondition(hk.binding(for: .captureScreenOCR).displayString == "⌃⌥S")
        hk.set(HotKeyBinding(keyCode: 0, modifiers: 256 | 512, enabled: true), for: .quickTranslate)
        hk.save(defaults: defaults)
        precondition(GlobalHotKeyConfiguration.load(defaults: defaults) == hk)

        // 9. History metadata, legacy decoding, search filtering, and single-entry deletion
        let historyFile = folder.appendingPathComponent("history.json")
        let legacyJSON = #"[{"id":"11111111-1111-1111-1111-111111111111","date":0,"source":"Old source","result":"Old result"}]"#
        try legacyJSON.write(to: historyFile, atomically: true, encoding: .utf8)
        let history = TranslationHistory(file: historyFile)
        precondition(history.entries.count == 1 && history.entries[0].source == "Old source" && history.entries[0].directionSummary == nil)
        history.add(source: "Hello Safari", result: "你好 Safari", sourceLanguage: "en", targetLanguage: "zh-Hans", app: "Safari", provider: "local")
        precondition(history.entries.count == 2)
        precondition(history.entries[0].directionSummary == "English → 简体中文")
        precondition(history.filtered(matching: "safari").count == 1)
        history.delete(id: history.entries[0].id)
        precondition(history.entries.count == 1 && history.entries[0].source == "Old source")

        // 10. Download source URL validation & SHA-256 verification
        let hfURL = try ModelDownloadSource.huggingface.resolvedURL(customURL: "")
        let mirrorURL = try ModelDownloadSource.hfMirror.resolvedURL(customURL: "")
        precondition(hfURL.host == "huggingface.co")
        precondition(mirrorURL.host == "hf-mirror.com")
        do {
            _ = try ModelDownloadSource.custom.resolvedURL(customURL: "http://example.com/model.gguf")
            fatalError("Custom non-HTTPS download URL must be rejected")
        } catch {}

        // 11. LocalModel dynamic port allocation (port = 0) & conversation parameter decoupling
        let modelFile = folder.appendingPathComponent("conv.gguf")
        try Data([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0] + Array(repeating: UInt8(0), count: 16)).write(to: modelFile)
        let argsFile = folder.appendingPathComponent("captured-args.json")
        let reqFile = folder.appendingPathComponent("captured-req.json")
        let stub = folder.appendingPathComponent("stub-llama-server")
        try #"""
        #!/usr/bin/python3
        import json, pathlib, sys
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        args = sys.argv[1:]
        pathlib.Path(\#(String(reflecting: argsFile.path))).write_text(json.dumps(args))
        port = int(args[args.index('--port') + 1])
        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *a): pass
            def do_GET(self):
                self.send_response(200); self.send_header('Content-Length', '2'); self.end_headers(); self.wfile.write(b'{}')
            def do_POST(self):
                body = self.rfile.read(int(self.headers['Content-Length']))
                pathlib.Path(\#(String(reflecting: reqFile.path))).write_bytes(body)
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.send_header('Connection', 'close'); self.end_headers()
                self.wfile.write(b'data: {"choices":[{"delta":{"content":"Hi"}}]}\n\ndata: [DONE]\n\n'); self.wfile.flush()
                self.close_connection = True
        ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
        """#.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        defaults.set(modelFile.path, forKey: "conversationModelPath")
        let pidFile = folder.appendingPathComponent("conv.pid")
        let convConfig = LocalModel.Configuration(
            binary: stub,
            defaultModel: modelFile,
            port: 0, // Dynamic port!
            log: folder.appendingPathComponent("conversation-runtime.log"),
            idleTimeout: 5,
            startupTimeout: 5,
            observeMemoryPressure: false,
            pidFile: pidFile
        )
        let convModel = LocalModel(conversation: true, defaults: defaults, configuration: convConfig)
        defer { convModel.stop() }
        let bytes = try await convModel.stream(messages: [["role": "user", "content": "hi"]])
        for try await _ in bytes.lines {}
        precondition(convModel.currentPort > 0, "Dynamic port must be allocated")
        precondition(FileManager.default.fileExists(atPath: pidFile.path), "PID file should track active subprocess")
        let launchedArgs = try JSONSerialization.jsonObject(with: Data(contentsOf: argsFile)) as! [String]
        precondition(launchedArgs.contains("nous-conversation") && !launchedArgs.contains("--chat-template-kwargs"),
                     "Conversation runtime must not force Index-Translate alias or enable_thinking=false")
        let reqBody = try JSONSerialization.jsonObject(with: Data(contentsOf: reqFile)) as! [String: Any]
        precondition(reqBody["model"] as? String == "nous-conversation")
        precondition((reqBody["temperature"] as? Double ?? 0) > 0)
        precondition(reqBody["chat_template_kwargs"] == nil)
        convModel.stop()
        precondition(!FileManager.default.fileExists(atPath: pidFile.path), "stop() must remove PID file")

        // 12. Orphan process cleanup verifies executable path before terminating
        let sleepProc = Process()
        sleepProc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleepProc.arguments = ["30"]
        try sleepProc.run()
        defer { if sleepProc.isRunning { sleepProc.terminate() } }
        // Wrong path must NOT kill an unrelated process
        try "\(sleepProc.processIdentifier)\n/nonexistent/llama-server\n".write(to: pidFile, atomically: true, encoding: .utf8)
        await convModel.cleanupOrphanProcess()
        precondition(sleepProc.isRunning, "Orphan cleanup must never kill a process whose executable path does not match")
        // Matching path MUST terminate the orphan
        try "\(sleepProc.processIdentifier)\n/bin/sleep\n".write(to: pidFile, atomically: true, encoding: .utf8)
        await convModel.cleanupOrphanProcess()
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(!sleepProc.isRunning, "Orphan cleanup must terminate a verified stale subprocess")

        print("PASS: localization, structured/fixed prompts, short-ASCII detection, panel compact sizing, task cancellation & attachment cleanup, clipboard budget & transient markers, streaming cache bypass, error detail redaction, global hotkeys, history search/metadata/delete, download mirrors, dynamic local port, decoupled conversation params and verified orphan cleanup")
    }
}
