import CoreGraphics
import DisplayMonitorCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ScrollStitchPiece: Sendable {
    var url: URL
    var topY: Int
    var pixelSize: PixelSize
    var sourceCropTop: Int
    var sourceCropBottom: Int

    init(
        url: URL,
        topY: Int,
        pixelSize: PixelSize,
        sourceCropTop: Int = 0,
        sourceCropBottom: Int? = nil
    ) {
        self.url = url
        self.topY = topY
        self.pixelSize = pixelSize
        self.sourceCropTop = max(0, min(sourceCropTop, pixelSize.height))
        self.sourceCropBottom = max(
            self.sourceCropTop,
            min(sourceCropBottom ?? pixelSize.height, pixelSize.height)
        )
    }
}

/// A signed top-left displacement between two viewports. `fromIndex` and
/// `toIndex` refer to entries in the capture ledger, not filesystem ordinals.
/// Keeping the edge separate from a piece lets the ledger be re-solved when a
/// later viewport provides a better anchor than the immediately preceding one.
struct ScrollRegistrationEdge: Equatable, Sendable {
    var fromIndex: Int
    var toIndex: Int
    var offset: Int
    var confidence: Double
    var overlapPixels: Int
    var residual: Double? = nil
    var ambiguityRatio: Double? = nil
}

struct ScrollVerticalRegistration: Equatable, Sendable {
    var offset: Int
    var confidence: Double
    var overlapPixels: Int
    var residual: Double
    var ambiguityRatio: Double

    func isReliable(viewportHeight: Int) -> Bool {
        let minimumOverlap = max(24, Int((Double(viewportHeight) * 0.28).rounded(.up)))
        return offset != 0 &&
            overlapPixels >= minimumOverlap &&
            confidence >= 0.62 &&
            residual <= 42 &&
            ambiguityRatio >= 1.06
    }
}

struct ScrollSeamPlan: Equatable, Sendable {
    var previousCropBottom: Int
    var currentCropTop: Int
    var residual: Double
}

struct ScrollImageSignature: Equatable, Sendable {
    var width: Int
    var height: Int
    var sourceHeight: Int
    var values: [UInt8]

    func meanAbsoluteDifference(from other: ScrollImageSignature) -> Double {
        guard width == other.width,
              height == other.height,
              values.count == other.values.count,
              !values.isEmpty else {
            return .greatestFiniteMagnitude
        }
        let sum = zip(values, other.values).reduce(0.0) { result, pair in
            result + abs(Double(pair.0) - Double(pair.1))
        }
        return sum / Double(values.count)
    }
}

enum ScrollStitcherError: LocalizedError {
    case invalidPiece
    case unsupportedDimensions
    case decodedBudgetExceeded
    case imageEncodingFailed
    case stripedEncodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPiece: return "滚动截图片段无效"
        case .unsupportedDimensions: return "滚动截图片段尺寸不一致"
        case .decodedBudgetExceeded: return "滚动截图超出解码内存预算"
        case .imageEncodingFailed: return "无法编码滚动截图"
        case .stripedEncodingFailed(let detail): return "分块 PNG 编码失败：\(detail)"
        }
    }
}

enum ScrollStitcher {
    /// Registers two equal-sized viewport images in top-left coordinates.
    /// Positive values mean the current viewport is lower in the document than
    /// the previous viewport. The confidence intentionally combines image
    /// improvement and overlap so callers can compare several earlier anchors.
    static func registerVertical(
        previous: CGImage,
        current: CGImage
    ) -> ScrollVerticalRegistration? {
        guard previous.width == current.width,
              previous.height == current.height,
              previous.width > 0,
              previous.height > 0 else {
            return nil
        }
        guard let previousSample = fineSample(for: previous),
              let currentSample = fineSample(for: current) else {
            return nil
        }
        return fineRegistration(previous: previousSample, current: currentSample)
    }

    /// Chooses one horizontal cut inside the proven overlap. The previous
    /// viewport contributes rows above the cut and the current viewport rows
    /// below it, so every output pixel has exactly one owner. This intentionally
    /// avoids alpha blending, which makes text look doubled or soft.
    static func chooseSeam(
        previous: CGImage,
        current: CGImage,
        offset: Int
    ) -> ScrollSeamPlan? {
        guard previous.width == current.width,
              previous.height == current.height,
              offset > 0,
              offset < previous.height,
              let previousSample = fineSample(for: previous),
              let currentSample = fineSample(for: current) else {
            return nil
        }
        let overlap = previous.height - offset
        let margin = min(10, max(2, overlap / 8))
        let lower = margin
        let upper = max(lower, overlap - margin)
        let center = overlap / 2
        var bestRow = center
        var bestScore = Double.greatestFiniteMagnitude
        var bestResidual = Double.greatestFiniteMagnitude

        if upper > lower {
            for currentRow in lower...upper {
                let residual = seamResidual(
                    previous: previousSample,
                    current: currentSample,
                    previousRow: offset + currentRow,
                    currentRow: currentRow
                )
                guard residual.isFinite else { continue }
                // Prefer a calm band near the middle when a large static area
                // offers many equally good cuts; do not hug either viewport
                // edge where rounded corners and scrollbars are common.
                let centerPenalty = Double(abs(currentRow - center)) /
                    Double(max(1, overlap)) * 0.35
                let score = residual + centerPenalty
                if score < bestScore {
                    bestScore = score
                    bestResidual = residual
                    bestRow = currentRow
                }
            }
        }
        return ScrollSeamPlan(
            previousCropBottom: offset + bestRow,
            currentCropTop: bestRow,
            residual: bestResidual.isFinite ? bestResidual : 0
        )
    }

