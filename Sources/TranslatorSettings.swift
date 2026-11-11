import SwiftUI
import AppKit
import ApplicationServices
import UniformTypeIdentifiers
struct HistoryEntry: Identifiable, Codable { var id = UUID(); let date: Date; let source: String; let result: String }
@MainActor final class TranslationHistory: ObservableObject {
    static let shared = TranslationHistory()
    @Published var entries: [HistoryEntry] = []
    private var file: URL { LocalModel.directory.appendingPathComponent("history.json") }
    init() { if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) { entries = saved } }
    func add(source: String, result: String) {
        entries.insert(HistoryEntry(date: Date(), source: source, result: result), at: 0)
        entries = Array(entries.prefix(500)); save()
    }
    func clear() { entries = []; save() }
    private func save() { try? FileManager.default.createDirectory(at: LocalModel.directory, withIntermediateDirectories: true); try? JSONEncoder().encode(entries).write(to: file, options: .atomic) }
}

@MainActor final class SettingsController: NSWindowController {
    let tabs: NSTabViewController
    init() {
        let tabs = NSTabViewController()
        self.tabs = tabs
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        func add<V: View>(_ title: String, _ symbol: String, _ view: V) {
            let host = NSHostingController(rootView: view.frame(width: 680, height: 540))
            host.title = title
            host.preferredContentSize = NSSize(width: 680, height: 540)
            let item = NSTabViewItem(viewController: host)
            item.label = title; item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add("General", "gearshape", GeneralSettings())
        add("Models", "cpu", ModelsSettings())
        add("Images", "text.viewfinder", Form { ImageRecognitionSettings() }.formStyle(.grouped))
        add("Permissions", "hand.raised", PermissionSettings())
        add("History", "clock", HistorySettings())
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = "Nous Translator Settings"
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 680, height: 540))
        super.init(window: window)
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    func present(models: Bool = false) {
        if models { tabs.selectedTabViewItemIndex = 1 }
        window?.toolbar?.displayMode = .iconAndLabel
        showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
struct GeneralSettings: View {
    @AppStorage("keepLocalTranslationReady") private var keepReady = true
    @AppStorage("translationResponseMode") private var responseMode = TranslationResponseMode.fast.rawValue
    var body: some View {
        Form {
            TranslationLanguageSettings()
            Section {
                Picker("Online translation", selection: $responseMode) {
                    ForEach(TranslationResponseMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Prepare local translation model", isOn: $keepReady)
            } header: { Text("Response Time") } footer: {
                Text("Fast reduces reasoning for supported OpenAI translation models; Model default leaves more time for difficult passages. Your selected model stays the same. Local preparation loads only the translation model and releases it after five idle minutes or when memory is low.")
            }
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "NousReleaseVersion") as? String ?? "Development")
            } header: { Text("Nous Translator") }
        }.formStyle(.grouped)
            .onChange(of: keepReady) { _, _ in LocalModel.shared.refreshPrewarming() }
    }
}
struct PermissionSettings: View {
    @State private var trusted = AXIsProcessTrusted()
    var body: some View {
        Form {
            Section {
                LabeledContent("Accessibility") {
                    Label(trusted ? "Allowed" : "Not Allowed", systemImage: trusted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(trusted ? Color.green : Color.secondary)
                }
                HStack {
                    Spacer()
                    Button("Open System Settings…") {
                        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            } header: { Text("Selection Translation") } footer: {
                Text("Allow Nous Translator to read selected text in other apps. Clipboard translation does not require Accessibility access.")
            }
        }.formStyle(.grouped)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in trusted = AXIsProcessTrusted() }
    }
}
struct ModelsSettings: View {
    @AppStorage("translationProvider") private var translation = ModelProvider.local.rawValue
    @AppStorage("conversationProvider") private var conversation = ModelProvider.unconfigured.rawValue
    @AppStorage("modelPath") private var modelPath = ""
    @AppStorage("conversationModelPath") private var conversationPath = ""
    @State private var provider = ModelProvider.openai
    @State private var profile = APIProfile.load(.openai)
    @State private var key = ""
    @State private var status = ""
    @State private var testing = false
    @State private var localModelsExpanded = true
    @StateObject private var download = ModelDownload.shared
    private var providers: [ModelProvider] { [.openai, .deepseek, .custom] }
    var body: some View {
        Form {
            Section {
                Picker("Selection translation", selection: $translation) {
                    ForEach(ModelProvider.allCases.filter { $0 != .unconfigured }) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Conversation", selection: $conversation) {
                    ForEach(ModelProvider.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: { Text("Use Models For") } footer: {
                Text("Use a general-purpose model for conversation. Only the selected online provider receives your text and conversation context.")
            }
            Section {
                DisclosureGroup("Index-Translate and Local GGUF Models", isExpanded: $localModelsExpanded) {
                LabeledContent("Translation model") { Text(modelPath.isEmpty ? "Index-Translate-2B" : URL(fileURLWithPath: modelPath).lastPathComponent).lineLimit(1) }
                HStack {
                    Spacer()
                    Button("Choose Translation Model…") { choose(conversation: false) }
                    Button("Use Index-Translate") { modelPath = ""; LocalModel.shared.stop(); LocalModel.shared.prewarmIfNeeded() }
                }
                LabeledContent("Conversation model") { Text(conversationPath.isEmpty ? "Not selected" : URL(fileURLWithPath: conversationPath).lastPathComponent).lineLimit(1) }
                HStack { Spacer(); Button("Choose Conversation Model…") { choose(conversation: true) } }
                HStack {
                    Text(download.installed ? "Index-Translate is downloaded" : "Index-Translate · 1.3 GB").foregroundStyle(.secondary)
                    Spacer()
                    if download.running { Button("Cancel") { download.cancel() } }
                    else { Button(download.installed ? "Download Again" : "Download") { download.start() } }
                }
                if download.running {
                    if let progress = download.progress { ProgressView(value: progress).accessibilityLabel("Model download progress") }
                    else { ProgressView().controlSize(.small) }
                }
                if !download.status.isEmpty { Text(download.status).font(.caption).foregroundStyle(.secondary) }
                }
            } header: { Text("On This Mac") } footer: { Text("Download Index-Translate to translate locally without an API key. After downloading, allow Accessibility in Permissions to enable selection translation. Changing a local model stops its current generation.") }
            Section {
                Picker("Provider", selection: $provider) { ForEach(providers) { Text($0.title).tag($0) } }.disabled(testing)
                if provider == .custom {
                    TextField("Base URL", text: $profile.baseURL, prompt: Text("https://example.com/v1"))
                } else { LabeledContent("Base URL", value: profile.baseURL) }
                TextField("Model ID", text: $profile.model, prompt: Text("Enter the model ID from your provider"))
                SecureField("API key", text: $key, prompt: Text("Leave blank to keep the saved key"))
                HStack {
                    Button("Remove Saved Key") { do { try APIKeyStore.delete(profile.account); status = "Saved key removed." } catch { status = error.localizedDescription } }
                    Spacer()
                    Button("Save") { save() }.disabled(testing)
                    Button(testing ? "Testing…" : "Test Connection") { test() }.disabled(testing)
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            } header: { Text("API Connection") } footer: {
                Text("Keys are stored in macOS Keychain. Custom API uses the OpenAI Chat Completions format. Test Connection sends a short test message and may incur a small API charge.")
            }


        }.formStyle(.grouped)
            .onAppear { download.refreshInstalled(); localModelsExpanded = !download.installed }
            .onChange(of: provider) { _, selected in profile = APIProfile.load(selected); key = ""; status = "" }
            .onChange(of: translation) { _, _ in LocalModel.shared.refreshPrewarming() }
    }
    @discardableResult private func save() -> Bool {
        do {
            _ = try profile.endpoint()
            guard !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelError.message("Enter a model ID.") }
            if !key.isEmpty { try APIKeyStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines), account: profile.account); key = "" }
            profile.save(); status = "Saved. Select this provider above to use it."; return true
        } catch { status = error.localizedDescription; return false }
    }
    private func test() {
        guard save() else { return }; testing = true; status = "Connecting…"
        let chosen = profile
        Task {
            defer { testing = false }
            do {
                let stream = try await ModelRouter.remoteStream(profile: chosen, messages: [["role": "user", "content": "Reply with OK."]])
                _ = try await CompletionReader.read(stream) { _ in }
                status = "Connected. The model returned a response."
            } catch { status = error.localizedDescription }
        }
    }
    private func choose(conversation: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if conversation { conversationPath = url.path; LocalModel.conversation.stop() }
        else { modelPath = url.path; LocalModel.shared.stop(); LocalModel.shared.prewarmIfNeeded() }
    }
}
struct HistorySettings: View {
    @ObservedObject private var history = TranslationHistory.shared
    @State private var clearConfirmation = false
    var body: some View {
        VStack(spacing: 0) {
            if history.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock").font(.system(size: 32)).foregroundStyle(.tertiary)
                    Text("No Translation History").font(.headline)
                    Text("Your new translations will appear here.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(history.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.date, style: .date).font(.caption).foregroundStyle(.secondary)
                        Text(entry.source).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        CopyableReply(text: entry.result)
                    }.padding(.vertical, 6)
                }
            }
            Divider()
            HStack {
                Text("Stored on this Mac · Up to 500 translations").font(.caption).foregroundStyle(.secondary)
                Spacer(); Button("Clear History…") { clearConfirmation = true }.disabled(history.entries.isEmpty)
            }.padding(16)
        }.confirmationDialog("Clear all translation history?", isPresented: $clearConfirmation) { Button("Clear History", role: .destructive) { history.clear() } }
    }
}
private final class ModelFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    // Download delegate callbacks are serialized by URLSession's delegate queue.
    private var result: Result<(URL, URLResponse), Error>?
    init(update: @escaping @Sendable (Int64, Int64) -> Void) { self.update = update }
    func download(from source: URL, configuration: URLSessionConfiguration) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: source)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        update(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // URLSession removes its temporary file when this callback returns. Retain a file,
        // not the model's bytes in memory, until validation and atomic installation finish.
        let retained = FileManager.default.temporaryDirectory.appendingPathComponent("nous-model-" + UUID().uuidString + ".download")
        do {
            guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at: location, to: retained)
            result = .success((retained, response))
        } catch { result = .failure(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let completion = continuation; continuation = nil; self.task = nil; lock.unlock()
        session.finishTasksAndInvalidate()
        if let error {
            if case let .success((file, _)) = result { try? FileManager.default.removeItem(at: file) }
            completion?.resume(throwing: error)
        } else { completion?.resume(with: result ?? .failure(URLError(.badServerResponse))) }
    }
}

@MainActor final class ModelDownload: ObservableObject {
    static let shared = ModelDownload()
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published private(set) var installed = false
    @Published private(set) var progress: Double?
    private let destination: URL
    private let source: URL
    private let configuration: URLSessionConfiguration
    private let minimumBytes: Int64
    private var work: Task<Void, Never>?
    private var generation = UUID()

