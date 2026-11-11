import Foundation
import CoreGraphics

/// Values only: Accessibility objects stay on the reader's actor.
struct SelectionSnapshot {
    var text = ""
    var bounds: CGRect?
    var secure = false
    var textUnderPointer = false
    var waitingForAccessibility = false
}

struct CapturedSelection {
    let text: String
    let rect: CGRect
}

/// Restore an observed Copy result independently of whether the selection is still wanted.
/// A later pasteboard change is never adopted as ours, even if the gesture still exists.
@MainActor enum SelectionClipboardTransaction {
    static func finishCopy(initialChangeCount: Int, isCurrent: () -> Bool,
        changeCount: () -> Int, readText: () -> String?, restore: () -> Void,
        sleep: () async -> Void = {
            // Draining a cancelled copy must still yield instead of spinning on cancelled sleeps.
            await Task.detached { try? await Task.sleep(nanoseconds: 20_000_000) }.value
        }
    ) async -> String? {
        var ownedChangeCount: Int?
        for attempt in 0..<41 {
            let count = changeCount()
            if count != initialChangeCount {
                // A change first seen after cancellation could be the user's newer Copy.
                // Pasteboard has no writer identity, so leave that ambiguous value untouched.
                guard !Task.isCancelled, isCurrent() else { return nil }
                ownedChangeCount = count
                break
            }
            if attempt < 40 { await sleep() }
        }
        guard let ownedChangeCount else { return nil }
        var stable = 0
        for _ in 0..<20 {
            await sleep()
            guard changeCount() == ownedChangeCount else { return nil }
            stable += 1
            if stable >= 3, readText() != nil { break }
        }
        guard changeCount() == ownedChangeCount else { return nil }
        let text = readText()
        guard changeCount() == ownedChangeCount else { return nil }
        let canUseSelection = !Task.isCancelled && isCurrent()
        // No await between the last version check and restoring the original representations.
        // Cancellation can discard the result without leaving our known Copy on the clipboard.
        restore()
        return canUseSelection ? text : nil
    }
}

/// One mouse gesture owns one read. Retrying never authorizes a copy after the user moves on.
@MainActor enum SelectionCapturePipeline {
    static func capture(
        down: CGPoint, up: CGPoint, primaryHeight: CGFloat, pointerWasText: Bool,
        delays: [UInt64] = [60_000_000, 90_000_000, 150_000_000, 200_000_000, 250_000_000],
        isCurrent: () -> Bool,
        read: () async -> SelectionSnapshot,
        copy: () async -> String?,
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async -> CapturedSelection? {
        var last = SelectionSnapshot()
        var waits = delays, index = 0, extendedWarmup = false
        while index < waits.count {
            let delay = waits[index]; index += 1
            do { try await sleep(delay) } catch { return nil }
            guard !Task.isCancelled, isCurrent() else { return nil }
            last = await read()
            guard !Task.isCancelled, isCurrent(), !last.secure else { return nil }
            let text = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                guard text.count <= 8000 else { return nil }
                // Real AX text + hit-tested text is enough; a custom cursor is not a veto.
                if last.bounds != nil || last.textUnderPointer || pointerWasText,
                   let rect = SelectionTranslationLayout.selectionRect(accessibility: last.bounds,
                        primaryHeight: primaryHeight, down: down, up: up) {
                    return CapturedSelection(text: text, rect: rect)
                }
            }
            // Chromium debounces AXEnhancedUserInterface for two seconds on first use.
            // Only a newly enabled browser gets this extra grace period; normal reads stay fast.
            if index == waits.count, last.waitingForAccessibility, !extendedWarmup {
                waits += [350_000_000, 500_000_000, 600_000_000]
                extendedWarmup = true
            }
        }
        // A zero-length caret rect is not a selected range. It must not suppress Copy fallback.
        guard !Task.isCancelled, isCurrent(), !last.secure,
              last.textUnderPointer || pointerWasText,
              let copied = await copy(), !Task.isCancelled, isCurrent() else { return nil }
        let text = copied.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 8000,
              let rect = SelectionTranslationLayout.selectionRect(accessibility: nil,
                primaryHeight: primaryHeight, down: down, up: up) else { return nil }
        return CapturedSelection(text: text, rect: rect)
    }
}

enum SelectionGestureRules {
    static func isWithinTextContent(accessibilityFrame frame: CGRect, primaryHeight: CGFloat, down: CGPoint, up: CGPoint) -> Bool {
        guard frame.width > 0, frame.height > 0,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }) else { return false }
        let content = CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        return content.contains(down) || content.contains(up)
    }

    static func shouldRead(down: CGPoint, up: CGPoint, clickCount: Int, shift: Bool) -> Bool {
        // Small selections (one narrow glyph) can be less than the old five-point threshold.
        hypot(up.x - down.x, up.y - down.y) >= 2 || clickCount >= 2 || shift
    }
}
