import AppKit
import Combine
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
    private var settingsController: SettingsController?
    private var updaterObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = SelectionTranslationController(store: store)
        store.cleanupOrphanAttachments()
        Task {
            await LocalModel.shared.cleanupOrphanProcess()
            await LocalModel.conversation.cleanupOrphanProcess()
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusBarBadge()
        rebuildStatusMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(showModels), name: .init("NousShowModels"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(openHistoryEntry(_:)), name: .init("NousOpenHistoryEntry"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged), name: UserDefaults.didChangeNotification, object: nil)

        updaterObservation = AppUpdater.shared.$state.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateStatusBarBadge()
                self?.rebuildStatusMenu()
            }
        }
        AppUpdater.shared.onUpdateDiscovered = { [weak self] update in
            guard let self else { return }
            UpdateToastController.shared.show(update: update) { [weak self] in
                self?.showUpdates()
            }
        }
        AppUpdater.shared.onBeforeTerminate = { [weak self] in
            self?.shutdownServices()
        }

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
        GlobalHotKeyManager.shared.start { [weak self] action in
            guard let self else { return }
            switch action {
            case .translateClipboard: self.translateClipboard()
            case .quickTranslate: self.quickTranslate()
            case .captureScreenOCR: self.translateScreenRegion()
            }
        }
        LocalModel.shared.prewarmIfNeeded()
        if CommandLine.arguments.contains("--preview") { controller.preview(); return }
        AppUpdater.shared.startBackgroundChecks()
        let needsModel = LocalModel.needsInitialModelSetup()
        if needsModel { showModels() }
        if CommandLine.arguments.contains("--update-accessibility-reset-failed") {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.text("Update Installed — Accessibility Reset Needed", zh: "更新已安装，但辅助功能授权重置失败")
            alert.informativeText = L10n.text(
                "Nous Translator updated and restarted successfully, but macOS could not reset its previous Accessibility entry automatically. Open System Settings → Privacy & Security → Accessibility to remove and re-enable Nous Translator.",
                zh: "Nous Translator 已完成更新并重启，但未能自动重置旧版辅助功能授权。请前往“系统设置 → 隐私与安全性 → 辅助功能”移除旧条目后重新允许。"
            )
            alert.addButton(withTitle: L10n.text("Open System Settings…", zh: "打开系统设置…"))
            alert.addButton(withTitle: L10n.text("Later", zh: "稍后"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        } else if CommandLine.arguments.contains("--request-accessibility-after-update") {
            // Register this installed copy after the updater resets its permission.
            // The updater opens System Settings, including when model setup is also needed.
            Self.requestAccessibility()
        } else if !needsModel && !SelectionPermissionRules.usesPerApplicationAccess() && !AXIsProcessTrusted() {
            Self.requestAccessibility()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    private func updateStatusBarBadge() {
        status.button?.image = StatusBarIcon.image(hasUpdate: AppUpdater.shared.hasVisibleUpdate)
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        if AppUpdater.shared.hasVisibleUpdate, let update = AppUpdater.shared.availableUpdate {
            let item = NSMenuItem(
                title: L10n.text("● Update Available: v\(update.version.raw)…", zh: "● 发现新版本：v\(update.version.raw)…"),
                action: #selector(showUpdates),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
        let primaryItems: [(String, Selector, String)] = [
            (L10n.text("Translate Clipboard", zh: "翻译剪贴板"), #selector(translateClipboard), "t"),
            (L10n.text("Quick Translate…", zh: "快捷输入翻译…"), #selector(quickTranslate), "n"),
            (L10n.text("Translate Screen Region…", zh: "截图识别并翻译…"), #selector(translateScreenRegion), "s")
        ]
        for (title, action, key) in primaryItems {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, action, key) in [
            (L10n.text("Check for Updates…", zh: "检查更新…"), #selector(checkForUpdates), ""),
            (L10n.text("Settings…", zh: "设置…"), #selector(showSettings), ","),
            (L10n.text("Quit Nous Translator", zh: "退出 Nous Translator"), #selector(quit), "q")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        status.menu = menu
    }

    @objc private func languageChanged() {
        rebuildStatusMenu()
        settingsController?.refreshLocalizedChrome()
    }

    @objc private func showSettings() {
        if settingsController == nil { settingsController = SettingsController() }
        settingsController?.present()
    }
    @objc private func showUpdates() {
        UpdateToastController.shared.dismiss()
        if settingsController == nil { settingsController = SettingsController() }
        settingsController?.present(updates: true)
    }
    @objc private func checkForUpdates() {
        showUpdates()
        Task { await AppUpdater.shared.checkForUpdates(userInitiated: true) }
    }
    @objc private func showModels() {
        if settingsController == nil { settingsController = SettingsController() }
        settingsController?.present(models: true)
    }
    @objc private func openHistoryEntry(_ notification: Notification) {
        guard let entry = notification.object as? HistoryEntry else { return }
        controller.openHistoryEntry(entry)
    }
    private static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    @objc private func translateClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let point = NSEvent.mouseLocation
        guard let screen = SelectionTranslationController.screen(containing: point) else { return }
        guard text.count <= 8000 else {
            let alert = NSAlert()
            alert.messageText = L10n.text("Please translate in parts (up to 8,000 characters).", zh: "请分段翻译，每次最多 8000 字。")
            alert.runModal()
            return
        }
        controller.translate(text, app: "Clipboard", selection: CGRect(origin: point, size: .zero), screen: screen)
    }
    @objc private func quickTranslate() {
        controller.openQuickInput()
    }
    @objc private func translateScreenRegion() {
        controller.captureAndTranslateScreen()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func shutdownServices() {
        UpdateToastController.shared.dismiss()
        AppUpdater.shared.stop()
        GlobalHotKeyManager.shared.stop()
        SpeechPlayer.shared.stop()
        controller.stop()
        store.stop()
        store.cleanupOrphanAttachments()
        LocalModel.shared.stop()
        LocalModel.conversation.stop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdownServices()
    }
}
