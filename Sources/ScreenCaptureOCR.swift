import Foundation

/// Captures a user-selected screen region via macOS native interactive screencapture,
/// then extracts text with the configured Apple Vision or online image recognition provider.
enum ScreenCaptureOCR {
    static func captureInteractiveRegion() async throws -> URL {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("nous-screen-ocr-" + UUID().uuidString + ".png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: output)
        }

        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: output.path),
              let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            try? FileManager.default.removeItem(at: output)
            if status == 0 {
                throw CancellationError()
            }
            throw ModelError.message(L10n.text(
                "Screen capture failed. Check Screen Recording permission in System Settings.",
                zh: "屏幕截图失败，请在“系统设置 → 隐私与安全性 → 录屏与系统录音”中检查权限。"
            ))
        }
        return output
    }

    static func recognizeCapturedImage(
        at url: URL,
        configuration: ImageRecognitionConfiguration = .load(),
        onSlowVision: (@MainActor @Sendable () -> Void)? = nil
    ) async throws -> String {
        defer { try? FileManager.default.removeItem(at: url) }
        let slowHint: Task<Void, Never>? = (configuration.provider == .local && onSlowVision != nil) ? Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await onSlowVision?()
        } : nil
        defer { slowHint?.cancel() }
        return try await ImageRecognition.recognize(url: url, configuration: configuration)
    }
}
