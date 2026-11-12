import Foundation

@main struct ImportedModelTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nous-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        ImportedModelStore.directoryOverride = folder.appendingPathComponent("Imported Models")
        defer {
            ImportedModelStore.directoryOverride = nil
            try? FileManager.default.removeItem(at: folder)
        }
        let source = folder.appendingPathComponent("custom.gguf")
        try Data([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0] + Array(repeating: UInt8(0), count: 16)).write(to: source)
        let copied = try ImportedModelStore.importGGUF(from: source)
        precondition(copied.path != source.path, "Import copies into the app data folder")
        precondition(LocalModelFile.hasGGUFHeader(at: copied), "The copy remains a GGUF file")
        let adopted = try ImportedModelStore.adoptSelection(source)
        #if NOUS_APP_STORE
        precondition(adopted.path != source.path, "App Store selection copies the model")
        precondition(adopted.path.contains("Imported Models"), "Copied models land in Imported Models")
        #else
        precondition(adopted.path == source.path, "Direct builds keep the original path")
        #endif
        let invalid = folder.appendingPathComponent("notes.txt")
        try Data("not a model".utf8).write(to: invalid)
        do {
            _ = try ImportedModelStore.importGGUF(from: invalid)
            fatalError("Non-GGUF files must be rejected")
        } catch { }
        print("PASS: GGUF import copy, distribution-specific adoption, invalid file rejection")
    }
}