    static func centeredSeam(viewportHeight: Int, offset: Int) -> ScrollSeamPlan {
        let clampedOffset = min(max(1, offset), max(1, viewportHeight - 1))
        let currentCropTop = max(0, (viewportHeight - clampedOffset) / 2)
        return ScrollSeamPlan(
            previousCropBottom: clampedOffset + currentCropTop,
            currentCropTop: currentCropTop,
            residual: 0
        )
    }

    static func registerVertical(
        previous previousSample: ScrollImageSignature,
        current currentSample: ScrollImageSignature
    ) -> ScrollVerticalRegistration? {
        guard previousSample.width == currentSample.width,
              previousSample.height == currentSample.height,
              previousSample.sourceHeight == currentSample.sourceHeight,
              previousSample.width > 0,
              previousSample.height > 0 else {
            return nil
        }

        let width = previousSample.width
        let height = previousSample.height
        let maximumShift = max(1, Int(Double(height) * 0.82))
        let searchStep = max(1, height / 180)
        var bestShift = 0
        var bestError = Double.greatestFiniteMagnitude
        var errors: [(shift: Int, error: Double)] = []
        var zeroError = Double.greatestFiniteMagnitude
        let xStep = max(1, width / 24)
        let yStep = max(1, height / 120)

        for shift in stride(from: -maximumShift, through: maximumShift, by: searchStep) {
            let previousStart = max(0, shift)
            let currentStart = max(0, -shift)
            let overlap = height - abs(shift)
            guard overlap >= max(12, height / 5) else { continue }
            var sum: Double = 0
            var count = 0
            for y in stride(from: 0, to: overlap, by: yStep) {
                let previousRow = (y + previousStart) * width
                let currentRow = (y + currentStart) * width
                for x in stride(from: 0, to: width, by: xStep) {
                    sum += abs(Double(previousSample.values[previousRow + x]) - Double(currentSample.values[currentRow + x]))
                    count += 1
                }
            }
            guard count > 0 else { continue }
            let error = sum / Double(count)
            if shift == 0 {
                zeroError = error
            }
            errors.append((shift, error))
            if error < bestError {
                bestError = error
                bestShift = shift
            }
        }

        if !zeroError.isFinite {
            var sum: Double = 0
            var count = 0
            for y in stride(from: 0, to: height, by: yStep) {
                let row = y * width
                for x in stride(from: 0, to: width, by: xStep) {
                    sum += abs(Double(previousSample.values[row + x]) - Double(currentSample.values[row + x]))
                    count += 1
                }
            }
            zeroError = count > 0 ? sum / Double(count) : .greatestFiniteMagnitude
        }

        // A low-contrast viewport (for example a blank web page) has no stable
        // registration signal. Do not invent a displacement from noise.
        let mean = previousSample.values.reduce(0.0) { $0 + Double($1) } / Double(previousSample.values.count)
        let variance = previousSample.values.reduce(0.0) {
            let delta = Double($1) - mean
            return $0 + delta * delta
        } / Double(previousSample.values.count)
        guard variance >= 16 else {
            return ScrollVerticalRegistration(
                offset: 0,
                confidence: 0,
                overlapPixels: 0,
                residual: 0,
                ambiguityRatio: 1
            )
        }

        // Treat an almost-identical viewport as no movement. A real shift must
        // improve the zero-shift error by a visible margin; this rejects the
        // small false shifts produced by repeated white/text rows.
        if bestShift == 0 || !zeroError.isFinite || bestError >= zeroError * 0.90 {
            return ScrollVerticalRegistration(
                offset: 0,
                confidence: 0,
                overlapPixels: 0,
                residual: bestError.isFinite ? bestError : 0,
                ambiguityRatio: 1
            )
        }
        let scale = Double(previousSample.sourceHeight) / Double(height)
        // Signature rows are normalized top-to-bottom. When the current
        // viewport moves down by `d`, previous row `y + d` matches current row
        // `y`, so `bestShift` is already the positive top-left document
        // displacement expected by the ledger.
        let offset = min(
            previousSample.sourceHeight,
            max(-previousSample.sourceHeight, Int((Double(bestShift) * scale).rounded()))
        )
        let overlap = max(0, previousSample.sourceHeight - abs(offset))
        let improvement = max(0, min(1, (zeroError - bestError) / max(1, zeroError)))
        let overlapRatio = Double(overlap) / Double(max(1, previousSample.sourceHeight))
        let confidence = min(1, improvement * 1.8 + overlapRatio * 0.2)
        let exclusionRadius = max(searchStep * 2, 2)
        let secondError = errors
            .filter { abs($0.shift - bestShift) > exclusionRadius }
            .map(\.error)
            .min() ?? bestError
        let ambiguityRatio = secondError / max(0.1, bestError)
        return ScrollVerticalRegistration(
            offset: offset,
            confidence: confidence,
            overlapPixels: overlap,
            residual: bestError,
            ambiguityRatio: ambiguityRatio
        )
    }

