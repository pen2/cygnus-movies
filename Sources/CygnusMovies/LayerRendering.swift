import AppKit
import AVFoundation

import CoreImage
import CoreText

struct RenderedVisualLayer {
    let layer: VisualLayer
    let range: CMTimeRange
    private let artwork: CIImage?

    init(_ layer: VisualLayer, canvas: CGSize, image: CGImage? = nil) {
        self.layer = layer
        range = CMTimeRange(start: frameTime(layer.start), duration: frameTime(layer.end - layer.start))
        if layer.kind == .text {
            artwork = Self.makeText(layer, canvas: canvas)
        } else {
            artwork = image.map { CIImage(cgImage: $0) }
        }
    }

    func applying(to image: CIImage, bounds: CGRect, at time: CMTime, region override: CanvasRegion? = nil) -> CIImage {
        let region = (override ?? layer.region).pixels(in: bounds.size)
        let rect = CGRect(x: region.minX, y: bounds.height - region.maxY, width: region.width, height: region.height)
            .integral.intersection(bounds)
        guard !rect.isEmpty else { return image }
        let dimension = min(bounds.width, bounds.height)
        let result: CIImage
        switch layer.kind {
        case .blur:
            let radius = dimension * (0.002 + 0.044 * layer.intensity)
            result = image.cropped(to: rect).clampedToExtent().applyingGaussianBlur(sigma: radius)
        case .mosaic:
            result = image.cropped(to: rect).clampedToExtent().applyingFilter("CIPixellate", parameters: [
                kCIInputCenterKey: CIVector(x: rect.midX, y: rect.midY),
                kCIInputScaleKey: dimension * (0.004 + 0.056 * layer.intensity)
            ])
        case .image:
            guard let artwork else { return image }
            result = artwork.positioned(in: rect)
        case .rectangle:
            let color = layer.rectangleColor ?? .rectangleDefault
            let fill = CGColor(srgbRed: color.red, green: color.green, blue: color.blue,
                               alpha: layer.rectangleOpacity ?? 1)
            result = CIImage(color: CIColor(cgColor: fill)).cropped(to: rect)
        case .text:
            guard let artwork else { return image }
            let transform = CGAffineTransform(scaleX: rect.width / artwork.extent.width,
                                              y: rect.height / artwork.extent.height)
                .concatenating(.init(translationX: rect.minX, y: rect.minY))
            result = artwork.transformed(by: transform)
        }
        let length = frameTime(layer.animationLength)
        let start = frameTime(layer.animationStart)
        let duration = min(0.3, length.seconds / 2)
        let elapsed = (time - start).seconds
        let remaining = (start + length - time).seconds
        if let transition = layer.entrance, transition != .cut, elapsed < duration {
            return transitioned(result, over: image, in: rect, progress: elapsed / duration, transition: transition)
        }
        if let transition = layer.exit, transition != .cut, remaining < duration {
            return transitioned(result, over: image, in: rect, progress: remaining / duration, transition: transition)
        }
        return result.cropped(to: rect).composited(over: image)
    }

    private func transitioned(_ overlay: CIImage, over image: CIImage, in rect: CGRect,
                              progress: Double, transition: Transition) -> CIImage {
        guard progress > 0 else { return image }
        let fraction = min(1, progress)
        switch transition {
        case .cut:
            return overlay.cropped(to: rect).composited(over: image)
        case .dissolve:
            let fading = overlay.cropped(to: rect).applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: fraction)
            ])
            return fading.composited(over: image)
        case .swipe, .swipeRight:
            let width = rect.width * fraction
            let x = transition == .swipe ? rect.minX : rect.maxX - width
            return overlay.cropped(to: CGRect(x: x, y: rect.minY, width: width, height: rect.height))
                .composited(over: image)
        }
    }

    private static func font(for layer: VisualLayer, size: CGFloat) -> CTFont {
        let bold = layer.regularWeight != true
        guard let family = layer.fontFamily else {
            let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            return font as CTFont
        }
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: family,
            kCTFontTraitsAttribute: [kCTFontSymbolicTrait: bold ? CTFontSymbolicTraits.boldTrait.rawValue : 0]
        ] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    private static func makeText(_ layer: VisualLayer, canvas: CGSize) -> CIImage? {
        guard !layer.text.isEmpty else { return nil }
        let region = layer.region.pixels(in: canvas).integral
        let size = region.size
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func color(_ value: LayerColor) -> CGColor {
            CGColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: 1)
        }
        let fill = color(layer.textColor ?? .white)
        let strokeColor = color(layer.outlineColor ?? .black)
        let style = NSMutableParagraphStyle()
        switch layer.textAlignment ?? .center {
        case .left: style.alignment = .left
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        }
        style.lineBreakMode = .byWordWrapping
        var fontSize = layer.textPoints(in: canvas)
        for _ in 0..<14 {
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font(for: layer, size: fontSize),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill,
                .paragraphStyle: style
            ]
            let text = NSAttributedString(string: layer.text, attributes: attributes)
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            let strokeWidth = layer.outlinePixels.map { $0 * 2 } ?? fontSize * layer.outline
            let padding = min(max(2, fontSize * 0.12, strokeWidth), max(0, (size.width - 1) / 2))
            let width = max(1, size.width - 2 * padding)
            let height = max(1, size.height - 2 * padding)
            let measured = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil
            )
            let fixedSize = layer.fontSizePoints != nil
            let lineBox = fixedSize ? ceil(measured.height + 1) : min(height, ceil(measured.height + 1))
            if fixedSize || measured.height <= height || fontSize <= 5 {
                let area = CGRect(x: padding, y: (size.height - lineBox) / 2, width: width, height: lineBox)
                let path = CGPath(rect: area, transform: nil)
                context.saveGState()
                if layer.shadow {
                    context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.05),
                                      blur: fontSize * 0.12, color: CGColor(gray: 0, alpha: 0.85))
                    context.beginTransparencyLayer(auxiliaryInfo: nil)
                }
                if strokeWidth > 0 {
                    attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = strokeColor
                    attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = 100 * strokeWidth / fontSize
                    let strokeText = NSAttributedString(string: layer.text, attributes: attributes)
                    let stroke = CTFramesetterCreateWithAttributedString(strokeText)
                    CTFrameDraw(CTFramesetterCreateFrame(stroke, CFRange(), path, nil), context)
                }
                // Paint the fill after the outline so thin glyphs keep their interior.
                CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), context)
                if layer.shadow { context.endTransparencyLayer() }
                context.restoreGState()
                return context.makeImage().map { CIImage(cgImage: $0) }
            }
            fontSize *= 0.8
        }
        return nil
    }
}


extension CIImage {
    func positioned(in rect: CGRect, fill: Bool = false) -> CIImage {
        let xScale = rect.width / extent.width
        let yScale = rect.height / extent.height
        let scale = fill ? max(xScale, yScale) : min(xScale, yScale)
        let transform = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
            .concatenating(.init(scaleX: scale, y: scale))
            .concatenating(.init(translationX: rect.midX, y: rect.midY))
        return transformed(by: transform)
    }
}
