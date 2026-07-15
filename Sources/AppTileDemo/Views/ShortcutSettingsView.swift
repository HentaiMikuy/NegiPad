import AppKit
import Carbon
import SwiftUI

struct ShortcutSettingsView: View {
    @EnvironmentObject private var settings: ShortcutSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("快捷键")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("设置一个在其他应用中也能唤醒启动器的全局快捷键。")
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .center, spacing: 20) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("唤醒启动器")
                                    .font(.headline)
                                Text("点击右侧按键区域，然后按下新的组合键。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            ShortcutRecorderView(
                                shortcut: settings.shortcut,
                                onCapture: settings.reportCaptureResult
                            )
                            .frame(width: 180, height: 30)
                        }

                        Divider()

                        statusView

                        HStack {
                            Text("默认快捷键：⌥空格")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("恢复默认") {
                                settings.restoreDefault()
                            }
                            .disabled(settings.shortcut == .default && settings.isRegistered)
                        }
                    }
                    .padding(8)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("快捷键冲突检查", systemImage: "checkmark.shield")
                        .font(.headline)
                    Text("保存前会尝试向 macOS 注册快捷键。若组合已被系统或其他应用占用，将显示冲突提示并继续保留原快捷键。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var statusView: some View {
        if let conflictMessage = settings.conflictMessage {
            Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let recorderMessage = settings.recorderMessage {
            Label(recorderMessage, systemImage: "info.circle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        } else if settings.isRegistered {
            Label(
                "全局快捷键 \(settings.shortcut.displayText) 已启用",
                systemImage: "checkmark.circle.fill"
            )
            .font(.callout)
            .foregroundStyle(.green)
        } else {
            Label("全局快捷键尚未启用", systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ShortcutRecorderView: NSViewRepresentable {
    let shortcut: GlobalShortcut
    let onCapture: (ShortcutCaptureResult) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.shortcut = shortcut
        button.onCapture = context.coordinator.onCapture
        button.updateTitle()
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        context.coordinator.onCapture = onCapture
        button.onCapture = context.coordinator.onCapture
        guard !button.isRecording else { return }
        button.shortcut = shortcut
        button.updateTitle()
    }

    final class Coordinator {
        var onCapture: (ShortcutCaptureResult) -> Void

        init(onCapture: @escaping (ShortcutCaptureResult) -> Void) {
            self.onCapture = onCapture
        }
    }
}

private final class ShortcutRecorderButton: NSButton {
    var shortcut = GlobalShortcut.default
    var onCapture: ((ShortcutCaptureResult) -> Void)?
    private(set) var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        focusRingType = .exterior
        toolTip = "点击后按下新的全局快捷键"
    }

    @objc private func beginRecording() {
        isRecording = true
        title = "请按下快捷键…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            finishRecording()
            return
        }

        let result = GlobalShortcut.capture(from: event)
        switch result {
        case let .shortcut(shortcut):
            self.shortcut = shortcut
            onCapture?(result)
            finishRecording()
        case .missingPrimaryModifier, .unsupportedKey:
            NSSound.beep()
            onCapture?(result)
        }
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if isRecording {
            finishRecording()
        }
        return result
    }

    func updateTitle() {
        title = shortcut.displayText
    }

    private func finishRecording() {
        isRecording = false
        updateTitle()
    }
}
