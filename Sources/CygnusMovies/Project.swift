import Foundation
import AVFoundation

enum Transition: String, Codable, CaseIterable {
    case cut, dissolve, swipe, swipeRight

    var title: String {
        switch self {
        case .cut: L10n.text("なし")
        case .dissolve: L10n.text("クロスディゾルブ")
        case .swipe: L10n.text("左からスワイプ")
        case .swipeRight: L10n.text("右からスワイプ")
        }
    }
}

enum Container: String, Codable, CaseIterable {
    case mp4, mov
    var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

enum Codec: String, Codable, CaseIterable {
    case h264, hevc
    var title: String { self == .h264 ? "H.264" : "H.265 / HEVC" }
    var type: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
}

enum AspectRatio: String, CaseIterable {
    case landscape, portrait, square
    var ratio: Double {
        switch self {
        case .landscape: 16.0 / 9
        case .portrait: 9.0 / 16
        case .square: 1
        }
    }

    var title: String {
        switch self {
        case .landscape: L10n.text("16:9 横")
        case .portrait: L10n.text("9:16 縦")
        case .square: L10n.text("1:1 正方形")
        }
    }
}

enum FrameRate: Int, Codable, CaseIterable {
    case fps30 = 30, fps60 = 60
}

enum OutputColor: String, Codable, CaseIterable {
    case sdr, hdr
    var title: String { self == .hdr ? "HDR (HLG)" : "SDR (Rec.709)" }
    var primaries: String { self == .hdr ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2 }
    var transfer: String { self == .hdr ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2 }
    var matrix: String { self == .hdr ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2 }
}

enum AudioOutput: String, Codable, CaseIterable {
    case aac, alac, pcm, none

    var title: String {
        switch self {
        case .aac: "AAC"
        case .alac: "Apple Lossless"
        case .pcm: L10n.text("リニアPCM")
        case .none: L10n.text("音声なし")
        }
    }
}

struct OutputSettings: Codable, Equatable {
    var portrait = false
    var ultraHD = false
    var container = Container.mp4
    var codec = Codec.h264
    var square: Bool?
    var frameRate: FrameRate?
    var color: OutputColor?
    var audio: AudioOutput?

    var aspectRatio: AspectRatio {
        get { square == true ? .square : portrait ? .portrait : .landscape }
        set {
            portrait = newValue == .portrait
            square = newValue == .square ? true : nil
        }
    }

    var size: CGSize {
        let width = ultraHD ? 3840 : 1920
        let height = ultraHD ? 2160 : 1080
        switch aspectRatio {
        case .landscape: return CGSize(width: width, height: height)
        case .portrait: return CGSize(width: height, height: width)
        case .square: return CGSize(width: height, height: height)
        }
    }

    var fps: Int { (frameRate ?? .fps30).rawValue }
    var colorMode: OutputColor { color ?? .sdr }
    var videoCodec: Codec { colorMode == .hdr ? .hevc : codec }
    var audioOptions: [AudioOutput] { container == .mov ? AudioOutput.allCases : [.aac, .none] }
    var audioFormat: AudioOutput {
        guard let audio, audioOptions.contains(audio) else { return .aac }
        return audio
    }

    var bitRate: Int {
        let base: Int
        if ultraHD { base = videoCodec == .h264 ? 45_000_000 : 28_000_000 }
        else { base = videoCodec == .h264 ? 12_000_000 : 8_000_000 }
        return fps == 60 ? base * 3 / 2 : base
    }
}

struct Source: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    var frames: Int
    var hiddenFromLibrary: Bool?
    var stillImage: Bool?
    var videoInfo: SourceVideoInfo?
    var isImage: Bool { stillImage == true }
    static let maxImageFrames = 30 * 60 * 60
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

struct SourceVideoInfo: Codable, Equatable {
    let width: Double
    let height: Double
    let fps: Double

    var isValid: Bool { width.isFinite && height.isFinite && fps.isFinite && width > 0 && height > 0 && fps > 0 }

