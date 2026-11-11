import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI

/// Shows the Translate button above any text selected with the mouse, and the translation panel.
@MainActor final class SelectionTranslationController {
    private let store: TaskStore
    private var monitors: [Any] = []
    private var downPoint = CGPoint.zero
    private var downOverText = false
    /// Set by a mouse-down in another app; a mouse-up without one (e.g. after dragging a Telos panel) is not a selection.
    private var awaitingUp = false
    private var gesture = UUID()
    private var captureTask: Task<Void, Never>?
    private var sourcePID: pid_t?
    private var workspaceObservers: [NSObjectProtocol] = []
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
        // Presses on Telos's own windows reach only the local monitor.
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
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.monitoringTrusted != AXIsProcessTrusted() else { return }
                // Key-event monitoring may have been installed before the user allowed AX access.
                // Refresh it after authorization without closing an existing translation panel.
                self.removeMonitors(); self.start()
            }
        }
    }

    private static func prepareFrontmostApplication() {
        guard AXIsProcessTrusted(), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        Task { await SelectionAccessibilityReader.shared.prepare(pid: pid) }
    }

    /// Global monitor events carry no window, so their location is already in screen coordinates.
    private static func screenLocation(_ event: NSEvent) -> CGPoint {
        event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
    }

    func stop() {
        removeMonitors(); panel?.close(); panel = nil
    }

    private func removeMonitors() {
        permissionTimer?.invalidate(); permissionTimer = nil
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
        // A visible Nous window may be behind the browser. Its frame does not tell us which app
        // received the gesture; the local/global event monitors already make that distinction.
        guard SelectionGestureRules.shouldRead(down: down, up: up, clickCount: event.clickCount,
                shift: event.modifierFlags.contains(.shift)), AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let token = UUID(); gesture = token
        sourcePID = app.processIdentifier
        // A text drag starts over text; it often ends past the end of a line, where the pointer is an arrow.
        let iBeam = downOverText || SelectionCapture.pointerIsIBeam
        let primary = NSScreen.screens.first?.frame.height ?? 0
        captureTask = Task { [weak self] in
            let isCurrent = { [weak self] in
                self?.gesture == token && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            }
            let result = await SelectionCapturePipeline.capture(down: down, up: up,
                primaryHeight: primary, pointerWasText: iBeam, isCurrent: isCurrent,
                read: { await SelectionAccessibilityReader.shared.selection(pid: app.processIdentifier,
                    down: down, up: up, primaryHeight: primary) },
                copy: { await SelectionCapture.copySelection(pid: app.processIdentifier, isCurrent: isCurrent) })
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
        let session = TranslationSession(source: "出现翻译的小 icon+文字入口，点击后，把划词文案传过去，翻译成英文（如果是中文翻译成英文）、或者中文（如果是英文翻译成中文）")
        session.translation = "A small icon-plus-text entry point appears. When tapped, the selected text is passed over and translated into English if the source is Chinese, or into Chinese if the source is English."
        session.finished = true
        let window = TranslationPanel(session: session, store: store, origin: CGPoint(x: visible.midX, y: visible.maxY - 140 - SelectionTranslationLayout.panelSize.height))
        panel = window; window.present()
    }

    private func hideButton() {
        button?.orderOut(nil); button = nil
    }

    func translate(_ text: String, app: String, selection: CGRect, screen: NSScreen) {
        panel?.close()
        let session = TranslationSession(source: text, app: app)
        let origin = SelectionTranslationLayout.panelOrigin(selection: selection, visible: screen.visibleFrame)
        let window = TranslationPanel(session: session, store: store, origin: origin)
        window.closed = { [weak self, weak window] in if self?.panel === window { self?.panel = nil } }
        panel = window
        window.present()
        session.start()
    }
}

/// Borderless panel that never activates Telos, so the source app keeps its selection.
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
            Text("Translate").font(.system(size: 12, weight: .medium)).lineLimit(1)
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
        .help("Translate selection").accessibilityLabel("Translate selection")
        .scaleEffect(shown || reduceMotion ? 1 : 0.85).opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { shown = true } }
    }
}

