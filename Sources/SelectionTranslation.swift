import AppKit
import ApplicationServices
import SwiftUI

/// Shows the Translate button above any text selected with the mouse, and the translation panel.
@MainActor final class SelectionTranslationController {
    private let store: TaskStore
    private var monitors: [Any] = []
    private var downPoint = CGPoint.zero
    private var downOverText = false
    /// Set by a mouse-down in another app; a mouse-up without one (e.g. after dragging a panel) is not a selection.
    private var awaitingUp = false
    private var gesture = UUID()
    private var captureTask: Task<Void, Never>?
    private var screenCaptureTask: Task<Void, Never>?
    private var sourcePID: pid_t?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var permissionObservers: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private var monitoringTrusted = false
    private var button: NSPanel?
    private var panel: TranslationPanel?

    init(store: TaskStore) { self.store = store }

    func start() {
        guard monitors.isEmpty else { return }
        monitoringTrusted = AXIsProcessTrusted()
        let handlers: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [
            (.leftMouseDown, { [weak self] event in
                self?.invalidateCapture()
                self?.downPoint = Self.screenLocation(event); self?.downOverText = SelectionCapture.pointerIsIBeam
                self?.awaitingUp = true; self?.hideButton()
                Self.prepareFrontmostApplication()
            }),
            (.leftMouseUp, { [weak self] event in self?.mouseUp(event) }),
            ([.rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel], { [weak self] event in
                // Our own Copy fallback must not cancel the read that requested it.
                if let cg = event.cgEvent, !TelosKeyboardEvent.shouldDisplay(cg) { return }
                if event.type == .scrollWheel {
                    if self?.awaitingUp == true { return } // Selection auto-scroll.
                    if event.scrollingDeltaX == 0 && event.scrollingDeltaY == 0 { return }
                }
                self?.cancelSelection()
            }),
        ]
        for (mask, handler) in handlers {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
                MainActor.assumeIsolated { handler(event) }
            }) { monitors.append(monitor) }
        }
        // Presses on our own windows reach only the local monitor.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.awaitingUp = false; self?.invalidateCapture()
                // Leave the capsule alive until its click action runs.
                if event.window !== self?.button { self?.hideButton() }
            }
            return event
        }) { monitors.append(monitor) }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.willSleepNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.didActivateApplicationNotification { Self.prepareFrontmostApplication() }
                    // The first drag can also activate the browser. That activation belongs to
                    // this gesture; only a switch away invalidates an already captured source.
                    if name == NSWorkspace.didActivateApplicationNotification,
                       self.awaitingUp || self.sourcePID == NSWorkspace.shared.frontmostApplication?.processIdentifier { return }
                    self.cancelSelection()
                }
            })
        }
        Self.prepareFrontmostApplication()
        installLegacyPermissionWatchers()
    }

    /// Avoids waking the main thread every second on macOS 27.3+ (per-app access) and once trusted on older macOS.
    private func installLegacyPermissionWatchers() {
        guard !SelectionPermissionRules.usesPerApplicationAccess() else { return }
        let checkTrust: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            if trusted {
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
            }
            guard self.monitoringTrusted != trusted else { return }
            // Key-event monitoring may have been installed before the user allowed AX access.
            // Refresh it after authorization without closing an existing translation panel.
            self.removeMonitors(); self.start()
        }
        permissionObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { checkTrust() }
        })
        permissionObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { checkTrust() }
        })
        if !monitoringTrusted {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                MainActor.assumeIsolated { checkTrust() }
            }
        }
    }

    private static func prepareFrontmostApplication() {
        // Per-app "Ask First" must never be triggered by app activation or an ordinary click.
        guard !SelectionPermissionRules.usesPerApplicationAccess(), AXIsProcessTrusted(),
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        Task { await SelectionAccessibilityReader.shared.prepare(pid: pid) }
    }

    /// Global monitor events carry no window, so their location is already in screen coordinates.
    private static func screenLocation(_ event: NSEvent) -> CGPoint {
        event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
    }

    func stop() {
        screenCaptureTask?.cancel(); screenCaptureTask = nil
        removeMonitors(); panel?.close(); panel = nil
    }

    private func removeMonitors() {
        permissionTimer?.invalidate(); permissionTimer = nil
        for observer in permissionObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        permissionObservers = []
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver); workspaceObservers = []
        cancelSelection()
    }

    private func invalidateCapture() {
        gesture = UUID(); captureTask?.cancel(); captureTask = nil; sourcePID = nil
    }

    private func cancelSelection() {
        awaitingUp = false; invalidateCapture(); hideButton()
    }

    private func mouseUp(_ event: NSEvent) {
        guard awaitingUp else { return }
        awaitingUp = false
        let up = Self.screenLocation(event), down = downPoint
        guard SelectionGestureRules.shouldRead(down: down, up: up, clickCount: event.clickCount,
                shift: event.modifierFlags.contains(.shift)),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let access = SelectionPermissionRules.mode(trusted: AXIsProcessTrusted())
        guard access != .denied else { return }
        let token = UUID(); gesture = token
        sourcePID = app.processIdentifier
        // A text drag starts over text; it often ends past the end of a line, where the pointer is an arrow.
        let iBeam = downOverText || SelectionCapture.pointerIsIBeam
        let primary = NSScreen.screens.first?.frame.height ?? 0
        captureTask = Task { [weak self] in
            let isCurrent = { [weak self] in
                self?.gesture == token && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            }
            guard !Task.isCancelled, isCurrent() else { return }
            if access == .targetOnly {
                guard await SelectionAccessibilityReader.shared.canReadApplication(pid: app.processIdentifier),
                      !Task.isCancelled, isCurrent() else { return }
                // Chromium exposes its selection tree after activation. Only activate this
                // already-checked target for the user's gesture, never on background focus changes.
                await SelectionAccessibilityReader.shared.prepare(pid: app.processIdentifier, targetOnly: true)
            }
            let result = await SelectionCapturePipeline.capture(down: down, up: up,
                primaryHeight: primary, pointerWasText: iBeam, isCurrent: isCurrent,
                read: { await SelectionAccessibilityReader.shared.selection(pid: app.processIdentifier,
                    down: down, up: up, primaryHeight: primary, targetOnly: access == .targetOnly) },
                copy: { await SelectionCapture.copySelection(pid: app.processIdentifier,
                    mode: access == .targetOnly ? .menuOnly : .menuOrKeyboard, isCurrent: isCurrent) })
            guard isCurrent(), let result else { return }
            self?.captureTask = nil
            self?.showButton(text: result.text, app: app.localizedName ?? "", selection: result.rect)
        }
    }

    private func showButton(text: String, app: String, selection: CGRect) {
        hideButton()
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(selection) }) ?? NSScreen.main else { return }
        let size = SelectionTranslationLayout.buttonSize
        let origin = SelectionTranslationLayout.buttonOrigin(selection: selection, visible: screen.visibleFrame)
        // Leave room around the capsule for its shadow.
        let margin: CGFloat = 12
        let window = FloatingPanel(contentRect: NSRect(x: origin.x - margin, y: origin.y - margin, width: size.width + margin * 2, height: size.height + margin * 2),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.allowsKey = false
        window.contentView = FirstMouseHostingView(rootView: TranslateButton { [weak self] in
            self?.hideButton(); self?.translate(text, app: app, selection: selection, screen: screen)
        }.padding(margin))
        window.orderFrontRegardless()
        button = window
    }

    /// Isolated preview: sample selection and translation, no network or event monitors.
    func preview() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let selection = CGRect(x: visible.midX - 420, y: visible.maxY - 160, width: 300, height: 40)
        showButton(text: "", app: "", selection: selection)
        let session = TranslationSession(source: "出现翻译的小 icon+文字入口，点击后，把划词文案传过去，翻译成英文（如果是中文翻译成英文）、或者中文（如果是英文翻译成中文）", configuration: .default)
        session.translation = "A small icon-plus-text entry point appears. When tapped, the selected text is passed over and translated into English if the source is Chinese, or into Chinese if the source is English."
        session.finished = true
        let size = SelectionTranslationLayout.panelSize
        let window = TranslationPanel(session: session, store: store, origin: CGPoint(x: visible.midX, y: visible.maxY - 140 - size.height), initialSize: size)
        panel = window; window.present()
    }

    private func hideButton() {
        button?.orderOut(nil); button = nil
    }

    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
    }

    func translate(_ text: String, app: String, selection: CGRect, screen: NSScreen) {
        panel?.close()
        let session = TranslationSession(source: text, app: app)
        let initialSize = SelectionTranslationLayout.initialPanelSize(for: text)
        let origin = SelectionTranslationLayout.panelOrigin(selection: selection, visible: screen.visibleFrame, size: initialSize)
        let window = TranslationPanel(session: session, store: store, origin: origin, initialSize: initialSize)
        window.closed = { [weak self, weak window] in if self?.panel === window { self?.panel = nil } }
        panel = window
        window.present()
        session.start()
    }

    func openQuickInput() {
        hideButton()
        panel?.close()
        let point = NSEvent.mouseLocation
        guard let screen = Self.screen(containing: point) else { return }
        let session = TranslationSession(quickInput: true)
        let initialSize = SelectionTranslationLayout.initialPanelSize(for: "")
        let origin = SelectionTranslationLayout.panelOrigin(selection: CGRect(origin: point, size: .zero), visible: screen.visibleFrame, size: initialSize)
        let window = TranslationPanel(session: session, store: store, origin: origin, initialSize: initialSize)
        window.closed = { [weak self, weak window] in if self?.panel === window { self?.panel = nil } }
        panel = window
        window.present()
        NSApp.activate(ignoringOtherApps: true)
    }

    func openHistoryEntry(_ entry: HistoryEntry) {
        hideButton()
        panel?.close()
        let point = NSEvent.mouseLocation
        guard let screen = Self.screen(containing: point) else { return }
        let session = TranslationSession(historyEntry: entry)
        let initialSize = SelectionTranslationLayout.initialPanelSize(for: entry.source)
        let origin = SelectionTranslationLayout.panelOrigin(selection: CGRect(origin: point, size: .zero), visible: screen.visibleFrame, size: initialSize)
        let window = TranslationPanel(session: session, store: store, origin: origin, initialSize: initialSize)
        window.closed = { [weak self, weak window] in if self?.panel === window { self?.panel = nil } }
        panel = window
        window.present()
    }

    func captureAndTranslateScreen() {
        hideButton()
        screenCaptureTask?.cancel()
        screenCaptureTask = Task { [weak self] in
            defer { self?.screenCaptureTask = nil }
            do {
                let imageURL = try await ScreenCaptureOCR.captureInteractiveRegion()
                guard let self, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: imageURL)
                    return
                }
                let point = NSEvent.mouseLocation
                guard let screen = Self.screen(containing: point) else {
                    try? FileManager.default.removeItem(at: imageURL)
                    return
                }
                self.panel?.close()
                let session = TranslationSession(recognizingScreen: true)
                let initialSize = CGSize(width: SelectionTranslationLayout.panelSize.width, height: 340)
                let origin = SelectionTranslationLayout.panelOrigin(selection: CGRect(origin: point, size: .zero), visible: screen.visibleFrame, size: initialSize)
                let window = TranslationPanel(session: session, store: self.store, origin: origin, initialSize: initialSize)
                window.closed = { [weak self, weak window] in if self?.panel === window { self?.panel = nil } }
                self.panel = window
                window.present()
                session.startScreenRecognition(imageURL: imageURL)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                let point = NSEvent.mouseLocation
                guard let screen = Self.screen(containing: point) else { return }
                self.panel?.close()
                let session = TranslationSession(recognizingScreen: true)
                session.isRecognizingScreen = false
                session.failure = error.localizedDescription
                let initialSize = CGSize(width: SelectionTranslationLayout.panelSize.width, height: 280)
                let origin = SelectionTranslationLayout.panelOrigin(selection: CGRect(origin: point, size: .zero), visible: screen.visibleFrame, size: initialSize)
                let window = TranslationPanel(session: session, store: self.store, origin: origin, initialSize: initialSize)
                window.closed = { [weak self, weak window] in if self?.panel === window { self?.panel = nil } }
                self.panel = window
                window.present()
            }
        }
    }
}