    static func signature(for image: CGImage) -> ScrollImageSignature? {
        grayscaleSample(for: image)
    }

    /// Solves the top-left document positions from a small graph of image
    /// registrations. The first piece is the fixed origin. A few Gauss-Seidel
    /// passes are sufficient here because edges only point from an older piece
    /// to a newer piece; this also tolerates an occasional weak/late anchor
    /// without letting one noisy match permanently corrupt the output.
    static func solveTopPositions(
        pieceCount: Int,
        edges: [ScrollRegistrationEdge]
    ) -> [Int] {
        guard pieceCount > 0 else { return [] }
        guard pieceCount > 1, !edges.isEmpty else {
            return Array(repeating: 0, count: pieceCount)
        }

        let adjacentEdges = edges.filter {
            $0.fromIndex >= 0 &&
                $0.toIndex == $0.fromIndex + 1 &&
                $0.toIndex < pieceCount &&
                $0.offset > 0
        }
        if edges.count == pieceCount - 1,
           adjacentEdges.count == pieceCount - 1 {
            var byDestination: [Int: ScrollRegistrationEdge] = [:]
            for edge in adjacentEdges {
                byDestination[edge.toIndex] = edge
            }
            if byDestination.count == pieceCount - 1 {
                var positions = Array(repeating: 0, count: pieceCount)
                for index in 1..<pieceCount {
                    guard let edge = byDestination[index] else { break }
                    positions[index] = positions[index - 1] + edge.offset
                }
                return positions
            }
        }

        var positions = Array(repeating: 0, count: pieceCount)
        let orderedEdges = edges
            .filter {
                $0.fromIndex >= 0 && $0.toIndex > $0.fromIndex &&
                    $0.toIndex < pieceCount && $0.offset > 0
            }
            .sorted {
                if $0.toIndex == $1.toIndex {
                    return $0.confidence > $1.confidence
                }
                return $0.toIndex < $1.toIndex
            }

        for _ in 0..<10 {
            positions[0] = 0
            for edge in orderedEdges {
                let candidate = positions[edge.fromIndex] + edge.offset
                let weight = min(0.9, max(0.25, 0.35 + edge.confidence * 0.55))
                let blended = Double(positions[edge.toIndex]) * (1 - weight) +
                    Double(candidate) * weight
                positions[edge.toIndex] = max(
                    positions[edge.fromIndex] + 1,
                    Int(blended.rounded())
                )
            }
        }
        positions[0] = 0
        return positions
    }

    static func writePNG(
        pieces: [ScrollStitchPiece],
        outputSize: PixelSize,
        mode: ArtifactEncoderMode,
        limits: ScrollCaptureLimits,
        destination: URL
    ) throws -> ArtifactEncoderMode {
        guard !pieces.isEmpty,
              outputSize.width > 0,
              outputSize.height > 0 else {
            throw ScrollStitcherError.invalidPiece
        }
        guard pieces.allSatisfy({ $0.pixelSize.width == outputSize.width }) else {
            throw ScrollStitcherError.unsupportedDimensions
        }
        switch mode {
        case .fullBitmap:
            do {
                try writeFullBitmapPNG(
                    pieces: pieces,
                    outputSize: outputSize,
                    decodedBudgetBytes: limits.storage.decodedBudgetBytes,
                    destination: destination
                )
                return .fullBitmap
            } catch ScrollStitcherError.decodedBudgetExceeded {
                // A full bitmap is only an optimization. If its concrete
                // runtime budget (output + viewport + headroom) does not fit,
                // fall through to bounded stripes rather than allocating a
                // larger bitmap or failing a valid long capture.
                try writeStripedPNG(
                    pieces: pieces,
                    outputSize: outputSize,
                    stripeHeight: limits.stripeHeight,
                    destination: destination
                )
                return .striped
            }
        case .striped:
            try writeStripedPNG(
                pieces: pieces,
                outputSize: outputSize,
                stripeHeight: limits.stripeHeight,
                destination: destination
            )
            return .striped
        }
    }