/// Streams the translation and keeps the follow-up task linked to it.
@MainActor final class TranslationSession: ObservableObject {
    let source: String
    let target: TranslationTarget
    /// The app the text was selected in; a hint about genre and register.
    private let app: String
    @Published var translation = ""
    @Published var failure: String?
    @Published var finished = false
    @Published var taskID: UUID?
    private var work: Task<Void, Never>?
    private var generation = UUID()

    init(source: String, app: String = "") {
        self.source = source; self.app = app
        target = TranslationTarget.detect(source)
    }

    func start() {
        work?.cancel(); translation = ""; failure = nil; finished = false
        let token = UUID(); generation = token
        work = Task { [weak self] in await self?.run(token: token) }
    }
    func cancel() { work?.cancel(); work = nil }

    private func run(token: UUID) async {
        do {
            let bytes = try await ModelRouter.stream(messages: [["role": "user", "content": "请将以下文本翻译为\(target == .english ? "英语" : "简体中文")，直接输出翻译结果，不要进行任何解释。\n\n\(source)"]], purpose: .translation)
            let raw = try await CompletionReader.read(bytes) { value in
                guard generation == token else { return }
                translation = TranslationTarget.cleanOutput(value)
            }
            guard generation == token else { return }
            translation = TranslationTarget.cleanOutput(raw, final: true)
            if translation.isEmpty { failure = "No translation was returned. Try again." } else { finished = true; TranslationHistory.shared.add(source: source, result: translation) }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            guard generation == token else { return }
            failure = "Translation failed: \(error.localizedDescription)"
        }
    }
}

final class TranslationPanel: FloatingPanel {
    var closed: () -> Void = {}
    private let session: TranslationSession
    private var keyMonitor: Any?
    private var didClose = false

    init(session: TranslationSession, store: TaskStore, origin: CGPoint) {
        self.session = session
        let size = SelectionTranslationLayout.panelSize, inset = TranslationPanelView.shadowInset
        super.init(contentRect: NSRect(x: origin.x - inset.leading, y: origin.y - inset.bottom,
                                       width: size.width + inset.leading + inset.trailing, height: size.height + inset.top + inset.bottom),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        appearance = NSAppearance(named: .darkAqua)
        let host = FirstMouseHostingView(rootView: TranslationPanelView(session: session, store: store) { [weak self] in self?.close() }
            .padding(inset))
        host.safeAreaRegions = []
        contentView = host
    }

    func present() {
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; animator().alphaValue = 1 }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self, event.keyCode == 53 else { return event }
            self.close(); return nil
        }
    }

    override func close() {
        guard !didClose else { return }
        didClose = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        session.cancel()
        super.close()
        closed()
    }
}

