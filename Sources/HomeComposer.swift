import SwiftUI
import AppKit

struct MessageBubble: View {
    var text: String
    var body: some View {
        MessageText(text: text, markdown: false).font(.system(size: 13.5)).tracking(-0.135).lineSpacing(1)
            .foregroundStyle(TelosTheme.shade(0.15, 0.88)).multilineTextAlignment(.leading)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(TelosTheme.bubble, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
struct RectPreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { _, new in new } }
}
extension View {
    func trackRect(_ key: String, in space: String, when tracked: Bool = true) -> some View {
        background {
            if tracked {
                GeometryReader { geo in Color.clear.preference(key: RectPreference.self, value: [key: geo.frame(in: .named(space))]) }
            }
        }
    }
}
struct TaskComposer: View {
    @ObservedObject var draft: ComposerDraft
    @Environment(\.colorScheme) private var colorScheme
    var canSend = true
    var action: () -> Void
    private var expanded: Bool { !draft.files.isEmpty || draft.compactLayoutHeight > 22 }
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: draft.chooseFiles) {
                Image(systemName: "plus").font(.system(size: 14, weight: .medium)).frame(width: 40, height: 40)
            }.buttonStyle(HoverButtonStyle()).modifier(GlassSurface(shape: Circle(), interactive: true)).help("Attach files")
            HStack(alignment: .bottom, spacing: 4) {
                AttachmentInput(draft: draft, placeholder: "Message", identifier: "translationAskField") { if canSend { action() } }
                Button(action: action) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)).frame(width: 24, height: 20)
                }.buttonStyle(.plain).disabled(!canSend || draft.isComposing)
                    .opacity(draft.hasContent ? 1 : 0).allowsHitTesting(draft.hasContent).accessibilityLabel("Send")
            }.padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 10)
                .background(ComposerHitArea(draft: draft))
                .modifier(PicoControlGlass(shape: RoundedRectangle(cornerRadius: 20)))
        }
    }
    private func updateCompactWidth(_ width: CGFloat) {
        let available = max(1, width - 44 - 48)
        if abs(draft.compactWidth - available) > 0.5 { draft.compactWidth = available }
    }
}


enum ComposerSizing {
    static func editorHeight(contentHeight: CGFloat, lineHeight: CGFloat, inset: CGFloat) -> CGFloat {
        // The empty field and its first typed line occupy the same 20pt slot.
        if contentHeight <= ceil(lineHeight) + 1 { return 20 }
        return min(144, max(20, ceil(contentHeight + inset * 2)))
    }
}

struct PicoControlGlass<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false
    func body(content: Content) -> some View {
        content.background {
            Color.clear.modifier(GlassSurface(shape: shape, interactive: interactive))
        }
    }
}
