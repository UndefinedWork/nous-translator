import Foundation

/// Copies a user-selected GGUF into the app’s Application Support folder so a sandboxed
/// helper can read it. Direct builds keep the original path and do not copy.
enum ImportedModelStore {
    /// Tests replace this so copies never touch the user’s Application Support folder.
    static var directoryOverride: URL?
    static var directory: URL { directoryOverride ?? LocalModel.directory.appendingPathComponent("Imported Models") }

    static func importGGUF(from url: URL, fileManager: FileManager = .default) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard LocalModelFile.hasGGUFHeader(at: fresh, minimumBytes: 24) else {
            throw ModelError.message("Choose a valid GGUF model file.")
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try fileManager.copyItem(at: fresh, to: destination)
        guard LocalModelFile.hasGGUFHeader(at: destination, minimumBytes: 24) else {
            try? fileManager.removeItem(at: destination)
            throw ModelError.message("The model copy is unreadable. Please choose the file again.")
        }
        return destination
    }

    static func adoptSelection(_ url: URL) throws -> URL {
        if AppDistribution.copiesUserSelectedModels { return try importGGUF(from: url) }
        return url
    }
}