/// Figma "划词翻译": 374×528, radius 38, native glass under a black gradient (99% → 97% at 80% → 40%)
/// and a 30% black shadow (y 20, blur 50). No border.
struct TranslationPanelView: View {
    static let shadowInset = EdgeInsets(top: 32, leading: 56, bottom: 84, trailing: 56)
    @ObservedObject var session: TranslationSession
    @ObservedObject var store: TaskStore
    var close: () -> Void
    @StateObject private var draft = ComposerDraft()
    @State private var sourceExpanded = false
    @State private var footerHeight: CGFloat = 80
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let shape = RoundedRectangle(cornerRadius: 38, style: .continuous)
    private var task: Todo? { session.taskID.flatMap { id in store.tasks.first { $0.id == id } } }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Color.clear.frame(height: 40)
                        source
                        result
                        if let task { conversation(task) }
                        Color.clear.frame(height: footerHeight).id("bottom")
                    }.padding(.horizontal, 16).padding(.top, 16)
                }.scrollIndicators(.hidden)
                    .onChange(of: task?.messages.last(where: { $0.role == "user" })?.id) { _, _ in
                        // One nonanimated adjustment after the editor collapses; never follow streaming or copy.
                        DispatchQueue.main.async {
                            var transaction = Transaction(); transaction.disablesAnimations = true
                            withTransaction(transaction) { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                    }

            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 56 / 528),
                                         .init(color: .black, location: 1 - (footerHeight + 4) / 528), .init(color: .clear, location: 1 - max(0, footerHeight - 20) / 528)],
                                 startPoint: .top, endPoint: .bottom))
            footer
        }
        .coordinateSpace(name: "translationFlight")
        .onPreferenceChange(RectPreference.self) { values in
            if let rect = values["footer"], abs(footerHeight - rect.height) > 0.5 { footerHeight = rect.height }
        }
        .overlay(alignment: .top) { header }
        .frame(width: SelectionTranslationLayout.panelSize.width, height: SelectionTranslationLayout.panelSize.height)
        .background(LinearGradient(stops: [.init(color: .black.opacity(0.99), location: 0), .init(color: .black.opacity(0.97), location: 0.8),
                                           .init(color: .black.opacity(0.4), location: 1)], startPoint: .top, endPoint: .bottom), in: shape)
        .modifier(PanelGlass(shape: shape))
        .clipShape(shape)
        .compositingGroup()
        .shadow(color: .black.opacity(0.3), radius: 25, y: 20)
    }

    /// Tool row: 40pt tall, 36pt glass close button on the trailing edge.
    private var header: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                GlassSymbolButton(symbol: "xmark", size: 36, pointSize: 13, help: "Close", action: close)
            }
        }.padding([.horizontal, .top], 16).frame(height: 56, alignment: .top)
            .modifier(WindowDrag())
    }

    private var footer: some View {
        TaskComposer(draft: draft, canSend: canSend, action: submit)
            .padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 16)
            .trackRect("footer", in: "translationFlight")
    }

    /// Figma "Message": #262628, radius 16, padding 12, 11/16 SF Pro, tracking −0.11, #E0E0E2.
    private var source: some View {
        Text(session.source).font(.system(size: 11)).tracking(-0.11).lineSpacing(TranslationType.spacing(size: 11, lineHeight: 16))
            .foregroundStyle(Color(red: 0.878, green: 0.878, blue: 0.886))
            .lineLimit(sourceExpanded ? nil : 2).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color(red: 0.149, green: 0.149, blue: 0.157), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { sourceExpanded.toggle() } }
            .help(sourceExpanded ? "Collapse" : "Show full selection")
            .accessibilityLabel("Selected text: " + session.source)
    }

    @ViewBuilder private var result: some View {
        if let failure = session.failure {
            VStack(alignment: .leading, spacing: 12) {
                Text(failure).font(.system(size: 14)).tracking(-0.56).foregroundStyle(.white.opacity(0.5))
                Button("Try Again") { session.start() }.buttonStyle(.plain).font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12).frame(height: 28).modifier(GlassSurface(shape: Capsule(), interactive: true))
            }.padding(.horizontal, 12).padding(.vertical, 10)
        } else if session.translation.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Translating…").font(.system(size: 14)).tracking(-0.56).foregroundStyle(.white.opacity(0.5))
            }.padding(.horizontal, 12).padding(.vertical, 10)
        } else {
            TranslationResult(text: session.translation, finished: session.finished)
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
                        CopyableReply(text: text, canCopy: !message.pending, markdown: false)
                            .font(.system(size: 14)).tracking(-0.56)
                            .lineSpacing(TranslationType.spacing(size: 14, lineHeight: 19))
                            .foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                    } else if message.pending && task.status == "running" {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text(task.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                        }.frame(height: 28).padding(.horizontal, 12)
                    }
                }
            }
            if ["error", "paused", "needs_input"].contains(task.status) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(task.summary).font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                    Button("Model Settings…") { NotificationCenter.default.post(name: .init("NousShowModels"), object: nil) }.buttonStyle(.plain)
                }.padding(.horizontal, 12)
            }

        }.padding(.top, 8)
    }

    private var canSend: Bool {
        guard draft.hasContent, session.finished || session.failure != nil else { return false }
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
    var body: some View {
        CopyableReply(text: text, canCopy: finished, markdown: false)
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

struct WindowDrag: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.contentShape(Rectangle()).gesture(WindowDragGesture()) } else { content }
    }
}
