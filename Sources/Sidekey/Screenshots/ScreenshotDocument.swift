import AppKit
import CoreImage
import Vision

enum ScreenshotTool: String, CaseIterable {
    case select, arrow, rectangle, ellipse, pen, text, blur, marker, counter, spotlight
}

enum ScreenshotBlurMode: String, CaseIterable {
    case textAndNumbers = "Text and numbers"
    case entireArea = "Entire area"
}

enum ScreenshotEditorKeys {
    static let tools: [(key: String, title: String, tool: ScreenshotTool)] = [
        ("v", "Select & crop", .select), ("a", "Arrow", .arrow), ("r", "Rectangle", .rectangle),
        ("o", "Oval", .ellipse), ("p", "Pen", .pen), ("t", "Text", .text),
        ("b", "Blur text and numbers", .blur), ("m", "Highlighter", .marker), ("n", "Numbered steps", .counter)
    ]
}

struct ScreenshotAnnotation {
    let id: UUID
    var tool: ScreenshotTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text: String
    var patch: CGImage?

    init(tool: ScreenshotTool, points: [CGPoint], color: NSColor = .systemRed,
         width: CGFloat = 3, text: String = "", patch: CGImage? = nil) {
        self.id = UUID(); self.tool = tool; self.points = points
        self.color = color; self.width = width; self.text = text; self.patch = patch
    }

    var rect: CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { result, point in
            CGRect(x: min(result.minX, point.x), y: min(result.minY, point.y),
                   width: max(result.maxX, point.x) - min(result.minX, point.x),
                   height: max(result.maxY, point.y) - min(result.minY, point.y))
        }
    }
}

/// Document coordinates are bottom-left screen points, independent of Retina scale.
enum ScreenshotGeometry {
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func pixelRect(_ rect: CGRect, size: CGSize, pixels: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .null }
        let clipped = rect.standardized.intersection(CGRect(origin: .zero, size: size))
        guard !clipped.isNull, !clipped.isEmpty else { return .null }
        return CGRect(x: clipped.minX * pixels.width / size.width,
                      y: (size.height - clipped.maxY) * pixels.height / size.height,
                      width: clipped.width * pixels.width / size.width,
                      height: clipped.height * pixels.height / size.height).integral
            .intersection(CGRect(origin: .zero, size: pixels))
    }

    static func toolbarFrame(selection: CGRect, screen: CGRect, size: CGSize) -> CGRect {
        let x = min(max(screen.minX + 8, selection.maxX - size.width), screen.maxX - size.width - 8)
        let below = selection.minY - size.height - 10
        let y = below >= screen.minY + 8 ? below : selection.maxY + 10
        return CGRect(x: max(screen.minX, x), y: max(screen.minY + 8, min(y, screen.maxY - size.height - 8)),
                      width: min(size.width, screen.width), height: size.height)
    }
}

enum ScreenshotImageError: LocalizedError {
    case rendering, emptySelection, noText
    var errorDescription: String? {
        switch self {
        case .rendering: return "The screenshot could not be prepared. Try a smaller area."
        case .emptySelection: return "Select an area first."
        case .noText: return "No text or numbers were found. Try Entire area, or select a larger area."
        }
    }
}

enum ScreenshotRenderer {
    static func draw(_ annotation: ScreenshotAnnotation, in context: CGContext, bounds: CGRect) {
        let points = annotation.points
        guard let start = points.first else { return }
        let end = points.last ?? start, rect = annotation.rect
        context.saveGState(); defer { context.restoreGState() }
        context.setStrokeColor(annotation.color.cgColor)
        context.setFillColor(annotation.color.cgColor)
        context.setLineWidth(annotation.width)
        context.setLineCap(.round); context.setLineJoin(.round)
        switch annotation.tool {
        case .arrow:
            context.move(to: start); context.addLine(to: end); context.strokePath()
            let angle = atan2(end.y - start.y, end.x - start.x), length = max(12, annotation.width * 4)
            for offset in [CGFloat(-0.5), CGFloat(0.5)] {
                context.move(to: CGPoint(x: end.x - length * cos(angle + offset), y: end.y - length * sin(angle + offset)))
                context.addLine(to: end); context.strokePath()
            }
        case .rectangle: context.stroke(rect)
        case .ellipse: context.strokeEllipse(in: rect)
        case .pen:
            context.move(to: start)
            for point in points.dropFirst() { context.addLine(to: point) }
            if points.count == 1 { context.addLine(to: CGPoint(x: start.x + 0.1, y: start.y)) }
            context.strokePath()
        case .marker:
            context.setFillColor(annotation.color.withAlphaComponent(0.28).cgColor); context.fill(rect)
        case .spotlight:
            context.addRect(bounds); context.addRect(rect)
            context.setFillColor(NSColor.black.withAlphaComponent(0.58).cgColor); context.fillPath(using: .evenOdd)
        case .blur:
            if let patch = annotation.patch { context.interpolationQuality = .high; context.draw(patch, in: rect) }
        case .text, .counter:
            let old = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            defer { NSGraphicsContext.current = old }
            if annotation.tool == .counter {
                let circle = CGRect(x: start.x - 14, y: start.y - 14, width: 28, height: 28)
                context.fillEllipse(in: circle)
                let value = NSAttributedString(string: annotation.text, attributes: [
                    .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white
                ])
                let size = value.size()
                value.draw(at: CGPoint(x: start.x - size.width / 2, y: start.y - size.height / 2))
            } else {
                let value = NSAttributedString(string: annotation.text, attributes: [
                    .font: NSFont.systemFont(ofSize: max(14, annotation.width * 6), weight: .medium),
                    .foregroundColor: annotation.color
                ])
                value.draw(at: start)
            }
        case .select: break
        }
    }