    init(destination: URL? = nil,
         source: URL = URL(string: "https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF/resolve/main/Index-Translate-2B.Q4_K_M.gguf")!,
         configuration: URLSessionConfiguration = .default, minimumBytes: Int64 = 1_000_000_000) {
        self.destination = destination ?? LocalModel.defaultModelURL; self.source = source
        self.configuration = configuration; self.minimumBytes = minimumBytes
        refreshInstalled()
    }
    func refreshInstalled() { installed = LocalModelFile.hasGGUFHeader(at: destination, minimumBytes: minimumBytes) }
    func cancel() { guard running else { return }; status = "Cancelling…"; work?.cancel() }
    func start() {
        guard !running else { return }
        running = true; progress = nil; status = "Connecting to the model download…"
        let token = UUID(); generation = token
        work = Task {
            let config = configuration.copy() as! URLSessionConfiguration
            config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 3600
            defer { running = false; work = nil }
            do {
                let transfer = ModelFileDownload { [weak self] received, expected in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.running, self.work?.isCancelled != true else { return }
                        self.progress = expected > 0 ? min(1, Double(received) / Double(expected)) : nil
                        let downloaded = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                        let total = expected > 0 ? " of " + ByteCountFormatter.string(fromByteCount: expected, countStyle: .file) : ""
                        self.status = "Downloading " + downloaded + total + "…"
                    }
                }
                let (temp, response) = try await transfer.download(from: source, configuration: config)
                defer { try? FileManager.default.removeItem(at: temp) }
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    throw ModelError.message("The model server could not complete the download. Please try again.")
                }
                status = "Checking download…"
                let size = Int64(try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                guard LocalModelFile.hasGGUFHeader(at: temp, minimumBytes: minimumBytes),
                      response.expectedContentLength < 0 || response.expectedContentLength == size else {
                    throw ModelError.message("The download is incomplete or is not a supported GGUF model. Please try again.")
                }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Stage on the destination volume, then replace atomically. A failed or cancelled
                // download never removes an existing model; a corrupt existing file can be repaired.
                let staged = destination.deletingLastPathComponent().appendingPathComponent(".model-" + UUID().uuidString + ".gguf")
                defer { try? FileManager.default.removeItem(at: staged) }
                try FileManager.default.moveItem(at: temp, to: staged)
                try Task.checkCancellation()
                if destination == LocalModel.defaultModelURL { LocalModel.shared.stop() }
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
                } else { try FileManager.default.moveItem(at: staged, to: destination) }
                refreshInstalled(); progress = 1; status = "Download complete. You can translate now."
                if destination == LocalModel.defaultModelURL { LocalModel.shared.prewarmIfNeeded() }
            } catch is CancellationError {
                progress = nil; status = "Download cancelled. You can retry at any time."
            } catch let error as URLError where error.code == .cancelled {
                progress = nil; status = "Download cancelled. You can retry at any time."
            } catch {
                progress = nil; status = "Download failed: " + error.localizedDescription
            }
        }
    }
}
