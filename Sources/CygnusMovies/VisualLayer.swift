import CoreGraphics
import Foundation

enum CanvasFill: String, Codable, CaseIterable {
    case black, blurred

    var title: String {
        switch self {
        case .black: L10n.text("黒で埋める")
        case .blurred: L10n.text("拡大してぼかす")
        }
    }
}

enum LayerKind: String, Codable, CaseIterable {
    case blur, mosaic, text, rectangle, image, video

    var title: String {
        switch self {
        case .blur: L10n.text("ぼかし")
        case .mosaic: L10n.text("モザイク")
        case .text: L10n.text("テキスト")
        case .rectangle: L10n.text("矩形")
        case .image: L10n.text("画像")
        case .video: L10n.text("動画")
        }
    }

    var symbol: String {
        switch self {
        case .blur: "drop"
        case .mosaic: "square.grid.3x3.fill"
        case .text: "textformat"
        case .rectangle: "rectangle.fill"
        case .image: "photo"
        case .video: "film"
        }
    }
}

struct CanvasRegion: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var isValid: Bool {
        width >= 0.02 && height >= 0.02 && x >= 0 && y >= 0
            && x + width <= 1.000001 && y + height <= 1.000001
    }

    func contained() -> CanvasRegion {
        let width = min(1, max(0.02, width))
        let height = min(1, max(0.02, height))
        return CanvasRegion(x: min(1 - width, max(0, x)), y: min(1 - height, max(0, y)),
                            width: width, height: height)
    }

    func pixels(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }
}

struct LayerColor: Codable, Equatable {
    let red: Double
    let green: Double
    let blue: Double

    static let preferenceKey = "shapeDefaultRGB"
    static let defaultRGB = 0xffffff
    static func fromRGB(_ value: Int) -> Self {
        Self(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
             blue: Double(value & 255) / 255)
    }
    static let white = LayerColor(red: 1, green: 1, blue: 1)
    static let black = LayerColor(red: 0, green: 0, blue: 0)
    static let rectangleDefault = LayerColor(red: 0.43, green: 0.85, blue: 0.81)

    var isValid: Bool { [red, green, blue].allSatisfy { (0...1).contains($0) } }
}

struct MediaCrop: Codable, Equatable {
    var left = 0, right = 0, top = 0, bottom = 0
    var isValid: Bool {
        [left, right, top, bottom].allSatisfy { (0...99).contains($0) }
            && left + right < 100 && top + bottom < 100
    }
    func rect(in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + extent.width * Double(left) / 100,
               y: extent.minY + extent.height * Double(bottom) / 100,
               width: extent.width * Double(100 - left - right) / 100,
               height: extent.height * Double(100 - top - bottom) / 100)
    }
}

enum LayerTextAlignment: String, Codable, CaseIterable {
    case left, center, right

    var title: String {
        switch self {
        case .left: L10n.text("左揃え")
        case .center: L10n.text("中央揃え")
        case .right: L10n.text("右揃え")
        }
    }
}

struct VisualLayer: Identifiable, Codable, Equatable {
    static let maximumEnd = 30_000_000
    struct AnimationSpan: Codable, Equatable {
        let offset: Int
        let length: Int
    }
    var id = UUID()
    var kind: LayerKind
    var start: Int
    var end: Int
    var region: CanvasRegion
    var sound: AudioSegment?
    func fits(sourceFrames: Int) -> Bool {
        let offset = sound?.sourceFrame ?? Double(videoSourceStart ?? 0)
        let rate = sound?.rate ?? 1
        return offset.isFinite && offset >= 0 && (0.001...1000).contains(rate) && offset + Double(end - start) * rate <= Double(sourceFrames) + 0.000001
    }
    var artworkID: String?
    var effectParameters: EffectParameters?
    var intensity = 0.5
    var text = L10n.text("テキスト")
    var textSize = 0.075
    var outline = 0.06
    var fontSizePoints: Double?
    var outlinePixels: Double?
    var textColor: LayerColor?
    var outlineColor: LayerColor?
    var rectangleColor: LayerColor?
    var mediaCrop: MediaCrop?
    var rectangleOpacity: Double?
    var textAlignment: LayerTextAlignment?
    var shadow = false
    var sourceID: UUID?
    var videoSourceStart: Int?
    var videoVolume: Double?
    var videoMuted: Bool?
    var fontFamily: String?
    var regularWeight: Bool?
    var usesEndpoints: Bool { artworkID == "line" || artworkID == "arrow" }
    // Older documents store endpoints relative to their layer bounds. Convert on edit.
    var editableParameters: EffectParameters? {
        guard usesEndpoints else { return effectParameters }
        var result = effectParameters ?? EffectParameters()
        for (key, origin, scale, fallback) in [("x1",region.x,region.width,0.0),("y1",region.y,region.height,0.0),
                                               ("x2",region.x,region.width,1.0),("y2",region.y,region.height,1.0)] {
            result.values[key] = origin + scale * (result.values[key] ?? fallback)
        }
        return result
    }

    mutating func setEditableParameters(_ value: EffectParameters?) {
        effectParameters = value
        if usesEndpoints { region = CanvasRegion(x:0,y:0,width:1,height:1) }
    }

    var entranceEffect: String?
    var exitEffect: String?
    var entrance: Transition?
    var exit: Transition?
    var animationSpan: AnimationSpan?

    var animationStart: Int { start + (animationSpan?.offset ?? 0) }
    var animationLength: Int { animationSpan?.length ?? (end - start) }

    var displayKind: String {
        if sound != nil { return L10n.text("音声") }
        if let artworkID, let effects = MovieExtensions.effects { return effects.title(for: artworkID) }
        return kind.title
    }
    var title: String { kind == .text && !text.isEmpty ? text : displayKind }

    static let fontSizeRange = 1.0...2160.0
    static let outlineRange = 0.0...256.0

    func textPoints(in canvas: CGSize) -> Double {
        fontSizePoints ?? min(canvas.width, canvas.height) * textSize
    }

    func strokePixels(in canvas: CGSize) -> Double {
        outlinePixels ?? textPoints(in: canvas) * outline / 2
    }

    var isValid: Bool {
        (sound.map { abs(Double($0.envelopeOffset)) <= 300_000_000 && (1...30_000_000).contains($0.envelopeLength) && (0...90).contains($0.fadeIn) && (0...90).contains($0.fadeOut) && (0...90).contains($0.overlapIn) && (0...90).contains($0.overlapOut) } ?? true)
            && start >= 0 && end > start && end <= Self.maximumEnd
            && (mediaCrop?.isValid ?? true) && region.isValid && (0...1).contains(intensity)
            && (0.01...0.25).contains(textSize) && (0...0.2).contains(outline)
            && (fontSizePoints.map(Self.fontSizeRange.contains) ?? true)
            && (outlinePixels.map(Self.outlineRange.contains) ?? true)
            && (textColor?.isValid ?? true) && (outlineColor?.isValid ?? true)
            && (rectangleColor?.isValid ?? true) && (rectangleOpacity.map { (0...1).contains($0) } ?? true)
            && (animationSpan.map { (-30_000_000...0).contains($0.offset) && (1...30_000_000).contains($0.length) } ?? true)
            && text.count <= 500 && (fontFamily?.count ?? 0) <= 150
            && (videoSourceStart.map { $0 >= 0 && $0 <= Self.maximumEnd } ?? true)
            && (videoVolume.map { (0...1).contains($0) } ?? true)
    }
}
