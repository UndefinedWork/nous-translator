import AppKit
import SwiftUI

/// Dynamic light/dark shades resolved from the hosting window's appearance.
enum TelosTheme {
    static func native(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light, alpha: 1)
        }
    }
    static func shade(_ light: CGFloat, _ dark: CGFloat) -> Color { Color(nsColor: native(light, dark)) }
    static func translucent(_ light: CGFloat, _ dark: CGFloat, lightAlpha: CGFloat, darkAlpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
    static let bubble = translucent(0, 1, lightAlpha: 0.055, darkAlpha: 0.10)
}
