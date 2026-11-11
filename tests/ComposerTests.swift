import AppKit
import SwiftUI

@main struct ComposerTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let font = NSFont.systemFont(ofSize: 14)
        func measured(_ text: String, width: CGFloat = 250) -> CGFloat {
            let storage = NSTextStorage(string: text, attributes: [.font: font])
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: width, height: 10000))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container); storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)
            let h = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
            return ComposerSizing.editorHeight(contentHeight: h, lineHeight: layout.defaultLineHeight(for: font), inset: 1)
        }
        for text in ["", "a", "Hello", "你", "你好", "你好 hello", "hello "] {
            precondition(measured(text) == 20, "Single-line height changed: \(text), \(measured(text))")
        }
        precondition(measured("Hello\nWorld") > 20)
        precondition(measured(String(repeating: "long text ", count: 300)) == 144)
        let draft = ComposerDraft()
        draft.setText("Hello"); precondition(draft.compactLayoutHeight <= 22)
        draft.setText(String(repeating: "Many words ", count: 30)); precondition(draft.compactLayoutHeight > 22)
        draft.editorHeight = 144; draft.clear()
        precondition(draft.editorHeight == 20 && !draft.hasContent)
        print("PASS: empty/Latin/CJK/mixed first-line stability, multiline growth, 144pt cap, compact expansion and reset")
    }
}