/// Borderless panel that never activates Nous Translator, so the source app keeps its selection.
class FloatingPanel: NSPanel {
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isFloatingPanel = true; level = .popUpMenu; hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear; isOpaque = false; hasShadow = false; isReleasedWhenClosed = false
    }
}
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Figma "Translate": 102×32 capsule, native glass with no fill, `translate` 11pt + label 12pt medium.
struct TranslateButton: View {
    var action: () -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let label = HStack(spacing: 4) {
            Image(systemName: "translate").font(.system(size: 11, weight: .medium)).frame(width: 20, height: 16)
            Text(L10n.text("Translate", zh: "翻译")).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }.foregroundStyle(.primary).padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minWidth: SelectionTranslationLayout.buttonSize.width, minHeight: SelectionTranslationLayout.buttonSize.height)
            .fixedSize().contentShape(Capsule())
        Group {
            if #available(macOS 26, *) {
                Button(action: action) { label }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .capsule)
            } else {
                Button(action: action) { label }.buttonStyle(.plain).background(.regularMaterial, in: Capsule())
            }
        }
        .shadow(color: .black.opacity(0.08), radius: 4, y: 3)
        .help(L10n.text("Translate selection", zh: "翻译所选文本"))
        .accessibilityLabel(L10n.text("Translate selection", zh: "翻译所选文本"))
        .scaleEffect(shown || reduceMotion ? 1 : 0.85).opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { shown = true } }
    }
}

