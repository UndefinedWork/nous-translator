import CoreGraphics
import Foundation
@main struct SelectionTranslationTests {
    static func main() {
        func check(_ text: String, _ expectedTarget: TranslationLanguage,
                   source: TranslationLanguage? = nil, configuration: TranslationLanguageConfiguration = .default) {
            let direction = configuration.direction(for: text)
            precondition(direction.target == expectedTarget, "Wrong target for \(text): \(direction.label)")
            if let source { precondition(direction.source.language == source, "Wrong source for \(text): \(direction.label)") }
            precondition(TranslationTarget.detect(text, configuration: configuration) == expectedTarget, "Legacy helper uses the same configuration")
            let message = direction.messages(text: text)[0]["content"]!
            precondition(message.contains("翻译为" + expectedTarget.instructionName) && message.hasSuffix(text), "The actual model prompt uses the resolved target and untouched source")
        }
        check("划词之后，出现翻译的小 icon+文字入口", .english, source: .chinese)
        check("A small icon-plus-text entry point appears.", .chinese, source: .english)
        check("serendipity", .chinese)
        check("翻译", .english, source: .chinese)
        check("我们明天用 Figma 和 SwiftUI 讨论 liquid glass", .english, source: .chinese)
        check("The word 你好 means hello in Chinese, and it is used every day.", .chinese, source: .english)
        check("請將這份文件傳送給我的同事，謝謝您的幫助。", .english, source: .traditionalChinese)
        check("明日の午後三時に会議を始めます。", .chinese, source: .japanese)
        check("明日は Figma と SwiftUI のデザインを確認します。", .chinese, source: .japanese)
        check("내일 오후 세 시에 회의를 시작하겠습니다.", .chinese, source: .korean)
        check("내일 Figma 디자인과 API 문서를 함께 확인합니다.", .chinese, source: .korean)

        let englishFrench = TranslationLanguageConfiguration(languageA: .english, languageB: .french)
        check("Please send the updated document before Friday.", .french, source: .english, configuration: englishFrench)
        check("Veuillez envoyer le document mis à jour avant vendredi.", .english, source: .french, configuration: englishFrench)
        check("Bitte senden Sie das aktualisierte Dokument vor Freitag.", .english, source: .german, configuration: englishFrench)
        let arabic = englishFrench.direction(for: "يرجى إرسال المستند المحدّث إلى زملائنا قبل يوم الجمعة. تتضمن الرسالة العبارة الصينية 你好.")
        precondition(arabic.source.language == .arabic && arabic.target == .english && arabic.usedFallback, "A short Han quote must not override a longer third-language selection")
        let japaneseKorean = TranslationLanguageConfiguration(languageA: .japanese, languageB: .korean)
        check("明日の午後三時に会議を始めます。", .korean, source: .japanese, configuration: japaneseKorean)
        check("내일 오후 세 시에 회의를 시작하겠습니다.", .japanese, source: .korean, configuration: japaneseKorean)
        let chineseScripts = TranslationLanguageConfiguration(languageA: .chinese, languageB: .traditionalChinese)
        check("请将这份文件发送给我的同事，谢谢您的帮助。", .traditionalChinese, source: .chinese, configuration: chineseScripts)
        check("請將這份文件傳送給我的同事，謝謝您的幫助。", .chinese, source: .traditionalChinese, configuration: chineseScripts)
        let traditionalEnglish = TranslationLanguageConfiguration(languageA: .traditionalChinese, languageB: .english)
        check("请将文件发送给我的同事。", .english, source: .chinese, configuration: traditionalEnglish)
        check("Please send the document to my colleague.", .traditionalChinese, source: .english, configuration: traditionalEnglish)
        for text in ["", "12345 — 😀", "… !? 2026/11/12"] {
            let direction = englishFrench.direction(for: text)
            precondition(direction.source == .unknown && direction.target == .english && direction.usedFallback)
            precondition(direction.label == "Unknown language → English", "Unknown text must not be labeled as the other configured language")
        }
        let third = englishFrench.direction(source: .init(code: "el"))
        precondition(third.target == .english && third.usedFallback && third.source.name == "Greek", "Third languages retain their true label and fall back to A")
        for mode in [TranslationDirectionMode.aToB, .bToA] {
            let fixed = TranslationLanguageConfiguration(languageA: .japanese, languageB: .french, mode: mode)
            let target: TranslationLanguage = mode == .aToB ? .french : .japanese
            for source in [DetectedTranslationLanguage(.english), .init(.japanese), .init(.french), .unknown] {
                let direction = fixed.direction(source: source)
                precondition(direction.target == target && direction.source == source && !direction.usedFallback, "Fixed directions change only the target, not the actual source label")
            }
        }
        let suite = "nous-language-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("custom", forKey: "translationProvider")
        defaults.set("/unchanged/model.gguf", forKey: "modelPath")
        precondition(TranslationLanguageConfiguration.load(defaults: defaults) == .default, "Old installations migrate to Chinese/English")
        precondition(defaults.data(forKey: TranslationLanguageConfiguration.storageKey) != nil, "Migration persists the pair")
        var saved = TranslationLanguageConfiguration(languageA: .german, languageB: .spanish, mode: .bToA)
        saved.save(defaults: defaults)
        precondition(TranslationLanguageConfiguration.load(defaults: defaults) == saved)
        saved.setLanguageA(.spanish)
        precondition(saved.languageA == .spanish && saved.languageB == .german, "Choosing the other language swaps instead of creating duplicates")
        saved.setLanguageB(.spanish)
        precondition(saved.languageA == .german && saved.languageB == .spanish)
        saved.swap()
        precondition(saved.languageA == .spanish && saved.languageB == .german && saved.mode == .bToA)
        let duplicate = Data(#"{"languageA":"ja","languageB":"ja","mode":"automatic"}"#.utf8)
        defaults.set(duplicate, forKey: TranslationLanguageConfiguration.storageKey)
        let normalized = TranslationLanguageConfiguration.load(defaults: defaults)
        precondition(normalized.languageA == .japanese && normalized.languageB != .japanese, "Duplicate saved languages are repaired")
        defaults.set(Data("broken".utf8), forKey: TranslationLanguageConfiguration.storageKey)
        precondition(TranslationLanguageConfiguration.load(defaults: defaults) == .default)
        precondition(defaults.string(forKey: "translationProvider") == "custom" && defaults.string(forKey: "modelPath") == "/unchanged/model.gguf", "Language migration never changes model preferences")

        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        // Accessibility rect (top-left origin) is flipped and kept when the gesture ended inside it.
        let ax = CGRect(x: 100, y: 200, width: 300, height: 40)
        let rect = SelectionTranslationLayout.selectionRect(accessibility: ax, primaryHeight: 900, down: CGPoint(x: 110, y: 690), up: CGPoint(x: 390, y: 670))!
        precondition(rect == CGRect(x: 100, y: 660, width: 300, height: 40))
        // Bounds away from the pointer belong to an older selection (e.g. a window was dragged).
        precondition(SelectionTranslationLayout.selectionRect(accessibility: CGRect(x: 900, y: 0, width: 10, height: 10), primaryHeight: 900, down: CGPoint(x: 100, y: 500), up: CGPoint(x: 300, y: 500)) == nil)
        // Multi-line: the app reports only the first line; the drag ends lines below but started on it.
        let firstLine = CGRect(x: 100, y: 200, width: 500, height: 20)
        precondition(SelectionTranslationLayout.selectionRect(accessibility: firstLine, primaryHeight: 900, down: CGPoint(x: 110, y: 690), up: CGPoint(x: 400, y: 560)) != nil)
        // Apps without bounds fall back to the gesture.
        let fallback = SelectionTranslationLayout.selectionRect(accessibility: nil, primaryHeight: 900, down: CGPoint(x: 100, y: 500), up: CGPoint(x: 300, y: 500))!
        precondition(fallback.midX == 200 && fallback.maxY > 500)

        let button = SelectionTranslationLayout.buttonOrigin(selection: rect, visible: visible)
        precondition(button.x + SelectionTranslationLayout.buttonSize.width / 2 == rect.midX, "Button is centered on the selection")
        precondition(button.y == rect.maxY + 6, "Button sits just above the selection")
        let top = SelectionTranslationLayout.buttonOrigin(selection: CGRect(x: 10, y: 850, width: 50, height: 20), visible: visible)
        precondition(top.y + SelectionTranslationLayout.buttonSize.height <= 850 && top.x >= 4, "Button flips below and stays on screen")

        let below = SelectionTranslationLayout.panelOrigin(selection: rect, visible: visible)
        precondition(below.y + SelectionTranslationLayout.panelSize.height <= rect.minY, "Panel opens below the selection")
        let above = SelectionTranslationLayout.panelOrigin(selection: CGRect(x: 600, y: 100, width: 100, height: 20), visible: visible)
        precondition(above.y >= 120, "Panel opens above a selection near the bottom")

        let prompt = SelectionTranslationContext.prompt(source: "你好", translation: "Hello", target: .english, request: "更正式一点")
        precondition(prompt.contains("你好") && prompt.contains("Hello") && prompt.hasSuffix("更正式一点"))
        let frenchContext = SelectionTranslationContext.prompt(source: "Hello", translation: "Bonjour", target: .french, request: "Explain")
        precondition(frenchContext.contains("translated it into French"), "Follow-up context uses the actual target language")
        precondition(TranslationLanguage.traditionalChinese.systemPrompt.contains("Chinese (Traditional)"))
        precondition(TranslationTarget.userMessage("你好", app: "Zoom") == "<text app=\"Zoom\">你好</text>")
        precondition(TranslationTarget.userMessage("hi", app: "A \"<b>\"") == "<text app=\"A b\">hi</text>", "App names cannot break the wrapper")
        precondition(TranslationTarget.cleanOutput("<text app=\"Zoom\">Hello</text>", final: true) == "Hello", "An echoed wrapper is removed")
        precondition(TranslationTarget.cleanOutput("\nHello there", final: true) == "Hello there")
        precondition(TranslationTarget.cleanOutput("<tex") == "", "A partial opening tag never shows while streaming")
        precondition(TranslationTarget.cleanOutput("<text app=\"Zoom\">Hello</te") == "Hello", "A partial closing tag is held back")
        precondition(TranslationTarget.cleanOutput("Use a < b", final: true) == "Use a < b", "Ordinary text is untouched")
        print("PASS: configurable language pairs, CJK/mixed/Latin detection, unknown/third-language fallback, fixed directions, persistence/migration, prompts, selection layout and follow-up context")
    }
}
