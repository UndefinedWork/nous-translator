import AppKit
import ApplicationServices

enum SelectionCopyCommand {
    case enabled(AXUIElement), disabled, unavailable
}

/// Cross-process AX requests can block. Keep them off the UI/event-monitor thread and bound traversal.
actor SelectionAccessibilityReader {
    static let shared = SelectionAccessibilityReader()
    private var manualAccessibility = Set<pid_t>()
    private var warmupUntil: [pid_t: TimeInterval] = [:]
    private var retryActivationAfter: [pid_t: TimeInterval] = [:]

    func prepare(pid: pid_t) { _ = application(pid) }

    private func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        // Reading AXRole wakes Chromium's native AX support. Electron also supports
        // AXManualAccessibility, but Nous Browser/Chromium does not expose that attribute.
        _ = attribute(app, kAXRoleAttribute)
        let now = ProcessInfo.processInfo.systemUptime
        if !manualAccessibility.contains(pid), now >= retryActivationAfter[pid, default: 0] {
            if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
                manualAccessibility.insert(pid)
            } else {
                var settable = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(app, "AXEnhancedUserInterface" as CFString, &settable) == .success, settable.boolValue {
                    if attribute(app, "AXEnhancedUserInterface") as? Bool != true {
                        // BrowserCrApplication forwards to AppKit after handling this request,
                        // so the result can be actionUnsupported even though activation succeeded.
                        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                    }
                    // Do not re-send on every retry: Chromium restarts its two-second timer.
                    manualAccessibility.insert(pid)
                    warmupUntil[pid] = now + 2.2
                } else {
                    retryActivationAfter[pid] = now + 5
                }
            }
        }
        return app
    }

    func selection(pid: pid_t, down: CGPoint, up: CGPoint, primaryHeight: CGFloat) -> SelectionSnapshot {
        let app = application(pid)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        let focused = element(attribute(app, kAXFocusedUIElementAttribute))
        if let focused, isSecure(focused) { return SelectionSnapshot(secure: true) }
        var candidates: [AXUIElement] = []
        // A drag can begin/end in the whitespace beside a line. Chromium may return its
        // embedding group from hit-testing even though the focused web area has real selected
        // text. Its content frame establishes that this gesture happened in the page, not chrome.
        var textUnderPointer = focused.map {
            containsTextGesture($0, primaryHeight: primaryHeight, down: down, up: up)
        } ?? false
        let warming = ProcessInfo.processInfo.systemUptime < warmupUntil[pid, default: 0]
        // Prefer a geometrically verified focused selection before walking a potentially large
        // browser tree. Otherwise traversal can consume the deadline before we read known text.
        if let focused, let selected = selectedSnapshot(focused, textUnderPointer: textUnderPointer, warming: warming),
           selected.bounds != nil || textUnderPointer,
           SelectionTranslationLayout.selectionRect(accessibility: selected.bounds, primaryHeight: primaryHeight, down: down, up: up) != nil {
            return selected
        }
        // In Chromium the focused element can be a container or browser chrome. Look where the
        // gesture occurred, then walk to the text/web area owning that selection.
        for point in [up, down] {
            var hit: AXUIElement?
            AXUIElementCopyElementAtPosition(app, Float(point.x), Float(primaryHeight - point.y), &hit)
            var current = hit
            for _ in 0..<8 {
                guard let node = current, ProcessInfo.processInfo.systemUptime < deadline else { break }
                if isSecure(node) { return SelectionSnapshot(secure: true) }
                if candidates.contains(where: { CFEqual($0, node) }) { break }
                let role = attribute(node, kAXRoleAttribute) as? String ?? ""
                if ["AXTextField", "AXTextArea", "AXStaticText", "AXWebArea"].contains(role) {
                    textUnderPointer = true
                }
                if ["AXWindow", "AXApplication", "AXToolbar", "AXMenuBar"].contains(role) { break }
                candidates.append(node)
                current = element(attribute(node, kAXParentAttribute))
            }
        }
        if let focused, !candidates.contains(where: { CFEqual($0, focused) }) { candidates.append(focused) }
        var fallback = SelectionSnapshot(textUnderPointer: textUnderPointer, waitingForAccessibility: warming)
        for node in candidates {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            if isSecure(node) { return SelectionSnapshot(secure: true) }
            guard let snapshot = selectedSnapshot(node, textUnderPointer: textUnderPointer, warming: warming) else { continue }
            if let bounds = snapshot.bounds {
                if SelectionTranslationLayout.selectionRect(accessibility: bounds, primaryHeight: primaryHeight, down: down, up: up) != nil {
                    return snapshot
                }
                // Ignore an old selected range in a different part of the window.
            } else if fallback.text.isEmpty {
                fallback = snapshot
            }
        }
        return fallback
    }

    private func selectedSnapshot(_ node: AXUIElement, textUnderPointer: Bool, warming: Bool) -> SelectionSnapshot? {
        var text = attribute(node, kAXSelectedTextAttribute) as? String ?? ""
        let range = attribute(node, kAXSelectedTextRangeAttribute)
        var selectedRange = CFRange(location: 0, length: 0)
        if let range, CFGetTypeID(range) == AXValueGetTypeID(), AXValueGetType(range as! AXValue) == .cfRange {
            AXValueGetValue(range as! AXValue, .cfRange, &selectedRange)
        }
        // Browser selections spanning DOM nodes, including backward ranges, also expose text
        // markers. They can provide both text and bounds when the ordinary range cannot.
        let markerRange = attribute(node, "AXSelectedTextMarkerRange")
        if text.isEmpty, let markerRange {
            text = parameter(node, "AXStringForTextMarkerRange", markerRange) as? String ?? ""
        }
        if text.isEmpty, selectedRange.length > 0, selectedRange.length <= 8000, let range {
            text = parameter(node, kAXStringForRangeParameterizedAttribute, range) as? String ?? ""
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var bounds: CGRect?
        if let markerRange { bounds = rectangle(parameter(node, "AXBoundsForTextMarkerRange", markerRange)) }
        if bounds == nil, selectedRange.length > 0, let range {
            bounds = rectangle(parameter(node, kAXBoundsForRangeParameterizedAttribute, range))
        }
        return SelectionSnapshot(text: text, bounds: bounds, textUnderPointer: textUnderPointer, waitingForAccessibility: warming)
    }

    private func rectangle(_ raw: CFTypeRef?) -> CGRect? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID(), AXValueGetType(raw as! AXValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(raw as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0,
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }) else { return nil }
        return rect
    }

    func copyCommand(pid: pid_t) -> SelectionCopyCommand {
        let app = application(pid)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        guard let bar = element(attribute(app, kAXMenuBarAttribute)),
              let menus = attribute(bar, kAXChildrenAttribute) as? [AXUIElement] else { return .unavailable }
        for menu in menus.dropFirst() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return .unavailable }
            for submenu in attribute(menu, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                for item in attribute(submenu, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { return .unavailable }
                    guard (attribute(item, kAXMenuItemCmdCharAttribute) as? String)?.lowercased() == "c",
                          (attribute(item, kAXMenuItemCmdModifiersAttribute) as? Int) == 0 else { continue }
                    return attribute(item, kAXEnabledAttribute) as? Bool == false ? .disabled : .enabled(item)
                }
            }
        }
        return .unavailable
    }

    private func isSecure(_ node: AXUIElement) -> Bool {
        attribute(node, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
    }
    private func containsTextGesture(_ node: AXUIElement, primaryHeight: CGFloat, down: CGPoint, up: CGPoint) -> Bool {
        guard let role = attribute(node, kAXRoleAttribute) as? String,
              ["AXWebArea", "AXTextArea", "AXTextField", "AXStaticText"].contains(role),
              let position = attribute(node, kAXPositionAttribute), let size = attribute(node, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetType(position as! AXValue) == .cgPoint, AXValueGetType(size as! AXValue) == .cgSize else { return false }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return false }
        return SelectionGestureRules.isWithinTextContent(accessibilityFrame: CGRect(origin: point, size: dimensions),
            primaryHeight: primaryHeight, down: down, up: up)
    }
    private func element(_ raw: CFTypeRef?) -> AXUIElement? {
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }
    private func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(node, 0.12)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func parameter(_ node: AXUIElement, _ name: String, _ argument: CFTypeRef) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(node, 0.12)
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(node, name as CFString, argument, &value) == .success else { return nil }
        return value
    }
}