/// Streams the translation and keeps the follow-up task linked to it.
@MainActor final class TranslationSession: ObservableObject {
    @Published var source: String
    @Published var direction: ResolvedTranslationDirection
    var target: TranslationTarget { direction.target }
    /// The app the text was selected in; a hint about genre and register.
    private var app: String
    @Published var translation = ""
    @Published var failure: String?
    @Published var finished = false
    @Published var isStreaming = false
    @Published var isQuickInput = false
    @Published var isRecognizingScreen = false
    @Published var preparationMessage = L10n.text("Preparing translation…", zh: "正在准备翻译…")
    @Published var taskID: UUID?
    private var work: Task<Void, Never>?
    private var generation = UUID()

    init(source: String, app: String = "", configuration: TranslationLanguageConfiguration = .load()) {
        self.source = source; self.app = app
        self.direction = configuration.direction(for: source)
    }

    init(quickInput: Bool, configuration: TranslationLanguageConfiguration = .load()) {
        self.source = ""; self.app = "Quick Input"
        self.direction = configuration.direction(for: "")
        self.isQuickInput = quickInput
    }

    init(recognizingScreen: Bool, configuration: TranslationLanguageConfiguration = .load()) {
        self.source = ""; self.app = "Screen Capture"
        self.direction = configuration.direction(for: "")
        self.isRecognizingScreen = recognizingScreen
        self.preparationMessage = L10n.text("Recognizing text from screen…", zh: "正在识别屏幕文字…")
    }