    var closestOutput: AutomaticOutput {
        let aspect = AspectRatio.allCases.min {
            abs(log(width / height / $0.ratio)) < abs(log(width / height / $1.ratio))
        } ?? .landscape
        let shortEdge = min(width, height)
        return AutomaticOutput(ultraHD: abs(shortEdge - 2160) < abs(shortEdge - 1080),
                               aspect: aspect.rawValue, fps: abs(fps - 60) < abs(fps - 30) ? .fps60 : .fps30)
    }
}

struct AutomaticOutput: Codable, Equatable {
    let ultraHD: Bool
    let aspect: String
    let fps: FrameRate

    func apply(to timeline: inout Timeline) {
        timeline.output.ultraHD = ultraHD
        timeline.output.aspectRatio = AspectRatio(rawValue: aspect) ?? .landscape
        timeline.output.frameRate = fps
        timeline.outputOrigin = .automatic
    }
}

enum OutputOrigin: String, Codable { case awaitingSource, automatic, manual }

struct ClipColorCorrection: Codable, Equatable {
    var brightness = 0.0
    var temperature = 6500.0
    var tint = 0.0
    var gamma = 1.0
    var saturation = 1.0
    var hue = 0.0

    var isValid: Bool {
        (-1...1).contains(brightness) && (2000...12000).contains(temperature)
            && (-150...150).contains(tint) && (0.1...4).contains(gamma)
            && (0...2).contains(saturation) && (-180...180).contains(hue)
    }
}

struct Clip: Identifiable, Codable, Equatable {
    var id = UUID()
    var sourceID: UUID
    var start = 0
    var end: Int
    var fadeIn = false
    var fadeOut = false
    var transition = Transition.cut
    var volume: Double?
    var muted: Bool?
    var canvasFill: CanvasFill?
    var continuationID: UUID?
    var speed: Double?
    var colorCorrection: ClipColorCorrection?
    // Fractional source frame boundaries preserve cuts in slowed footage.
    var sourceIn: Double?
    var sourceOut: Double?
    var timelineFrames: Int?
    var gain: Float { muted == true ? 0 : Float(min(1, max(0, volume ?? 1))) }
    static let speedRange = 0.1...8.0
    var playbackRate: Double { speed ?? 1 }
    var sourceStart: Double { sourceIn ?? Double(start) }
    var sourceEnd: Double { sourceOut ?? Double(end) }
    var sourceLength: Double { sourceEnd - sourceStart }
    var length: Int { timelineFrames ?? max(1, Int((sourceLength / playbackRate).rounded())) }
    var sourceFramesPerTimelineFrame: Double { sourceLength / Double(length) }

    mutating func setSourceRange(start: Double, end: Double, duration: Int? = nil) {
        let start = abs(start - start.rounded()) < 0.0000001 ? start.rounded() : start
        let end = abs(end - end.rounded()) < 0.0000001 ? end.rounded() : end
        self.start = Int(floor(start))
        self.end = Int(ceil(end))
        sourceIn = start == Double(self.start) ? nil : start
        sourceOut = end == Double(self.end) ? nil : end
        timelineFrames = duration
    }
}

struct Timeline: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var clips: [Clip] = []
    var output = OutputSettings()
    var outputOrigin: OutputOrigin? = .awaitingSource
    var showWaveform: Bool? // Legacy project field; waveform display is now an app preference.
    // Stored bottom to top so each layer affects the layers below it.
    var visualLayers: [VisualLayer]?
    var layers: [VisualLayer] {
        get { visualLayers ?? [] }
        set { visualLayers = newValue.isEmpty ? nil : newValue }
    }

    var hasContent: Bool { !clips.isEmpty || !layers.isEmpty }
}

struct Project: Codable, Equatable {
    var version = 1
    var name: String?
    var numberTimelines: Bool?
    var automaticOutput: AutomaticOutput?
    var sources: [Source] = []
    var timelines = [Timeline(name: L10n.text("タイムライン 1"))]

