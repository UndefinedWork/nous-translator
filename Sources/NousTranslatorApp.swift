import AppKit
import SwiftUI
#if !NOUS_APP_STORE
import ApplicationServices
#endif

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
    private var pasteWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = SelectionTranslationController(store: store)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "translate", accessibilityDescription: "Nous Translator")
        status.button?.toolTip = AppDistribution.menuBarHelp
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            return item
        }
        menu.addItem(item("Settings…", #selector(showSettings), ","))
        menu.addItem(item("Translate Clipboard", #selector(translateClipboard), "t"))
        menu.addItem(item("Translate Pasted Text…", #selector(showPasteTranslator), "p"))
        #if !NOUS_APP_STORE
        menu.addItem(item("Enable Selection Translation…", #selector(permission), ""))
        #endif
        menu.addItem(item("Quit Nous Translator", #selector(quit), "q"))
        status.menu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(showModels), name: .init("NousShowModels"), object: nil)
        #if NOUS_APP_STORE
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        #endif
        if CommandLine.arguments.contains("--settings-preview") {
            showSettings()
            if CommandLine.arguments.contains("--models") { showModels() }
            if CommandLine.arguments.contains("--images") { settingsController?.tabs.selectedTabViewItemIndex = 2 }
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
        LocalModel.shared.prewarmIfNeeded()
        if CommandLine.arguments.contains("--preview") { controller.preview() }
        else if LocalModel.needsInitialModelSetup() { showModels() }
        #if !NOUS_APP_STORE
        else if !AXIsProcessTrusted() { permission() }
        #endif
    }
    @objc private func showSettings() {
        if settingsController == nil { settingsController = SettingsController() }
        settingsController?.present()
    }
    @objc private func showModels() {
        if settingsController == nil { settingsController = SettingsController() }
        settingsController?.present(models: true)
    }
    #if !NOUS_APP_STORE
    @objc private func permission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    #endif
    @objc private func translateClipboard() {
        presentTranslation(from: NSPasteboard.general.string(forType: .string), source: "Clipboard")
    }
    @objc private func showPasteTranslator() {
        if pasteWindow == nil {
            let view = PasteTranslationView { [weak self] text in
                self?.presentTranslation(from: text, source: "Pasted Text")
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 280),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Translate Pasted Text"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.center()
            pasteWindow = window
        }
        pasteWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    /// System Services entry. The selector must match Info.plist `NSMessage`.
    @objc func translateService(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        presentTranslation(from: pasteboard.string(forType: .string), source: "Services")
    }
    private func presentTranslation(from raw: String?, source: String) {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        guard text.count <= 8000 else {
            let alert = NSAlert()
            alert.messageText = "请分段翻译，每次最多 8000 字。"
            alert.runModal()
            return
        }
        let point = NSEvent.mouseLocation
        controller.translate(text, app: source, selection: CGRect(origin: point, size: .zero), screen: screen)
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

struct PasteTranslationView: View {
    @State private var text = ""
    var translate: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppDistribution.usesAccessibilitySelection
                 ? "Paste or type the text to translate."
                 : "Paste or type the text to translate. This Mac App Store build does not read selections from other apps.")
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Translate") {
                    translate(text)
                }.keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(16)
    }
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