    init(historyEntry: HistoryEntry, configuration: TranslationLanguageConfiguration = .load()) {
        self.source = historyEntry.source
        self.app = historyEntry.app ?? "History"
        let base = configuration.direction(for: historyEntry.source)
        if let rawTarget = historyEntry.targetLanguage, let resolvedTarget = TranslationLanguage(rawValue: rawTarget) {
            self.direction = base.overridingTarget(resolvedTarget)
        } else {
            self.direction = base
        }
        self.translation = historyEntry.result
        self.finished = true
    }

    func submitQuickInput(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.count <= 8000 else {
            failure = L10n.text("Please translate in parts (up to 8,000 characters).", zh: "请分段翻译，每次最多 8000 字。")
            return
        }
        source = trimmed
        direction = TranslationLanguageConfiguration.load().direction(for: trimmed)
        isQuickInput = false
        start()
    }

    func startScreenRecognition(imageURL: URL) {
        work?.cancel()
        isRecognizingScreen = true
        failure = nil
        finished = false
        translation = ""
        preparationMessage = L10n.text("Recognizing text from screen…", zh: "正在识别屏幕文字…")
        let token = UUID(); generation = token
        work = Task { [weak self] in
            guard let self else {
                try? FileManager.default.removeItem(at: imageURL)
                return
            }
            do {
                let recognized = try await ScreenCaptureOCR.recognizeCapturedImage(at: imageURL) { [weak self] in
                    guard let self, self.generation == token, self.isRecognizingScreen else { return }
                    self.preparationMessage = L10n.text(
                        "Preparing Apple Vision model (first use may take ~20s)…",
                        zh: "正在准备 Apple Vision 模型（首次可能需约 20 秒）…")
                }
                guard self.generation == token, !Task.isCancelled else { return }
                let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count <= 8000 else {
                    self.isRecognizingScreen = false
                    self.failure = L10n.text("Recognized text exceeds 8,000 characters. Capture a smaller region.",
                                             zh: "识别文字超过 8000 字，请缩小截图范围。")
                    return
                }
                self.source = trimmed
                self.direction = TranslationLanguageConfiguration.load().direction(for: trimmed)
                self.isRecognizingScreen = false
                self.start()
            } catch is CancellationError {
                guard self.generation == token else { return }
                self.isRecognizingScreen = false
            } catch {
                guard self.generation == token else { return }
                self.isRecognizingScreen = false
                self.failure = error.localizedDescription
            }
        }
    }

    func start() {
        work?.cancel(); translation = ""; failure = nil; finished = false; isStreaming = true
        preparationMessage = L10n.text("Preparing translation…", zh: "正在准备翻译…")
        let token = UUID(); generation = token
        work = Task { [weak self] in await self?.run(token: token) }
    }

    func retranslate(to newTarget: TranslationLanguage) {
        direction = direction.overridingTarget(newTarget)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isQuickInput = false
        start()
    }

    func swapDirection() {
        let config = TranslationLanguageConfiguration.load()
        let nextTarget: TranslationLanguage
        if target == config.languageA {
            nextTarget = config.languageB
        } else if target == config.languageB {
            nextTarget = config.languageA
        } else if let detected = direction.source.language, detected != target {
            nextTarget = detected
        } else {
            nextTarget = config.languageA
        }
        retranslate(to: nextTarget)
    }

    func stopStreaming() {
        guard isStreaming else { return }
        generation = UUID()
        work?.cancel(); work = nil
        isStreaming = false
        if !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finished = true
        } else {
            failure = L10n.text("Translation stopped.", zh: "已停止翻译。")
        }
    }

    func cancel() {
        generation = UUID(); work?.cancel(); work = nil; isStreaming = false; isRecognizingScreen = false
    }

    private func run(token: UUID) async {
        defer {
            if generation == token { isStreaming = false }
        }
        do {
            let provider = ModelRouter.provider(for: .translation)
            let messages = direction.messages(text: source, structured: provider != .local, app: app)
            let bytes = try await ModelRouter.stream(messages: messages, purpose: .translation,
                progress: { [weak self] progress in
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    switch progress {
                    case .loadingModel: self.preparationMessage = L10n.text("Loading local model…", zh: "正在加载本地模型…")
                    case .waitingForFirstToken: self.preparationMessage = L10n.text("Waiting for model…", zh: "等待模型响应…")
                    }
                })
            let raw = try await CompletionReader.read(bytes) { value in
                guard generation == token else { return }
                translation = TranslationTarget.cleanOutput(value)
            }
            guard generation == token else { return }
            translation = TranslationTarget.cleanOutput(raw, final: true)
            if translation.isEmpty {
                failure = L10n.text("No translation was returned. Try again.", zh: "未返回译文，请重试。")
            } else {
                finished = true
                TranslationHistory.shared.add(
                    source: source,
                    result: translation,
                    sourceLanguage: direction.source.code,
                    targetLanguage: direction.target.rawValue,
                    app: app.isEmpty ? nil : app,
                    provider: provider.rawValue
                )
            }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            guard generation == token else { return }
            failure = L10n.text("Translation failed: \(error.localizedDescription)", zh: "翻译失败：\(error.localizedDescription)")
        }
    }
}

