import SwiftUI
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Independent image recognition settings section with key presence indicator and multimodal connection testing.
struct ImageRecognitionSettings: View {
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
    @State private var configuration = ImageRecognitionConfiguration.load()
    @State private var key = ""
    @State private var keySaved = false
    @State private var testing = false
    @State private var status = ""

    private var hasUnsavedChanges: Bool {
        let saved = ImageRecognitionConfiguration.load(provider: configuration.provider)
        let activeProvider = ImageRecognitionConfiguration.load().provider
        if configuration.provider != activeProvider { return true }
        if configuration.provider == .local { return configuration.fastOCR != saved.fastOCR }
        return configuration.model.trimmingCharacters(in: .whitespacesAndNewlines) != saved.model.trimmingCharacters(in: .whitespacesAndNewlines)
            || configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) != saved.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            || !key.isEmpty
    }

    var body: some View {
        Section {
            Picker(L10n.text("Recognize images with", zh: "图片识别引擎"), selection: $configuration.provider) {
                Text(L10n.text("Apple Vision · On This Mac", zh: "Apple Vision · 本机离线")).tag(ModelProvider.local)
                Text("OpenAI").tag(ModelProvider.openai)
                Text(L10n.text("Custom API", zh: "自定义 API")).tag(ModelProvider.custom)
            }.disabled(testing)
            if configuration.provider == .local {
                Picker(L10n.text("Text recognition", zh: "识别精度"), selection: $configuration.fastOCR) {
                    Text(L10n.text("Accurate", zh: "精准（Accurate）")).tag(false)
                    Text(L10n.text("Fast", zh: "快速（Fast）")).tag(true)
                }
                if configuration.fastOCR {
                    Text(L10n.text(
                        "Fast recognition may support fewer languages and miss small or complex text.",
                        zh: "快速模式支持的语言可能较少，且容易漏掉小字或复杂排版。"
                    ))
                    .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if configuration.provider == .custom {
                    TextField(L10n.text("Image API base URL", zh: "图片 API 服务地址"), text: $configuration.baseURL,
                              prompt: Text("https://example.com/v1"))
                } else {
                    LabeledContent(L10n.text("Image API base URL", zh: "图片 API 服务地址"), value: configuration.profile.baseURL)
                }
                TextField(L10n.text("Image model ID", zh: "图片模型 ID"), text: $configuration.model,
                          prompt: Text(L10n.text("Enter a model that accepts images", zh: "填写支持图片输入的模型 ID")))
                SecureField("API key", text: $key, prompt: Text(keySaved
                    ? L10n.text("Saved in Keychain · Leave blank to reuse", zh: "已存于钥匙串 · 留空复用")
                    : L10n.text("Enter your API key", zh: "输入你的 API Key")))
                HStack(spacing: 6) {
                    Label(keySaved
                          ? L10n.text("API key saved for this address", zh: "当前地址已保存 API Key")
                          : L10n.text("No saved key for this address", zh: "当前地址未保存 Key"),
                          systemImage: keySaved ? "checkmark.seal.fill" : "key")
                        .font(.caption)
                        .foregroundStyle(keySaved ? Color.green : Color.secondary)
                    if hasUnsavedChanges {
                        Spacer()
                        Text(L10n.text("Unsaved changes", zh: "有未保存更改"))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Text(L10n.text(
                    "If this address already has a saved key, leave the field blank to reuse it. The key is shared by features using the same provider and address.",
                    zh: "同一提供方与地址可复用已保存的 Key（与翻译/对话共享该地址的 Keychain 条目）。"
                ))
                .font(.caption).foregroundStyle(.secondary)
                Text(L10n.text(
                    "Choose your image model explicitly. Translation and conversation model IDs are not copied here.",
                    zh: "请显式填写支持图片的模型 ID，不会自动复用翻译或对话模型 ID。"
                ))
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if configuration.provider != .local {
                    Button(L10n.text("Remove Saved Key", zh: "删除已保存 Key")) {
                        do {
                            try APIKeyStore.delete(configuration.profile.account)
                            key = ""; keySaved = false
                            status = L10n.text("Saved key removed for this provider and address.", zh: "已删除当前提供方和地址保存的 Key。")
                        } catch { status = error.localizedDescription }
                    }.disabled(!keySaved || testing)
                }
                Spacer()
                Button(L10n.text("Save Image Recognition", zh: "保存图片识别设置")) { save() }.disabled(testing)
                if configuration.provider != .local {
                    Button(testing ? L10n.text("Testing…", zh: "测试中…") : L10n.text("Test Connection", zh: "测试图片识别")) {
                        testConnection()
                    }.disabled(testing)
                }
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        } header: { Text(L10n.text("Image Recognition", zh: "图片文字识别")) } footer: {
            if configuration.provider == .local {
                Text(L10n.text(
                    "Apple Vision reads image text on this Mac without an API key or model download. The first recognition can take longer while macOS prepares its model. Send only an image to extract its text, or add a question to continue with your conversation model.",
                    zh: "Apple Vision 在本机识别图片文字，无需 Key 或下载模型。首次识别时 macOS 准备模型可能需要较长时间。仅发送图片会直接返回文字，附带问题时再交给对话模型处理。"
                ))
            } else {
                Text(L10n.text(
                    "Online recognition sends a resized image to this provider and may incur API charges. Send an image by itself to extract its text; add a question to continue with your conversation model. PDF and text attachments are read on this Mac. Images are never sent to another provider as an automatic fallback.",
                    zh: "在线识别会把缩放重编码后的图片发送给该服务并可能产生费用。PDF 和文本附件仍在本地提取，失败不会自动切换提供方。"
                ))
            }
        }
        .id(appLanguage)
        .onAppear {
            configuration = .load()
            keySaved = configuration.provider != .local && APIKeyStore.hasSavedKey(configuration.profile.account)
        }
        .onChange(of: configuration.provider) { _, selected in
            configuration = .load(provider: selected)
            key = ""; status = ""
            keySaved = selected != .local && APIKeyStore.hasSavedKey(configuration.profile.account)
        }
        .onChange(of: configuration.baseURL) { _, _ in
            key = ""; status = ""
            keySaved = configuration.provider != .local && APIKeyStore.hasSavedKey(configuration.profile.account)
        }
    }

    @discardableResult private func save() -> Bool {
        do {
            try configuration.validate()
            if configuration.provider != .local, !key.isEmpty {
                let entered = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !entered.isEmpty else {
                    throw ModelError.message(L10n.text("Enter a valid API key, or leave the field empty to reuse the saved key.",
                                                       zh: "请输入有效的 API Key，或留空以复用已保存的 Key。"))
                }
                try APIKeyStore.save(entered, account: configuration.profile.account)
                key = ""
                keySaved = true
            }
            try configuration.save()
            status = configuration.provider == .local
                ? L10n.text("Saved. Images will be read on this Mac.", zh: "已保存。图片将在本机使用 Apple Vision 识别。")
                : L10n.text("Saved. New image requests will use this provider and image model.", zh: "已保存。新图片识别将使用此在线模型。")
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    private func testConnection() {
        guard save() else { return }
        testing = true
        status = L10n.text("Sending a tiny test image…", zh: "正在发送微型测试图片…")
        let chosen = configuration
        Task {
            defer { testing = false }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("nous-vision-test-" + UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                try Self.writeTestImage(to: temp)
                let recognized = try await ImageRecognition.recognize(url: temp, configuration: chosen, cache: nil)
                status = L10n.text("Connected. Recognized: \"\(recognized.prefix(40))\"", zh: "连接成功，识别结果：“\(recognized.prefix(40))”")
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private static func writeTestImage(to url: URL) throws {
        guard let context = CGContext(data: nil, width: 160, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ModelError.message(L10n.text("Could not generate test image.", zh: "无法生成测试图片。"))
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 64))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 36, nil)
        let text = NSAttributedString(string: "OK", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 50, y: 18)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ModelError.message(L10n.text("Could not encode test image.", zh: "无法编码测试图片。"))
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ModelError.message(L10n.text("Could not write test image.", zh: "无法写入测试图片。"))
        }
    }
}
