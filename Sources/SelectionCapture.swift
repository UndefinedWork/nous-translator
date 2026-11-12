#if !NOUS_APP_STORE
import AppKit
import ApplicationServices

/// Reads the text a gesture selected in another app.
/// Accessibility first; Chromium/Electron and web views that expose nothing fall back to a
/// generated ⌘C, restoring the previous pasteboard only while its Copy result remains identifiable.
@MainActor enum SelectionCapture {
    private static let iBeam = NSCursor.iBeam.image.tiffRepresentation
    private static let verticalIBeam = NSCursor.iBeamCursorForVerticalLayout.image.tiffRepresentation
    private static var copying = false

    static var pointerIsIBeam: Bool {
        guard let current = NSCursor.currentSystem?.image.tiffRepresentation else { return false }
        return current == iBeam || current == verticalIBeam
    }

    /// Copy is serialized so rapid selections cannot restore one another's pasteboard snapshots.
    /// A cancelled read drains the pending copy, but never consumes or overwrites a newer user action.
    static func copySelection(pid: pid_t, isCurrent: () -> Bool) async -> String? {
        // A previous cancelled gesture may still be draining an asynchronous browser Copy.
        // Wait for it rather than making the next valid selection fail intermittently.
        for _ in 0..<65 where copying {
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return nil }
            guard isCurrent() else { return nil }
        }
        guard !copying, !Task.isCancelled, isCurrent() else { return nil }
        copying = true
        defer { copying = false }
        let command = await SelectionAccessibilityReader.shared.copyCommand(pid: pid)
        guard !Task.isCancelled, isCurrent(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        if case .disabled = command { return nil }
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        guard pasteboard.changeCount == before, isCurrent() else { return nil }
        let pressedMenu: Bool
        if case let .enabled(menu) = command {
            pressedMenu = AXUIElementPerformAction(menu, kAXPressAction as CFString) == .success
        } else { pressedMenu = false }
        if !pressedMenu {
            guard CGPreflightPostEventAccess(), isCurrent(),
                  let source = CGEventSource(stateID: .combinedSessionState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else { return nil }
            down.flags = .maskCommand; up.flags = .maskCommand
            TelosKeyboardEvent.markSynthetic(down); TelosKeyboardEvent.markSynthetic(up)
            down.postToPid(pid); up.postToPid(pid)
        }
        return await SelectionClipboardTransaction.finishCopy(initialChangeCount: before,
            isCurrent: isCurrent, changeCount: { pasteboard.changeCount },
            readText: { pasteboard.string(forType: .string) }, restore: {
                pasteboard.clearContents()
                let items = saved.map { entries in
                    let item = NSPasteboardItem()
                    for (type, data) in entries { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { pasteboard.writeObjects(items) }
            })
    }

}
#endif
