import Foundation

@main struct ImportedModelTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nous-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let previousIO = ImportedModelStore.io
        ImportedModelStore.directoryOverride = folder.appendingPathComponent("Imported Models")
        defer {
            ImportedModelStore.io = previousIO
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
        precondition(ImportedModelStore.sanitizedFileName("../../etc/passwd") == "passwd.gguf",
                     "Path elements collapse to a file name inside Imported Models")
        precondition(ImportedModelStore.sanitizedFileName("My Model.gguf") == "My_Model.gguf")
        let named = folder.appendingPathComponent("My Model.gguf")
        try Data([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0] + Array(repeating: UInt8(0), count: 16)).write(to: named)
        let safe = try ImportedModelStore.importGGUF(from: named)
        precondition(safe.lastPathComponent.contains("My_Model.gguf"), "Imported names are sanitized")
        precondition(!safe.path.contains(".."), "Import never writes outside Imported Models")

        ImportedModelStore.io.copyItem = { _, destination in
            try Data([0x47, 0x47, 0x55, 0x46]).write(to: destination)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC), userInfo: [
                NSLocalizedDescriptionKey: "simulated disk full"
            ])
        }
        do {
            _ = try ImportedModelStore.importGGUF(from: source)
            fatalError("A failed copy must throw")
        } catch let error as ModelError {
            precondition(error.localizedDescription.contains("disk space"),
                         "Disk failures surface a copy error, not a raw Cocoa error")
        } catch {
            fatalError("Disk failures must be wrapped as ModelError, got \(error)")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: ImportedModelStore.directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".") && $0.pathExtension == "copying" }
        precondition(leftovers.isEmpty, "Failed copy must not leave a partial staging file")

        ImportedModelStore.io = previousIO
        ImportedModelStore.io.copyItem = { _, destination in
            try Data("not-gguf".utf8).write(to: destination)
        }
        do {
            _ = try ImportedModelStore.importGGUF(from: source)
            fatalError("A corrupt copy must be rejected")
        } catch { }
        let afterCorrupt = try FileManager.default.contentsOfDirectory(
            at: ImportedModelStore.directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".") }
        precondition(afterCorrupt.isEmpty, "An unreadable copy is deleted")
        print("PASS: GGUF import copy, sanitization, disk-failure cleanup, distribution-specific adoption")
    }
}