final class TranslationPanel: FloatingPanel {
    var closed: () -> Void = {}
    private let session: TranslationSession
    private let store: TaskStore
    private var keyMonitor: Any?
    private var didClose = false
    private var userResized = false
    private var panelSize: CGSize

    init(session: TranslationSession, store: TaskStore, origin: CGPoint, initialSize: CGSize = SelectionTranslationLayout.panelSize) {
        self.session = session
        self.store = store
        self.panelSize = initialSize
        let inset = TranslationPanelView.shadowInset
        super.init(contentRect: NSRect(x: origin.x - inset.leading, y: origin.y - inset.bottom,
                                       width: initialSize.width + inset.leading + inset.trailing,
                                       height: initialSize.height + inset.top + inset.bottom),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        appearance = NSAppearance(named: .darkAqua)
        let host = FirstMouseHostingView(rootView: TranslationPanelView(
            session: session,
            store: store,
            onRequestAutoHeight: { [weak self] desired in self?.autoExpandIfNeeded(to: desired) },
            onManualResize: { [weak self] delta in self?.resizeBy(delta: delta) },
            close: { [weak self] in self?.close() }
        ).padding(inset))
        host.safeAreaRegions = []
        contentView = host
    }

    private func autoExpandIfNeeded(to desiredHeight: CGFloat) {
        guard !userResized else { return }
        let clamped = min(SelectionTranslationLayout.panelSize.height, max(panelSize.height, desiredHeight))
        guard clamped > panelSize.height + 12 else { return }
        applyPanelSize(CGSize(width: panelSize.width, height: clamped), animated: true)
    }

    private func resizeBy(delta: CGSize) {
        userResized = true
        let next = CGSize(
            width: min(SelectionTranslationLayout.maxPanelSize.width, max(SelectionTranslationLayout.minPanelSize.width, panelSize.width + delta.width)),
            height: min(SelectionTranslationLayout.maxPanelSize.height, max(SelectionTranslationLayout.minPanelSize.height, panelSize.height + delta.height))
        )
        applyPanelSize(next, animated: false)
    }

    private func applyPanelSize(_ newSize: CGSize, animated: Bool) {
        let inset = TranslationPanelView.shadowInset
        let dy = newSize.height - panelSize.height
        panelSize = newSize
        var nextFrame = frame
        nextFrame.size = CGSize(width: newSize.width + inset.leading + inset.trailing,
                                height: newSize.height + inset.top + inset.bottom)
        // Anchor top-left corner while growing downward.
        nextFrame.origin.y -= dy
        if let visible = screen?.visibleFrame {
            if nextFrame.minY + inset.bottom < visible.minY + 8 {
                nextFrame.origin.y = visible.minY + 8 - inset.bottom
            }
            if nextFrame.maxX - inset.trailing > visible.maxX - 8 {
                nextFrame.origin.x = visible.maxX - 8 - nextFrame.width + inset.trailing
            }
        }
        setFrame(nextFrame, display: true, animate: animated)
    }

    func present() {
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; animator().alphaValue = 1 }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 { // Escape
                self.close(); return nil
            }
            if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "r" {
                if !self.session.source.isEmpty && !self.session.isRecognizingScreen {
                    self.session.start()
                    return nil
                }
            }
            if (mods == [.command, .shift] || mods == .command),
               event.charactersIgnoringModifiers?.lowercased() == "c" {
                // Always copy translation on ⌘⇧C; on ⌘C only when user isn't copying selected text in an editor.
                let hasEditorSelection: Bool = {
                    if let textView = self.firstResponder as? NSTextView {
                        return textView.selectedRange().length > 0
                    }
                    return false
                }()
                if mods == [.command, .shift] || !hasEditorSelection {
                    if !self.session.translation.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(self.session.translation, forType: .string)
                        return nil
                    }
                }
            }
            return event
        }
    }

    override func close() {
        guard !didClose else { return }
        didClose = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        session.cancel()
        if let taskID = session.taskID {
            store.close(taskID)
        }
        SpeechPlayer.shared.stop()
        super.close()
        closed()
    }
}