    func validate() throws {
        guard version == 1, !timelines.isEmpty,
              Set(sources.map(\.id)).count == sources.count,
              Set(timelines.map(\.id)).count == timelines.count,
              sources.allSatisfy({ $0.path.hasPrefix("/") && (1...30_000_000).contains($0.frames)
                  && ($0.videoInfo?.isValid ?? true) }),
              automaticOutput.map({ AspectRatio(rawValue: $0.aspect) != nil }) ?? true
        else { throw MovieError(L10n.text("このプロジェクト形式には対応していません。")) }

        let lengths = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.frames) })
        let images = Set(sources.filter(\.isImage).map(\.id))
        for timeline in timelines {
            guard Set(timeline.clips.map(\.id)).count == timeline.clips.count,
                  Set(timeline.layers.map(\.id)).count == timeline.layers.count,
                  timeline.layers.allSatisfy({ layer in
                      layer.isValid && (layer.kind != .image || layer.sourceID.map(images.contains) == true)
                  }),
                  timeline.clips.allSatisfy({
                      guard let length = lengths[$0.sourceID] else { return false }
                      return $0.start >= 0 && $0.start < $0.end && $0.end <= length
                          && $0.sourceStart.isFinite && $0.sourceEnd.isFinite
                          && $0.sourceStart >= Double($0.start) && $0.sourceEnd <= Double($0.end)
                          && $0.sourceStart < $0.sourceEnd && Clip.speedRange.contains($0.playbackRate)
                          && ($0.timelineFrames.map { (1...300_000_000).contains($0) } ?? true)
                          && ($0.colorCorrection?.isValid ?? true)
                  })
            else { throw MovieError(L10n.text("プロジェクト内のクリップ情報が無効です。")) }
        }
    }
}

struct Placement {
    let clip: Clip
    let start: Int
    let overlapBefore: Int
    let overlapAfter: Int

    var end: Int { start + clip.length }
}

private struct ClipGroup {
    var combined: Clip
    var fragments: [Clip]
}

private func clipGroups(_ clips: [Clip]) -> [ClipGroup] {
    var groups: [ClipGroup] = []
    for clip in clips {
        if let previous = groups.last?.combined, let id = clip.continuationID, id == previous.continuationID,
           clip.sourceID == previous.sourceID, abs(clip.sourceStart - previous.sourceEnd) < 0.000001,
           previous.transition == .cut, !previous.fadeOut, !clip.fadeIn,
           clip.gain == previous.gain, clip.canvasFill == previous.canvasFill,
           clip.playbackRate == previous.playbackRate, clip.colorCorrection == previous.colorCorrection {
            let index = groups.count - 1
            groups[index].combined.timelineFrames = previous.length + clip.length
            groups[index].combined.end = clip.end
            groups[index].combined.sourceOut = clip.sourceOut
            groups[index].combined.fadeOut = clip.fadeOut
            groups[index].combined.transition = clip.transition
            groups[index].fragments.append(clip)
        } else {
            groups.append(ClipGroup(combined: clip, fragments: [clip]))
        }
    }
    return groups
}

// Adjacent pieces of an unmodified blade cut keep the original transition and fades.
func renderLayout(_ clips: [Clip]) -> [Placement] {
    placementLayout(clipGroups(clips).map(\.combined))
}

func layout(_ clips: [Clip]) -> [Placement] {
    let groups = clipGroups(clips)
    return zip(groups, placementLayout(groups.map(\.combined))).flatMap { group, placement in
        var cursor = placement.start
        return group.fragments.map { clip in
            let start = cursor
            let end = start + clip.length
            cursor = end
            let before = max(0, min(end, placement.start + placement.overlapBefore) - start)
            let after = max(0, end - max(start, placement.end - placement.overlapAfter))
            return Placement(clip: clip, start: start, overlapBefore: before, overlapAfter: after)
        }
    }
}

private func placementLayout(_ clips: [Clip]) -> [Placement] {
    let overlaps = clips.indices.map { index in
        guard index + 1 < clips.count, clips[index].transition != .cut else { return 0 }
        return min(9, clips[index].length / 3, clips[index + 1].length / 3)
    }
    var position = 0
    return clips.indices.map { index in
        let placement = Placement(
            clip: clips[index], start: position,
            overlapBefore: index > 0 ? overlaps[index - 1] : 0,
            overlapAfter: overlaps[index]
        )
        position = placement.end - placement.overlapAfter
        return placement
    }
}

func frameTime(_ frames: Int) -> CMTime { CMTime(value: Int64(frames), timescale: 30) }

func timecode(_ frames: Int, fps: Int = 30) -> String {
    let seconds = frames / fps
    return String(format: "%02d:%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60, frames % fps)
}

struct MovieError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
