import SwiftUI
import AppKit
import ApplicationServices
import CryptoKit
import UniformTypeIdentifiers

struct HistoryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    let date: Date
    let source: String
    let result: String
    var sourceLanguage: String? = nil
    var targetLanguage: String? = nil
    var app: String? = nil
    var provider: String? = nil

    var directionSummary: String? {
        guard let targetCode = targetLanguage, let target = TranslationLanguage(rawValue: targetCode) else { return nil }
        let sourceLabel = sourceLanguage.map { DetectedTranslationLanguage(code: $0).shortName }
        if let sourceLabel { return "\(sourceLabel) → \(target.shortName)" }
        return "→ \(target.shortName)"
    }
}

@MainActor final class TranslationHistory: ObservableObject {
    static let shared = TranslationHistory()
    @Published var entries: [HistoryEntry] = []
    private let file: URL
    private let ioQueue = DispatchQueue(label: "com.nous.translator.history", qos: .utility)

    init(file: URL? = nil) {
        self.file = file ?? LocalModel.directory.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: self.file),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    func add(source: String, result: String, sourceLanguage: String? = nil, targetLanguage: String? = nil, app: String? = nil, provider: String? = nil) {
        entries.insert(HistoryEntry(date: Date(), source: source, result: result,
                                    sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                                    app: app, provider: provider), at: 0)
        entries = Array(entries.prefix(500))
        save()
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func filtered(matching query: String) -> [HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.source.localizedCaseInsensitiveContains(needle)
                || $0.result.localizedCaseInsensitiveContains(needle)
                || ($0.app?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        let snapshot = entries
        let targetFile = file
        ioQueue.async {
            try? FileManager.default.createDirectory(at: targetFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: targetFile, options: .atomic)
            }
        }
    }
}

@MainActor final class SettingsController: NSWindowController {
    let tabs: NSTabViewController
    init() {
        let tabs = NSTabViewController()
        self.tabs = tabs
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        func add<V: View>(_ title: String, _ symbol: String, _ view: V) {
            let host = NSHostingController(rootView: view.frame(minWidth: 680, minHeight: 540))
            host.title = title
            host.preferredContentSize = NSSize(width: 680, height: 540)
            let item = NSTabViewItem(viewController: host)
            item.label = title; item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add(L10n.text("General", zh: "通用"), "gearshape", GeneralSettings())
        add(L10n.text("Models", zh: "模型"), "cpu", ModelsSettings())
        add(L10n.text("Images", zh: "图片识别"), "text.viewfinder", Form { ImageRecognitionSettings() }.formStyle(.grouped))
        add(L10n.text("Permissions", zh: "权限"), "hand.raised", PermissionSettings())
        add(L10n.text("History", zh: "历史"), "clock", HistorySettings())
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = L10n.text("Nous Translator Settings", zh: "Nous Translator 设置")
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 540)
        window.setContentSize(NSSize(width: 680, height: 540))
        super.init(window: window)
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    func refreshLocalizedChrome() {
        window?.title = L10n.text("Nous Translator Settings", zh: "Nous Translator 设置")
        let titles = [
            L10n.text("General", zh: "通用"),
            L10n.text("Models", zh: "模型"),
            L10n.text("Images", zh: "图片识别"),
            L10n.text("Permissions", zh: "权限"),
            L10n.text("History", zh: "历史")
        ]
        for (index, title) in titles.enumerated() where index < tabs.tabViewItems.count {
            tabs.tabViewItems[index].label = title
        }
    }
    func present(models: Bool = false, updates: Bool = false) {
        if models { tabs.selectedTabViewItemIndex = 1 }
        else if updates { tabs.selectedTabViewItemIndex = 0 }
        window?.toolbar?.displayMode = .iconAndLabel
        showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

struct GeneralSettings: View {
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
    @AppStorage("keepLocalTranslationReady") private var keepReady = true
    @AppStorage("translationResponseMode") private var responseMode = TranslationResponseMode.fast.rawValue
    @ObservedObject private var hotKeys = GlobalHotKeyManager.shared
    @ObservedObject private var updater = AppUpdater.shared

    private var highlightUpdateAtTop: Bool {
        switch updater.state {
        case .available, .downloading, .verifying, .installing, .failed: return true
        default: return false
        }
    }

    var body: some View {
        Form {
            if highlightUpdateAtTop {
                SoftwareUpdateSettingsSection(updater: updater)
            }
            TranslationLanguageSettings()
            Section {
                Picker(L10n.text("Online translation", zh: "在线翻译速度"), selection: $responseMode) {
                    ForEach(TranslationResponseMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle(L10n.text("Prepare local translation model", zh: "预热本地翻译模型"), isOn: $keepReady)
            } header: { Text(L10n.text("Response Time", zh: "响应速度")) } footer: {
                Text(L10n.text(
                    "Fast reduces reasoning for supported OpenAI translation models; Model default leaves more time for difficult passages. Your selected model stays the same. Local preparation loads only the translation model and releases it after five idle minutes or when memory is low.",
                    zh: "“快速”会降低受支持 OpenAI 翻译模型的推理强度；“模型默认”保留服务商默认行为。本地预热仅提前加载翻译模型，闲置五分钟或内存不足时自动释放。"
                ))
            }
            Section {
                ForEach(GlobalHotKeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        HotKeyRecorderControl(action: action, manager: hotKeys)
                    }
                }
                HStack {
                    Spacer()
                    Button(L10n.text("Reset Defaults", zh: "恢复默认快捷键")) {
                        hotKeys.resetDefaults()
                    }
                }
            } header: { Text(L10n.text("Global Shortcuts", zh: "全局快捷键")) } footer: {
                Text(L10n.text(
                    "Global shortcuts work without Accessibility permission. Screen region capture uses macOS Screen Recording permission.",
                    zh: "全局快捷键无需辅助功能权限；截图识别翻译需允许 macOS 录屏权限。"
                ))
            }
            if !highlightUpdateAtTop {
                SoftwareUpdateSettingsSection(updater: updater)
            }
            Section {
                Picker(L10n.text("Interface language", zh: "界面语言"), selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: { Text("Nous Translator") }
        }.formStyle(.grouped)
            .id(appLanguage)
            .onChange(of: keepReady) { _, _ in LocalModel.shared.refreshPrewarming() }
    }
}

struct PermissionSettings: View {
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
    @State private var trusted = AXIsProcessTrusted()
    private var perApplication: Bool { SelectionPermissionRules.usesPerApplicationAccess() }
    var body: some View {
        Form {
            Section {
                LabeledContent(perApplication ? "System & App Protection Override" : L10n.text("Accessibility", zh: "辅助功能")) {
                    if perApplication {
                        Text(L10n.text("Managed by macOS", zh: "由 macOS 按应用管理")).foregroundStyle(.secondary)
                    } else {
                        Label(trusted ? L10n.text("Allowed", zh: "已允许") : L10n.text("Not Allowed", zh: "未允许"),
                              systemImage: trusted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(trusted ? Color.green : Color.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button(L10n.text("Open System Settings…", zh: "打开系统设置…")) {
                        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            } header: { Text(L10n.text("Selection Translation", zh: "划词翻译权限")) } footer: {
                Text(perApplication
                    ? L10n.text(
                        "Click + in System Settings, choose Nous Translator, then Choose Apps and select Nous Browser or the apps you want to translate in. Clipboard translation and global shortcuts do not need this permission.",
                        zh: "在系统设置中点击 + 选择 Nous Translator，再点 Choose Apps 选择需要划词的应用（如 Nous Browser）。剪贴板翻译和全局快捷键不需要此权限。"
                    )
                    : L10n.text(
                        "Allow Nous Translator to read selected text in other apps. Clipboard translation does not require Accessibility access.",
                        zh: "允许 Nous Translator 读取其他应用中的选中文字。剪贴板翻译不需要辅助功能权限。"
                    ))
            }
        }.formStyle(.grouped)
            .id(appLanguage)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in trusted = AXIsProcessTrusted() }
    }
}

enum ModelDownloadSource: String, CaseIterable, Identifiable {
    case huggingface, hfMirror, custom
    var id: String { rawValue }
    static let storageKey = "modelDownloadSource"
    static let customURLKey = "modelDownloadCustomURL"
    static let officialPath = "IndexTeam/Index-Translate-2B-GGUF/resolve/main/Index-Translate-2B.Q4_K_M.gguf"
    static let officialSHA256 = "044b313d29342bd3b2c77cbb64023ca0d209bd9b3247763f9d162767ef2d746a"

    var title: String {
        switch self {
        case .huggingface: return "Hugging Face"
        case .hfMirror: return "HF-Mirror"
        case .custom: return L10n.text("Custom HTTPS URL", zh: "自定义 HTTPS 地址")
        }
    }

    func resolvedURL(customURL: String) throws -> URL {
        switch self {
        case .huggingface:
            return URL(string: "https://huggingface.co/" + Self.officialPath)!
        case .hfMirror:
            return URL(string: "https://hf-mirror.com/" + Self.officialPath)!
        case .custom:
            let trimmed = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let host = components.host, !host.isEmpty,
                  components.scheme == "https" || (components.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else {
                throw ModelError.message(L10n.text("Enter a valid HTTPS model download URL.", zh: "请输入有效的 HTTPS 模型下载地址。"))
            }
            return url
        }
    }
}

struct ModelsSettings: View {
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
    @AppStorage("translationProvider") private var translation = ModelProvider.local.rawValue
    @AppStorage("conversationProvider") private var conversation = ModelProvider.unconfigured.rawValue
    @AppStorage("modelPath") private var modelPath = ""
    @AppStorage("conversationModelPath") private var conversationPath = ""
    @AppStorage(ModelDownloadSource.storageKey) private var downloadSourceRaw = ModelDownloadSource.huggingface.rawValue
    @AppStorage(ModelDownloadSource.customURLKey) private var customDownloadURL = ""
    @State private var provider = ModelProvider.openai
    @State private var profile = APIProfile.load(.openai)
    @State private var key = ""
    @State private var keySaved = false
    @State private var status = ""
    @State private var testing = false
    @State private var localModelsExpanded = true
    @StateObject private var download = ModelDownload.shared
    private var providers: [ModelProvider] { [.openai, .deepseek, .custom] }
    private var downloadSource: ModelDownloadSource { ModelDownloadSource(rawValue: downloadSourceRaw) ?? .huggingface }
    private var hasUnsavedChanges: Bool {
        let saved = APIProfile.load(provider)
        return profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) != saved.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            || profile.model.trimmingCharacters(in: .whitespacesAndNewlines) != saved.model.trimmingCharacters(in: .whitespacesAndNewlines)
            || !key.isEmpty
    }

    var body: some View {
        Form {
            Section {
                Picker(L10n.text("Selection translation", zh: "划词翻译"), selection: $translation) {
                    ForEach(ModelProvider.allCases.filter { $0 != .unconfigured }) { Text($0.title).tag($0.rawValue) }
                }
                Picker(L10n.text("Conversation", zh: "通用对话"), selection: $conversation) {
                    ForEach(ModelProvider.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: { Text(L10n.text("Use Models For", zh: "模型用途")) } footer: {
                Text(L10n.text(
                    "Use a general-purpose model for conversation. Only the selected online provider receives your text and conversation context.",
                    zh: "通用对话需使用通用模型。仅所选在线服务会收到你的文本和对话上下文。"
                ))
            }
            Section {
                DisclosureGroup(L10n.text("Index-Translate and Local GGUF Models", zh: "Index-Translate 与本地 GGUF 模型"), isExpanded: $localModelsExpanded) {
                    LabeledContent(L10n.text("Translation model", zh: "翻译模型")) {
                        Text(modelPath.isEmpty ? "Index-Translate-2B" : URL(fileURLWithPath: modelPath).lastPathComponent).lineLimit(1)
                    }
                    HStack {
                        Spacer()
                        Button(L10n.text("Choose Translation Model…", zh: "选择翻译模型…")) { choose(conversation: false) }
                        Button(L10n.text("Use Index-Translate", zh: "使用 Index-Translate")) { modelPath = ""; LocalModel.shared.stop(); LocalModel.shared.prewarmIfNeeded() }
                    }
                    LabeledContent(L10n.text("Conversation model", zh: "对话模型")) {
                        Text(conversationPath.isEmpty ? L10n.text("Not selected", zh: "未选择") : URL(fileURLWithPath: conversationPath).lastPathComponent).lineLimit(1)
                    }
                    HStack { Spacer(); Button(L10n.text("Choose Conversation Model…", zh: "选择对话模型…")) { choose(conversation: true) } }
                    Picker(L10n.text("Download source", zh: "下载源"), selection: $downloadSourceRaw) {
                        ForEach(ModelDownloadSource.allCases) { Text($0.title).tag($0.rawValue) }
                    }.disabled(download.running)
                    if downloadSource == .custom {
                        TextField(L10n.text("Model URL", zh: "模型地址"), text: $customDownloadURL, prompt: Text("https://example.com/Index-Translate-2B.Q4_K_M.gguf"))
                            .disabled(download.running)
                    }
                    HStack {
                        Text(download.installed
                             ? L10n.text("Index-Translate is downloaded", zh: "Index-Translate 已下载")
                             : L10n.text("Index-Translate · 1.3 GB (SHA-256 verified)", zh: "Index-Translate · 1.3 GB（含 SHA-256 校验）"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if download.running {
                            Button(L10n.text("Cancel", zh: "取消")) { download.cancel() }
                        } else {
                            if download.canResume {
                                Button(L10n.text("Resume", zh: "继续下载")) { startConfiguredDownload() }
                            } else {
                                Button(download.installed ? L10n.text("Download Again", zh: "重新下载") : L10n.text("Download", zh: "下载")) {
                                    startConfiguredDownload()
                                }
                            }
                        }
                    }
                    if download.running {
                        if let progress = download.progress { ProgressView(value: progress).accessibilityLabel("Model download progress") }
                        else { ProgressView().controlSize(.small) }
                    }
                    if !download.status.isEmpty { Text(download.status).font(.caption).foregroundStyle(.secondary) }
                }
            } header: { Text(L10n.text("On This Mac", zh: "本机模型")) } footer: {
                Text(L10n.text(
                    "Download Index-Translate to translate locally without an API key. Cancelling preserves resume progress. Changing a local model stops its current generation.",
                    zh: "下载 Index-Translate 即可免 Key 本地翻译；取消支持断点续传。更换本地模型会停止当前生成。"
                ))
            }
            Section {
                Picker(L10n.text("Provider", zh: "服务商"), selection: $provider) { ForEach(providers) { Text($0.title).tag($0) } }.disabled(testing)
                if provider == .custom {
                    TextField(L10n.text("Base URL", zh: "服务地址"), text: $profile.baseURL, prompt: Text("https://example.com/v1"))
                } else { LabeledContent(L10n.text("Base URL", zh: "服务地址"), value: profile.baseURL) }
                TextField(L10n.text("Model ID", zh: "模型 ID"), text: $profile.model, prompt: Text(L10n.text("Enter the model ID from your provider", zh: "填写服务商的模型 ID")))
                SecureField("API key", text: $key, prompt: Text(keySaved
                    ? L10n.text("Saved in Keychain · Leave blank to keep", zh: "已存于钥匙串 · 留空保持不变")
                    : L10n.text("Enter your API key", zh: "输入你的 API Key")))
                HStack(spacing: 6) {
                    Label(keySaved
                          ? L10n.text("API key saved in Keychain", zh: "已保存 API Key（钥匙串）")
                          : L10n.text("No saved key for this address", zh: "当前地址未保存 Key"),
                          systemImage: keySaved ? "checkmark.seal.fill" : "key")
                        .font(.caption)
                        .foregroundStyle(keySaved ? Color.green : Color.secondary)
                    if hasUnsavedChanges {
                        Spacer()
                        Text(L10n.text("Unsaved changes", zh: "有未保存更改"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                HStack {
                    Button(L10n.text("Remove Saved Key", zh: "删除已保存 Key")) {
                        do {
                            try APIKeyStore.delete(profile.account)
                            keySaved = false
                            status = L10n.text("Saved key removed.", zh: "已删除保存的 Key。")
                        } catch { status = error.localizedDescription }
                    }.disabled(!keySaved)
                    Spacer()
                    Button(L10n.text("Save", zh: "保存")) { save() }.disabled(testing)
                    Button(testing ? L10n.text("Testing…", zh: "测试中…") : L10n.text("Test Connection", zh: "测试连接")) { test() }.disabled(testing)
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            } header: { Text(L10n.text("API Connection", zh: "在线 API 连接")) } footer: {
                Text(L10n.text(
                    "Keys are stored in macOS Keychain. Custom API uses the OpenAI Chat Completions format. Test Connection sends a short test message and may incur a small API charge.",
                    zh: "Key 保存在 macOS 钥匙串中。自定义 API 兼容 OpenAI Chat Completions 格式。测试连接会发送简短请求，可能产生少量费用。"
                ))
            }
        }.formStyle(.grouped)
            .id(appLanguage)
            .onAppear {
                download.refreshInstalled()
                localModelsExpanded = !download.installed
                keySaved = APIKeyStore.hasSavedKey(profile.account)
            }
            .onChange(of: provider) { _, selected in
                profile = APIProfile.load(selected); key = ""; status = ""
                keySaved = APIKeyStore.hasSavedKey(profile.account)
            }
            .onChange(of: profile.baseURL) { _, _ in
                keySaved = APIKeyStore.hasSavedKey(profile.account)
            }
            .onChange(of: translation) { _, _ in LocalModel.shared.refreshPrewarming() }
    }

    private func startConfiguredDownload() {
        do {
            let url = try downloadSource.resolvedURL(customURL: customDownloadURL)
            let expectedHash = downloadSource == .custom ? nil : ModelDownloadSource.officialSHA256
            download.start(from: url, expectedSHA256: expectedHash)
        } catch {
            download.setError(error.localizedDescription)
        }
    }

    @discardableResult private func save() -> Bool {
        do {
            _ = try profile.endpoint()
            guard !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ModelError.message(L10n.text("Enter a model ID.", zh: "请输入模型 ID。"))
            }
            if !key.isEmpty {
                try APIKeyStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines), account: profile.account)
                key = ""
                keySaved = true
            }
            profile.save()
            status = L10n.text("Saved. Select this provider above to use it.", zh: "已保存。可在上方用途中选择此服务商。")
            return true
        } catch { status = error.localizedDescription; return false }
    }
    private func test() {
        guard save() else { return }; testing = true; status = L10n.text("Connecting…", zh: "连接中…")
        let chosen = profile
        Task {
            defer { testing = false }
            do {
                let stream = try await ModelRouter.remoteStream(profile: chosen, messages: [["role": "user", "content": "Reply with OK."]])
                _ = try await CompletionReader.read(stream) { _ in }
                status = L10n.text("Connected. The model returned a response.", zh: "连接成功，模型已返回响应。")
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
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
    @ObservedObject private var history = TranslationHistory.shared
    @State private var searchText = ""
    @State private var clearConfirmation = false

    private var displayedEntries: [HistoryEntry] {
        history.filtered(matching: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !history.entries.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.text("Search history…", zh: "搜索历史记录…"), text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .padding([.horizontal, .top], 12).padding(.bottom, 6)
            }
            if history.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock").font(.system(size: 32)).foregroundStyle(.tertiary)
                    Text(L10n.text("No Translation History", zh: "暂无翻译历史")).font(.headline)
                    Text(L10n.text("Your new translations will appear here.", zh: "新的翻译记录将显示在这里。")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayedEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(L10n.text("No matching translations", zh: "没有匹配的翻译记录")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(displayedEntries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(entry.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            if let direction = entry.directionSummary {
                                Text(direction).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.08), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                            if let app = entry.app, !app.isEmpty {
                                Text(app).font(.caption).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.source, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc").font(.caption)
                            }.buttonStyle(.plain).foregroundStyle(.secondary)
                                .help(L10n.text("Copy source", zh: "复制原文"))
                            Button {
                                NotificationCenter.default.post(name: .init("NousOpenHistoryEntry"), object: entry)
                            } label: {
                                Image(systemName: "arrow.up.right.square").font(.caption)
                            }.buttonStyle(.plain).foregroundStyle(.secondary)
                                .help(L10n.text("Open in translation panel", zh: "在翻译浮窗中打开"))
                            Button(role: .destructive) {
                                history.delete(id: entry.id)
                            } label: {
                                Image(systemName: "trash").font(.caption)
                            }.buttonStyle(.plain).foregroundStyle(.secondary)
                                .help(L10n.text("Delete entry", zh: "删除此条记录"))
                        }
                        Text(entry.source).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        CopyableReply(text: entry.result, speakID: "history:" + entry.id.uuidString)
                    }.padding(.vertical, 6)
                }
            }
            Divider()
            HStack {
                Text(L10n.text(
                    "Stored on this Mac · \(history.entries.count) / 500 translations",
                    zh: "保存在本机 · 共 \(history.entries.count) / 500 条"
                )).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("Clear History…", zh: "清除历史…")) { clearConfirmation = true }
                    .disabled(history.entries.isEmpty)
            }.padding(16)
        }
        .id(appLanguage)
        .confirmationDialog(L10n.text("Clear all translation history?", zh: "确认清除所有翻译历史？"), isPresented: $clearConfirmation) {
            Button(L10n.text("Clear History", zh: "清除历史"), role: .destructive) { history.clear() }
        }
    }
}

private final class ModelFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Int64, Int64) -> Void
    let onResumeData: @Sendable (Data) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    // Download delegate callbacks are serialized by URLSession's delegate queue.
    private var result: Result<(URL, URLResponse), Error>?

    init(update: @escaping @Sendable (Int64, Int64) -> Void, onResumeData: @escaping @Sendable (Data) -> Void = { _ in }) {
        self.update = update
        self.onResumeData = onResumeData
    }

    func download(from source: URL, resumeData: Data?, configuration: URLSessionConfiguration) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task: URLSessionDownloadTask
                if let resumeData {
                    task = session.downloadTask(withResumeData: resumeData)
                } else {
                    task = session.downloadTask(with: source)
                }
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock()
        guard let task else { return }
        let saveResume = self.onResumeData
        task.cancel { data in
            if let data, !data.isEmpty { saveResume(data) }
        }
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
            let nsError = error as NSError
            if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, !data.isEmpty {
                onResumeData(data)
            }
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
    @Published private(set) var canResume = false
    private let destination: URL
    private var defaultSource: URL
    private let configuration: URLSessionConfiguration
    private let minimumBytes: Int64
    private let defaultExpectedSHA256: String?
    private let resumeFile: URL
    private var resumeSourceURL: URL?
    private var resumeData: Data?
    private var work: Task<Void, Never>?
    private var generation = UUID()

    init(destination: URL? = nil,
         source: URL = URL(string: "https://huggingface.co/" + ModelDownloadSource.officialPath)!,
         configuration: URLSessionConfiguration = .default,
         minimumBytes: Int64 = 1_000_000_000,
         expectedSHA256: String? = nil) {
        self.destination = destination ?? LocalModel.defaultModelURL
        self.defaultSource = source
        self.configuration = configuration
        self.minimumBytes = minimumBytes
        self.defaultExpectedSHA256 = expectedSHA256
        self.resumeFile = self.destination.deletingLastPathComponent().appendingPathComponent(".download-resume.dat")
        refreshInstalled()
        loadSavedResumeData()
    }

    func refreshInstalled() { installed = LocalModelFile.hasGGUFHeader(at: destination, minimumBytes: minimumBytes) }
    func setError(_ message: String) { status = L10n.text("Download failed: ", zh: "下载失败：") + message }
    func cancel() { guard running else { return }; status = L10n.text("Cancelling…", zh: "正在取消…"); work?.cancel() }

    private func loadSavedResumeData() {
        guard let data = try? Data(contentsOf: resumeFile), !data.isEmpty else {
            resumeData = nil; canResume = false; return
        }
        resumeData = data
        canResume = true
    }

    private func storeResumeData(_ data: Data, for source: URL) {
        resumeData = data
        resumeSourceURL = source
        canResume = true
        try? FileManager.default.createDirectory(at: resumeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: resumeFile, options: .atomic)
    }

    private func clearResumeData() {
        resumeData = nil
        resumeSourceURL = nil
        canResume = false
        try? FileManager.default.removeItem(at: resumeFile)
    }

    func start() {
        start(from: defaultSource, expectedSHA256: defaultExpectedSHA256)
    }

    func start(from source: URL, expectedSHA256: String?) {
        guard !running else { return }
        running = true; progress = nil; status = L10n.text("Connecting to the model download…", zh: "正在连接模型下载服务器…")
        let token = UUID(); generation = token
        let initialResume: Data? = (resumeSourceURL == nil || resumeSourceURL == source) ? resumeData : nil
        if initialResume == nil && resumeData != nil { clearResumeData() }
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 3600
        let destination = self.destination
        let minimumBytes = self.minimumBytes

        work = Task { [weak self] in
            guard let self else { return }
            defer { self.running = false; self.work = nil }
            do {
                let transfer = ModelFileDownload(update: { [weak self] received, expected in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.running, self.work?.isCancelled != true else { return }
                        self.progress = expected > 0 ? min(1, Double(received) / Double(expected)) : nil
                        let downloaded = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                        let total = expected > 0 ? " / " + ByteCountFormatter.string(fromByteCount: expected, countStyle: .file) : ""
                        self.status = L10n.text("Downloading ", zh: "正在下载 ") + downloaded + total + "…"
                    }
                }, onResumeData: { [weak self] data in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.storeResumeData(data, for: source)
                    }
                })
                let (temp, response) = try await transfer.download(from: source, resumeData: initialResume, configuration: config)
                defer { try? FileManager.default.removeItem(at: temp) }
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse, [200, 206].contains(response.statusCode) else {
                    self.clearResumeData()
                    throw ModelError.message(L10n.text("The model server could not complete the download. Please try again.",
                                                       zh: "模型服务器无法完成下载，请重试。"))
                }
                self.status = L10n.text("Checking download…", zh: "正在校验下载文件…")
                let size = Int64(try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                let lengthValid = response.statusCode == 206 || response.expectedContentLength < 0 || response.expectedContentLength == size
                guard LocalModelFile.hasGGUFHeader(at: temp, minimumBytes: minimumBytes), lengthValid else {
                    self.clearResumeData()
                    throw ModelError.message(L10n.text("The download is incomplete or is not a supported GGUF model. Please try again.",
                                                       zh: "下载不完整或不是有效的 GGUF 模型文件，请重试。"))
                }
                if let expectedSHA256 {
                    self.status = L10n.text("Verifying SHA-256 checksum…", zh: "正在验证 SHA-256 校验和…")
                    let actual = try await Self.sha256(of: temp)
                    guard actual.lowercased() == expectedSHA256.lowercased() else {
                        self.clearResumeData()
                        throw ModelError.message(L10n.text("Downloaded file checksum mismatch. Please retry or switch download source.",
                                                           zh: "下载文件 SHA-256 校验不匹配，请重试或更换下载源。"))
                    }
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
                self.clearResumeData()
                self.refreshInstalled(); self.progress = 1
                self.status = L10n.text("Download complete. You can translate now.", zh: "下载完成，现在可以开始翻译。")
                if destination == LocalModel.defaultModelURL { LocalModel.shared.prewarmIfNeeded() }
            } catch is CancellationError {
                self.progress = nil
                self.status = L10n.text("Download cancelled. You can retry at any time.", zh: "下载已取消，可随时继续或重试。")
            } catch let error as URLError where error.code == .cancelled {
                self.progress = nil
                self.status = L10n.text("Download cancelled. You can retry at any time.", zh: "下载已取消，可随时继续或重试。")
            } catch {
                self.progress = nil
                self.status = L10n.text("Download failed: ", zh: "下载失败：") + error.localizedDescription
            }
        }
    }

    static func sha256(of url: URL) async throws -> String {
        try await ImageRecognition.worker {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
}
