import AppKit
import SwiftUI
import ApplicationServices

@main struct NousTranslatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = TaskStore()
    private var controller: SelectionTranslationController!
    private var status: NSStatusItem!
    private var conversationWindow: NSWindow?
    private var settingsController: SettingsController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = SelectionTranslationController(store: store)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "translate", accessibilityDescription: "Nous Translator")
        let menu = NSMenu()
        for (title, action, key) in [("Settings…", #selector(showSettings), ","), ("Translate Clipboard", #selector(translateClipboard), "t"), ("Enable Selection Translation…", #selector(permission), ""), ("Quit Nous Translator", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
        }
        status.menu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(showModels), name: .init("NousShowModels"), object: nil)
        if CommandLine.arguments.contains("--settings-preview") {
            showSettings()
            if CommandLine.arguments.contains("--models") { showModels() }
            if CommandLine.arguments.contains("--capture") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let view = self?.settingsController?.window?.contentView?.superview,
                          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/nous-settings-preview.png"))
                    NSApp.terminate(nil)
                }
            }
            return
        }
        if CommandLine.arguments.contains("--smoke-test") {
            Task {
                var results: [String] = []
                do {
                    for prompt in ["请将以下文本翻译为英语，直接输出翻译结果，不要进行任何解释。\n\n我们明天下午三点开会。", "请将以下文本翻译为简体中文，直接输出翻译结果，不要进行任何解释。\n\nCould you send me the updated design before Friday?"] {
                        let bytes = try await LocalModel.shared.stream(messages: [["role":"user", "content":prompt]])
                        for try await line in bytes.lines { results.append(line) }
                    }
                    try results.joined(separator: "\n").write(toFile: "/tmp/nous-smoke-result.txt", atomically: true, encoding: .utf8)
                } catch { try? error.localizedDescription.write(toFile: "/tmp/nous-smoke-error.txt", atomically: true, encoding: .utf8) }
                NSApp.terminate(nil)
            }
            return
        }
        controller.start()
        if CommandLine.arguments.contains("--preview") { controller.preview() }
        else if LocalModel.needsInitialModelSetup() { showModels() }
        else if !AXIsProcessTrusted() { permission() }
    }
    @objc private func showSettings() {
        if settingsController == nil { settingsController = SettingsController() }
        settingsController?.present()
    }
    @objc private func showModels() {
        if settingsController == nil { settingsController = SettingsController() }
        settingsController?.present(models: true)
    }
    @objc private func permission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func translateClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let screen = NSScreen.main else { return }
        guard text.count <= 8000 else { let alert = NSAlert(); alert.messageText = "请分段翻译，每次最多 8000 字。"; alert.runModal(); return }
        let point = NSEvent.mouseLocation
        controller.translate(text, app: "Clipboard", selection: CGRect(origin: point, size: .zero), screen: screen)
    }
    func showPanel() {
        guard let id = store.selected else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Nous Translator"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ConversationView(store: store, id: id))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        conversationWindow = window
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { controller.stop(); store.stop(); LocalModel.shared.stop(); LocalModel.conversation.stop() }
}
struct ConversationView: View {
    @ObservedObject var store: TaskStore
    let id: UUID
    @StateObject private var draft = ComposerDraft()
    var body: some View {
        VStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let task = store.tasks.first(where: { $0.id == id }) {
                        ForEach(task.messages) { message in MessageText(text: message.text).frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading) }
                        if task.status == "error" { Text(task.summary).foregroundStyle(.secondary) }
                    }
                    if let stream = store.streams[id] { MessageText(text: stream, markdown: false) }
                }.padding()
            }
            AttachmentInput(draft: draft, placeholder: "Message", identifier: "conversationAsk") {
                if store.ask(id, text: draft.text, files: draft.files) { draft.clear() }
            }.padding()
        }
    }
}
