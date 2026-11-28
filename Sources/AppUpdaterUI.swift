import AppKit
import SwiftUI

/// Lightweight non-activating toast shown below the menu bar when a newer GitHub Release is found.
@MainActor final class UpdateToastController {
    static let shared = UpdateToastController()
    private var panel: FloatingPanel?
    private var autoHideTask: Task<Void, Never>?

    func show(update: AvailableUpdate, onOpenSettings: @escaping () -> Void) {
        dismiss()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let toastSize = CGSize(width: 318, height: 92)
        let margin: CGFloat = 16
        let origin = CGPoint(
            x: visible.maxX - toastSize.width - 14,
            y: visible.maxY - toastSize.height - 14
        )
        let window = FloatingPanel(
            contentRect: NSRect(
                x: origin.x - margin,
                y: origin.y - margin,
                width: toastSize.width + margin * 2,
                height: toastSize.height + margin * 2
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.allowsKey = false
        window.level = .floating
        window.contentView = FirstMouseHostingView(
            rootView: UpdateToastView(
                update: update,
                onOpen: { [weak self] in
                    self?.dismiss()
                    onOpenSettings()
                },
                onDismiss: { [weak self] in
                    self?.dismiss()
                }
            )
            .frame(width: toastSize.width, height: toastSize.height)
            .padding(margin)
        )
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.22
            window.animator().alphaValue = 1
        }
        panel = window

        // Auto-hide after 14 seconds; the menu bar dot & menu item remain available.
        autoHideTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 14_000_000_000) } catch { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        autoHideTask?.cancel()
        autoHideTask = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct UpdateToastView: View {
    let update: AvailableUpdate
    let onOpen: () -> Void
    let onDismiss: () -> Void
    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.18))
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("Update Available: v\(update.version.raw)", zh: "发现新版本：v\(update.version.raw)"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(L10n.text("Open Settings for one-click download & restart.", zh: "前往设置即可一键下载更新并自动重启。"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                Button(L10n.text("Update…", zh: "去更新")) { onOpen() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(L10n.text("Later", zh: "稍后")) { onDismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if #available(macOS 26, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                Rectangle().fill(.regularMaterial).clipShape(shape)
            }
        }
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }
}

/// Renders the menu bar icon with an optional accent dot when an update is available.
@MainActor enum StatusBarIcon {
    static func image(hasUpdate: Bool) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: "translate", accessibilityDescription: "Nous Translator") else {
            return nil
        }
        guard hasUpdate else {
            symbol.isTemplate = true
            return symbol
        }
        let canvasSize = NSSize(width: 20, height: 18)
        let composed = NSImage(size: canvasSize, flipped: false) { rect in
            let iconSize = symbol.size
            let drawRect = NSRect(
                x: (rect.width - iconSize.width) / 2 - 1,
                y: (rect.height - iconSize.height) / 2,
                width: iconSize.width,
                height: iconSize.height
            )
            // Draw template symbol tinted with system label color so it adapts to menu bar appearance.
            if let tinted = symbol.copy() as? NSImage {
                tinted.lockFocus()
                NSColor.labelColor.set()
                NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
                tinted.unlockFocus()
                tinted.draw(in: drawRect)
            }
            let dotRect = NSRect(x: rect.maxX - 6.5, y: rect.maxY - 6.5, width: 5.5, height: 5.5)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        composed.isTemplate = false
        return composed
    }
}

/// Software Update section embedded in Settings → General.
struct SoftwareUpdateSettingsSection: View {
    @ObservedObject var updater: AppUpdater
    @State private var notesExpanded = true

