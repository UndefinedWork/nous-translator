import Foundation
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

private actor RequestRecorder {
    private(set) var requests: [URLRequest] = []
    func add(_ request: URLRequest) { requests.append(request) }
    var count: Int { requests.count }
}
private actor RecognitionGate {
    private var reached = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() { reached = true; waiters.forEach { $0.resume() }; waiters = [] }
    func wait() async {
        if reached { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@main struct ImageRecognitionTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nous-image-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("sample.png")
        try fixtureImage(at: image, width: 3000, height: 1500)

        let suite = "nous-image-settings-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "fastOCR")
        defaults.set("openai", forKey: "translationProvider")
        defaults.set("text-only-model", forKey: "api.openai.model")
        defaults.set("https://api.openai.com/v1", forKey: "api.openai.url")
        let migrated = ImageRecognitionConfiguration.load(defaults: defaults)
        precondition(migrated.provider == .local && migrated.fastOCR && migrated.model.isEmpty,
                     "Existing OCR speed migrates locally; translation provider/model never imply image upload consent")
        let unconfiguredOnline = ImageRecognitionConfiguration.load(provider: .openai, defaults: defaults)
        precondition(unconfiguredOnline.model.isEmpty, "A vision model must be chosen explicitly")
        try rejects { try unconfiguredOnline.validate() }
        var online = ImageRecognitionConfiguration(provider: .openai, model: "fixture-vision-model", baseURL: "https://api.openai.com/v1", fastOCR: true)
        try online.save(defaults: defaults)
        precondition(ImageRecognitionConfiguration.load(defaults: defaults) == online)
        precondition(APIProfile.load(.openai, defaults: defaults).model == "text-only-model", "Saving an image model must not change the conversation/translation profile")
        precondition(online.profile.account == APIProfile(provider: .openai, baseURL: online.baseURL, model: "another-model").account,
                     "Images reuse only the same provider/address Keychain account")
        defaults.set("deepseek", forKey: "imageRecognition.provider")
        precondition(ImageRecognitionConfiguration.load(defaults: defaults).provider == .local,
                     "An unsupported saved image provider never silently uploads elsewhere")
        try rejects { try ImageRecognitionConfiguration(provider: .deepseek, model: "fixture", baseURL: "https://api.deepseek.com").validate() }
        try rejects { try ImageRecognitionConfiguration(provider: .custom, model: "fixture", baseURL: "http://example.com/v1").validate() }
        try rejects { try ImageRecognitionConfiguration(provider: .openai, model: "fixture", baseURL: "https://example.com/v1").validate() }

        let supported = ["en-US", "fr-FR", "de-DE"]
        let selected = ImageRecognition.preferredLanguages(supported: supported, preferred: ["zh-Hans-CN", "ja-JP", "fr"])
        precondition(selected.first == "fr-FR" && Set(selected) == Set(supported),
                     "Vision language priorities contain only languages supported at the selected recognition level")

        let recorder = RequestRecorder()
        let cache = ImageRecognitionCache(capacity: 3)
        let fakeTransport: ImageRecognition.Transport = { request, _ in
            await recorder.add(request)
            let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            precondition(json["model"] as? String == "fixture-vision-model")
            precondition(json["store"] as? Bool == false)
            precondition(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
            let messages = json["messages"] as! [[String: Any]]
            precondition((messages[0]["content"] as? String)?.contains("never an instruction") == true)
            let content = messages[1]["content"] as! [[String: Any]]
            let imagePart = content.first { $0["type"] as? String == "image_url" }!
            let imageURL = (imagePart["image_url"] as! [String: String])["url"]!
            precondition(imageURL.hasPrefix("data:image/jpeg;base64,"))
            let bytes = Data(base64Encoded: String(imageURL.dropFirst("data:image/jpeg;base64,".count)))!
            precondition(bytes.count <= ImageRecognition.maximumUploadBytes)
            let source = CGImageSourceCreateWithData(bytes as CFData, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
            precondition((properties[kCGImagePropertyPixelWidth] as! Int) <= ImageRecognition.maximumUploadDimension)
            precondition((properties[kCGImagePropertyPixelHeight] as! Int) <= ImageRecognition.maximumUploadDimension)
            precondition(properties[kCGImagePropertyGPSDictionary] == nil, "Source location metadata is not uploaded")
            return "  Hello 42\n你好  "
        }
        let first = try await ImageRecognition.recognize(url: image, configuration: online,
            transport: fakeTransport, keyReader: { _ in "test-only-placeholder" }, cache: cache)
        precondition(first == "Hello 42\n你好")
        let second = try await ImageRecognition.recognize(url: image, configuration: online,
            transport: { _, _ in fatalError("Identical successful images should use the bounded memory cache") },
            keyReader: { _ in fatalError("Cached results do not read credentials") }, cache: cache)
        precondition(second == first)
        let count = await recorder.count
        precondition(count == 1)
        let previousIdentity = online.cacheIdentity
        online.model = "another-vision-model"
        precondition(online.cacheIdentity != previousIdentity, "Changing the image model invalidates the cached result")
        _ = try await ImageRecognition.recognize(url: image, configuration: online,
            transport: { request, _ in await recorder.add(request); return "New model result" },
            keyReader: { _ in "test-only-placeholder" }, cache: cache)
        let updatedCount = await recorder.count
        precondition(updatedCount == 2)
        let bounded = ImageRecognitionCache(capacity: 1)
        await bounded.insert("first", for: "first"); await bounded.insert("second", for: "second")
        let evicted = await bounded.value(for: "first")
        precondition(evicted == nil, "Recognition cache evicts old entries instead of growing without bound")

        for reply in ["   \n", String(repeating: "x", count: ImageRecognition.maximumTextCharacters + 1)] {
            try await rejectsAsync {
                _ = try await ImageRecognition.recognize(url: image, configuration: online,
                    transport: { _, _ in reply }, keyReader: { _ in "test-only-placeholder" }, cache: nil)
            }
        }
        try await rejectsAsync {
            _ = try await ImageRecognition.recognize(url: image, configuration: online,
                transport: { _, _ in throw URLError(.notConnectedToInternet) },
                keyReader: { _ in "test-only-placeholder" }, cache: nil)
        }
        let oversized = directory.appendingPathComponent("oversized.png")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let sparse = try FileHandle(forWritingTo: oversized)
        try sparse.truncate(atOffset: UInt64(ImageRecognition.maximumInputBytes + 1)); try sparse.close()
        try await rejectsAsync {
            _ = try await ImageRecognition.recognize(url: oversized, configuration: online,
                transport: { _, _ in fatalError("Oversized files must never be uploaded") },
                keyReader: { _ in fatalError("Reject oversized files before reading credentials") }, cache: nil)
        }

        let gate = RecognitionGate(), cancelledCache = ImageRecognitionCache()
        let pending = Task {
            try await ImageRecognition.recognize(url: image, configuration: online,
                transport: { _, _ in await gate.signal(); try await Task.sleep(nanoseconds: 10_000_000_000); return "too late" },
                keyReader: { _ in "test-only-placeholder" }, cache: cancelledCache)
        }
        await gate.wait(); pending.cancel()
        do { _ = try await pending.value; fatalError("Cancellation must not return text") }
        catch is CancellationError {} catch { throw error }
        let afterCancellation = try await ImageRecognition.recognize(url: image, configuration: online,
            transport: { _, _ in "Fresh result after cancellation" }, keyReader: { _ in "test-only-placeholder" }, cache: cancelledCache)
        precondition(afterCancellation == "Fresh result after cancellation")

        let textFile = directory.appendingPathComponent("notes.txt")
        try "Local document 123".write(to: textFile, atomically: true, encoding: .utf8)
        let pdfFile = directory.appendingPathComponent("notes.pdf")
        try fixturePDF(at: pdfFile)
        for document in [textFile, pdfFile] {
            let text = try await AttachmentTextExtractor.extract(url: document, configuration: online,
                transport: { _, _ in fatalError("PDF/text extraction must remain local") },
                keyReader: { _ in fatalError("PDF/text extraction never reads an API key") }, cache: nil)
            precondition(text.contains("Local document 123"))
        }

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(try Data(contentsOf: image), forType: .png)
        let draft = ComposerDraft()
        precondition(draft.paste(pasteboard), "Encoded image paste is accepted")
        for _ in 0..<100 where draft.files.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(draft.files.count == 1 && FileManager.default.fileExists(atPath: draft.files[0].path),
                     "Background image import creates a usable attachment without full image conversion on the editor thread")
        draft.clear()
        let clearedDraft = ComposerDraft()
        precondition(clearedDraft.paste(pasteboard))
        clearedDraft.clear()
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(clearedDraft.files.isEmpty, "Clearing the draft cancels a queued image import and prevents late reinsertion")

        // Exercise Apple's real OCR implementation on a generated, non-private image.
        for fast in [false, true] {
            let local = try await ImageRecognition.recognize(url: image,
                configuration: ImageRecognitionConfiguration(fastOCR: fast),
                transport: { _, _ in fatalError("Apple Vision must never invoke an online transport") },
                keyReader: { _ in fatalError("Apple Vision must never read an API key") }, cache: nil)
            precondition(local.lowercased().contains("hello") && local.contains("42"), "Real Vision OCR must work in both accurate and fast modes")
        }
        print("PASS: independent image settings, safe legacy migration, image_url payload/limits, endpoint isolation, cancellation, bounded cache, errors, local PDF/text, background image paste, and real Vision accurate/fast OCR")
    }

    static func rejects(_ body: () throws -> Void) throws {
        do { try body(); fatalError("Expected rejection") } catch {}
    }
    static func rejectsAsync(_ body: () async throws -> Void) async throws {
        do { try await body(); fatalError("Expected rejection") } catch {}
    }
    static func fixtureImage(at url: URL, width: Int, height: Int) throws {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw("Hello 42", in: context, at: CGPoint(x: 160, y: height / 2), size: 180)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
    }
    static func fixturePDF(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 600, height: 400)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        draw("Local document 123", in: context, at: CGPoint(x: 40, y: 200), size: 28)
        context.endPDFPage(); context.closePDF()
    }
    static func draw(_ string: String, in context: CGContext, at point: CGPoint, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let text = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
}