    /// Encodes one viewport away from the main actor. A sibling staging file is
    /// renamed only after ImageIO has produced a complete PNG.
    @discardableResult
    static func writeViewportPNG(
        image: CGImage,
        destination: URL
    ) throws -> Int64 {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let staging = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: staging) }
        guard let imageDestination = CGImageDestinationCreateWithURL(
            staging as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScrollStitcherError.imageEncodingFailed
        }
        CGImageDestinationAddImage(imageDestination, image, nil)
        guard CGImageDestinationFinalize(imageDestination) else {
            throw ScrollStitcherError.imageEncodingFailed
        }
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staging, to: destination)
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    /// Produces a bounded live preview. It never allocates the full long-image
    /// bitmap and is intentionally separate from final canonical encoding.
    static func writePreviewPNG(
        pieces: [ScrollStitchPiece],
        outputSize: PixelSize,
        maximumWidth: Int = 360,
        maximumHeight: Int = 2_048,
        destination: URL
    ) throws -> PixelSize {
        guard !pieces.isEmpty,
              outputSize.width > 0,
              outputSize.height > 0 else {
            throw ScrollStitcherError.invalidPiece
        }
        let scale = min(
            1,
            min(
                Double(maximumWidth) / Double(outputSize.width),
                Double(maximumHeight) / Double(outputSize.height)
            )
        )
        let previewSize = PixelSize(
            width: max(1, Int((Double(outputSize.width) * scale).rounded())),
            height: max(1, Int((Double(outputSize.height) * scale).rounded()))
        )
        guard let context = bitmapContext(width: previewSize.width, height: previewSize.height) else {
            throw ScrollStitcherError.imageEncodingFailed
        }
        context.clear(CGRect(x: 0, y: 0, width: previewSize.width, height: previewSize.height))
        for piece in pieces {
            try Task.checkCancellation()
            guard let image = image(at: piece.url) else {
                throw ScrollStitcherError.invalidPiece
            }
            let cropTop = max(0, min(piece.sourceCropTop, piece.pixelSize.height))
            let cropBottom = max(cropTop, min(piece.sourceCropBottom, piece.pixelSize.height))
            guard cropBottom > cropTop else { continue }
            let top = Double(piece.topY) * scale
            let height = Double(piece.pixelSize.height) * scale
            let contributionTop = Double(piece.topY + cropTop) * scale
            let contributionBottom = Double(piece.topY + cropBottom) * scale
            context.saveGState()
            context.clip(
                to: CGRect(
                    x: 0,
                    y: Double(previewSize.height) - contributionBottom,
                    width: Double(previewSize.width),
                    height: contributionBottom - contributionTop
                )
            )
            context.draw(
                image,
                in: CGRect(
                    x: 0,
                    y: Double(previewSize.height) - top - height,
                    width: Double(previewSize.width),
                    height: height
                )
            )
            context.restoreGState()
        }
        guard let image = context.makeImage() else {
            throw ScrollStitcherError.imageEncodingFailed
        }
        try Task.checkCancellation()
        try writeViewportPNG(image: image, destination: destination)
        return previewSize
    }

    private static func writeFullBitmapPNG(
        pieces: [ScrollStitchPiece],
        outputSize: PixelSize,
        decodedBudgetBytes: Int64,
        destination: URL
    ) throws {
        let outputBytes = try byteCount(width: outputSize.width, height: outputSize.height)
        let largestPieceBytes = try pieces.map { try byteCount(width: $0.pixelSize.width, height: $0.pixelSize.height) }.max() ?? 0
        let required = outputBytes + largestPieceBytes + 128 * 1_024 * 1_024
        guard required <= decodedBudgetBytes else {
            throw ScrollStitcherError.decodedBudgetExceeded
        }
        guard let context = bitmapContext(width: outputSize.width, height: outputSize.height) else {
            throw ScrollStitcherError.imageEncodingFailed
        }
        try draw(pieces: pieces, in: context, stripeTop: 0, stripeHeight: outputSize.height)
        guard let image = context.makeImage() else {
            throw ScrollStitcherError.imageEncodingFailed
        }
        try? FileManager.default.removeItem(at: destination)
        guard let imageDestination = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScrollStitcherError.imageEncodingFailed
        }
        CGImageDestinationAddImage(imageDestination, image, nil)
        guard CGImageDestinationFinalize(imageDestination) else {
            throw ScrollStitcherError.imageEncodingFailed
        }
    }

    private static func writeStripedPNG(
        pieces: [ScrollStitchPiece],
        outputSize: PixelSize,
        stripeHeight: Int,
        destination: URL
    ) throws {
        let stripeHeight = max(1, min(stripeHeight, outputSize.height))
        let encoder = try StripedPNGEncoder(
            destination: destination,
            width: outputSize.width,
            height: outputSize.height
        )
        do {
            for stripeTop in stride(from: 0, to: outputSize.height, by: stripeHeight) {
                let height = min(stripeHeight, outputSize.height - stripeTop)
                let rows = try makeStripeRows(
                    pieces: pieces,
                    outputWidth: outputSize.width,
                    stripeTop: stripeTop,
                    stripeHeight: height
                )
                try encoder.append(rows: rows)
            }
            try encoder.finish()
        } catch {
            encoder.abort()
            throw error
        }
    }

    private static func draw(
        pieces: [ScrollStitchPiece],
        in context: CGContext,
        stripeTop: Int,
        stripeHeight: Int
    ) throws {
        context.clear(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        for piece in pieces {
            let cropTop = max(0, min(piece.sourceCropTop, piece.pixelSize.height))
            let cropBottom = max(cropTop, min(piece.sourceCropBottom, piece.pixelSize.height))
            let contributionTop = piece.topY + cropTop
            let contributionBottom = piece.topY + cropBottom
            guard contributionBottom > stripeTop,
                  contributionTop < stripeTop + stripeHeight,
                  cropBottom > cropTop else {
                continue
            }
            let image = try validatedImage(for: piece, outputWidth: context.width)
            let clippedTop = max(stripeTop, contributionTop)
            let clippedBottom = min(stripeTop + stripeHeight, contributionBottom)
            context.saveGState()
            context.clip(
                to: CGRect(
                    x: 0,
                    y: CGFloat(stripeHeight - (clippedBottom - stripeTop)),
                    width: CGFloat(piece.pixelSize.width),
                    height: CGFloat(clippedBottom - clippedTop)
                )
            )
            context.draw(
                image,
                in: CGRect(
                    x: 0,
                    // CGContext's user space grows upward. Convert the
                    // ledger's top-left `topY` into the local bottom-left
                    // destination without applying a second image flip.
                    y: CGFloat(stripeHeight - (piece.topY - stripeTop + piece.pixelSize.height)),
                    width: CGFloat(piece.pixelSize.width),
                    height: CGFloat(piece.pixelSize.height)
                )
            )
            context.restoreGState()
        }
    }

    /// Composes one output stripe in explicit top-left pixel coordinates. This
    /// avoids depending on CGContext's bottom-left backing-store row order in
    /// the streaming PNG path.
    private static func makeStripeRows(
        pieces: [ScrollStitchPiece],
        outputWidth: Int,
        stripeTop: Int,
        stripeHeight: Int
    ) throws -> Data {
        let bytesPerRow = outputWidth * 4
        var pixels = Data(repeating: 0, count: bytesPerRow * stripeHeight)
        for piece in pieces {
            let cropTop = max(0, min(piece.sourceCropTop, piece.pixelSize.height))
            let cropBottom = max(cropTop, min(piece.sourceCropBottom, piece.pixelSize.height))
            let contributionTop = piece.topY + cropTop
            let contributionBottom = piece.topY + cropBottom
            let overlapTop = max(stripeTop, contributionTop)
            let overlapBottom = min(stripeTop + stripeHeight, contributionBottom)
            guard overlapBottom > overlapTop else { continue }
            let image = try validatedImage(for: piece, outputWidth: outputWidth)
            guard let sourceBytes = rgbaBytes(for: image) else {
                throw ScrollStitcherError.invalidPiece
            }
            let sourceBytesPerRow = image.bytesPerRow
            guard image.width == outputWidth,
                  image.height == piece.pixelSize.height,
                  sourceBytes.count >= sourceBytesPerRow * image.height,
                  sourceBytesPerRow >= bytesPerRow else {
                throw ScrollStitcherError.unsupportedDimensions
            }
            for globalY in overlapTop..<overlapBottom {
                let sourceRow = globalY - piece.topY
                let destinationRow = globalY - stripeTop
                let sourceStart = sourceRow * sourceBytesPerRow
                let destinationStart = destinationRow * bytesPerRow
                pixels.replaceSubrange(
                    destinationStart..<(destinationStart + bytesPerRow),
                    with: sourceBytes[sourceStart..<(sourceStart + bytesPerRow)]
                )
            }
        }

        var rows = Data(capacity: (bytesPerRow + 1) * stripeHeight)
        for row in 0..<stripeHeight {
            rows.append(0) // PNG filter: None
            let start = row * bytesPerRow
            rows.append(pixels[start..<(start + bytesPerRow)])
        }
        return rows
    }

    /// Both encoders must reject a missing, corrupt or resized contributing
    /// piece. Rendering a scaled image or silently leaving a blank area would
    /// otherwise produce a valid PNG that misrepresents the capture ledger.
    private static func validatedImage(
        for piece: ScrollStitchPiece,
        outputWidth: Int
    ) throws -> CGImage {
        guard let image = image(at: piece.url) else {
            throw ScrollStitcherError.invalidPiece
        }
        guard piece.pixelSize.width == outputWidth,
              image.width == piece.pixelSize.width,
              image.height == piece.pixelSize.height else {
            throw ScrollStitcherError.unsupportedDimensions
        }
        return image
    }

    /// Returns tightly packed RGBA rows in top-to-bottom order. Pieces are
    /// written by this app as 8-bit PNGs; the direct provider path handles the
    /// common RGBA/ARGB variants, while the context fallback normalizes any
    /// other ImageIO representation without changing visual orientation.
    private static func rgbaBytes(for image: CGImage) -> Data? {
        let alpha = image.alphaInfo
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        if image.bitsPerComponent == 8,
           image.bitsPerPixel == 32,
           image.bytesPerRow >= image.width * 4,
           let provider = image.dataProvider,
           let providerData = provider.data as Data? {
            let rowBytes = image.width * 4
            if order == .byteOrder32Big,
               alpha == .last || alpha == .premultipliedLast {
                return providerData
            }
            if order == .byteOrder32Big,
               alpha == .first || alpha == .premultipliedFirst {
                var output = Data(repeating: 0, count: rowBytes * image.height)
                for row in 0..<image.height {
                    let sourceStart = row * image.bytesPerRow
                    let destinationStart = row * rowBytes
                    for x in 0..<image.width {
                        let source = sourceStart + x * 4
                        let destination = destinationStart + x * 4
                        output[destination] = providerData[source + 1]
                        output[destination + 1] = providerData[source + 2]
                        output[destination + 2] = providerData[source + 3]
                        output[destination + 3] = providerData[source]
                    }
                }
                return output
            }
        }

        guard let context = bitmapContext(width: image.width, height: image.height) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let normalized = context.makeImage(),
              let provider = normalized.dataProvider,
              let data = provider.data as Data? else {
            return nil
        }
        return data
    }

    private static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func loadImage(at url: URL) -> CGImage? {
        image(at: url)
    }

    private static func byteCount(width: Int, height: Int) throws -> Int64 {
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow else { throw ScrollStitcherError.decodedBudgetExceeded }
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
        guard !bytes.overflow else { throw ScrollStitcherError.decodedBudgetExceeded }
        return Int64(bytes.partialValue)
    }

    private struct FineSample {
        var width: Int
        var height: Int
        var grayscale: [UInt8]
        var edges: [UInt8]
    }

    /// Full-height, horizontally bounded sample used by the precise pass. The
    /// old signature reduced a 272 px viewport to roughly 32 rows, which made
    /// every estimated displacement jump in 8–9 px increments.
    private static func fineSample(for image: CGImage) -> FineSample? {
        let width = min(128, image.width)
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue
              ),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var grayscale = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let source = (y * width + x) * 4
                let red = Double(bytes[source])
                let green = Double(bytes[source + 1])
                let blue = Double(bytes[source + 2])
                grayscale[y * width + x] = UInt8(
                    (red * 0.299 + green * 0.587 + blue * 0.114).rounded()
                )
            }
        }
        var edges = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let horizontal = x > 0
                    ? abs(Int(grayscale[index]) - Int(grayscale[index - 1]))
                    : 0
                let vertical = y > 0
                    ? abs(Int(grayscale[index]) - Int(grayscale[index - width]))
                    : 0
                edges[index] = UInt8(min(255, horizontal + vertical * 2))
            }
        }
        return FineSample(width: width, height: height, grayscale: grayscale, edges: edges)
    }

    private static func fineRegistration(
        previous: FineSample,
        current: FineSample
    ) -> ScrollVerticalRegistration? {
        guard previous.width == current.width,
              previous.height == current.height,
              previous.height > 0 else { return nil }
        let height = previous.height
        let minimumOverlap = max(24, Int((Double(height) * 0.28).rounded(.up)))
        let maximumShift = height - minimumOverlap
        guard maximumShift > 0 else { return nil }

        let edgeMean = previous.edges.reduce(0.0) { $0 + Double($1) } /
            Double(max(1, previous.edges.count))
        guard edgeMean >= 0.75 else {
            return ScrollVerticalRegistration(
                offset: 0,
                confidence: 0,
                overlapPixels: 0,
                residual: 0,
                ambiguityRatio: 1
            )
        }

        let coarseStep = max(1, height / 180)
        var coarse: [(shift: Int, error: Double)] = []
        for shift in stride(from: -maximumShift, through: maximumShift, by: coarseStep) {
            let error = registrationResidual(
                previous: previous,
                current: current,
                shift: shift,
                sampleColumns: 16,
                sampleRows: 80
            )
            if error.isFinite {
                coarse.append((shift, error))
            }
        }
        guard !coarse.isEmpty else { return nil }

        // Refine several spatially distinct minima. Repeated rows can make one
        // coarse minimum look excellent; retaining alternatives lets the
        // ambiguity gate reject that match instead of silently accepting it.
        var seeds: [Int] = []
        for candidate in coarse.sorted(by: { $0.error < $1.error }) {
            if seeds.allSatisfy({ abs($0 - candidate.shift) > max(3, coarseStep * 2) }) {
                seeds.append(candidate.shift)
            }
            if seeds.count == 6 { break }
        }
        if !seeds.contains(0) { seeds.append(0) }
        var fineShifts = Set<Int>()
        for seed in seeds {
            for shift in max(-maximumShift, seed - coarseStep)...min(maximumShift, seed + coarseStep) {
                fineShifts.insert(shift)
            }
        }
        let fine = fineShifts.compactMap { shift -> (shift: Int, error: Double)? in
            let error = registrationResidual(previous: previous, current: current, shift: shift)
            return error.isFinite ? (shift, error) : nil
        }
        guard let best = fine.min(by: { $0.error < $1.error }) else { return nil }
        let zeroError = registrationResidual(previous: previous, current: current, shift: 0)

        if best.shift == 0 || !zeroError.isFinite || best.error >= zeroError * 0.92 {
            return ScrollVerticalRegistration(
                offset: 0,
                confidence: 0,
                overlapPixels: 0,
                residual: best.error,
                ambiguityRatio: 1
            )
        }
        let exclusionRadius = max(3, coarseStep)
        let secondError = fine
            .filter { abs($0.shift - best.shift) > exclusionRadius }
            .map(\.error)
            .min() ?? best.error
        let ambiguityRatio = min(99, secondError / max(0.1, best.error))
        let improvement = max(0, min(1, (zeroError - best.error) / max(1, zeroError)))
        let ambiguityScore = max(0, min(1, (ambiguityRatio - 1) / 0.35))
        let fitScore = max(0, min(1, 1 - best.error / 48))
        let overlap = height - abs(best.shift)
        let overlapScore = Double(overlap) / Double(height)
        let confidence = improvement * 0.45 + ambiguityScore * 0.25 +
            fitScore * 0.20 + overlapScore * 0.10
        return ScrollVerticalRegistration(
            offset: best.shift,
            confidence: min(1, confidence),
            overlapPixels: overlap,
            residual: best.error,
            ambiguityRatio: ambiguityRatio
        )
    }

    private static func registrationResidual(
        previous: FineSample,
        current: FineSample,
        shift: Int,
        sampleColumns: Int = 48,
        sampleRows: Int = 240
    ) -> Double {
        let overlap = previous.height - abs(shift)
        guard overlap > 0 else { return .greatestFiniteMagnitude }
        let previousStart = max(0, shift)
        let currentStart = max(0, -shift)
        let xMargin = min(max(2, previous.width / 14), max(2, previous.width / 4))
        let xStep = max(1, previous.width / max(1, sampleColumns))
        let yStep = max(1, overlap / max(1, sampleRows))
        var sum = 0.0
        var count = 0
        for y in stride(from: 0, to: overlap, by: yStep) {
            let previousRow = (previousStart + y) * previous.width
            let currentRow = (currentStart + y) * current.width
            for x in stride(from: xMargin, to: previous.width - xMargin, by: xStep) {
                let previousEdge = Int(previous.edges[previousRow + x])
                let currentEdge = Int(current.edges[currentRow + x])
                guard max(previousEdge, currentEdge) >= 4 else { continue }
                let edgeDifference = abs(previousEdge - currentEdge)
                let toneDifference = abs(
                    Int(previous.grayscale[previousRow + x]) -
                        Int(current.grayscale[currentRow + x])
                )
                sum += Double(edgeDifference) * 0.82 + Double(toneDifference) * 0.18
                count += 1
            }
        }
        guard count >= max(24, overlap / max(1, yStep)) else {
            return .greatestFiniteMagnitude
        }
        return sum / Double(count)
    }

    private static func seamResidual(
        previous: FineSample,
        current: FineSample,
        previousRow: Int,
        currentRow: Int
    ) -> Double {
        let xMargin = min(max(2, previous.width / 14), max(2, previous.width / 4))
        var sum = 0.0
        var count = 0
        for delta in -2...2 {
            let previousY = previousRow + delta
            let currentY = currentRow + delta
            guard previousY >= 0, previousY < previous.height,
                  currentY >= 0, currentY < current.height else { continue }
            let previousBase = previousY * previous.width
            let currentBase = currentY * current.width
            for x in xMargin..<(previous.width - xMargin) {
                let edgeDifference = abs(
                    Int(previous.edges[previousBase + x]) -
                        Int(current.edges[currentBase + x])
                )
                let toneDifference = abs(
                    Int(previous.grayscale[previousBase + x]) -
                        Int(current.grayscale[currentBase + x])
                )
                sum += Double(edgeDifference) * 0.75 + Double(toneDifference) * 0.25
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : .greatestFiniteMagnitude
    }

    private static func grayscaleSample(for image: CGImage) -> ScrollImageSignature? {
        let sampleWidth = min(72, image.width)
        let sampleHeight = min(
            image.height,
            min(
                512,
                max(96, Int(Double(image.height) * Double(sampleWidth) / Double(max(1, image.width))))
            )
        )
        guard let context = CGContext(
            data: nil,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: sampleWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ), let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        var values = [UInt8](repeating: 0, count: sampleWidth * sampleHeight)
        for y in 0..<sampleHeight {
            for x in 0..<sampleWidth {
                let source = (y * sampleWidth + x) * 4
                let red = Double(bytes[source])
                let green = Double(bytes[source + 1])
                let blue = Double(bytes[source + 2])
                values[y * sampleWidth + x] = UInt8((red * 0.299 + green * 0.587 + blue * 0.114).rounded())
            }
        }
        return ScrollImageSignature(
            width: sampleWidth,
            height: sampleHeight,
            sourceHeight: image.height,
            values: values
        )
    }
}

private final class StripedPNGEncoder {
    private let destination: URL
    private let handle: FileHandle
    private var deflater: ZlibDeflater
    private var finished = false

    init(destination: URL, width: Int, height: Int) throws {
        self.destination = destination
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ScrollStitcherError.stripedEncodingFailed("无法创建输出文件")
        }
        handle = try FileHandle(forWritingTo: destination)
        deflater = ZlibDeflater()
        try write(Data([137, 80, 78, 71, 13, 10, 26, 10]))
        var header = Data()
        header.appendUInt32BE(UInt32(width))
        header.appendUInt32BE(UInt32(height))
        header.append(contentsOf: [8, 6, 0, 0, 0]) // 8-bit RGBA
        try writeChunk(type: "IHDR", data: header)
    }

    func append(rows: Data) throws {
        guard !finished else { throw ScrollStitcherError.stripedEncodingFailed("编码器已结束") }
        for chunk in try deflater.process(rows, final: false) where !chunk.isEmpty {
            try writeChunk(type: "IDAT", data: chunk)
        }
    }

    func finish() throws {
        guard !finished else { return }
        for chunk in try deflater.process(Data(), final: true) where !chunk.isEmpty {
            try writeChunk(type: "IDAT", data: chunk)
        }
        try writeChunk(type: "IEND", data: Data())
        try handle.synchronize()
        try handle.close()
        finished = true
    }

    func abort() {
        guard !finished else { return }
        try? handle.close()
        try? FileManager.default.removeItem(at: destination)
        finished = true
    }

    private func writeChunk(type: String, data: Data) throws {
        var chunk = Data()
        chunk.appendUInt32BE(UInt32(data.count))
        let typeData = Data(type.utf8)
        chunk.append(typeData)
        chunk.append(data)
        var crcInput = typeData
        crcInput.append(data)
        chunk.appendUInt32BE(PNGCRC32.value(for: crcInput))
        try write(chunk)
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }
}

