import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ScenePreviewRenderer {
    static func pngData(
        width: Int,
        height: Int,
        waterDepth: [Float],
        maximumDimension: Int = 256
    ) throws -> Data {
        guard width > 0, height > 0,
              width <= Int.max / height,
              waterDepth.count == width * height,
              maximumDimension > 0 else {
            throw ScenePackageError.invalidDimensions
        }
        let scale = min(1, Double(maximumDimension) / Double(max(width, height)))
        let outputWidth = max(1, Int((Double(width) * scale).rounded()))
        let outputHeight = max(1, Int((Double(height) * scale).rounded()))

        var minimum = Float.infinity
        var maximum = -Float.infinity
        for value in waterDepth where value.isFinite {
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }
        guard minimum.isFinite, maximum.isFinite else {
            throw ScenePackageError.nonFiniteField(resource: "initial_water_depth.bin", index: 0)
        }
        let denominator = maximum - minimum
        var pixels = [UInt8](repeating: 0, count: outputWidth * outputHeight * 4)
        for outputRow in 0..<outputHeight {
            let displaySourceRow = min(outputRow * height / outputHeight, height - 1)
            let engineRow = height - displaySourceRow - 1
            for outputColumn in 0..<outputWidth {
                let engineColumn = min(outputColumn * width / outputWidth, width - 1)
                let value = waterDepth[engineRow * width + engineColumn]
                guard value.isFinite else {
                    throw ScenePackageError.nonFiniteField(
                        resource: "initial_water_depth.bin",
                        index: engineRow * width + engineColumn
                    )
                }
                let normalized = denominator > 0
                    ? max(0, min((value - minimum) / denominator, 1))
                    : 0.5
                let red = UInt8((8 + 218 * normalized).rounded())
                let green = UInt8((68 + 174 * normalized).rounded())
                let blue = UInt8((120 + 130 * normalized).rounded())
                let destination = (outputRow * outputWidth + outputColumn) * 4
                pixels[destination] = red
                pixels[destination + 1] = green
                pixels[destination + 2] = blue
                pixels[destination + 3] = 255
            }
        }
        let pixelData = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: pixelData),
              let image = CGImage(
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
              ) else {
            throw ScenePackageError.invalidPreview
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScenePackageError.invalidPreview
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScenePackageError.invalidPreview
        }
        return output as Data
    }
}
