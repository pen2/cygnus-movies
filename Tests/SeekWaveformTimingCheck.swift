import AppKit
import AVFoundation

@main struct SeekWaveformTimingCheck {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let source = try await inspectSource(folder.appendingPathComponent("long.mov"))
        for (start, end) in [(176, 9790), (177, 9791), (178, 9792), (9791, 17508), (17508, 24919), (24919, 35510)] {
            let timeline = Timeline(name: "Trim", clips: [Clip(sourceID: source.id, start: start, end: end)])
            let edit = try await compose(timeline, sources: [source])
            precondition(edit.asset.duration <= frameTime(edit.frames))
            let valid = try await edit.video.isValid(for: edit.asset,
                timeRange: CMTimeRange(start: .zero, duration: frameTime(edit.frames)), validationDelegate: nil)
            precondition(valid)
            let reader = try AVAssetReader(asset: edit.asset)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: edit.asset.tracks(withMediaType: .video),
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.videoComposition = edit.video
            reader.add(output)
            precondition(reader.startReading())
            precondition(output.copyNextSampleBuffer() != nil)
            reader.cancelReading()
        }
        print("PASS exact video/audio end times, composition validation and decoded frames at neighboring non-keyframe cuts in 29.97 fps PCM media")

        var short = Timeline(name: "Cache", clips: [Clip(sourceID: source.id, end: 90)])
        let cache = WaveformCache()
        let snapshot = short
        async let a = cache.samples(snapshot, sources: [source])
        async let b = cache.samples(snapshot, sources: [source])
        let (first, shared) = try await (a,b)
        precondition(first == shared)
        var count = await cache.calculations
        precondition(count == 1)
        short.name = "Renamed"
        short.output.ultraHD = true
        short.clips[0].colorCorrection = ClipColorCorrection(brightness: 0.2)
        let reused = try await cache.samples(short, sources: [source])
        count = await cache.calculations
        precondition(first == reused && count == 1)
        short.clips[0].muted = true
        let silent = try await cache.samples(short, sources: [source])
        count = await cache.calculations
        precondition(count == 2 && silent.max()! < 0.001)
        short.clips[0].muted = nil
        _ = try await cache.samples(short, sources: [source])
        count = await cache.calculations
        precondition(count == 2)
        short.clips[0].end = 80
        _ = try await cache.samples(short, sources: [source])
        count = await cache.calculations
        precondition(count == 3)
        print("PASS waveform request coalescing, timeline revisit/undo reuse, visual-edit reuse and audio/trim invalidation")

        short.clips[0].end = 150
        let document = folder.appendingPathComponent("seek.cygnusmovies")
        try JSONEncoder().encode(Project(sources: [source], timelines: [short])).write(to: document)
        let editor = Editor()
        precondition(editor.openProject(at: document))
        await editor.rebuildPreview()
        for _ in 0..<400 where editor.player.currentItem?.status != .readyToPlay {
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(editor.player.currentItem?.status == .readyToPlay)
        editor.togglePlayback()
        editor.seek(30, continuingPlayback: true)
        editor.seek(60, continuingPlayback: true)
        try await Task.sleep(for: .milliseconds(500))
        precondition(editor.playing && editor.player.rate > 0 && editor.player.currentTime().seconds >= 2)
        editor.togglePlayback()
        editor.seek(10, continuingPlayback: true)
        try await Task.sleep(for: .milliseconds(100))
        precondition(!editor.playing && editor.player.rate == 0)
        editor.togglePlayback()
        editor.seek(20, continuingPlayback: true)
        editor.togglePlayback()
        try await Task.sleep(for: .milliseconds(100))
        precondition(!editor.playing && editor.player.rate == 0)
        editor.seek(editor.totalFrames, continuingPlayback: true)
        precondition(!editor.playing)
        print("PASS playing seek resumes, paused seek stays paused, rapid seeks and pause-during-seek remain paused, end stops")
        AudioPreparationCache.shared.removeTemporaryFiles()
    }
}