    var body: some View {
        Section {
            LabeledContent(L10n.text("Current version", zh: "当前版本")) {
                HStack(spacing: 6) {
                    Text(updater.currentVersion.raw)
                    if updater.currentChannel == "preview" || updater.currentVersion.isPrerelease {
                        Text(L10n.text("Preview", zh: "预览版"))
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            switch updater.state {
            case .idle:
                checkRow(statusText: lastCheckedText)

            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("Checking GitHub Releases…", zh: "正在检查 GitHub 新版本…"))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

            case .upToDate:
                checkRow(statusText: L10n.text("Nous Translator is up to date.", zh: "当前已是最新版本。"))

            case let .available(update):
                updateCard(update: update)

            case let .downloading(update, progress, detail):
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.text("Downloading v\(update.version.raw)…", zh: "正在下载 v\(update.version.raw)…"))
                            .font(.headline)
                        Spacer()
                        Button(L10n.text("Cancel", zh: "取消")) { updater.cancelInstall() }
                    }
                    if let progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)

            case let .verifying(update, detail):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("Preparing v\(update.version.raw)", zh: "正在准备 v\(update.version.raw)"))
                            .font(.subheadline.weight(.medium))
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.text("Cancel", zh: "取消")) { updater.cancelInstall() }
                }.padding(.vertical, 4)

            case let .installing(update):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("Installing v\(update.version.raw) and restarting…", zh: "正在安装 v\(update.version.raw) 并自动重启…"))
                        .font(.subheadline.weight(.medium))
                }.padding(.vertical, 4)

            case let .failed(message, update):
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.text("Update failed", zh: "更新失败"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Button(L10n.text("Open GitHub Releases", zh: "前往 GitHub 下载")) {
                            NSWorkspace.shared.open(update?.htmlURL ?? UpdaterRules.releasesPageURL)
                        }
                        Spacer()
                        if let update {
                            Button(L10n.text("Retry Update", zh: "重试更新")) {
                                updater.downloadAndInstall(update)
                            }.buttonStyle(.borderedProminent)
                        } else {
                            Button(L10n.text("Check Again", zh: "重新检查")) {
                                Task { await updater.checkForUpdates(userInitiated: true) }
                            }
                        }
                    }
                }.padding(.vertical, 4)
            }

            Toggle(L10n.text("Check for updates automatically", zh: "自动检查 GitHub 更新"), isOn: $updater.autoCheckEnabled)
            Toggle(L10n.text("Include preview releases", zh: "接收预览版（beta）更新"), isOn: $updater.includePrereleases)
        } header: {
            Text(L10n.text("Software Update", zh: "软件更新"))
        } footer: {
            Text(L10n.text(
                "Updates are downloaded directly from GitHub Releases (UndefinedWork/nous-translator), verified with SHA-256 and code signature before replacing the app and restarting automatically. Models, history, preferences, and Keychain keys are preserved.",
                zh: "更新直接从 GitHub Releases（UndefinedWork/nous-translator）下载，经 SHA-256 与代码签名校验后替换应用并自动重启。模型、历史、偏好设置和钥匙串密钥均会保留。"
            ))
        }
    }

    private var lastCheckedText: String {
        guard let date = updater.lastChecked else {
            return L10n.text("Never checked", zh: "尚未检查更新")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return L10n.text("Last checked ", zh: "上次检查：") + formatter.localizedString(for: date, relativeTo: Date())
    }

    private func checkRow(statusText: String) -> some View {
        HStack {
            Text(statusText).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(L10n.text("Check for Updates", zh: "检查更新")) {
                Task { await updater.checkForUpdates(userInitiated: true) }
            }
        }
    }

    private func updateCard(update: AvailableUpdate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(update.title).font(.headline)
                        if update.isPrerelease {
                            Text(L10n.text("Preview", zh: "预览版"))
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                    let sizeText = update.zipSize > 0
                        ? ByteCountFormatter.string(fromByteCount: update.zipSize, countStyle: .file)
                        : ""
                    Text(sizeText.isEmpty ? "v\(update.version.raw)" : "v\(update.version.raw) · \(sizeText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !update.notes.isEmpty {
                DisclosureGroup(L10n.text("Release Notes", zh: "更新说明"), isExpanded: $notesExpanded) {
                    ScrollView {
                        Text(update.notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(maxHeight: 130)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            HStack(spacing: 10) {
                Button(L10n.text("Skip This Version", zh: "跳过此版本")) {
                    updater.skip(update)
                }
                Button(L10n.text("View on GitHub", zh: "在 GitHub 查看")) {
                    NSWorkspace.shared.open(update.htmlURL)
                }
                Spacer()
                Button(L10n.text("Download & Install Update", zh: "一键下载并更新")) {
                    updater.downloadAndInstall(update)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 6)
    }
}
