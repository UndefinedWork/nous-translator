import Foundation
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

private final class ForbiddenExternalAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
    var attempts: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private actor RecognitionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func pause() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@main struct AttachmentFlowTests {
    @MainActor static func main() async throws {
        // Match the real app: initialize AppKit on its actor before Vision work is
        // dispatched to a background worker, avoiding lazy AppKit initialization there.
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nous-attachment-flow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "nous-attachment-flow-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unconfigured", forKey: "conversationProvider")
        defaults.set("local", forKey: "imageRecognition.provider")
        let image = folder.appendingPathComponent("sample.png")
        try makeImage(at: image)
        let imageData = try Data(contentsOf: image)
        let document = folder.appendingPathComponent("notes.txt")
        let expectedDocument = "Project notes\n会议时间：明天下午三点。"
        try expectedDocument.write(to: document, atomically: true, encoding: .utf8)
        let attachmentDirectory = folder.appendingPathComponent("isolated-app-support/Attachments")
        let cache = ImageRecognitionCache(capacity: 4)
        let external = ForbiddenExternalAccess()
        var validationCalls = 0
        var extractionCalls = 0
        var extractedCopies: [String] = []
        let configuration = { ImageRecognitionConfiguration.load(defaults: defaults) }
        let store = TaskStore(attachmentDirectory: attachmentDirectory,
            imageConfiguration: configuration,
            extractAttachment: { file, configuration in
                extractionCalls += 1
                extractedCopies.append(file.path)
                return try await AttachmentTextExtractor.extract(url: URL(fileURLWithPath: file.path),
                    configuration: configuration,
                    transport: { _, _ in
                        external.record()
                        throw ModelError.message("Online image recognition is forbidden in this test")
                    },
                    keyReader: { _ in
                        external.record()
                        throw ModelError.message("Keychain access is forbidden in this test")
                    }, cache: cache)
            },
            validateConversation: {
                validationCalls += 1
                precondition(defaults.string(forKey: "conversationProvider") == "unconfigured")
                throw ModelError.message("Conversation is unconfigured in the isolated test suite")
            })
        defer { store.stop() }
        func file(_ url: URL) -> ComposerFile { ComposerFile(name: url.lastPathComponent, path: url.path) }
        func wait(_ label: String, until predicate: () -> Bool) async throws {
            // Apple Vision may spend about 20 seconds compiling for the Neural Engine on a cold cache.
            for _ in 0..<3000 {
                if predicate() { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw NSError(domain: "AttachmentFlowTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Timed out: " + label])
        }
        func settled(_ id: UUID, in target: TaskStore) async throws -> Todo {
            try await wait("attachment task completion: " + (target.tasks.first(where: { $0.id == id })?.summary ?? "missing task")) {
                target.tasks.first(where: { $0.id == id })?.status != "running"
            }
            return target.tasks.first(where: { $0.id == id })!
        }
        func answer(_ task: Todo) -> ChatMessage { task.messages.last(where: { $0.role == "assistant" })! }

        // Actual Apple Vision OCR runs through the same TaskStore extraction pipeline.
        // The standalone attachment marker must not be mistaken for a chat question.
        let imageID = store.add("[Attachment: sample.png]", files: [file(image)]) { _ in "" }!
        let imageStarted = ProcessInfo.processInfo.systemUptime
        let imageTask = try await settled(imageID, in: store)
        FileHandle.standardError.write(Data("Actual TaskStore OCR completed in \(ProcessInfo.processInfo.systemUptime - imageStarted) seconds\n".utf8))
        let imageReply = answer(imageTask)
        precondition(imageTask.status == "completed", imageTask.summary)
        precondition(!imageReply.pending && imageReply.text.lowercased().contains("nous translator"), imageReply.text)
        precondition(imageReply.text.lowercased().contains("hello local ocr"), imageReply.text)
        precondition(imageTask.messages.first?.text == "", "Attachment markers are not a conversation question")
        precondition(validationCalls == 0 && external.attempts == 0, "Recognition-only must not require conversation or external services")

        let documentID = store.add("", files: [file(document)]) { _ in "" }!
        let documentTask = try await settled(documentID, in: store)
        precondition(documentTask.status == "completed" && answer(documentTask).text == expectedDocument)
        precondition(!answer(documentTask).pending)
        precondition(validationCalls == 0 && external.attempts == 0)

        let mixedID = store.add("[Attachment: sample.png]\n[Attachment: notes.txt]", files: [file(image), file(document)]) { _ in "" }!
        let mixedTask = try await settled(mixedID, in: store)
        precondition(mixedTask.status == "completed")
        let mixedText = answer(mixedTask).text
        precondition(mixedText.contains("sample.png\n") && mixedText.contains("notes.txt\n"))
        precondition(mixedText.contains(expectedDocument))
        precondition(validationCalls == 0 && external.attempts == 0)
        precondition(extractedCopies.allSatisfy { $0.hasPrefix(attachmentDirectory.path + "/") }, "Only isolated copied attachments are processed")
        let preservedImage = try Data(contentsOf: image)
        let preservedDocument = try String(contentsOf: document, encoding: .utf8)
        precondition(preservedImage == imageData, "The source image must remain unchanged")
        precondition(preservedDocument == expectedDocument)

        // Explicit questions still require a conversation model, and fail before OCR
        // or online image recognition could consume time or incur charges.
        let extractionsBeforeQuestion = extractionCalls
        let questionID = store.add("What does this image say? [Attachment: sample.png]", files: [file(image)]) { _ in "" }!
        let questionTask = try await settled(questionID, in: store)
        precondition(questionTask.status == "error" && questionTask.summary.contains("unconfigured"))
        precondition(validationCalls == 1 && extractionCalls == extractionsBeforeQuestion)
        precondition(answer(questionTask).text.isEmpty && !answer(questionTask).pending)
        precondition(external.attempts == 0)

        // Deliberately return late content from an extractor that ignores cancellation.
        // TaskStore itself must guard against recording this as a successful result.
        let gate = RecognitionGate()
        let cancelledStore = TaskStore(attachmentDirectory: folder.appendingPathComponent("cancelled-attachments"),
            imageConfiguration: configuration,
            extractAttachment: { _, _ in await gate.pause(); return "This late text must never be shown" },
            validateConversation: { throw ModelError.message("Unexpected conversation validation") })
        defer { cancelledStore.stop() }
        let cancelledID = cancelledStore.add("", files: [file(document)]) { _ in "" }!
        for _ in 0..<100 {
            if await gate.entered { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let entered = await gate.entered
        precondition(entered)
        cancelledStore.stop()
        await gate.release()
        let cancelledTask = try await settled(cancelledID, in: cancelledStore)
        precondition(cancelledTask.status == "cancelled")
        precondition(answer(cancelledTask).text.isEmpty && !answer(cancelledTask).pending)
        precondition(cancelledTask.messages.first?.modelText == nil && cancelledStore.streams[cancelledID] == nil)

        // URLSession cancellation uses URLError.cancelled rather than CancellationError.
        let transportCancelledStore = TaskStore(attachmentDirectory: folder.appendingPathComponent("transport-cancelled-attachments"),
            imageConfiguration: configuration,
            extractAttachment: { _, _ in throw URLError(.cancelled) },
            validateConversation: { throw ModelError.message("Unexpected conversation validation") })
        defer { transportCancelledStore.stop() }
        let transportCancelledID = transportCancelledStore.add("", files: [file(document)]) { _ in "" }!
        let transportCancelledTask = try await settled(transportCancelledID, in: transportCancelledStore)
        precondition(transportCancelledTask.status == "cancelled" && answer(transportCancelledTask).text.isEmpty)
        precondition(!answer(transportCancelledTask).pending)
        print("PASS: TaskStore real local OCR and text-only recognition, attachment markers, multi-file labels, unconfigured conversation guard before extraction, late-result cancellation, transport cancellation, isolated storage and zero external/key access")
    }

    private static func makeImage(at url: URL) throws {
        let context = CGContext(data: nil, width: 1200, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 360))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        for (text, y) in [("NOUS TRANSLATOR", 230.0), ("Hello local OCR", 110.0)] {
            context.textPosition = CGPoint(x: 40, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
