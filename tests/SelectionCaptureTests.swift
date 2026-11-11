import Foundation
import CoreGraphics

@main struct SelectionCaptureTests {
    @MainActor static func main() async {
        // Event timelines exercise restoration separately from stale-result suppression.
        // All pasteboard operations are injected: these tests do not touch system permissions
        // or the user's clipboard.
        for scenario in ["normal", "cancel-after-copy", "new-user-copy", "background-write", "cancel-before-copy"] {
            var version = 10, tick = 0, restored = false, current = true
            var clipboard = "original clipboard"
            let result = await SelectionClipboardTransaction.finishCopy(initialChangeCount: 10,
                isCurrent: { current }, changeCount: { version }, readText: { clipboard },
                restore: { restored = true; version += 1; clipboard = "original clipboard" },
                sleep: {
                    tick += 1
                    if tick == 1 {
                        version = 11; clipboard = "synthetic selection"
                        if scenario == "cancel-before-copy" { current = false }
                    }
                    if tick == 2 {
                        if scenario == "cancel-after-copy" { current = false }
                        if scenario == "new-user-copy" { current = false; version = 12; clipboard = "new user copy" }
                        if scenario == "background-write" { version = 12; clipboard = "new external value" }
                    }
                })
            switch scenario {
            case "normal":
                precondition(restored && clipboard == "original clipboard" && result == "synthetic selection")
            case "cancel-after-copy":
                precondition(restored && clipboard == "original clipboard" && result == nil,
                             "Cancelling after our Copy is observed restores the original clipboard, but never returns stale text")
            case "new-user-copy":
                precondition(!restored && clipboard == "new user copy" && result == nil,
                             "A newer real Copy must survive cancellation of our selection read")
            case "background-write":
                precondition(!restored && clipboard == "new external value" && result == nil,
                             "A second clipboard write is not adopted as ours merely because the gesture is current")
            default:
                precondition(!restored && result == nil,
                             "A clipboard change first observed after cancellation has unknown ownership and is left untouched")
            }
        }
        let cancelledCopy = Task { @MainActor in
            var version = 20, tick = 0, restored = false
            let result = await SelectionClipboardTransaction.finishCopy(initialChangeCount: 20,
                isCurrent: { true }, changeCount: { version }, readText: { "copied" },
                restore: { restored = true; version += 1 }, sleep: {
                    tick += 1
                    if tick == 1 { version = 21 }
                    if tick == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                })
            return restored && result == nil
        }
        let cancelledCopyRestored = await cancelledCopy.value
        precondition(cancelledCopyRestored, "Task cancellation still restores a previously owned Copy result")

        let down = CGPoint(x: 100, y: 500), up = CGPoint(x: 300, y: 500)
        var reads = 0, copies = 0
        let delayed = await SelectionCapturePipeline.capture(down: down, up: up, primaryHeight: 900,
            pointerWasText: false, delays: [0, 0, 0, 0], isCurrent: { true },
            read: {
                reads += 1
                return SelectionSnapshot(text: reads >= 3 ? "Browser selection" : "", textUnderPointer: true)
            }, copy: { copies += 1; return "wrong" })
        precondition(delayed?.text == "Browser selection" && reads == 3 && copies == 0,
                     "Delayed Chromium selection is retried; custom cursor + missing bounds must not veto real text")

        reads = 0
        var waits: [UInt64] = []
        let coldBrowser = await SelectionCapturePipeline.capture(down: down, up: up, primaryHeight: 900,
            pointerWasText: false, delays: [0, 0], isCurrent: { true },
            read: {
                reads += 1
                return SelectionSnapshot(text: reads == 5 ? "Newly enabled browser" : "", textUnderPointer: true, waitingForAccessibility: true)
            }, copy: { copies += 1; return "wrong" }, sleep: { waits.append($0) })
        precondition(coldBrowser?.text == "Newly enabled browser" && reads == 5 && copies == 0,
                     "First-use Chromium AX initialization receives its bounded two-second grace period")
        precondition(waits.suffix(3) == [350_000_000, 500_000_000, 600_000_000])

        reads = 0; copies = 0
        let caret = await SelectionCapturePipeline.capture(down: down, up: up, primaryHeight: 900,
            pointerWasText: false, delays: [0, 0], isCurrent: { true },
            read: { reads += 1; return SelectionSnapshot(bounds: CGRect(x: 100, y: 400, width: 0, height: 18), textUnderPointer: true) },
            copy: { copies += 1; return " copied browser text \n" })
        precondition(caret?.text == "copied browser text" && reads == 2 && copies == 1,
                     "An empty caret range cannot suppress Copy fallback, which runs once after retries")

        copies = 0
        let secure = await SelectionCapturePipeline.capture(down: down, up: up, primaryHeight: 900,
            pointerWasText: true, delays: [0], isCurrent: { true },
            read: { SelectionSnapshot(secure: true, textUnderPointer: true) },
            copy: { copies += 1; return "password" })
        precondition(secure == nil && copies == 0, "Secure fields are never copied")

        let chrome = await SelectionCapturePipeline.capture(down: down, up: up, primaryHeight: 900,
            pointerWasText: false, delays: [0], isCurrent: { true },
            read: { SelectionSnapshot() }, copy: { copies += 1; return "old selection" })
        precondition(chrome == nil && copies == 0, "Dragging browser chrome cannot copy an unrelated selection")

        let oldBounds = await SelectionCapturePipeline.capture(down: down, up: up, primaryHeight: 900,
            pointerWasText: false, delays: [0], isCurrent: { true },
            read: { SelectionSnapshot(text: "stale", bounds: CGRect(x: 900, y: 0, width: 20, height: 20)) },
            copy: { copies += 1; return "stale" })
        precondition(oldBounds == nil && copies == 0, "An unrelated AX selection never gets a capsule")

        var current = true
        reads = 0
        let interruptedWait = await SelectionCapturePipeline.capture(down: down, up: up, primaryHeight: 900,
            pointerWasText: true, delays: [0], isCurrent: { current },
            read: { reads += 1; return SelectionSnapshot(text: "old") }, copy: { copies += 1; return "old" },
            sleep: { _ in current = false })
        precondition(interruptedWait == nil && reads == 0 && copies == 0,
                     "Mouse-down, keypress, app switch and scroll invalidate a pending read before AX work")

        current = true
        let interruptedRead = await SelectionCapturePipeline.capture(down: down, up: up, primaryHeight: 900,
            pointerWasText: true, delays: [0], isCurrent: { current },
            read: { current = false; return SelectionSnapshot(text: "old") }, copy: { copies += 1; return "old" })
        precondition(interruptedRead == nil && copies == 0, "A late AX reply cannot display or start Copy")

        current = true
        let interruptedCopy = await SelectionCapturePipeline.capture(down: down, up: up, primaryHeight: 900,
            pointerWasText: true, delays: [0], isCurrent: { current },
            read: { SelectionSnapshot() }, copy: { current = false; return "old" })
        precondition(interruptedCopy == nil, "A late clipboard result cannot show the previous gesture")

        reads = 0
        let cancelled = await SelectionCapturePipeline.capture(down: down, up: up, primaryHeight: 900,
            pointerWasText: true, delays: [0], isCurrent: { true },
            read: { reads += 1; return SelectionSnapshot(text: "old") }, copy: { copies += 1; return "old" },
            sleep: { _ in throw CancellationError() })
        precondition(cancelled == nil && reads == 0 && copies == 0, "Cancelled sleeps terminate the read")

        let oversized = await SelectionCapturePipeline.capture(down: down, up: up, primaryHeight: 900,
            pointerWasText: true, delays: [0], isCurrent: { true },
            read: { SelectionSnapshot(text: String(repeating: "字", count: 8001)) }, copy: { copies += 1; return "wrong" })
        precondition(oversized == nil && copies == 0, "Over-limit selections retain the existing bound")

        precondition(SelectionGestureRules.shouldRead(down: down, up: CGPoint(x: 103, y: 500), clickCount: 1, shift: false), "Narrow glyph selection")
        precondition(SelectionGestureRules.shouldRead(down: down, up: down, clickCount: 2, shift: false), "Double click")
        precondition(SelectionGestureRules.shouldRead(down: down, up: down, clickCount: 1, shift: true), "Shift-click extends selection")
        precondition(!SelectionGestureRules.shouldRead(down: down, up: down, clickCount: 1, shift: false), "Ordinary clicks do not capture")
        let page = CGRect(x: 80, y: 100, width: 600, height: 600)
        precondition(SelectionGestureRules.isWithinTextContent(accessibilityFrame: page, primaryHeight: 900, down: down, up: up),
                     "Whitespace beside a line is still inside the focused page, even when hit-testing returns an embedding group")
        precondition(!SelectionGestureRules.isWithinTextContent(accessibilityFrame: page, primaryHeight: 900,
            down: CGPoint(x: 100, y: 850), up: CGPoint(x: 300, y: 850)), "Dragging browser chrome is outside the focused page")
        print("PASS: clipboard cancellation/restoration and newer-write races; delayed browser selection, custom cursors, caret fallback, secure fields, stale ranges, cancellation, narrow selections and shift-click")
    }
}
