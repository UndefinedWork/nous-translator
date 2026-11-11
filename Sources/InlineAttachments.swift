import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO
import PDFKit

struct ComposerFile: Codable {
    var name: String
    var path: String

    func extractedText(configuration: ImageRecognitionConfiguration = .load()) async throws -> String {
        try await AttachmentTextExtractor.extract(url: URL(fileURLWithPath: path), configuration: configuration)
    }
}

/// Documents remain local even when online image recognition is selected.
/// All detection, file reads, decoding and OCR happen away from the main actor.
enum AttachmentTextExtractor {
    static func extract(url: URL, configuration: ImageRecognitionConfiguration = .load(),
                        transport: ImageRecognition.Transport? = nil,
                        keyReader: @escaping ImageRecognition.KeyReader = { try APIKeyStore.read($0) },
                        cache: ImageRecognitionCache? = .shared) async throws -> String {
        try Task.checkCancellation()
        let image = try await ImageRecognition.worker { ImageRecognition.isImage(url: url) }
        if image {
            return try await ImageRecognition.recognize(url: url, configuration: configuration,
                transport: transport, keyReader: keyReader, cache: cache)
        }
        // Local documents have a separate cache identity, so changing an online image
        // provider never causes PDF/text files to be uploaded or needlessly reprocessed.
        let fingerprint = try await ImageRecognition.worker { try ImageRecognition.fingerprint(url: url) }
        let kind = url.pathExtension.lowercased() == "pdf" ? "pdf" : "text"
        let key = fingerprint + ":local-document:" + kind
        if let value = await cache?.value(for: key) { try Task.checkCancellation(); return value }
        let extracted = try await ImageRecognition.worker {
            let text: String
            if kind == "pdf" {
                guard let document = PDFDocument(url: url), !document.isLocked else {
                    throw ModelError.message("This PDF could not be read or requires a password.")
                }
                var pages: [String] = [], characters = 0
                for index in 0..<document.pageCount {
                    try Task.checkCancellation()
                    let page = document.page(at: index)?.string ?? ""
                    characters += page.count
                    guard characters <= ImageRecognition.maximumTextCharacters else {
                        throw ModelError.message("The PDF contains too much text. Send fewer pages (up to 16000 characters).")
                    }
                    if !page.isEmpty { pages.append(page) }
                }
                text = pages.joined(separator: "\n")
            } else {
                text = try String(contentsOf: url, encoding: .utf8)
            }
            try Task.checkCancellation()
            let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else {
                throw ModelError.message(kind == "pdf"
                    ? "This PDF has no readable text layer. Attach an image of the page for image recognition."
                    : "No readable text was found in the attachment.")
            }
            guard result.count <= ImageRecognition.maximumTextCharacters else {
                throw ModelError.message("The attachment contains too much text. Send it in smaller parts (up to 16000 characters).")
            }
            return result
        }
        try Task.checkCancellation()
        if let cache { await cache.insert(extracted, for: key) }
        try Task.checkCancellation()
        return extracted
    }
}
final class FileAttachment: NSTextAttachment {
    let file: ComposerFile
    init(file: ComposerFile) {
        self.file = file
        super.init(data: nil, ofType: nil)
        let chip = FileChip(textCell: file.name)
        if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: file.path) as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 48, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
            chip.thumbnail = NSImage(cgImage: image, size: NSSize(width: 20, height: 20))
        }
        attachmentCell = chip
    }
    required init?(coder: NSCoder) { nil }
}
final class FileChip: NSTextAttachmentCell {
    var hovered = false
    var thumbnail: NSImage?
    override func cellSize() -> NSSize { NSSize(width: min(220, CGFloat(stringValue.count) * 7 + 44), height: 28) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -7) }
    override func draw(withFrame frame: NSRect, in view: NSView?) {
        TelosTheme.native(1, 0.23).setFill(); NSColor.separatorColor.setStroke()
        let path = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        path.fill(); path.stroke()
        let symbol = NSImage(systemSymbolName: hovered ? "xmark.circle.fill" : "doc", accessibilityDescription: hovered ? "Remove attachment" : "Attachment")
        (hovered ? symbol : (thumbnail ?? symbol))?.draw(in: NSRect(x: frame.minX + 7, y: frame.minY + 6, width: 16, height: 16))
        (stringValue as NSString).draw(in: NSRect(x: frame.minX + 28, y: frame.minY + 6, width: frame.width - 34, height: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor])
    }
}
@MainActor final class ComposerDraft: ObservableObject {
    @Published var content = NSAttributedString(string: "") {
        didSet { cachedCompactHeight = nil }
    }
    @Published var compactWidth: CGFloat = 250 { didSet { cachedCompactHeight = nil } }
    private var cachedCompactHeight: CGFloat?
    private var filePicker: NSOpenPanel?
    private var imageImports: [UUID: Task<Void, Never>] = [:]
    private var importGeneration = UUID()
    @Published var error: String?
    @Published var isHovered = false
    @Published var isFocused = false
    @Published var isPressed = false
    @Published var isComposing = false
    @Published var editorHeight: CGFloat = 20
    var showsPlaceholder: Bool { content.length == 0 && !isComposing }
    weak var hitSurface: NSView?
    weak var editor: AttachmentTextView?
    private let staging = FileManager.default.temporaryDirectory.appendingPathComponent("TelosDraft-" + UUID().uuidString)
    var compactLayoutHeight: CGFloat {
        if let cachedCompactHeight { return cachedCompactHeight }
        // Only measure enough text to decide the compact/expanded state.
        let storage = NSTextStorage(attributedString: content.attributedSubstring(from: NSRange(location: 0, length: min(content.length, 2048))))
        let layout = NSLayoutManager(); let container = NSTextContainer(size: NSSize(width: max(1, compactWidth), height: 144))
        container.lineFragmentPadding = 0; layout.addTextContainer(container); storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let height = min(144, max(20, ceil(max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY))))
        cachedCompactHeight = height
        return height
    }
    var hasContent: Bool { !content.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var files: [ComposerFile] {
        var result: [ComposerFile] = []
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, _ in
            if let a = value as? FileAttachment { result.append(a.file) }
        }
        return result
    }
    var text: String {
        let result = NSMutableAttributedString(attributedString: content)
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length), options: .reverse) { value, range, _ in
            if let a = value as? FileAttachment { result.replaceCharacters(in: range, with: "[Attachment: \(a.file.name)]") }
        }
        return result.string
    }
    func setText(_ text: String) { content = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]) }
    func clear() {
        importGeneration = UUID(); imageImports.values.forEach { $0.cancel() }; imageImports = [:]
        setText(""); editorHeight = 20; editor?.undoManager?.removeAllActions()
        try? FileManager.default.removeItem(at: staging)
    }
    func chooseFiles() {
        if let filePicker { NSApp.activate(ignoringOtherApps: true); filePicker.makeKeyAndOrderFront(nil); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = "Attach files"; panel.prompt = "Attach"
        panel.level = .modalPanel
        filePicker = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self else { return }
            if response == .OK { self.insert(panel.urls) }
            self.filePicker = nil
            self.editor?.window?.makeKeyAndOrderFront(nil)
            self.editor?.window?.makeFirstResponder(self.editor)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func insert(_ urls: [URL]) {
        do {
            let value = NSMutableAttributedString(string: "")
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard info.isRegularFile == true, (info.fileSize ?? 0) <= 50 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                let dir = staging.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let copy = dir.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: copy)
                value.append(NSAttributedString(attachment: FileAttachment(file: ComposerFile(name: url.lastPathComponent, path: copy.path))))
            }
            if let editor {
                editor.insertText(value, replacementRange: editor.selectedRange())
                editor.window?.makeFirstResponder(editor)
            } else {
                let updated = NSMutableAttributedString(attributedString: content)
                updated.append(value); content = updated
            }
        } catch { self.error = "Could not attach file (maximum 50 MB): \(error.localizedDescription)" }
    }
    func paste(_ board: NSPasteboard) -> Bool {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { insert(urls); return true }
        // Preserve encoded pasteboard bytes; converting NSImage → TIFF → PNG here used
        // to decode and re-encode the full screenshot on the editor's main thread.
        let imageTypes = [.png, .tiff] + NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
        for type in imageTypes where board.types?.contains(type) == true {
            guard let data = board.data(forType: type) else { continue }
            guard data.count <= ImageRecognition.maximumInputBytes else {
                error = "Could not attach image (maximum 50 MB)."; return true
            }
            let id = UUID(), generation = importGeneration
            let suffix = UTType(type.rawValue)?.preferredFilenameExtension ?? "image"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Image-\(id)." + suffix)
            imageImports[id] = Task { [weak self] in
                defer { try? FileManager.default.removeItem(at: url); self?.imageImports.removeValue(forKey: id) }
                do {
                    try await ImageRecognition.worker { try data.write(to: url, options: .atomic) }
                    try Task.checkCancellation()
                    guard let self, self.importGeneration == generation else { return }
                    self.insert([url])
                } catch is CancellationError {
                } catch { self?.error = error.localizedDescription }
            }
            return true
        }
        return false
    }
    deinit { imageImports.values.forEach { $0.cancel() }; try? FileManager.default.removeItem(at: staging) }
}
final class AttachmentTextView: NSTextView {
    var dictationInputSurface: NSView? { draft?.hitSurface }
    weak var draft: ComposerDraft?
    var submit: () -> Void = {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); if result { draft?.isFocused = true }; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); if result { draft?.isFocused = false }; return result }

    private var measurementQueued = false
    func scheduleMeasurement() {
        guard !measurementQueued else { return }
        measurementQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurementQueued = false
            guard let layout = self.layoutManager, let container = self.textContainer else { return }
            // The editor stops growing at 144 points; lay out only that viewport.
            layout.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: max(1, container.size.width), height: 144), in: container)
            var height = layout.usedRect(for: container).maxY
            if layout.extraLineFragmentTextContainer === container {
                height = max(height, layout.extraLineFragmentRect.maxY)
            }
            let lineHeight = layout.defaultLineHeight(for: self.font ?? .systemFont(ofSize: 14))
            let measured = ComposerSizing.editorHeight(contentHeight: height, lineHeight: lineHeight, inset: self.textContainerInset.height)
            if self.draft?.editorHeight != measured { self.draft?.editorHeight = measured }
        }
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changedWidth = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changedWidth { scheduleMeasurement() }
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        publishEditingState()
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        publishEditingState()
    }
    override func unmarkText() {
        super.unmarkText()
        publishEditingState()
    }
    override func didChangeText() {
        super.didChangeText()
        // Native Undo can restore attachments without calling insertText again.
        publishEditingState()
    }
    func publishEditingState() {
        if draft?.isComposing != hasMarkedText() { draft?.isComposing = hasMarkedText() }
        if let draft, !draft.content.isEqual(to: attributedString()) {
            draft.content = NSAttributedString(attributedString: attributedString())
        }
        scheduleMeasurement()
    }
    // AppKit validates Paste and routes context-menu/services imports using these types.
    // Keep native graphics import disabled: every image must become our removable FileAttachment.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
        types += NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
        for type in super.readablePasteboardTypes where !types.contains(type) { types.append(type) }
        return types
    }
    override func readSelection(from board: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if draft?.paste(board) == true { return true }
        return super.readSelection(from: board, type: type)
    }
    override func paste(_ sender: Any?) { if draft?.paste(.general) != true { pasteAsPlainText(sender) } }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        return draft?.paste(sender.draggingPasteboard) ?? false
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) && !hasMarkedText() { submit(); return }
        super.keyDown(with: event)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    func attachments(_ action: (FileChip, NSRange, NSRect) -> Void) {
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let cell = (value as? FileAttachment)?.attachmentCell as? FileChip else { return }
            var rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            rect.origin.x += textContainerOrigin.x; rect.origin.y += textContainerOrigin.y
            action(cell, range, rect)
        }
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        attachments { cell, _, rect in cell.hovered = rect.contains(p) }; needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { attachments { cell, _, _ in cell.hovered = false }; needsDisplay = true }
    /// Focus, position and paint the caret before NSTextView enters mouse tracking.
    func beginPointerEditing(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        draft?.isPressed = true
        if event.clickCount == 1 && !event.modifierFlags.contains(.shift) && !hasMarkedText() {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            let selection = selectedRange()
            // Retain native dragging of selected text and double/triple-click selection.
            if selection.length == 0 || !NSLocationInRange(index, selection) {
                setSelectedRange(NSRange(location: index, length: 0))
            }
        }
        updateInsertionPointStateAndRestartTimer(true)
        needsDisplay = true
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.contentView?.displayIfNeeded()
    }
    override var shouldDrawInsertionPoint: Bool {
        super.shouldDrawInsertionPoint || (draft?.isPressed == true && window?.firstResponder === self && selectedRange().length == 0)
    }
    override func mouseDown(with event: NSEvent) {
        beginPointerEditing(event)
        defer {
            draft?.isPressed = false

        }
        let p = convert(event.locationInWindow, from: nil); var target: NSRange?
        attachments { cell, range, rect in if cell.hovered && rect.contains(p) && p.x < rect.minX + 26 { target = range } }
        if let target { insertText("", replacementRange: target) } else { super.mouseDown(with: event) }
    }
}
struct InlineComposerEditor: NSViewRepresentable {
    @ObservedObject var draft: ComposerDraft
    var placeholder: String
    var identifier: String
    var action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(draft) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        let view = AttachmentTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        view.minSize = NSSize(width: 0, height: 20)
        view.isRichText = true; view.importsGraphics = false; view.allowsUndo = true; view.drawsBackground = false
        view.font = .systemFont(ofSize: 14); view.textColor = .labelColor; view.textContainerInset = NSSize(width: 0, height: 1)
        view.insertionPointColor = .white
        view.textContainer?.lineFragmentPadding = 0; view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator; view.draft = draft; draft.editor = view
        view.registerForDraggedTypes([.fileURL, .png, .tiff]); view.setAccessibilityIdentifier(identifier)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? AttachmentTextView else { return }
        view.submit = action
        if !view.hasMarkedText(), !view.attributedString().isEqual(to: draft.content) {
            view.textStorage?.setAttributedString(draft.content)
            view.scheduleMeasurement()
        }
        view.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
        view.insertionPointColor = .white
        view.setAccessibilityLabel(placeholder)
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let draft: ComposerDraft
        init(_ draft: ComposerDraft) { self.draft = draft }
        func textDidChange(_ notification: Notification) { if let view = notification.object as? AttachmentTextView { view.publishEditingState() } }
    }
}
struct AttachmentInput: View {
    @ObservedObject var draft: ComposerDraft
    var placeholder: String
    var identifier: String
    var action: () -> Void
    var body: some View {
        InlineComposerEditor(draft: draft, placeholder: placeholder, identifier: identifier, action: action)
            .frame(height: draft.editorHeight)
            .transaction { $0.animation = nil }
            .overlay(alignment: .topLeading) { if draft.showsPlaceholder { Text(placeholder).font(.system(size: 14)).foregroundStyle(.secondary).frame(height: 20, alignment: .center).allowsHitTesting(false) } }
            .alert("Attachment", isPresented: Binding(get: { draft.error != nil }, set: { if !$0 { draft.error = nil } })) { Button("OK") { draft.error = nil } } message: { Text(draft.error ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: .init(identifier == "newTaskField" ? "TelosNewTask" : "TelosFocusAsk"))) { _ in draft.editor?.window?.makeFirstResponder(draft.editor) }
    }
}

/// Padding is part of the input target, rather than an inert area around the text view.
struct ComposerHitArea: NSViewRepresentable {
    let draft: ComposerDraft
    func makeNSView(context: Context) -> ComposerHitView {
        let view = ComposerHitView(); view.draft = draft; draft.hitSurface = view; return view
    }
    func updateNSView(_ view: ComposerHitView, context: Context) { view.draft = draft; draft.hitSurface = view }
}
final class ComposerHitView: NSView {
    weak var draft: ComposerDraft?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
    override func mouseDown(with event: NSEvent) {
        guard let editor = draft?.editor else { return }
        editor.beginPointerEditing(event)
    }
    override func mouseUp(with event: NSEvent) { draft?.isPressed = false }
}
