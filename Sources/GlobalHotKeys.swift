import AppKit
import Carbon.HIToolbox
import SwiftUI

enum GlobalHotKeyAction: String, CaseIterable, Codable, Identifiable {
    case translateClipboard
    case quickTranslate
    case captureScreenOCR

    var id: String { rawValue }

    var hotKeyID: UInt32 {
        switch self {
        case .translateClipboard: return 1
        case .quickTranslate: return 2
        case .captureScreenOCR: return 3
        }
    }

    var title: String {
        switch self {
        case .translateClipboard: return L10n.text("Translate Clipboard", zh: "翻译剪贴板")
        case .quickTranslate: return L10n.text("Quick Translate Input", zh: "快捷输入翻译")
        case .captureScreenOCR: return L10n.text("Translate Screen Region (OCR)", zh: "截图识别并翻译")
        }
    }

    var defaultBinding: HotKeyBinding {
        let mods = UInt32(controlKey | optionKey)
        switch self {
        case .translateClipboard: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_T), modifiers: mods, enabled: true)
        case .quickTranslate: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_N), modifiers: mods, enabled: true)
        case .captureScreenOCR: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: mods, enabled: true)
        }
    }
}

struct HotKeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var enabled: Bool

    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += Self.keyLabel(for: keyCode)
        return result
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static func hasPrimaryModifier(_ carbonModifiers: UInt32) -> Bool {
        (carbonModifiers & UInt32(cmdKey | optionKey | controlKey)) != 0
    }

    static func keyLabel(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"; case kVK_ANSI_B: return "B"; case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"; case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"; case kVK_ANSI_H: return "H"; case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"; case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"; case kVK_ANSI_N: return "N"; case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"; case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"; case kVK_ANSI_T: return "T"; case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"; case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"; case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"; case kVK_ANSI_1: return "1"; case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"; case kVK_ANSI_4: return "4"; case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"; case kVK_ANSI_7: return "7"; case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
        case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
        case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default: return "Key(\(keyCode))"
        }
    }
}

struct GlobalHotKeyConfiguration: Codable, Equatable {
    static let storageKey = "globalHotKeys.v1"
    var bindings: [String: HotKeyBinding] = [:]

    func binding(for action: GlobalHotKeyAction) -> HotKeyBinding {
        bindings[action.rawValue] ?? action.defaultBinding
    }

    mutating func set(_ binding: HotKeyBinding, for action: GlobalHotKeyAction) {
        bindings[action.rawValue] = binding
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return decoded
    }

    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

/// Carbon RegisterEventHotKey works without Accessibility permission and consumes the combo cleanly.
@MainActor final class GlobalHotKeyManager: ObservableObject {
    static let shared = GlobalHotKeyManager()
    private static let signature: OSType = 0x4E4F5553 // 'NOUS'

    @Published var configuration: GlobalHotKeyConfiguration
    private var eventHandler: EventHandlerRef?
    private var registrations: [GlobalHotKeyAction: EventHotKeyRef] = [:]
    private var handler: ((GlobalHotKeyAction) -> Void)?
    private var started = false

    init(defaults: UserDefaults = .standard) {
        self.configuration = GlobalHotKeyConfiguration.load(defaults: defaults)
    }

    func start(handler: @escaping (GlobalHotKeyAction) -> Void) {
        self.handler = handler
        started = true
        installEventHandlerIfNeeded()
        reload()
    }

    func update(_ binding: HotKeyBinding, for action: GlobalHotKeyAction, defaults: UserDefaults = .standard) {
        configuration.set(binding, for: action)
        configuration.save(defaults: defaults)
        if started { reload() }
    }

    func resetDefaults(defaults: UserDefaults = .standard) {
        configuration = GlobalHotKeyConfiguration()
        configuration.save(defaults: defaults)
        if started { reload() }
    }

    func reload() {
        unregisterAll()
        guard started else { return }
        for action in GlobalHotKeyAction.allCases {
            let binding = configuration.binding(for: action)
            guard binding.enabled, HotKeyBinding.hasPrimaryModifier(binding.modifiers) else { continue }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.hotKeyID)
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registrations[action] = ref
            }
        }
    }

    func stop() {
        started = false
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        handler = nil
    }

    private func unregisterAll() {
        for ref in registrations.values {
            UnregisterEventHotKey(ref)
        }
        registrations.removeAll()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == GlobalHotKeyManager.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            let firedID = hotKeyID.id
            Task { @MainActor in
                guard let action = GlobalHotKeyAction.allCases.first(where: { $0.hotKeyID == firedID }) else { return }
                manager.handler?(action)
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, selfPointer, &eventHandler)
    }
}

struct HotKeyRecorderControl: View {
    let action: GlobalHotKeyAction
    @ObservedObject var manager: GlobalHotKeyManager
    @State private var recording = false
    @State private var monitor: Any?

    private var binding: HotKeyBinding { manager.configuration.binding(for: action) }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { binding.enabled },
                set: { enabled in
                    var updated = binding
                    updated.enabled = enabled
                    manager.update(updated, for: action)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Button {
                if recording { stopRecording() } else { startRecording() }
            } label: {
                Text(recording
                    ? L10n.text("Press shortcut…", zh: "请按下快捷键…")
                    : (binding.enabled ? binding.displayString : L10n.text("Disabled", zh: "已禁用")))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(recording ? Color.accentColor : (binding.enabled ? Color.primary : Color.secondary))
                    .frame(minWidth: 96)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(recording ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(L10n.text("Click to record a shortcut (Esc to cancel, Delete to disable)", zh: "点击录制快捷键（Esc 取消，Delete 禁用）"))
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        stopRecording()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
                var updated = binding
                updated.enabled = false
                manager.update(updated, for: action)
                stopRecording()
                return nil
            }
            let modifiers = HotKeyBinding.carbonModifiers(from: event.modifierFlags)
            guard HotKeyBinding.hasPrimaryModifier(modifiers) else { return nil }
            manager.update(HotKeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers, enabled: true), for: action)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
