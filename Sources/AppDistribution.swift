import Foundation

/// Compile-time distribution. The Mac App Store binary is built with `-D NOUS_APP_STORE`
/// and does not compile Accessibility selection capture.
enum AppDistribution {
    #if NOUS_APP_STORE
    static let identifier = "appstore"
    static let usesAccessibilitySelection = false
    static let copiesUserSelectedModels = true
    static let menuBarHelp = "Translate text from the clipboard, pasted input, or the Translate with Nous Translator service."
    #else
    static let identifier = "direct"
    static let usesAccessibilitySelection = true
    static let copiesUserSelectedModels = false
    static let menuBarHelp = "Select text in another app, or use Translate Clipboard."
    #endif

    /// Prefer the App Store helper location, then the direct-distribution runtime path.
    static var bundledRuntimeURL: URL {
        let macos = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/llama-server")
        if FileManager.default.isExecutableFile(atPath: macos.path) { return macos }
        return (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("Runtime/llama-server")
    }
}
