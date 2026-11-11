import SwiftUI
import AppKit
import ImageIO
struct SentMessageView: View {
    let message: ChatMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(message.files, id: \.path) { file in
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) } label: {
                    VStack(alignment: .leading) {
                        if let image = AttachmentThumbnail.image(file.path) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 210, maxHeight: 140).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        Label(file.name, systemImage: "doc").font(.caption).lineLimit(1)
                    }
                }.buttonStyle(.plain)
            }
            if !message.text.isEmpty { Text(message.text).textSelection(.enabled) }
        }.font(.system(size: 14)).padding(12)
            .background(TelosTheme.bubble, in: RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .bottomTrailing) {
                Tail().fill(TelosTheme.bubble).frame(width: 10, height: 12).offset(x: 5, y: -1)
            }
    }
}
private struct Tail: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in p.move(to: .zero); p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: 0, y: r.maxY)); p.addQuadCurve(to: CGPoint(x: 0, y: r.maxY - 3), control: CGPoint(x: r.midX, y: r.maxY)); p.closeSubpath() }
    }
}
struct CopyableReply: View {
    let text: String
    var canCopy = true
    var markdown = true
    @State private var hovered = false
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageText(text: text, markdown: markdown).frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                copied = true
            } label: {
                CopyGlyph(copied: copied)
            }
            .buttonStyle(.plain).frame(width: 24, height: 24)
            .opacity(canCopy && (hovered || copied) ? 1 : 0)
            .allowsHitTesting(canCopy && (hovered || copied)).accessibilityHidden(!canCopy)
            .help(copied ? "Copied" : "Copy").accessibilityLabel("Copy response")
        }.onHover { hovered = $0 }
            .task(id: copied) {
                guard copied else { return }
                do { try await Task.sleep(nanoseconds: 1_500_000_000); copied = false } catch {}
            }
    }
}
struct CopyGlyph: View {
    let copied: Bool
    var body: some View {
        ZStack {
            Image(systemName: "square.on.square").opacity(copied ? 0 : 1)
            Image(systemName: "checkmark").opacity(copied ? 1 : 0)
        }.font(.system(size: 13)).foregroundStyle(.secondary)
            .frame(width: 24, height: 24).contentShape(Rectangle())
            .transaction { $0.animation = nil }
    }
}
struct MessageArrival: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    func body(content: Content) -> some View {
        content.opacity(appeared ? 1 : 0).offset(y: appeared || reduceMotion ? 0 : 6)
            .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { appeared = true } }
    }
}

@MainActor private enum AttachmentThumbnail {
    static let cache = NSCache<NSString, NSImage>()
    static func image(_ path: String) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 420, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let result = NSImage(cgImage: cg, size: .zero)
        cache.totalCostLimit = 16 * 1024 * 1024
        cache.setObject(result, forKey: path as NSString, cost: cg.bytesPerRow * cg.height)
        return result
    }
}
