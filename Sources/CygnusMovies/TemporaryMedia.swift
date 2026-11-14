import AppKit
import UniformTypeIdentifiers

// Files exist only for this process; AVFoundation needs file-backed movie assets.
final class TemporaryMediaStore {
    private(set) var directory: URL?

    func destination(extension ext: String) throws -> URL {
        if directory == nil {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("cygnus-clipboard-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            directory = root
        }
        return directory!.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    @MainActor func capture(_ pasteboard: NSPasteboard) async throws -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        var copies: [URL] = []
        for url in urls where url.isFileURL {
            let type = UTType(filenameExtension: url.pathExtension)
            guard type?.conforms(to: .image) == true || ["mp4", "mov"].contains(url.pathExtension.lowercased()) else { continue }
            let target = try destination(extension: url.pathExtension)
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: url, to: target)
            }.value
            copies.append(target)
        }
        if !copies.isEmpty { return copies }
        // Prefer an image's original PNG data (including its alpha channel).
        if let data = pasteboard.data(forType: .png) {
            let target = try destination(extension: "png")
            try data.write(to: target, options: .atomic)
            return [target]
        }
        if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) {
            let target = try destination(extension: "png")
            try data.write(to: target, options: .atomic)
            return [target]
        }
        for (type, ext) in [(NSPasteboard.PasteboardType(UTType.mpeg4Movie.identifier), "mp4"),
                            (NSPasteboard.PasteboardType(UTType.quickTimeMovie.identifier), "mov")] {
            if let data = pasteboard.data(forType: type) {
                let target = try destination(extension: ext)
                try data.write(to: target, options: .atomic)
                return [target]
            }
        }
        throw MovieError(L10n.text("クリップボードに対応する画像・動画がありません。"))
    }

    func cleanup() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    deinit { cleanup() }
}

extension Project {
    var withoutTemporaryMedia: Project {
        let temporaryIDs = Set(sources.filter { $0.temporary == true }.map(\.id))
        var copy = self
        copy.sources.removeAll { temporaryIDs.contains($0.id) }
        for index in copy.timelines.indices {
            copy.timelines[index].clips.removeAll { temporaryIDs.contains($0.sourceID) }
            copy.timelines[index].layers.removeAll { $0.sourceID.map(temporaryIDs.contains) == true }
        }
        return copy
    }
}
