import CoreGraphics
import Foundation

enum DisplayResolutionPolicy: String, CaseIterable, Identifiable, Sendable {
    case identicalCells
    case nearestCell
    case bilinearScalar
    case areaAverage

    var id: Self { self }

    var title: String {
        switch self {
        case .identicalCells: "Identical cells"
        case .nearestCell: "Nearest cell"
        case .bilinearScalar: "Bilinear scalar"
        case .areaAverage: "Area average"
        }
    }
}

enum ScalarResampler {
    static func values(
        engineValues: [Float],
        width: Int,
        height: Int,
        outputWidth: Int,
        outputHeight: Int,
        policy: DisplayResolutionPolicy
    ) -> [Float]? {
        guard width > 0, height > 0,
              outputWidth > 0, outputHeight > 0,
              width <= Int.max / height,
              outputWidth <= Int.max / outputHeight,
              engineValues.count == width * height else { return nil }
        if policy == .identicalCells {
            guard outputWidth == width, outputHeight == height else { return nil }
            return (0..<height).flatMap { displayRow in
                let engineRow = height - displayRow - 1
                return Array(engineValues[(engineRow * width)..<((engineRow + 1) * width)])
            }
        }

        var result = [Float](repeating: 0, count: outputWidth * outputHeight)
        for row in 0..<outputHeight {
            for column in 0..<outputWidth {
                let destination = row * outputWidth + column
                switch policy {
                case .identicalCells:
                    preconditionFailure("Identical cells are handled before output allocation")
                case .nearestCell:
                    let sourceColumn = min(
                        Int((Double(column) + 0.5) * Double(width) / Double(outputWidth)),
                        width - 1
                    )
                    let sourceDisplayRow = min(
                        Int((Double(row) + 0.5) * Double(height) / Double(outputHeight)),
                        height - 1
                    )
                    result[destination] = topDownValue(
                        engineValues,
                        width: width,
                        height: height,
                        column: sourceColumn,
                        displayRow: sourceDisplayRow
                    )
                case .bilinearScalar:
                    result[destination] = bilinearValue(
                        engineValues,
                        width: width,
                        height: height,
                        outputColumn: column,
                        outputRow: row,
                        outputWidth: outputWidth,
                        outputHeight: outputHeight
                    )
                case .areaAverage:
                    result[destination] = areaAverageValue(
                        engineValues,
                        width: width,
                        height: height,
                        outputColumn: column,
                        outputRow: row,
                        outputWidth: outputWidth,
                        outputHeight: outputHeight
                    )
                }
            }
        }
        return result
    }

    private static func topDownValue(
        _ values: [Float],
        width: Int,
        height: Int,
        column: Int,
        displayRow: Int
    ) -> Float {
        values[(height - displayRow - 1) * width + column]
    }