/// Figma "划词翻译": radius 38, native glass under a black gradient (99% → 97% at 80% → 40%)
/// and a 30% black shadow (y 20, blur 50). No border. Supports adaptive height and corner resizing.
struct TranslationPanelView: View {
    static let shadowInset = EdgeInsets(top: 32, leading: 56, bottom: 84, trailing: 56)
    @ObservedObject var session: TranslationSession
    @ObservedObject var store: TaskStore
    var onRequestAutoHeight: (CGFloat) -> Void = { _ in }
    var onManualResize: (CGSize) -> Void = { _ in }
    var close: () -> Void
    @StateObject private var draft = ComposerDraft()
    @ObservedObject private var speech = SpeechPlayer.shared
    @State private var quickInputText = ""
    @State private var sourceExpanded = false
    @State private var footerHeight: CGFloat = 80
    @State private var lastDragTranslation: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let shape = RoundedRectangle(cornerRadius: 38, style: .continuous)
    private var task: Todo? { session.taskID.flatMap { id in store.tasks.first { $0.id == id } } }
    private var sourceCanExpand: Bool { session.source.count > 80 || session.source.contains("\n") }

    var body: some View {
        GeometryReader { geo in
            let height = max(240, geo.size.height)
            ZStack(alignment: .bottom) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Color.clear.frame(height: 40)
                            if session.isQuickInput {
                                quickInputCard
                            } else if !session.source.isEmpty {
                                source
                            }
                            if !session.isQuickInput {
                                result
                            }
                            if let task { conversation(task) }
                            Color.clear.frame(height: footerHeight).id("bottom")
                        }.padding(.horizontal, 16).padding(.top, 16)
                    }.scrollIndicators(.hidden)
                        .onChange(of: task?.messages.last(where: { $0.role == "user" })?.id) { _, _ in
                            onRequestAutoHeight(SelectionTranslationLayout.panelSize.height)
                            DispatchQueue.main.async {
                                var transaction = Transaction(); transaction.disablesAnimations = true
                                withTransaction(transaction) { proxy.scrollTo("bottom", anchor: .bottom) }
                            }
                        }
                        .onChange(of: session.translation.count) { _, count in
                            if count > 280 {
                                onRequestAutoHeight(SelectionTranslationLayout.panelSize.height)
                            } else if count > 120 {
                                onRequestAutoHeight(380)
                            }
                        }
                }
                .mask(LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: min(0.25, 56 / height)),
                    .init(color: .black, location: max(0.5, 1 - (footerHeight + 4) / height)),
                    .init(color: .clear, location: max(0.55, 1 - max(0, footerHeight - 20) / height))
                ], startPoint: .top, endPoint: .bottom))

                if !session.isQuickInput {
                    footer
                }
            }
            .coordinateSpace(name: "translationFlight")
            .onPreferenceChange(RectPreference.self) { values in
                if let rect = values["footer"], abs(footerHeight - rect.height) > 0.5 { footerHeight = rect.height }
            }
            .overlay(alignment: .top) { header }
            .overlay(alignment: .bottomTrailing) { resizeGrip }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LinearGradient(stops: [.init(color: .black.opacity(0.99), location: 0), .init(color: .black.opacity(0.97), location: 0.8),
                                               .init(color: .black.opacity(0.4), location: 1)], startPoint: .top, endPoint: .bottom), in: shape)
            .modifier(PanelGlass(shape: shape))
            .clipShape(shape)
            .compositingGroup()
            .shadow(color: .black.opacity(0.3), radius: 25, y: 20)
        }
    }

    private var resizeGrip: some View {
        Color.clear
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let dx = value.translation.width - lastDragTranslation.width
                        let dy = value.translation.height - lastDragTranslation.height
                        lastDragTranslation = value.translation
                        onManualResize(CGSize(width: dx, height: dy))
                    }
                    .onEnded { _ in lastDragTranslation = .zero }
            )
            .help(L10n.text("Drag corner to resize", zh: "拖动边角调整大小"))
    }

    /// Tool row: 36pt clear Liquid Glass language capsule on leading edge, symmetric with 36pt close circle on trailing edge.
    private var header: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                if !session.isRecognizingScreen {
                    GlassLanguageMenuButton(
                        title: session.target.shortName,
                        selected: session.target,
                        help: L10n.text("Switch target language", zh: "切换目标语言"),
                        onSwap: { session.swapDirection() },
                        onSelect: { session.retranslate(to: $0) }
                    )
                }
                Spacer(minLength: 0)
                GlassSymbolButton(symbol: "xmark", size: 36, pointSize: 13, help: L10n.text("Close", zh: "关闭"), action: close)
            }
        }.padding([.horizontal, .top], 16).frame(height: 56, alignment: .top)
            .modifier(WindowDrag())
    }

    private var quickInputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Enter or paste text to translate", zh: "输入或粘贴需要翻译的文本"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            TextEditor(text: $quickInputText)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .foregroundStyle(.white)
                .frame(minHeight: 110, maxHeight: 200)
                .padding(8)
                .background(Color(red: 0.149, green: 0.149, blue: 0.157), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack {
                if let failure = session.failure {
                    Text(failure).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Button(L10n.text("Translate", zh: "翻译")) {
                    session.submitQuickInput(quickInputText)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 30)
                .modifier(GlassSurface(shape: Capsule(), interactive: true))
                .disabled(quickInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        TaskComposer(draft: draft, canSend: canSend, action: submit)
            .padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 16)
            .trackRect("footer", in: "translationFlight")
    }

    /// Figma "Message": #262628, radius 16, padding 12, 11/16 SF Pro, tracking −0.11, #E0E0E2.
    private var source: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(session.source).font(.system(size: 11)).tracking(-0.11).lineSpacing(TranslationType.spacing(size: 11, lineHeight: 16))
                .foregroundStyle(Color(red: 0.878, green: 0.878, blue: 0.886))
                .lineLimit(sourceExpanded ? nil : 2).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                speech.toggle(id: "source:" + session.source.prefix(40), text: session.source, language: session.direction.source.language)
            } label: {
                let speaking = speech.activeID == "source:" + session.source.prefix(40)
                Image(systemName: speaking ? "stop.circle.fill" : "speaker.wave.2")
                    .font(.system(size: 11))
                    .foregroundStyle(speaking ? .white : .white.opacity(0.45))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(L10n.text("Speak source text", zh: "朗读原文"))
        }
        .padding(12)
        .background(Color(red: 0.149, green: 0.149, blue: 0.157), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture {
            guard sourceCanExpand else { return }
            withAnimation(.easeOut(duration: 0.2)) { sourceExpanded.toggle() }
        }
        .help(sourceCanExpand ? (sourceExpanded ? L10n.text("Collapse", zh: "收起") : L10n.text("Show full selection", zh: "展开全文")) : "")
        .accessibilityLabel(L10n.text("Selected text: ", zh: "选中文本：") + session.source)
    }

    @ViewBuilder private var result: some View {
        if let failure = session.failure {
            VStack(alignment: .leading, spacing: 12) {
                Text(failure).font(.system(size: 14)).tracking(-0.56).foregroundStyle(.white.opacity(0.5))
                if !session.source.isEmpty {
                    Button(L10n.text("Try Again", zh: "重试")) { session.start() }.buttonStyle(.plain).font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12).frame(height: 28).modifier(GlassSurface(shape: Capsule(), interactive: true))
                }
            }.padding(.horizontal, 12).padding(.vertical, 10)
        } else if session.translation.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(session.preparationMessage).font(.system(size: 14)).tracking(-0.56).foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 4)
                if session.isStreaming {
                    Button(L10n.text("Stop", zh: "停止")) { session.stopStreaming() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 10).frame(height: 24).modifier(GlassSurface(shape: Capsule(), interactive: true))
                }
            }.padding(.horizontal, 12).padding(.vertical, 10)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                TranslationResult(
                    text: session.translation,
                    finished: session.finished,
                    target: session.target,
                    onRetranslate: { session.start() }
                )
                if session.isStreaming {
                    HStack {
                        Spacer()
                        Button(L10n.text("Stop", zh: "停止")) { session.stopStreaming() }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 10).frame(height: 24).modifier(GlassSurface(shape: Capsule(), interactive: true))
                    }.padding(.horizontal, 12)
                }
            }
        }
    }

    @ViewBuilder private func conversation(_ task: Todo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(task.messages) { message in
                if message.role == "user" {
                    HStack {
                        Spacer(minLength: 48)
                        SentMessageView(message: message)
                            .modifier(MessageArrival())
                    }
                } else if message.role == "assistant" {
                    let text = message.pending ? (store.streams[task.id] ?? "") : message.text
                    if !text.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            CopyableReply(
                                text: text,
                                canCopy: !message.pending,
                                markdown: false,
                                useCache: !message.pending,
                                speakID: message.pending ? nil : message.id.uuidString
                            )
                            .font(.system(size: 14)).tracking(-0.56)
                            .lineSpacing(TranslationType.spacing(size: 14, lineHeight: 19))
                            .foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                            if message.pending && task.status == "running" {
                                HStack {
                                    Spacer()
                                    Button(L10n.text("Stop", zh: "停止")) { store.cancel(task.id) }
                                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                                        .padding(.horizontal, 10).frame(height: 24).modifier(GlassSurface(shape: Capsule(), interactive: true))
                                }.padding(.horizontal, 12)
                            }
                        }
                    } else if message.pending && task.status == "running" {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text(task.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Button(L10n.text("Stop", zh: "停止")) { store.cancel(task.id) }
                                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                                .padding(.horizontal, 8).frame(height: 22).modifier(GlassSurface(shape: Capsule(), interactive: true))
                        }.frame(height: 28).padding(.horizontal, 12)
                    }
                }
            }
            if ["error", "paused", "needs_input"].contains(task.status) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(task.summary).font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                    Button(L10n.text("Model Settings…", zh: "模型设置…")) {
                        NotificationCenter.default.post(name: .init("NousShowModels"), object: nil)
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 12)
            }

        }.padding(.top, 8)
    }

    private var canSend: Bool {
        guard draft.hasContent, !session.isRecognizingScreen, session.finished || session.failure != nil else { return false }
        return !["running", "awaiting_approval"].contains(task?.status ?? "")
    }

    private func submit() {
        guard canSend else { return }
        let text = draft.text, files = draft.files
        if let id = session.taskID {
            guard store.ask(id, text: text, files: files) else { return }
        } else {
            let source = session.source, translation = session.translation, target = session.target
            guard let id = store.add(text, files: files, context: { request in
                SelectionTranslationContext.prompt(source: source, translation: translation, target: target, request: request)
            }) else { return }
            session.taskID = id
        }
        PicoSounds.messageSent()
        draft.clear()
    }
}

