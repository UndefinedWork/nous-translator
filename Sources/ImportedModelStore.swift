import Foundation

/// Copies a user-selected GGUF into the app’s Application Support folder so a sandboxed
/// helper can read it. Direct builds keep the original path and do not copy.
enum ImportedModelStore {
    struct IO {
        var createDirectory: (URL) throws -> Void
        var copyItem: (URL, URL) throws -> Void
        var moveItem: (URL, URL) throws -> Void
        var removeItem: (URL) throws -> Void
    }

    /// Tests replace this so copies never touch the user’s Application Support folder.
    static var directoryOverride: URL?
    /// Tests replace copy/move to simulate disk-full and other I/O failures.
    static var io = IO(
        createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
        copyItem: { try FileManager.default.copyItem(at: $0, to: $1) },
        moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
        removeItem: { try FileManager.default.removeItem(at: $0) }
    )

    static var directory: URL { directoryOverride ?? LocalModel.directory.appendingPathComponent("Imported Models") }

    static func sanitizedFileName(_ name: String) -> String {
        let base = URL(fileURLWithPath: name).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let cleaned = String(base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let clipped = String(cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "._")).prefix(80))
        if clipped.lowercased().hasSuffix(".gguf"), clipped.count > 5 { return clipped }
        if clipped.isEmpty { return "model.gguf" }
        return clipped + ".gguf"
    }

    static func importGGUF(from url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard LocalModelFile.hasGGUFHeader(at: fresh, minimumBytes: 24) else {
            throw ModelError.message("Choose a valid GGUF model file.")
        }
        try io.createDirectory(directory)
        let destination = directory.appendingPathComponent(UUID().uuidString + "-" + sanitizedFileName(url.lastPathComponent))
        let staging = directory.appendingPathComponent("." + UUID().uuidString + ".copying")
        do {
            try io.copyItem(fresh, staging)
            guard LocalModelFile.hasGGUFHeader(at: staging, minimumBytes: 24) else {
                throw ModelError.message("The model copy is unreadable. Please choose the file again.")
            }
            try io.moveItem(staging, destination)
            return destination
        } catch let error as ModelError {
            try? io.removeItem(staging)
            try? io.removeItem(destination)
            throw error
        } catch {
            try? io.removeItem(staging)
            try? io.removeItem(destination)
            throw ModelError.message("Could not copy the model into the app folder. Check available disk space and try again.")
        }
    }

    static func adoptSelection(_ url: URL) throws -> URL {
        if AppDistribution.copiesUserSelectedModels { return try importGGUF(from: url) }
        return url
    }
}
