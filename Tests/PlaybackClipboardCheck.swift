import AppKit
import AVFoundation

@main struct PlaybackClipboardCheck {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let png = try Data(contentsOf: URL(fileURLWithPath: "Resources/AppIcon-preview.png"))
        board.setData(png, forType: .png)
        let editor = Editor()
        editor.pasteTemporaryMedia(from: board)
        while editor.loadingSources { try await Task.sleep(for: .milliseconds(25)) }
        precondition(editor.error == nil && editor.project.sources.count == 1)
        let source = editor.project.sources[0]
        precondition(source.isImage && source.temporary == true && FileManager.default.fileExists(atPath: source.path))
        precondition(editor.initialExportDirectory == nil)
        editor.undo()
        precondition(editor.project.sources.isEmpty)
        editor.redo()
        precondition(editor.project.sources[0].temporary == true)
        editor.addClip(source)
        editor.addLayer(.image, source: source)
        let clean = editor.project.withoutTemporaryMedia
        precondition(clean.sources.isEmpty && clean.timelines[0].clips.isEmpty && clean.timelines[0].layers.isEmpty)
        let json = try JSONEncoder().encode(clean)
        precondition(!String(decoding: json, as: UTF8.self).contains(source.path))
        try clean.validate()
        print("PASS pasted PNG, temporary label flag, atomic undo/redo, save exclusion and output directory")

        editor.updateOutputSizing { $0.frameRate = .fps60 }
        editor.seek(0)
        editor.stepFrame(1)
        precondition(editor.previewFrame == 1 && editor.playhead == 0)
        editor.stepFrame(1)
        precondition(editor.previewFrame == 2 && editor.playhead == 1)
        editor.stepFrame(-1)
        precondition(editor.previewFrame == 1)
        editor.stepFrame(Int.max / 2)
        precondition(editor.previewFrame == editor.previewFrameCount - 1)
        editor.stepFrame(-Int.max / 2)
        precondition(editor.previewFrame == 0)
        print("PASS exact 60 fps frame stepping and start/end bounds")

        let baseline = try await renderedPreviewFrame(editor.timeline, sources: editor.project.sources, frame: 0)
        editor.addLayer(.rectangle)
        let withOverlay = try await renderedPreviewFrame(editor.timeline, sources: editor.project.sources, frame: 0)
        precondition(baseline.width == 1920 && baseline.height == 1080)
        let first = NSBitmapImageRep(cgImage: baseline).representation(using: .png, properties: [:])!
        let second = NSBitmapImageRep(cgImage: withOverlay).representation(using: .png, properties: [:])!
        precondition(first != second)
        try second.write(to: folder.appendingPathComponent("rendered.png"))
        print("PASS full-resolution frame capture includes composed image layers and rectangle overlays")

        let movieURL = URL(fileURLWithPath: "Resources/StillTiming.mp4").standardizedFileURL
        board.clearContents(); board.writeObjects([movieURL as NSURL])
        let store = TemporaryMediaStore()
        let copied = try await store.capture(board)
        precondition(copied.count == 1 && copied[0] != movieURL)
        let copiedData = try Data(contentsOf: copied[0])
        let originalData = try Data(contentsOf: movieURL)
        precondition(copiedData == originalData)
        let info = try await inspectSource(copied[0])
        precondition(!info.isImage && info.frames > 0)
        store.cleanup()
        precondition(!FileManager.default.fileExists(atPath: copied[0].path))
        print("PASS pasted movie file is copied to session storage and removed by cleanup")

        var small = Timeline(name: "Small", clips: [Clip(sourceID: source.id, end: 30)])
        small.layers = []
        let large = Timeline(name: "Large", clips: [Clip(sourceID: source.id, end: 90)])
        editor.jobs = [Editor.ExportJob(timeline: small, destination: folder.appendingPathComponent("a.mp4"), progress: 1, status: .complete),
                       Editor.ExportJob(timeline: large, destination: folder.appendingPathComponent("b.mp4"), progress: 0.5, status: .exporting)]
        precondition(abs(editor.overallExportProgress - 0.625) < 0.00001 && editor.completedExportCount == 1)
        editor.exporting = true
        precondition(editor.windowTitle.contains("62%"))
        editor.jobs[1].status = .failed("test")
        precondition(editor.overallExportProgress < 1)
        editor.jobs[1].status = .complete
        precondition(editor.overallExportProgress == 1)
        editor.exporting = false
        precondition(editor.windowTitle == "cygnus movies")
        editor.jobs = []
        precondition(editor.overallExportProgress == 0)
        print("PASS weighted batch progress, completion, failure, empty queue and title reset")
        editor.temporaryMedia.cleanup()
        precondition(!FileManager.default.fileExists(atPath: source.path))
    }
}
