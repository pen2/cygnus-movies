import AVFoundation
import CoreImage
import CoreVideo
import Foundation

final class LayerPreviewGeometry: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (id: UUID, region: CanvasRegion)?

    func set(id: UUID, region: CanvasRegion) { lock.withLock { value = (id, region) } }

    func current() -> (id: UUID, region: CanvasRegion)? { lock.withLock { value } }

    func clear(id: UUID) -> Bool {
        lock.withLock {
            guard value?.id == id else { return false }
            value = nil
            return true
        }
    }

    func reset() { lock.withLock { value = nil } }
}

final class PictureInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    struct Layer {
        let trackID: CMPersistentTrackID
        let transform: CGAffineTransform
        let background: CGAffineTransform?
        var still: CGImage?
        var fillStill = false
        var blank = false
        var correction: ClipColorCorrection?
    }

    let timeRange: CMTimeRange
    let animationRange: CMTimeRange
    let primary: Layer
    let previous: Layer?
    let transition: Transition
    let fadeIn: CMTime
    let fadeOut: CMTime
    let effects: [RenderedVisualLayer]
    let layerPreview: LayerPreviewGeometry?

    init(
        range: CMTimeRange, primary: Layer, previous: Layer? = nil, transition: Transition = .cut,
        fadeIn: CMTime = .zero, fadeOut: CMTime = .zero, effects: [RenderedVisualLayer] = [],
        layerPreview: LayerPreviewGeometry? = nil, animationRange: CMTimeRange? = nil
    ) {
        timeRange = range
        self.animationRange = animationRange ?? range
        self.primary = primary
        self.previous = previous
        self.transition = transition
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.effects = effects
        self.layerPreview = layerPreview
    }

    var enablePostProcessing: Bool { false }
    // Render at the output cadence even when slowed source frames repeat.
    var containsTweening: Bool { true }
    var passthroughTrackID: CMPersistentTrackID { kCMPersistentTrackID_Invalid }
    var requiredSourceTrackIDs: [NSValue]? {
        let overlays = effects.filter { $0.range.intersection(timeRange).duration > .zero }.compactMap(\.videoTrackID)
        return ([primary.trackID, previous?.trackID].compactMap { $0 } + overlays).map { NSNumber(value: $0) }
    }
}

class MovieCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private static let rec709 = CGColorSpace(name: CGColorSpace.itur_709)!
    var colorSpace: CGColorSpace { Self.rec709 }
    var supportsHDRSourceFrames: Bool { false }
    var supportsWideColorSourceFrames: Bool { false }
    private static let bgra = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.bgra }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.bgra }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? PictureInstruction,
                  let target = request.renderContext.newPixelBuffer() else {
                request.finish(with: MovieError(L10n.text("プレビュー用の映像フレームを作成できません。")))
                return
            }

            let bounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(target), height: CVPixelBufferGetHeight(target))
            let black = CIImage(color: .black).cropped(to: bounds)
            func fitted(_ layer: PictureInstruction.Layer) -> CIImage? {
                if layer.blank { return black }
                if let still = layer.still {
                    let image = CIImage(cgImage: still)
                    var background = black
                    if layer.fillStill {
                        background = image.positioned(in: bounds, fill: true)
                            .cropped(to: bounds).clampedToExtent()
                            .applyingGaussianBlur(sigma: min(bounds.width, bounds.height) * 0.028)
                            .cropped(to: bounds).composited(over: black)
                    }
                    return image.positioned(in: bounds).composited(over: background).cropped(to: bounds)
                }
                guard let buffer = request.sourceFrame(byTrackID: layer.trackID) else { return nil }
                let sourceFrame = CIImage(cvPixelBuffer: buffer)
                let frame = layer.correction.map { sourceFrame.corrected($0) } ?? sourceFrame
                // AVFoundation track transforms use top-left coordinates. Core Image uses bottom-left.
                let sourceFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: frame.extent.height)
                let canvasFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
                var background = black
                if let fill = layer.background {
                    background = frame.transformed(by: sourceFlip.concatenating(fill).concatenating(canvasFlip))
                        .cropped(to: bounds).clampedToExtent()
                        .applyingGaussianBlur(sigma: min(bounds.width, bounds.height) * 0.028)
                        .cropped(to: bounds)
                }
                return frame.transformed(by: sourceFlip.concatenating(layer.transform).concatenating(canvasFlip))
                    .composited(over: background).cropped(to: bounds)
            }

            let elapsed = (request.compositionTime - instruction.animationRange.start).seconds
            let duration = instruction.animationRange.duration.seconds
            let incoming = fitted(instruction.primary)
            let result: CIImage
            if let previous = instruction.previous, let outgoing = fitted(previous), let incoming {
                let fraction = min(1, max(0, elapsed / duration))
                if instruction.transition == .swipe || instruction.transition == .swipeRight {
                    let width = bounds.width * (instruction.transition == .swipeRight ? -1 : 1)
                    result = incoming.transformed(by: .init(translationX: (fraction - 1) * width, y: 0))
                        .composited(over: outgoing.transformed(by: .init(translationX: fraction * width, y: 0)))
                } else {
                    result = dissolve(from: outgoing, to: incoming, fraction: fraction)
                }
            } else if let frame = incoming ?? instruction.previous.flatMap(fitted) {
                var opacity = 1.0
                if instruction.fadeIn > .zero {
                    opacity = min(opacity, elapsed / instruction.fadeIn.seconds)
                }
                if instruction.fadeOut > .zero {
                    opacity = min(opacity, (duration - elapsed) / instruction.fadeOut.seconds)
                }
                result = opacity < 1 ? dissolve(from: black, to: frame, fraction: max(0, opacity)) : frame
            } else {
                result = black
            }
            var composite = result.composited(over: black)
            let preview = instruction.layerPreview?.current()
            for effect in instruction.effects where effect.range.containsTime(request.compositionTime) {
                let region = preview?.id == effect.layer.id ? preview?.region : nil
                let frame = effect.videoTrackID.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
                composite = effect.applying(to: composite, bounds: bounds, at: request.compositionTime, region: region, videoFrame: frame)
            }
            context.render(composite, to: target, bounds: bounds, colorSpace: colorSpace)
            request.finish(withComposedVideoFrame: target)
        }
    }

    private func dissolve(from: CIImage, to: CIImage, fraction: Double) -> CIImage {
        from.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: to, kCIInputTimeKey: fraction])
    }
}

private extension CIImage {
    func corrected(_ correction: ClipColorCorrection) -> CIImage {
        var image = self
        if correction.temperature != 6500 || correction.tint != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: correction.temperature, y: correction.tint)
            ])
        }
        if correction.brightness != 0 || correction.saturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: correction.brightness,
                kCIInputSaturationKey: correction.saturation
            ])
        }
        if correction.gamma != 1 {
            image = image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": correction.gamma])
        }
        if correction.hue != 0 {
            image = image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: correction.hue * .pi / 180])
        }
        return image
    }
}


final class HDRMovieCompositor: MovieCompositor, @unchecked Sendable {
    private static let formats = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_32BGRA]
    override var supportsHDRSourceFrames: Bool { true }
    override var supportsWideColorSourceFrames: Bool { true }
    private static let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
    override var colorSpace: CGColorSpace { Self.hlg }
    override var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: Self.formats]
    }
    override var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
    }
}