    static func image(source: CGImage, size: CGSize, annotations: [ScreenshotAnnotation], crop: CGRect) throws -> CGImage {
        guard let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotImageError.rendering }
        context.scaleBy(x: CGFloat(source.width) / size.width, y: CGFloat(source.height) / size.height)
        context.draw(source, in: CGRect(origin: .zero, size: size))
        for annotation in annotations { draw(annotation, in: context, bounds: CGRect(origin: .zero, size: size)) }
        let pixelRect = ScreenshotGeometry.pixelRect(crop, size: size, pixels: CGSize(width: source.width, height: source.height))
        guard !pixelRect.isNull, let result = context.makeImage()?.cropping(to: pixelRect) else { throw ScreenshotImageError.emptySelection }
        return result
    }

    /// Composite replacement pixels before encoding. Export never carries editable originals.
    static func blurred(_ image: CGImage, boxes: [CGRect]) throws -> CGImage {
        let ci = CIImage(cgImage: image)
        let radius = max(14, min(CGFloat(image.width), CGFloat(image.height)) * 0.06)
        let filtered = ci.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: ci.extent)
        let renderer = CIContext(options: [.useSoftwareRenderer: true])
        guard let blurred = renderer.createCGImage(filtered, from: ci.extent),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotImageError.rendering }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: bounds)
        context.saveGState()
        for box in boxes {
            let pixelBox = CGRect(x: box.minX * bounds.width, y: box.minY * bounds.height,
                                  width: box.width * bounds.width, height: box.height * bounds.height)
                .insetBy(dx: -3, dy: -3).intersection(bounds)
            if !pixelBox.isEmpty { context.addRect(pixelBox) }
        }
        context.clip(); context.draw(blurred, in: bounds); context.restoreGState()
        guard let result = context.makeImage() else { throw ScreenshotImageError.rendering }
        return result
    }

    static func resized(_ image: CGImage, width: Int) throws -> CGImage {
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        guard width > 0, width <= 16_384, height <= 16_384,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ScreenshotImageError.rendering }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ScreenshotImageError.rendering }
        return result
    }
}

struct ScreenshotTextAnalysis {
    let boxes: [CGRect]
    let text: String
}

enum ScreenshotTextDetector {
    /// Vision stays on device. Correction is off so standalone numbers and codes survive.
    // WHY: .project-docs/decisions/2026-10-20-screenshot-toolbar.md
    static func analyze(_ image: CGImage, detectAdditionalBoxes: Bool = true) throws -> ScreenshotTextAnalysis {
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.usesLanguageCorrection = false
        recognition.automaticallyDetectsLanguage = true
        recognition.minimumTextHeight = 0
        let supported = try recognition.supportedRecognitionLanguages()
        let languages = ["en-US", "ru-RU"].filter { supported.contains($0) }
        if !languages.isEmpty { recognition.recognitionLanguages = languages }
        let detection = VNDetectTextRectanglesRequest()
        detection.reportCharacterBoxes = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform(detectAdditionalBoxes ? [recognition, detection] : [recognition])
        let observations = recognition.results ?? []
        var boxes = observations.map(\.boundingBox)
        if detectAdditionalBoxes { boxes += (detection.results ?? []).map(\.boundingBox) }
        return ScreenshotTextAnalysis(boxes: boxes, text: observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
    }
}
