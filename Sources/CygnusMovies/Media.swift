import AVFoundation
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

private struct MediaSource {
    let asset: AVURLAsset
    let video: AVAssetTrack
    let audio: AVAssetTrack?
    let videoRange: CMTimeRange
    let audioRange: CMTimeRange?
    let size: CGSize
    let orientation: CGAffineTransform
    let fps: Double

    init(url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MovieError(L10n.format("素材が見つかりません。素材一覧から再指定してください。\n%@", String(describing: url.path)))
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw MovieError(L10n.format("%@ に映像トラックがありません。", String(describing: url.lastPathComponent)))
        }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        self.asset = asset
        self.video = video
        self.audio = audio
        videoRange = try await video.load(.timeRange)
        audioRange = try await audio?.load(.timeRange)
        (size, orientation) = try await video.load(.naturalSize, .preferredTransform)
        let nominal = try await video.load(.nominalFrameRate)
        fps = nominal > 0 ? Double(nominal) : 30
    }

    var frameCount: Int {
        let seconds = videoRange.duration.seconds
        guard seconds.isFinite, seconds >= 0, seconds <= 1_000_000 else { return 0 }
        return Int(videoRange.duration.convertScale(30, method: .roundTowardZero).value)
    }

    func transform(in canvas: CGSize, fill: Bool = false) -> CGAffineTransform {
        let bounds = CGRect(origin: .zero, size: size).applying(orientation).standardized
        let xScale = canvas.width / bounds.width
        let yScale = canvas.height / bounds.height
        let scale = fill ? max(xScale, yScale) : min(xScale, yScale)
        return orientation
            .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(
                translationX: (canvas.width - bounds.width * scale) / 2,
                y: (canvas.height - bounds.height * scale) / 2
            ))
    }
}

func loadStillImage(_ url: URL, maximumSize: Int) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: maximumSize
          ] as CFDictionary) else {
        throw MovieError(L10n.format("%@ を画像として読み込めません。", String(describing: url.lastPathComponent)))
    }
    return image
}

func inspectSource(_ url: URL) async throws -> Source {
    let ext = url.pathExtension.lowercased()
    if UTType(filenameExtension: ext)?.conforms(to: .image) == true {
        _ = try loadStillImage(url, maximumSize: 180)
        return Source(path: url.path, frames: Source.maxImageFrames, stillImage: true)
    }
    guard ["mp4", "mov"].contains(ext) else {
        throw MovieError(L10n.text("MOV、MP4、または対応する画像を選択してください。"))
    }
    let media = try await MediaSource(url: url)
    guard media.frameCount > 0 else {
        throw MovieError(L10n.format("%@ の映像の長さが無効です。", String(describing: url.lastPathComponent)))
    }
    let displayed = CGRect(origin: .zero, size: media.size).applying(media.orientation).standardized.size
    return Source(path: url.path, frames: media.frameCount,
                  videoInfo: SourceVideoInfo(width: displayed.width, height: displayed.height, fps: media.fps))
}

struct EditComposition {
    let asset: AVMutableComposition
    let video: AVMutableVideoComposition
    let audio: AVMutableAudioMix
    let frames: Int

    func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = video
        item.audioMix = audio
        item.audioTimePitchAlgorithm = .spectral
        return item
    }
}

private func frameRange(_ start: Int, _ length: Int) -> CMTimeRange {
    CMTimeRange(start: frameTime(start), duration: frameTime(length))
}

