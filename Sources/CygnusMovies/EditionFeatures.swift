import SwiftUI
import CoreImage

/// Values owned by an edition and serialized with the edited object.
public struct EffectParameters: Codable, Equatable {
    public var values: [String: Double] = [:]
    public init() {}
}

public protocol MovieEffects {
    var shapes: [(id: String, title: String)] { get }
    @MainActor func hitPath(shape: String, parameters: EffectParameters?, rect: CGRect, scale: CGFloat) -> Path
    func symbol(for shape: String) -> String
    func title(for shape: String) -> String
    @MainActor func clipInspector(parameters: Binding<EffectParameters?>, transition: Binding<String>, frames: Binding<Int>, maximum: Int, video: Bool) -> AnyView
    @MainActor func shapeInspector(parameters: Binding<EffectParameters?>, shape: Binding<String?>) -> AnyView
    @MainActor func guide(shape: String?, parameters: Binding<EffectParameters?>, frame: CGRect, canvas: CGSize, scale: CGFloat) -> AnyView
    @MainActor func transitionPicker(_ title: String, selection: Binding<String>) -> AnyView
    func layerTransition(_ id: String, overlay: CIImage, progress: Double, bounds: CGRect) -> CIImage?
    @MainActor func mediaInspector(parameters: Binding<EffectParameters?>) -> AnyView
    func decorateMedia(_ image: CIImage, parameters: EffectParameters) -> CIImage
    func artwork(shape: String, parameters: EffectParameters?, size: CGSize, fill: CGColor) -> CGImage?
    func foreground(_ image: CIImage, parameters: EffectParameters, canvas: CGRect) -> CIImage
    func transition(_ id: String, from: CIImage, to: CIImage, progress: Double, bounds: CGRect) -> CIImage?
}

public protocol ExportController {
    @MainActor func settings() -> AnyView
    func acquire() async throws
    func release() async
    @MainActor func started()
    @MainActor func estimate(elapsed: TimeInterval, fraction: Double) -> String
    @MainActor func completed(success: Int, failed: Int, canceled: Int, show: @escaping @MainActor () -> Void)
}

/// Set by the application entry point before any rendering starts.
public enum MovieExtensions {
    public static var capture: MovieCapture?
    public static var effects: MovieEffects?
    public static var exports: ExportController?
}

public struct AudioSegment: Codable, Equatable {
    public var sourceFrame: Double
    public var rate: Double
    public var envelopeOffset: Int
    public let envelopeLength: Int
    public let fadeIn: Int
    public let fadeOut: Int
    public var overlapIn = 0
    public var overlapOut = 0
    public let originatingClip: UUID?
    public init(sourceFrame: Double = 0, rate: Double = 1, envelopeOffset: Int = 0, envelopeLength: Int, fadeIn: Int = 0, fadeOut: Int = 0, originatingClip: UUID? = nil) {
        self.sourceFrame = sourceFrame
        self.rate = rate
        self.envelopeOffset = envelopeOffset
        self.envelopeLength = envelopeLength
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.originatingClip = originatingClip
    }
}

import AVFoundation

public protocol AudioEditing {
    func segment(for placement: Placement?, source: Source, detached: Bool, maximumLength: Int) -> AudioSegment?
    @MainActor func clipInspector(sources: [Source], separated: Bool, select: @escaping (Source?) -> Void) -> AnyView
    func sourceFrames(_ url: URL) async throws -> Int?
    func insert(_ segment: AudioSegment, url: URL, start: Int, length: Int, gain: Float, composition: AVMutableComposition) async throws -> AVMutableAudioMixInputParameters?
    @MainActor func monitorVolume(player: AVPlayer) -> AnyView
    @MainActor func controls(beginPlayback: @escaping () -> Void, stopPlayback: @escaping () -> Void, register: @escaping (URL) -> Void) -> AnyView
}

public extension MovieExtensions {
    static var audio: AudioEditing?
}

public protocol MovieCapture {
    @MainActor func panel(register: @escaping @MainActor (URL) async throws -> Void) -> AnyView
}
