import AppKit
import AVFoundation

@main struct TimelineVideoLayerCheck {
    static func pixels(_ image: CGImage) -> Data {
        var bytes = [UInt8](repeating: 0, count: 64 * 36 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 64, height: 36, bitsPerComponent: 8,
                                    bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 36))
        }
        return Data(bytes)
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let image = try await inspectSource(folder.appendingPathComponent("blue.png"))
        let movie = try await inspectSource(folder.appendingPathComponent("motion.mov"))
        let rotated = try await inspectSource(folder.appendingPathComponent("rotated.mov"))
        let editor = Editor()
        editor.importSources([image.url, movie.url])
        while editor.loadingSources { try await Task.sleep(for: .milliseconds(25)) }
        precondition(editor.autoFitFrames == movie.frames)
        let oldToken = editor.autoFitToken
        editor.addClip(editor.project.sources.first { !$0.isImage }!)
        precondition(editor.autoFitToken != oldToken && editor.autoFitFrames == editor.totalFrames)
        let nextToken = editor.autoFitToken
        editor.addClip(editor.project.sources.first { !$0.isImage }!)
        precondition(editor.autoFitToken == nextToken)
        print("PASS automatic fit on first video import and placement, without refitting later additions")

        editor.addTimeline(); editor.addTimeline()
        let ordered = editor.project.timelines.map(\.id)
        editor.selectTimeline(ordered[1])
        editor.moveTimeline(ordered[1], by: -1)
        precondition(editor.project.timelines.map(\.id) == [ordered[1], ordered[0], ordered[2]])
        precondition(editor.timeline.id == ordered[1])
        editor.undo(); precondition(editor.project.timelines.map(\.id) == ordered)
        editor.redo(); precondition(editor.project.timelines.first!.id == ordered[1])
        editor.moveTimeline(ordered[1], to: 3)
        precondition(editor.project.timelines.last!.id == ordered[1])
        precondition(!editor.canMoveTimeline(ordered[1], by: 1))
        editor.toggleTimelineNumbers()
        precondition(editor.timelineDisplayName(editor.project.timelines[0]).hasPrefix("01"))
        editor.addLayer(.text)
        precondition(editor.selectedLayer!.end - editor.selectedLayer!.start >= 180)
        print("PASS timeline arrows/drop insertion, edge guards, numbering, selection and undo/redo; longer default layers")

        let base = Timeline(name: "Overlay", clips: [Clip(sourceID: image.id, end: 150)])
        let file = folder.appendingPathComponent("overlay.cygnusmovies")
        try JSONEncoder().encode(Project(sources: [image, movie, rotated], timelines: [base])).write(to: file)
        let overlay = Editor(); precondition(overlay.openProject(at: file))
        overlay.seek(30)
        overlay.addLayer(.video, source: movie, duration: 900)
        let layer = overlay.selectedLayer!
        precondition(layer.end - layer.start == movie.frames)
        try overlay.project.validate()
        let before = pixels(try await renderedPreviewFrame(overlay.timeline, sources: overlay.project.sources, frame: 15))
        let during = pixels(try await renderedPreviewFrame(overlay.timeline, sources: overlay.project.sources, frame: 45))
        let later = pixels(try await renderedPreviewFrame(overlay.timeline, sources: overlay.project.sources, frame: 75))
        let after = pixels(try await renderedPreviewFrame(overlay.timeline, sources: overlay.project.sources, frame: 135))
        precondition(before != during && during != later && before == after)
        let sound = try await waveform(overlay.timeline, sources: overlay.project.sources)
        precondition(sound.max()! > 0.01)
        overlay.updateLayer(layer.id) { $0.videoMuted = true }
        let muted = try await waveform(overlay.timeline, sources: overlay.project.sources)
        precondition(muted.max()! < 0.001)
        overlay.updateLayer(layer.id) { $0.videoMuted = nil }
        overlay.updateLayer(layer.id) { $0.videoVolume = 0.5 }
        let quiet = try await waveform(overlay.timeline, sources: overlay.project.sources)
        precondition(abs(quiet.max()! / sound.max()! - 0.5) < 0.02)
        overlay.updateLayer(layer.id) { $0.videoVolume = nil }
        overlay.seek(60); overlay.split()
        let parts = overlay.timeline.layers.sorted { $0.start < $1.start }
        precondition(parts.count == 2 && parts[1].videoSourceStart == 30)
        let splitFrame = pixels(try await renderedPreviewFrame(overlay.timeline, sources: overlay.project.sources, frame: 75))
        precondition(splitFrame == later)
        overlay.trimLayer(parts[1].id, start: 75)
        precondition(overlay.timeline.layers[1].videoSourceStart == 45)
        overlay.trimLayer(parts[1].id, end: 900)
        precondition(overlay.timeline.layers[1].end == 120)
        try overlay.project.validate()
        let roundTrip = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(overlay.project))
        precondition(roundTrip == overlay.project)
        print("PASS moving video overlay before/during/after, audio/mute, split continuity, source bounds and project round trip")

        var standalone = Timeline(name: "Video only")
        standalone.layers = [VisualLayer(kind: .video, start: 30, end: 30 + rotated.frames,
                                        region: CanvasRegion(x: 0.1, y: 0.1, width: 0.8, height: 0.8), sourceID: rotated.id)]
        let rotatedFrame = try await renderedPreviewFrame(standalone, sources: [rotated], frame: 45)
        precondition(rotatedFrame.width == 1920 && rotatedFrame.height == 1080)
        try await exportMovie(standalone, sources: [rotated], to: folder.appendingPathComponent("video-layer.mp4")) { _ in }
        let exported = try await inspectSource(folder.appendingPathComponent("video-layer.mp4"))
        precondition(exported.frames >= 119)
        let asset = AVURLAsset(url: exported.url)
        let generator = AVAssetImageGenerator(asset: asset)
        let exportedFrame = try await generator.image(at: frameTime(45)).image
        let reference = [UInt8](pixels(rotatedFrame)), actual = [UInt8](pixels(exportedFrame))
        let meanError = zip(reference, actual).map { abs(Int($0) - Int($1)) }.reduce(0, +) / reference.count
        precondition(meanError < 15)
        var transitioned = standalone
        transitioned.layers[0].entrance = .dissolve
        transitioned.layers[0].exit = .swipeRight
        _ = try await renderedPreviewFrame(transitioned, sources: [rotated], frame: 31)
        _ = try await renderedPreviewFrame(transitioned, sources: [rotated], frame: transitioned.layers[0].end - 2)
        print("PASS standalone rotated video layer on black canvas and production export")
        AudioPreparationCache.shared.removeTemporaryFiles()
    }
}
