import AppKit
import Carbon
import Combine
import Foundation

struct GlobalShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyLabel: String

    static let `default` = GlobalShortcut(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(optionKey),
        keyLabel: "空格"
    )

    var displayText: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyLabel
    }

    static func capture(from event: NSEvent) -> ShortcutCaptureResult {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0

        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }

        let primaryModifiers = UInt32(cmdKey | optionKey | controlKey)
        guard modifiers & primaryModifiers != 0 else {
            return .missingPrimaryModifier
        }

        guard let keyLabel = keyLabel(for: event), !keyLabel.isEmpty else {
            return .unsupportedKey
        }

        return .shortcut(
            GlobalShortcut(
                keyCode: UInt32(event.keyCode),
                carbonModifiers: modifiers,
                keyLabel: keyLabel
            )
        )
    }

    private static func keyLabel(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_Space: return "空格"
        case kVK_Return: return "回车"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "删除"
        case kVK_ForwardDelete: return "向前删除"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        default:
            let characters = event.charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            return characters?.isEmpty == false ? characters : nil
        }
    }
}

enum ShortcutCaptureResult {
    case shortcut(GlobalShortcut)
    case missingPrimaryModifier
    case unsupportedKey
}

@MainActor
final class ShortcutSettings: ObservableObject {
    @Published private(set) var shortcut: GlobalShortcut
    @Published private(set) var isRegistered = false
    @Published private(set) var conflictMessage: String?
    @Published var recorderMessage: String?

    private let preferencesKey = "AppTileDemo.GlobalShortcut"
    private let monitor = GlobalHotKeyMonitor()

    init() {
        if let data = UserDefaults.standard.data(forKey: preferencesKey),
           let savedShortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data) {
            shortcut = savedShortcut
        } else {
            shortcut = .default
        }
    }

    func activate(action: @escaping @MainActor @Sendable () -> Void) {
        monitor.setAction(action)
        registerCurrentShortcut()
    }

    func updateShortcut(_ candidate: GlobalShortcut) {
        recorderMessage = nil
        conflictMessage = nil

        if candidate == shortcut, isRegistered {
            return
        }

        let previousShortcut = shortcut
        let result = monitor.register(candidate)

        guard result == noErr else {
            let restoreResult = monitor.register(previousShortcut)
            isRegistered = restoreResult == noErr
            conflictMessage = conflictDescription(for: candidate, status: result)
            return
        }

        shortcut = candidate
        isRegistered = true
        saveShortcut()
    }

    func restoreDefault() {
        updateShortcut(.default)
    }

    func reportCaptureResult(_ result: ShortcutCaptureResult) {
        switch result {
        case let .shortcut(shortcut):
            updateShortcut(shortcut)
        case .missingPrimaryModifier:
            recorderMessage = "快捷键至少需要包含 ⌘、⌥ 或 ⌃。"
        case .unsupportedKey:
            recorderMessage = "无法识别这个按键，请尝试其他组合。"
        }
    }

    private func registerCurrentShortcut() {
        let result = monitor.register(shortcut)
        isRegistered = result == noErr
        conflictMessage = result == noErr
            ? nil
            : conflictDescription(for: shortcut, status: result)
    }

    private func conflictDescription(for shortcut: GlobalShortcut, status: OSStatus) -> String {
        if status == OSStatus(eventHotKeyExistsErr) {
            return "快捷键 \(shortcut.displayText) 已被系统或其他应用占用，请设置其他组合。"
        }
        return "快捷键 \(shortcut.displayText) 无法注册（错误代码：\(status)），请设置其他组合。"
    }

    private func saveShortcut() {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: preferencesKey)
    }
}

private final class GlobalHotKeyMonitor: @unchecked Sendable {
    private static let signature: OSType = 0x4154_5444 // "ATTD"
    private static let identifier: UInt32 = 1

    nonisolated(unsafe) private static let eventHandler: EventHandlerUPP = {
        _, event, userData in
        guard let event, let userData else {
            return OSStatus(eventNotHandledErr)
        }

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

        guard status == noErr,
              hotKeyID.signature == GlobalHotKeyMonitor.signature,
              hotKeyID.id == GlobalHotKeyMonitor.identifier else {
            return OSStatus(eventNotHandledErr)
        }

        let monitor = Unmanaged<GlobalHotKeyMonitor>
            .fromOpaque(userData)
            .takeUnretainedValue()
        monitor.performAction()
        return noErr
    }

    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private var action: (@MainActor @Sendable () -> Void)?
    private var eventHandlerStatus: OSStatus = noErr

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        eventHandlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerReference
        )
    }

    deinit {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }
    }

    func setAction(_ action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    func register(_ shortcut: GlobalShortcut) -> OSStatus {
        guard eventHandlerStatus == noErr else {
            return eventHandlerStatus
        }

        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }

        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: Self.identifier
        )
        return RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
    }

    private func performAction() {
        let action = action
        Task { @MainActor in
            action?()
        }
    }
}
