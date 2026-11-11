import AVFoundation
import CoreVideo
import VideoToolbox

enum EncodingMode {
    case hardware, softwareDisabled, softwareFallback

    var title: String {
        switch self {
        case .hardware: L10n.text("ハードウェアエンコード")
        case .softwareDisabled: L10n.text("ソフトウェアエンコード（設定でオフ）")
        case .softwareFallback: L10n.text("ソフトウェアエンコード（ハードウェア利用不可）")
        }
    }
}

enum EncodingPreferences {
    static let hardwareKey = "useHardwareEncoding"
    static var useHardware: Bool { UserDefaults.standard.object(forKey: hardwareKey) as? Bool ?? true }
}

private struct HardwareEncodingFailure: Error {}

func exportMovie(
    _ timeline: Timeline, sources: [Source], to destination: URL,
    useHardware: Bool = true, encoderSelected: @Sendable (EncodingMode) async -> Void = { _ in },
    progress: @Sendable (Double) async -> Void
) async throws {
    let edit = try await compose(timeline, sources: sources)
    if useHardware {
        do {
            try await writeMovie(edit, output: timeline.output, to: destination, mode: .hardware,
                                 encoderSelected: encoderSelected, progress: progress)
            return
        } catch is HardwareEncodingFailure {
            try Task.checkCancellation()
        }
    }
    try await writeMovie(edit, output: timeline.output, to: destination,
                         mode: useHardware ? .softwareFallback : .softwareDisabled,
                         encoderSelected: encoderSelected, progress: progress)
}

private func writeMovie(
    _ edit: EditComposition, output: OutputSettings, to destination: URL, mode: EncodingMode,
    encoderSelected: @Sendable (EncodingMode) async -> Void,
    progress: @Sendable (Double) async -> Void
) async throws {
    let hardware = mode == .hardware
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".cygnus-\(UUID().uuidString)")
        .appendingPathExtension(output.container.rawValue)
    let reader = try AVAssetReader(asset: edit.asset)
    let writer = try AVAssetWriter(outputURL: temporary, fileType: output.container.fileType)
    defer {
        if reader.status == .reading { reader.cancelReading() }
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: temporary)
    }

    func writerError(_ error: Error) -> Error { hardware ? HardwareEncodingFailure() : error }
    let color = output.colorMode
    let picture = AVAssetReaderVideoCompositionOutput(
        videoTracks: try await edit.asset.loadTracks(withMediaType: .video),
        videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: color == .hdr
                        ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA]
    )
    picture.videoComposition = edit.video
    picture.alwaysCopiesSampleData = false
    var compression: [String: Any] = [
        AVVideoAverageBitRateKey: output.bitRate,
        AVVideoExpectedSourceFrameRateKey: output.fps
    ]
    if color == .hdr { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel }
    let settings: [String: Any] = [
        AVVideoCodecKey: output.videoCodec.type,
        AVVideoWidthKey: Int(output.size.width),
        AVVideoHeightKey: Int(output.size.height),
        AVVideoEncoderSpecificationKey: hardware
            ? [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
            : [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false],
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: color.primaries,
            AVVideoTransferFunctionKey: color.transfer,
            AVVideoYCbCrMatrixKey: color.matrix
        ],
        AVVideoCompressionPropertiesKey: compression
    ]
    guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
        throw writerError(MovieError(L10n.text("このMacでは選択した映像形式に書き出せません。")))
    }
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    var channels = [(picture as AVAssetReaderOutput, videoInput)]

    let audioTracks = try await edit.asset.loadTracks(withMediaType: .audio)
    if !audioTracks.isEmpty, output.audioFormat != .none {
        let sound = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2
        ])
        sound.audioMix = edit.audio
        sound.alwaysCopiesSampleData = false
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings(output.audioFormat))
        channels.append((sound, audioInput))
    }

    for (output, input) in channels {
        let track = input.mediaType == .video ? L10n.text("映像") : L10n.text("音声")
        guard reader.canAdd(output) else { throw MovieError(L10n.format("%@の読み出し形式に対応していません。", String(describing: track))) }
        guard writer.canAdd(input) else { throw MovieError(L10n.format("%@の書き出し形式に対応していません。", String(describing: track))) }
        reader.add(output)
        writer.add(input)
    }
    guard reader.startReading() else { throw reader.error ?? MovieError(L10n.text("映像の読み出しを開始できません。")) }
    guard writer.startWriting() else { throw writerError(writer.error ?? MovieError(L10n.text("ファイルへの書き込みを開始できません。"))) }
    writer.startSession(atSourceTime: .zero)

    var finished = Set<Int>()
    var lastProgress = 0.0
    var reportedEncoder = false
    while finished.count < channels.count {
        try Task.checkCancellation()
        if writer.status == .failed { throw writerError(writer.error ?? MovieError(L10n.text("書き込みに失敗しました。"))) }
        if reader.status == .failed { throw reader.error ?? MovieError(L10n.text("映像の読み出しに失敗しました。")) }

        var advanced = false
        for index in channels.indices where !finished.contains(index) {
            let (output, input) = channels[index]
            guard input.isReadyForMoreMediaData else { continue }
            advanced = true
            if let sample = output.copyNextSampleBuffer() {
                guard input.append(sample) else { throw writerError(writer.error ?? MovieError(L10n.text("サンプルを書き込めません。"))) }
                if index == 0 {
                    if !reportedEncoder {
                        reportedEncoder = true
                        await encoderSelected(mode)
                    }
                    let ratio = min(0.99, sample.presentationTimeStamp.seconds / frameTime(edit.frames).seconds)
                    if ratio >= lastProgress + 0.01 {
                        lastProgress = ratio
                        await progress(ratio)
                    }
                }
            } else {
                if reader.status == .failed { throw reader.error ?? MovieError(L10n.text("映像の読み出しに失敗しました。")) }
                input.markAsFinished()
                finished.insert(index)
            }
        }
        if !advanced { try await Task.sleep(for: .milliseconds(5)) }
    }

    writer.endSession(atSourceTime: frameTime(edit.frames))
    await writer.finishWriting()
    guard writer.status == .completed else { throw writerError(writer.error ?? MovieError(L10n.text("ファイルを確定できません。"))) }
    try Task.checkCancellation()
    try FileManager.default.moveItem(at: temporary, to: destination)
    await progress(1)
}


private func audioSettings(_ format: AudioOutput) -> [String: Any] {
    var settings: [String: Any] = [AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2]
    switch format {
    case .aac, .none:
        settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
        settings[AVEncoderBitRateKey] = 192_000
    case .alac:
        settings[AVFormatIDKey] = kAudioFormatAppleLossless
        settings[AVEncoderBitDepthHintKey] = 16
    case .pcm:
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMBitDepthKey] = 16
        settings[AVLinearPCMIsBigEndianKey] = false
        settings[AVLinearPCMIsFloatKey] = false
        settings[AVLinearPCMIsNonInterleaved] = false
    }
    return settings
}