func compose(_ timeline: Timeline, sources: [Source], includeVisualLayers: Bool = true,
             layerPreview: LayerPreviewGeometry? = nil) async throws -> EditComposition {
    let placements = renderLayout(timeline.clips)
    let clipEnd = placements.last?.end ?? 0
    let end = max(clipEnd, timeline.layers.map(\.end).max() ?? 0)
    guard end > 0 else { throw MovieError(L10n.text("タイムラインが空です。")) }

    let asset = AVMutableComposition()
    let video = AVMutableVideoComposition()
    video.renderSize = timeline.output.size
    let color = timeline.output.colorMode
    video.frameDuration = CMTime(value: 1, timescale: Int32(timeline.output.fps))
    video.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
    video.customVideoCompositorClass = color == .hdr ? HDRMovieCompositor.self : MovieCompositor.self
    video.colorPrimaries = color.primaries
    video.colorTransferFunction = color.transfer
    video.colorYCbCrMatrix = color.matrix

    var videoTracks: [AVMutableCompositionTrack] = []
    var audioTracks: [AVMutableCompositionTrack] = []
    for _ in 0..<2 {
        guard let picture = asset.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sound = asset.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MovieError(L10n.text("編集用トラックを作成できません。")) }
        videoTracks.append(picture)
        audioTracks.append(sound)
    }

    let audioParameters = audioTracks.map {
        let parameters = AVMutableAudioMixInputParameters(track: $0)
        parameters.audioTimePitchAlgorithm = .spectral
        return parameters
    }
    let audio = AVMutableAudioMix()
    audio.inputParameters = audioParameters

    let references = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
    var mediaByID: [UUID: MediaSource] = [:]
    var imagesByID: [UUID: CGImage] = [:]
    var stillTiming: MediaSource?
    var pictureLayers: [PictureInstruction.Layer] = []
    var effects: [RenderedVisualLayer] = []
    var instructions: [AVVideoCompositionInstructionProtocol] = []

    func picture(_ id: UUID) throws -> CGImage {
        if let cached = imagesByID[id] { return cached }
        guard let source = references[id], source.isImage else { throw MovieError(L10n.text("画像素材が登録されていません。")) }
        let image = try loadStillImage(source.url, maximumSize: Int(max(video.renderSize.width, video.renderSize.height)))
        imagesByID[id] = image
        return image
    }

    func insertClock(_ frames: Int, at start: Int, into track: AVMutableCompositionTrack) async throws {
        if stillTiming == nil {
            guard let clockURL = Bundle.main.url(forResource: "StillTiming", withExtension: "mp4") else {
                throw MovieError(L10n.text("静止画用のタイミング素材がアプリに見つかりません。"))
            }
            stillTiming = try await MediaSource(url: clockURL)
        }
        guard let clock = stillTiming, clock.frameCount > 0 else {
            throw MovieError(L10n.text("静止画用のタイミング素材が無効です。"))
        }
        var inserted = 0
        while inserted < frames {
            try Task.checkCancellation()
            let count = min(clock.frameCount, frames - inserted)
            let range = CMTimeRange(start: clock.videoRange.start, duration: frameTime(count))
            try track.insertTimeRange(range, of: clock.video, at: frameTime(start + inserted))
            inserted += count
        }
    }

    if includeVisualLayers {
        for layer in timeline.layers {
            try Task.checkCancellation()
            var image: CGImage?
            if layer.kind == .image {
                guard let id = layer.sourceID else { throw MovieError(L10n.text("画像レイヤーに素材が設定されていません。")) }
                image = try picture(id)
            }
            effects.append(RenderedVisualLayer(layer, canvas: video.renderSize, image: image))
        }
    }

    for (index, placement) in placements.enumerated() {
        try Task.checkCancellation()
        let clip = placement.clip
        guard let reference = references[clip.sourceID] else { throw MovieError(L10n.text("素材が登録されていません。")) }

        let lane = index % 2
        let startTime = frameTime(placement.start)
        let track = videoTracks[lane]
        let media: MediaSource?
        let sourceRange: CMTimeRange
        let primary: PictureInstruction.Layer

        if reference.isImage {
            sourceRange = .zero
            // Feed the compositor regular source timestamps, even on an image-only timeline.
            try await insertClock(clip.length, at: placement.start, into: track)
            media = nil
            primary = PictureInstruction.Layer(trackID: track.trackID, transform: .identity, background: nil,
                                               still: try includeVisualLayers ? picture(reference.id) : nil,
                                               fillStill: clip.canvasFill == .blurred)
        } else {
            let movie: MediaSource
            if let cached = mediaByID[clip.sourceID] {
                movie = cached
            } else {
                movie = try await MediaSource(url: reference.url)
                mediaByID[clip.sourceID] = movie
            }
            guard clip.end <= movie.frameCount else {
                throw MovieError(L10n.format("%@ が編集時より短くなっています。素材を再指定してください。", String(describing: reference.name)))
            }

            media = movie
            let sourceStart = CMTime(seconds: clip.sourceStart / 30, preferredTimescale: 600_000)
            let sourceDuration = CMTime(seconds: clip.sourceLength / 30, preferredTimescale: 600_000)
            sourceRange = CMTimeRange(start: movie.videoRange.start + sourceStart, duration: sourceDuration)
            try track.insertTimeRange(sourceRange, of: movie.video, at: startTime)
            track.scaleTimeRange(CMTimeRange(start: startTime, duration: sourceRange.duration), toDuration: frameTime(clip.length))
            let transform = movie.transform(in: video.renderSize)
            let fill = includeVisualLayers && clip.canvasFill == .blurred
                ? movie.transform(in: video.renderSize, fill: true) : transform
            primary = PictureInstruction.Layer(trackID: track.trackID, transform: transform,
                                               background: fill == transform ? nil : fill,
                                               correction: includeVisualLayers ? clip.colorCorrection : nil)
        }

        let bodyStart = placement.start + placement.overlapBefore
        let bodyLength = clip.length - placement.overlapBefore - placement.overlapAfter
        let bodyEnd = bodyStart + bodyLength
        let fadeIn = clip.fadeIn ? min(9, bodyLength / (clip.fadeOut ? 2 : 1)) : 0
        let fadeOut = clip.fadeOut ? min(9, bodyLength - fadeIn) : 0
        let parameters = audioParameters[lane]
        let gain = clip.gain

        if let sourceAudio = media?.audio, let audioRange = media?.audioRange {
            let available = sourceRange.intersection(audioRange)
            if available.duration > .zero {
                let ratio = frameTime(clip.length).seconds / sourceRange.duration.seconds
                let offset = CMTimeMultiplyByFloat64(available.start - sourceRange.start, multiplier: ratio)
                let duration = CMTimeMultiplyByFloat64(available.duration, multiplier: ratio)
                let soundStart = startTime + offset
                try audioTracks[lane].insertTimeRange(available, of: sourceAudio, at: soundStart)
                audioTracks[lane].scaleTimeRange(CMTimeRange(start: soundStart, duration: available.duration),
                                                toDuration: duration)
                if placement.overlapBefore > 0 {
                    parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: gain,
                                             timeRange: frameRange(placement.start, placement.overlapBefore))
                }
                if fadeIn > 0 {
                    parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: gain, timeRange: frameRange(bodyStart, fadeIn))
                }
                let steadyLength = bodyLength - fadeIn - fadeOut
                if steadyLength > 0 {
                    parameters.setVolumeRamp(fromStartVolume: gain, toEndVolume: gain,
                                             timeRange: frameRange(bodyStart + fadeIn, steadyLength))
                }
                if fadeOut > 0 {
                    parameters.setVolumeRamp(fromStartVolume: gain, toEndVolume: 0, timeRange: frameRange(bodyEnd - fadeOut, fadeOut))
                }
                if placement.overlapAfter > 0 {
                    parameters.setVolumeRamp(fromStartVolume: gain, toEndVolume: 0,
                                             timeRange: frameRange(bodyEnd, placement.overlapAfter))
                }
            }
        }

        pictureLayers.append(primary)
        if placement.overlapBefore > 0 {
            let previous = pictureLayers[index - 1]
            instructions.append(PictureInstruction(
                range: frameRange(placement.start, placement.overlapBefore), primary: primary,
                previous: previous, transition: placements[index - 1].clip.transition, effects: effects, layerPreview: layerPreview
            ))
        }
        instructions.append(PictureInstruction(
            range: frameRange(bodyStart, bodyLength), primary: primary,
            fadeIn: frameTime(fadeIn), fadeOut: frameTime(fadeOut), effects: effects, layerPreview: layerPreview
        ))
    }

    if end > clipEnd {
        let track = videoTracks[placements.count % 2]
        try await insertClock(end - clipEnd, at: clipEnd, into: track)
        let black = PictureInstruction.Layer(trackID: track.trackID, transform: .identity,
                                             background: nil, blank: true)
        instructions.append(PictureInstruction(range: frameRange(clipEnd, end - clipEnd),
                                               primary: black, effects: effects, layerPreview: layerPreview))
    }

    for track in videoTracks + audioTracks where track.segments.allSatisfy(\.isEmpty) {
        asset.removeTrack(track)
    }
    audio.inputParameters = audioParameters.filter { parameter in
        asset.track(withTrackID: parameter.trackID) != nil
    }
    video.instructions = instructions
    return EditComposition(asset: asset, video: video, audio: audio, frames: end)
}

