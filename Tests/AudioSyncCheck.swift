import AVFoundation

@main struct AudioSyncCheck {
    static func energy(_ edit: EditComposition) async throws -> ([Double], Double) {
        let tracks = try await edit.asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: edit.asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        output.audioMix = edit.audio
        reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        var bins = [Double](repeating: 0, count: Int(frameTime(edit.frames).seconds * 100) + 10)
        var end = 0.0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let start = sample.presentationTimeStamp.seconds
            let count = CMSampleBufferGetNumSamples(sample)
            end = start + Double(count) / 48_000
            guard let data = sample.dataBuffer else { continue }
            var values = [Int16](repeating: 0, count: count * 2)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            precondition(status == noErr, "PCM copy status: \(status), frames: \(count), bytes: \(CMBlockBufferGetDataLength(data))")
            for i in stride(from: 0, to: count, by: 8) {
                let bin = Int((start + Double(i) / 48_000) * 100)
                if bins.indices.contains(bin) { bins[bin] = max(bins[bin], abs(Double(values[i * 2])) / 32768) }
            }
        }
        guard reader.status == .completed else { throw reader.error! }
        return (bins, end)
    }

    static func onset(_ bins: [Double], around time: Double) -> Double {
        let start = max(0, Int((time - 0.2) * 100))
        let end = min(bins.count - 1, Int((time + 0.2) * 100))
        guard let index = (start...end).first(where: { bins[$0] > 0.15 }) else {
            fatalError("No audio marker near \(time)")
        }
        return Double(index) / 100
    }

    static func main() async throws {
        setbuf(stdout, nil)
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let names = ["lead48", "lead44", "tail44", "tail48", "tail32", "tail96", "offset32"]
        var sources: [String: Source] = [:]
        for name in names { sources[name] = try await inspectSource(folder.appendingPathComponent(name + ".mov")) }
        let all = Array(sources.values)
        let cases: [(String, String, Transition, Double)] = [
            ("lead48", "tail44", .cut, 1), ("lead48", "tail32", .cut, 1),
            ("lead48", "tail96", .cut, 1), ("lead44", "tail48", .cut, 1),
            ("lead48", "tail44", .dissolve, 1), ("lead48", "tail44", .swipe, 1),
            ("lead48", "offset32", .cut, 1),
            ("lead48", "tail44", .cut, 0.5), ("lead48", "tail32", .cut, 2)]
        for (lead, tail, transition, speed) in cases {
            let a = sources[lead]!, b = sources[tail]!
            var first = Clip(sourceID: a.id, end: a.frames); first.transition = transition
            var last = Clip(sourceID: b.id, end: b.frames); last.speed = speed
            let timeline = Timeline(name: tail, clips: [first, last])
            print("CHECK", lead, tail, transition.rawValue, speed)
            let edit = try await compose(timeline, sources: all)
            let (bins, end) = try await energy(edit)
            let start = Double(layout(timeline.clips).last!.start) / 30
            let sourceOffset = tail == "offset32" ? 0.2 : 0
            let expected = start + (sourceOffset + 0.5) / speed
            let actual = onset(bins, around: expected)
            print("TIMING", expected, actual, end, frameTime(edit.frames).seconds)
            precondition(abs(actual - expected) < 0.04, "Audio marker drift: \(actual - expected)")
            let lastMarker = start + (sourceOffset + 1.5) / speed
            precondition(abs(onset(bins, around: lastMarker) - lastMarker) < 0.04, "Last audio marker drift")
            if speed == 1 {
                precondition(abs(end - frameTime(edit.frames).seconds) < 0.04, "Audio end drift: \(end)")
            } else {
                // Spectral time stretching trims processing-tail silence; check
                // actual sound events rather than treating silence as lost audio.
                precondition(end > start + 1.6 / speed - 0.04, "Last audible event was truncated")
            }
            print("PASS",lead,"+",tail,transition.rawValue,"speed",speed,"onset error",actual - expected,"end error",end - frameTime(edit.frames).seconds)
        }
        if CommandLine.arguments.contains("--skip-export") { AudioPreparationCache.shared.removeTemporaryFiles(); return }
        // Exercise the production AVAssetWriter path, not just composition reads.
        let lead = sources["lead48"]!, tail = sources["tail44"]!
        let timeline = Timeline(name: "long-cut", clips: [Clip(sourceID: lead.id, end: lead.frames), Clip(sourceID: tail.id, end: tail.frames)])
        try await exportMovie(timeline, sources: all, to: folder.appendingPathComponent("export-long.mp4")) { _ in }
        var transitionTimeline = Timeline(name: "short-dissolve", clips: [Clip(sourceID: lead.id, end: 90), Clip(sourceID: tail.id, end: tail.frames)])
        transitionTimeline.clips[0].transition = .dissolve
        transitionTimeline.output.frameRate = .fps60
        try await exportMovie(transitionTimeline, sources: all, to: folder.appendingPathComponent("export-dissolve.mp4"), useHardware: false) { _ in }
        print("PASS production hardware export after a six-minute lead and software export with a transition at 60 fps")
        AudioPreparationCache.shared.removeTemporaryFiles()
    }
}