/// Figma "Text": padding 12/10, 12pt gap; 14/19 SF Pro tracking −0.56 white;
/// `square.on.square` 13pt medium at 50% white, shown on hover.
private struct TranslationResult: View {
    let text: String
    let finished: Bool
    let target: TranslationLanguage
    let onRetranslate: () -> Void
    var body: some View {
        CopyableReply(
            text: text,
            canCopy: finished,
            markdown: false,
            useCache: finished,
            speakID: finished ? "translation:" + text.prefix(40) : nil,
            speakLanguage: target,
            onRetranslate: finished ? onRetranslate : nil
        )
        .font(.system(size: 14)).tracking(-0.56)
        .lineSpacing(TranslationType.spacing(size: 14, lineHeight: 19))
        .foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

/// Converts a Figma line height into SwiftUI line spacing for SF Pro at that size.
private enum TranslationType {
    static func spacing(size: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        return max(0, lineHeight - (font.ascender - font.descender + font.leading))
    }
}

/// "Button - Liquid Glass - Language": a 36pt clear Liquid Glass capsule showing only the target language name,
/// optically symmetric with the 36pt circular close button on the trailing edge.
private struct GlassLanguageMenuButton: View {
    let title: String
    let selected: TranslationLanguage
    let help: String
    let onSwap: () -> Void
    let onSelect: (TranslationLanguage) -> Void
    var body: some View {
        Menu {
            Button(L10n.text("Swap Direction", zh: "反转翻译方向"), action: onSwap)
            Divider()
            ForEach(TranslationLanguage.allCases) { language in
                Button {
                    onSelect(language)
                } label: {
                    if language == selected {
                        Label(language.shortName, systemImage: "checkmark")
                    } else {
                        Text(language.shortName)
                    }
                }
            }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minWidth: 36)
                .frame(height: 36)
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .modifier(GlassSurface(shape: Capsule(), interactive: true))
        .fixedSize()
        .help(help)
        .accessibilityLabel(help + ": " + title)
    }
}

/// "Button - Liquid Glass - Symbol": a circle of native glass with no fill.
private struct GlassSymbolButton: View {
    let symbol: String
    let size: CGFloat
    let pointSize: CGFloat
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: pointSize, weight: .medium)).foregroundStyle(.white)
                .frame(width: size, height: size).contentShape(Circle())
        }.buttonStyle(.plain).modifier(GlassSurface(shape: Circle(), interactive: true))
            .help(help).accessibilityLabel(help)
    }
}

