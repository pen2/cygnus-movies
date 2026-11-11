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
    case blur, mosaic, text, rectangle, image

    var title: String {
        switch self {
        case .blur: L10n.text("ぼかし")
        case .mosaic: L10n.text("モザイク")
        case .text: L10n.text("テキスト")
        case .rectangle: L10n.text("矩形")
        case .image: L10n.text("画像")
        }
    }

    var symbol: String {
        switch self {
        case .blur: "drop"
        case .mosaic: "square.grid.3x3.fill"
        case .text: "textformat"
        case .rectangle: "rectangle.fill"
        case .image: "photo"
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

    static let white = LayerColor(red: 1, green: 1, blue: 1)
    static let black = LayerColor(red: 0, green: 0, blue: 0)
    static let rectangleDefault = LayerColor(red: 0.43, green: 0.85, blue: 0.81)

    var isValid: Bool { [red, green, blue].allSatisfy { (0...1).contains($0) } }
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
    var intensity = 0.5
    var text = L10n.text("テキスト")
    var textSize = 0.075
    var outline = 0.06
    var fontSizePoints: Double?
    var outlinePixels: Double?
    var textColor: LayerColor?
    var outlineColor: LayerColor?
    var rectangleColor: LayerColor?
    var rectangleOpacity: Double?
    var textAlignment: LayerTextAlignment?
    var shadow = false
    var sourceID: UUID?
    var fontFamily: String?
    var regularWeight: Bool?
    var entrance: Transition?
    var exit: Transition?
    var animationSpan: AnimationSpan?

    var animationStart: Int { start + (animationSpan?.offset ?? 0) }
    var animationLength: Int { animationSpan?.length ?? (end - start) }

    var title: String { kind == .text && !text.isEmpty ? text : kind.title }

    static let fontSizeRange = 1.0...2160.0
    static let outlineRange = 0.0...256.0

    func textPoints(in canvas: CGSize) -> Double {
        fontSizePoints ?? min(canvas.width, canvas.height) * textSize
    }

    func strokePixels(in canvas: CGSize) -> Double {
        outlinePixels ?? textPoints(in: canvas) * outline / 2
    }

    var isValid: Bool {
        start >= 0 && end > start && end <= Self.maximumEnd
            && region.isValid && (0...1).contains(intensity)
            && (0.01...0.25).contains(textSize) && (0...0.2).contains(outline)
            && (fontSizePoints.map(Self.fontSizeRange.contains) ?? true)
            && (outlinePixels.map(Self.outlineRange.contains) ?? true)
            && (textColor?.isValid ?? true) && (outlineColor?.isValid ?? true)
            && (rectangleColor?.isValid ?? true) && (rectangleOpacity.map { (0...1).contains($0) } ?? true)
            && (animationSpan.map { (-30_000_000...0).contains($0.offset) && (1...30_000_000).contains($0.length) } ?? true)
            && text.count <= 500 && (fontFamily?.count ?? 0) <= 150
    }
}
