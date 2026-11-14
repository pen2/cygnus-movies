import AVFoundation

struct PreparedAudio: @unchecked Sendable {
    let asset: AVAsset
    let track: AVAssetTrack
    let range: CMTimeRange
    let originalStart: CMTime

    func mappedRange(_ original: CMTimeRange) -> CMTimeRange {
        CMTimeRange(start: range.start + original.start - originalStart, duration: original.duration)
    }
}

// Resample before adding timeline gaps. Resampling a 44.1 kHz composition lane
// with a long empty lead-in directly to 48 kHz can shorten that lead-in in
// AVAssetReaderAudioMixOutput. Canonical source tracks avoid that conversion.
actor AudioPreparationCache {
    static let shared = AudioPreparationCache()
    nonisolated let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cygnus-audio-\(UUID().uuidString)", isDirectory: true)

    private struct Key: Hashable {
        let path: String
        let size: Int64
        let modified: Date?
        let trackID: CMPersistentTrackID
    }
    private var tasks: [Key: Task<Void, Never>] = [:]
    private var results: [Key: Result<PreparedAudio, Error>] = [:]

    func prepare(asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange) async throws -> PreparedAudio {
        try Task.checkCancellation()
        let descriptions = try await track.load(.formatDescriptions)
        let rates = descriptions.compactMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate }
        let scale = try await track.load(.naturalTimeScale)
        if !rates.isEmpty, rates.allSatisfy({ abs($0 - 48_000) < 0.01 }), scale == 48_000 {
            return PreparedAudio(asset: asset, track: track, range: range, originalStart: range.start)
        }
        let values = try asset.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = Key(path: asset.url.standardizedFileURL.path, size: Int64(values.fileSize ?? 0),
                      modified: values.contentModificationDate, trackID: track.trackID)
        if tasks[key] == nil, results[key] == nil {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
            tasks[key] = Task.detached(priority: .userInitiated) {
                let result: Result<PreparedAudio, Error>
                do { result = .success(try await prepareSourceAudio(asset: asset, track: track, range: range, to: destination)) }
                catch { result = .failure(error) }
                await self.finish(key, result: result)
            }
        }
        // Cancellation stops this caller promptly without cancelling a conversion
        // another preview/export may also be awaiting.
        while results[key] == nil { try await Task.sleep(for: .milliseconds(25)) }
        try Task.checkCancellation()
        return try results[key]!.get()
    }

    private func finish(_ key: Key, result: Result<PreparedAudio, Error>) {
        tasks[key] = nil
        results[key] = result
    }

    nonisolated func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func prepareSourceAudio(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange,
                                to destination: URL) async throws -> PreparedAudio {
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = range
    let pcm: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
    output.alwaysCopiesSampleData = false
    let writer = try AVAssetWriter(outputURL: destination, fileType: .caf)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
    var completed = false
    defer {
        if reader.status == .reading { reader.cancelReading() }
        if writer.status == .writing { writer.cancelWriting() }
        if !completed { try? FileManager.default.removeItem(at: destination) }
    }
    guard reader.canAdd(output), writer.canAdd(input) else {
        throw MovieError(L10n.text("音声のサンプリング周波数を変換できません。"))
    }
    reader.add(output)
    writer.add(input)
    guard reader.startReading() else { throw reader.error ?? MovieError(L10n.text("音声を読み込めません。")) }
    guard writer.startWriting() else { throw writer.error ?? MovieError(L10n.text("音声を変換できません。")) }
    writer.startSession(atSourceTime: range.start)
    while true {
        try Task.checkCancellation()
        if writer.status == .failed { throw writer.error ?? MovieError(L10n.text("音声を変換できません。")) }
        guard input.isReadyForMoreMediaData else { try await Task.sleep(for: .milliseconds(5)); continue }
        guard let sample = output.copyNextSampleBuffer() else {
            guard reader.status == .completed else { throw reader.error ?? MovieError(L10n.text("音声を読み込めません。")) }
            break
        }
        guard input.append(sample) else { throw writer.error ?? MovieError(L10n.text("音声を変換できません。")) }
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: range.end)
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? MovieError(L10n.text("音声を変換できません。")) }
    let converted = AVURLAsset(url: destination)
    guard let convertedTrack = try await converted.loadTracks(withMediaType: .audio).first else {
        throw MovieError(L10n.text("音声を変換できません。"))
    }
    let convertedRange = try await convertedTrack.load(.timeRange)
    completed = true
    return PreparedAudio(asset: converted, track: convertedTrack, range: convertedRange, originalStart: range.start)
}