    private static func bilinearValue(
        _ values: [Float],
        width: Int,
        height: Int,
        outputColumn: Int,
        outputRow: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> Float {
        let x = (Double(outputColumn) + 0.5) * Double(width) / Double(outputWidth) - 0.5
        let y = (Double(outputRow) + 0.5) * Double(height) / Double(outputHeight) - 0.5
        let rawX0 = Int(floor(x))
        let rawY0 = Int(floor(y))
        let x0 = min(max(rawX0, 0), width - 1)
        let x1 = min(max(rawX0 + 1, 0), width - 1)
        let y0 = min(max(rawY0, 0), height - 1)
        let y1 = min(max(rawY0 + 1, 0), height - 1)
        let tx = Float(x - floor(x))
        let ty = Float(y - floor(y))
        let top = interpolate(
            topDownValue(values, width: width, height: height, column: x0, displayRow: y0),
            topDownValue(values, width: width, height: height, column: x1, displayRow: y0),
            fraction: tx
        )
        let bottom = interpolate(
            topDownValue(values, width: width, height: height, column: x0, displayRow: y1),
            topDownValue(values, width: width, height: height, column: x1, displayRow: y1),
            fraction: tx
        )
        return interpolate(top, bottom, fraction: ty)
    }

    private static func interpolate(_ first: Float, _ second: Float, fraction: Float) -> Float {
        if fraction == 0 { return first }
        if fraction == 1 { return second }
        guard first.isFinite, second.isFinite else { return .nan }
        return first + (second - first) * fraction
    }

    private static func areaAverageValue(
        _ values: [Float],
        width: Int,
        height: Int,
        outputColumn: Int,
        outputRow: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> Float {
        let xStart = Double(outputColumn * width) / Double(outputWidth)
        let xEnd = Double((outputColumn + 1) * width) / Double(outputWidth)
        let yStart = Double(outputRow * height) / Double(outputHeight)
        let yEnd = Double((outputRow + 1) * height) / Double(outputHeight)
        let firstColumn = max(Int(floor(xStart)), 0)
        let lastColumn = min(Int(ceil(xEnd)), width)
        let firstRow = max(Int(floor(yStart)), 0)
        let lastRow = min(Int(ceil(yEnd)), height)
        var weightedSum = 0.0
        var totalWeight = 0.0
        for displayRow in firstRow..<lastRow {
            let overlapY = max(
                0,
                min(yEnd, Double(displayRow + 1)) - max(yStart, Double(displayRow))
            )
            for column in firstColumn..<lastColumn {
                let overlapX = max(
                    0,
                    min(xEnd, Double(column + 1)) - max(xStart, Double(column))
                )
                let weight = overlapX * overlapY
                guard weight > 0 else { continue }
                let value = topDownValue(
                    values,
                    width: width,
                    height: height,
                    column: column,
                    displayRow: displayRow
                )
                guard value.isFinite else { return .nan }
                weightedSum += Double(value) * weight
                totalWeight += weight
            }
        }
        return totalWeight > 0 ? Float(weightedSum / totalWeight) : .nan
    }
}

enum ScalarRasterizer {
    static let maximumOutputDimension = 4_096

    static func image(
        engineValues: [Float],
        width: Int,
        height: Int,
        signed: Bool,
        palette: ColorPalette,
        policy: DisplayResolutionPolicy,
        targetPixelSize: CGSize? = nil
    ) -> CGImage? {
        guard width > 0, height > 0, engineValues.count == width * height else { return nil }
        let outputWidth: Int
        let outputHeight: Int
        if policy == .identicalCells {
            outputWidth = width
            outputHeight = height
        } else {
            let requestedWidth = min(
                max(Int((targetPixelSize?.width ?? CGFloat(width)).rounded()), 1),
                maximumOutputDimension
            )
            let requestedHeight = min(
                max(Int((targetPixelSize?.height ?? CGFloat(height)).rounded()), 1),
                maximumOutputDimension
            )
            outputWidth = policy == .areaAverage ? min(requestedWidth, width) : requestedWidth
            outputHeight = policy == .areaAverage ? min(requestedHeight, height) : requestedHeight
        }
        guard let sampled = ScalarResampler.values(
            engineValues: engineValues,
            width: width,
            height: height,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            policy: policy
        ) else { return nil }

        let range = ScalarRange.finiteRange(of: engineValues, signed: signed)
        let lookup = (0..<256).map { index in
            let t = Float(index) / 255
            let value = range.minimum + (range.maximum - range.minimum) * t
            return ColorMap.map(value, range: range, palette: palette)
        }
        let denominator = range.maximum - range.minimum
        var pixels = [UInt8](repeating: 0, count: outputWidth * outputHeight * 4)
        for (index, value) in sampled.enumerated() {
            let color: RGBA
            if value.isFinite, denominator > 0 {
                let normalized = max(0, min((value - range.minimum) / denominator, 1))
                color = lookup[Int((normalized * 255).rounded())]
            } else if value.isFinite {
                color = lookup[128]
            } else {
                color = ColorMap.invalid
            }
            let destination = index * 4
            pixels[destination] = color.red
            pixels[destination + 1] = color.green
            pixels[destination + 2] = color.blue
            pixels[destination + 3] = color.alpha
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: outputWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

enum MaterialRasterizer {
    static func image(
        bedElevation: [Float],
        waterDepth: [Float],
        width: Int,
        height: Int,
        policy: DisplayResolutionPolicy,
        targetPixelSize: CGSize? = nil
    ) -> CGImage? {
        guard width > 0,
              height > 0,
              bedElevation.count == width * height,
              waterDepth.count == width * height else { return nil }
        let outputWidth: Int
        let outputHeight: Int
        if policy == .identicalCells {
            outputWidth = width
            outputHeight = height
        } else {
            let requestedWidth = min(
                max(Int((targetPixelSize?.width ?? CGFloat(width)).rounded()), 1),
                ScalarRasterizer.maximumOutputDimension
            )
            let requestedHeight = min(
                max(Int((targetPixelSize?.height ?? CGFloat(height)).rounded()), 1),
                ScalarRasterizer.maximumOutputDimension
            )
            outputWidth = policy == .areaAverage ? min(requestedWidth, width) : requestedWidth
            outputHeight = policy == .areaAverage ? min(requestedHeight, height) : requestedHeight
        }
        guard let sampledBed = ScalarResampler.values(
            engineValues: bedElevation,
            width: width,
            height: height,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            policy: policy
        ), let sampledDepth = ScalarResampler.values(
            engineValues: waterDepth,
            width: width,
            height: height,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            policy: policy
        ) else { return nil }

        let bedRange = ScalarRange.finiteRange(of: bedElevation)
        let observedMaximumDepth = waterDepth.lazy.filter(\.isFinite).max() ?? 0
        let waterReferenceDepth = max(observedMaximumDepth, 2)
        var pixels = [UInt8](repeating: 0, count: outputWidth * outputHeight * 4)
        for index in sampledBed.indices {
            let color = ColorMap.material(
                bedElevation: sampledBed[index],
                waterDepth: sampledDepth[index],
                bedRange: bedRange,
                waterReferenceDepth: waterReferenceDepth
            )
            let destination = index * 4
            pixels[destination] = color.red
            pixels[destination + 1] = color.green
            pixels[destination + 2] = color.blue
            pixels[destination + 3] = color.alpha
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: outputWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
