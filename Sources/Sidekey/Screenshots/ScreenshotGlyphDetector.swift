import AppKit
import Vision

/// Fast Vision can omit a single digit. Repeat uncovered glyph candidates in a
/// bounded OCR atlas and accept only repeated letters/digits, mapping them back to the
/// original pixels. No synthetic pixels are ever added to the exported image.
// WHY: .project-docs/decisions/2026-10-20-screenshot-toolbar.md
enum ScreenshotGlyphDetector {
    static func boxes(in image: CGImage, excluding known: [CGRect]) throws -> [CGRect] {
        let request = VNDetectContoursRequest()
        request.detectsDarkOnLight = true; request.maximumImageDimension = 2048
        try ScreenshotTextDetector.useCPU(request)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var pending = request.results?.first?.topLevelContours ?? [], candidates: [CGRect] = []
        let width = CGFloat(image.width), height = CGFloat(image.height)
        var inspected = 0
        while let contour = pending.popLast(), inspected < 8192 {
            inspected += 1
            pending.append(contentsOf: contour.childContours)
            let box = contour.normalizedPath.boundingBox
            let w = box.width * width, h = box.height * height
            // A one-pixel stem (e.g. 11 pt "1") can round just below one pixel.
            guard h >= 4, w >= 0.75, w / h >= 0.06, w / h <= 0.95,
                  !known.contains(where: { $0.insetBy(dx: -2 / width, dy: -2 / height).contains(CGPoint(x: box.midX, y: box.midY)) }) else { continue }
            candidates.append(box)
        }
        candidates.sort { $0.height > $1.height }
        candidates = Array(candidates.prefix(256))
        guard !candidates.isEmpty else { return [] }
        try Task.checkCancellation()
        let columns = 4, cellWidth = 256, cellHeight = 64
        let rows = (candidates.count + columns - 1) / columns
        guard let atlas = CGContext(data: nil, width: columns * cellWidth, height: rows * cellHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotImageError.rendering }
        atlas.setFillColor(CGColor(gray: 1, alpha: 1))
        atlas.fill(CGRect(x: 0, y: 0, width: atlas.width, height: atlas.height))
        atlas.interpolationQuality = .high
        var glyphRects = [CGRect](repeating: .zero, count: candidates.count)
        for (index, box) in candidates.enumerated() {
            try Task.checkCancellation()
            let pixels = CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
                .insetBy(dx: -2, dy: -2).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard let cropped = image.cropping(to: pixels) else { continue }
            let glyph = try ScreenshotTextDetector.recognitionImage(cropped)
            let w = min(42, 40 * CGFloat(glyph.width) / CGFloat(glyph.height))
            let origin = CGPoint(x: index % columns * cellWidth, y: index / columns * cellHeight)
            glyphRects[index] = CGRect(x: origin.x + 40, y: origin.y + 12, width: w * 3 + 8, height: 40)
            // Curved guard digits give very thin stems enough context for fast OCR.
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: atlas, flipped: false)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34), .foregroundColor: NSColor.black]
            ("8" as NSString).draw(at: CGPoint(x: origin.x + 8, y: origin.y + 12), withAttributes: attributes)
            ("8" as NSString).draw(at: CGPoint(x: origin.x + 40 + 3 * (w + 4), y: origin.y + 12), withAttributes: attributes)
            NSGraphicsContext.current = previous
            for repeatIndex in 0..<3 {
                atlas.draw(glyph, in: CGRect(x: CGFloat(index % columns * cellWidth + 40) + CGFloat(repeatIndex) * (w + 4),
                    y: CGFloat(index / columns * cellHeight + 12), width: w, height: 40))
            }
        }
        guard let atlasImage = atlas.makeImage() else { throw ScreenshotImageError.rendering }
        let recognition = ScreenshotTextDetector.fastRequest()
        try VNImageRequestHandler(cgImage: atlasImage, options: [:]).perform([recognition])
        var characters: [Int: [Character]] = [:]
        for observation in recognition.results ?? [] {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.2 else { continue }
            let text = candidate.string
            var index = text.startIndex
            while index < text.endIndex {
                let end = text.index(after: index)
                if (text[index].isNumber || text[index].isLetter),
                   let box = try candidate.boundingBox(for: index..<end)?.boundingBox {
                    let point = CGPoint(x: box.midX * CGFloat(atlas.width), y: box.midY * CGFloat(atlas.height))
                    let column = Int(point.x) / cellWidth, row = Int(point.y) / cellHeight
                    let slot = row * columns + column
                    if column >= 0, column < columns, row >= 0, row < rows, slot < candidates.count,
                       glyphRects[slot].contains(point) {
                        characters[slot, default: []].append(text[index])
                    }
                }
                index = end
            }
        }
        return characters.keys.sorted().compactMap { index in
            let values = characters[index]!
            return values.count >= 2 && Set(values).count == 1 ? candidates[index] : nil
        }
    }
}