func sourceThumbnail(_ source: Source, frame: Int = 30) async throws -> CGImage {
    if source.isImage { return try loadStillImage(source.url, maximumSize: 180) }
    let media = try await MediaSource(url: source.url)
    let generator = AVAssetImageGenerator(asset: media.asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 180, height: 110)
    generator.requestedTimeToleranceBefore = frameTime(3)
    generator.requestedTimeToleranceAfter = frameTime(3)
    let time = media.videoRange.start + frameTime(max(0, min(frame, media.frameCount - 1)))
    return try await generator.image(at: time).image
}

func waveform(_ timeline: Timeline, sources: [Source]) async throws -> [Float] {
    let edit = try await compose(timeline, sources: sources, includeVisualLayers: false)
    let audioTracks = try await edit.asset.loadTracks(withMediaType: .audio)
    guard !audioTracks.isEmpty else { return [0] }

    let sampleRate = 16_000
    let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ])
    output.audioMix = edit.audio
    output.alwaysCopiesSampleData = false
    let reader = try AVAssetReader(asset: edit.asset)
    guard reader.canAdd(output) else { throw MovieError(L10n.text("音声波形を取得できません。")) }
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? MovieError(L10n.text("音声波形を取得できません。")) }
    defer { if reader.status == .reading { reader.cancelReading() } }

    let count = max(1, min(12_000, edit.frames * 2))
    let samplesPerBin = frameTime(edit.frames).seconds * Double(sampleRate) / Double(count)
    var peaks = [Float](repeating: 0, count: count)
    var samples = [Int16]()
    while let sample = output.copyNextSampleBuffer() {
        try Task.checkCancellation()
        let seconds = sample.presentationTimeStamp.seconds
        guard seconds.isFinite, let buffer = sample.dataBuffer else { continue }
        let bytes = CMBlockBufferGetDataLength(buffer)
        let sampleCount = bytes / MemoryLayout<Int16>.stride
        guard sampleCount > 0, bytes.isMultiple(of: MemoryLayout<Int16>.stride) else { continue }

        if samples.count < sampleCount { samples = [Int16](repeating: 0, count: sampleCount) }
        let copied = samples.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
        }
        guard copied == noErr else { throw MovieError(L10n.text("音声波形を取得できません。")) }
        let start = Int((seconds * Double(sampleRate)).rounded())
        var offset = max(0, -start)
        let end = sampleCount / 2
        while offset < end {
            let bin = Int(Double(start + offset) / samplesPerBin)
            if bin >= peaks.count { break }
            let next = min(end, max(offset + 1, Int(ceil(Double(bin + 1) * samplesPerBin)) - start))
            var peak = 0
            for index in (offset * 2)..<(next * 2) {
                peak = max(peak, abs(Int(samples[index])))
            }
            peaks[bin] = max(peaks[bin], Float(peak) / 32768)
            offset = next
        }
    }
    if reader.status == .failed { throw reader.error ?? MovieError(L10n.text("音声波形を取得できません。")) }
    return peaks
}