/// Minimal streaming zlib writer for bounded-memory PNG output.
///
/// The previous Compression-framework path emitted raw DEFLATE bytes without
/// a valid zlib wrapper on this macOS runtime. PNG readers then treated the
/// striped artifact as corrupt/transparent. Stored DEFLATE blocks are slightly
/// larger but deterministic, valid, and keep the bounded stripe memory model.
private final class ZlibDeflater {
    private var wroteHeader = false
    private var finished = false
    private var adlerS1: UInt32 = 1
    private var adlerS2: UInt32 = 0

    func process(_ data: Data, final: Bool) throws -> [Data] {
        guard !finished else {
            throw ScrollStitcherError.stripedEncodingFailed("zlib 编码器已结束")
        }

        var output = Data()
        if !wroteHeader {
            // CMF/FLG for deflate with a 32 KiB window and no compression.
            output.append(contentsOf: [0x78, 0x01])
            wroteHeader = true
        }

        if !data.isEmpty {
            var offset = 0
            while offset < data.count {
                let count = min(65_535, data.count - offset)
                output.append(0x00) // BFINAL=0, BTYPE=00 (stored block)
                output.append(UInt8(count & 0xFF))
                output.append(UInt8((count >> 8) & 0xFF))
                let inverse = UInt16(0xFFFF - count)
                output.append(UInt8(inverse & 0xFF))
                output.append(UInt8((inverse >> 8) & 0xFF))
                output.append(data.subdata(in: offset..<(offset + count)))
                updateAdler(data, offset: offset, count: count)
                offset += count
            }
        }

        if final {
            // Empty final stored block; all previous blocks remain intact.
            output.append(contentsOf: [0x01, 0x00, 0x00, 0xFF, 0xFF])
            output.append(UInt8((adlerS2 >> 8) & 0xFF))
            output.append(UInt8(adlerS2 & 0xFF))
            output.append(UInt8((adlerS1 >> 8) & 0xFF))
            output.append(UInt8(adlerS1 & 0xFF))
            finished = true
        }
        return output.isEmpty ? [] : [output]
    }

    private func updateAdler(_ data: Data, offset: Int, count: Int) {
        for byte in data[offset..<(offset + count)] {
            adlerS1 = (adlerS1 + UInt32(byte)) % 65_521
            adlerS2 = (adlerS2 + adlerS1) % 65_521
        }
    }
}

private enum PNGCRC32 {
    static func value(for data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