/// Native clear Liquid Glass (Figma GLASS, no fill) on macOS 26; a material stand-in earlier or with Reduce Transparency.
struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency {
            content.glassEffect(interactive ? .clear.interactive() : .clear, in: shape)
        } else {
            content.background(TelosTheme.shade(0.94, 0.2), in: shape)
        }
    }
}

/// Lets neighboring glass shapes blend and morph together, as the system does.
struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content
    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing, content: content) } else { content() }
    }
}

struct PanelGlass: ViewModifier {
    let shape: RoundedRectangle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency {
            // Frosted, untinted glass (the gradient's 16pt background blur); light so the cleared bottom reads as in the design.
            content.background { Color.clear.glassEffect(.regular, in: shape).environment(\.colorScheme, .light) }
        } else {
            content.background(TelosTheme.shade(0.97, 0.06), in: shape)
        }
    }
}

/// Supports dragging borderless panels on macOS 15+ (WindowDragGesture) AND macOS 14 (AppKit performDrag).
struct WindowDrag: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.contentShape(Rectangle()).gesture(WindowDragGesture())
        } else {
            content.background(WindowDragHandle())
        }
    }
}

private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragHandleView { WindowDragHandleView() }
    func updateNSView(_ nsView: WindowDragHandleView, context: Context) {}
}

private final class WindowDragHandleView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
