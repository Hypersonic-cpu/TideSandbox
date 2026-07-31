import CoreGraphics
import SwiftUI

struct MosaicGridView: View {
    @ObservedObject var model: SimulationViewModel
    @State private var brushIsActive = false

    var body: some View {
        GeometryReader { proxy in
            let mapping = GridDisplayMapping(
                gridWidth: model.snapshot.width,
                gridHeight: model.snapshot.height,
                viewSize: proxy.size
            )
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if let mapping,
                   let image = MosaicRaster.image(
                    snapshot: model.snapshot,
                    mode: model.displayMode,
                    palette: model.palette
                   ) {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: mapping.contentFrame.width, height: mapping.contentFrame.height)
                        .position(x: mapping.contentFrame.midX, y: mapping.contentFrame.midY)
                    overlay(mapping: mapping)
                } else {
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
            .gesture(pointerGesture(mapping: mapping))
        }
        .accessibilityIdentifier("mosaic-grid")
    }

    @ViewBuilder
    private func overlay(mapping: GridDisplayMapping) -> some View {
        Canvas { context, _ in
            if model.showGrid, mapping.tileSize >= 4 {
                var path = Path()
                for column in 0...mapping.gridWidth {
                    let x = mapping.contentFrame.minX + CGFloat(column) * mapping.tileSize
                    path.move(to: CGPoint(x: x, y: mapping.contentFrame.minY))
                    path.addLine(to: CGPoint(x: x, y: mapping.contentFrame.maxY))
                }
                for row in 0...mapping.gridHeight {
                    let y = mapping.contentFrame.minY + CGFloat(row) * mapping.tileSize
                    path.move(to: CGPoint(x: mapping.contentFrame.minX, y: y))
                    path.addLine(to: CGPoint(x: mapping.contentFrame.maxX, y: y))
                }
                context.stroke(path, with: .color(.black.opacity(0.18)), lineWidth: 0.5)
            }

            if let brushPoint = model.brushPreviewPoint,
               model.tool == .raise || model.tool == .lower {
                let center = mapping.viewPoint(
                    forPhysicalPoint: brushPoint,
                    domainWidth: model.snapshot.domainWidth,
                    domainHeight: model.snapshot.domainHeight
                )
                let radiusX = CGFloat(model.brushRadius / model.snapshot.domainWidth) *
                              mapping.contentFrame.width
                let radiusY = CGFloat(model.brushRadius / model.snapshot.domainHeight) *
                              mapping.contentFrame.height
                let rect = CGRect(
                    x: center.x - radiusX,
                    y: center.y - radiusY,
                    width: radiusX * 2,
                    height: radiusY * 2
                )
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.12)))
                context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 1.5)
            }

            if !model.polygonPoints.isEmpty {
                var path = Path()
                for (index, point) in model.polygonPoints.enumerated() {
                    let viewPoint = mapping.viewPoint(
                        forPhysicalPoint: point,
                        domainWidth: model.snapshot.domainWidth,
                        domainHeight: model.snapshot.domainHeight
                    )
                    if index == 0 { path.move(to: viewPoint) } else { path.addLine(to: viewPoint) }
                    context.fill(
                        Path(ellipseIn: CGRect(x: viewPoint.x - 3, y: viewPoint.y - 3,
                                              width: 6, height: 6)),
                        with: .color(.white)
                    )
                }
                context.stroke(path, with: .color(.white),
                               style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
        }
        .allowsHitTesting(false)
    }

    private func pointerGesture(mapping: GridDisplayMapping?) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard let mapping,
                      let point = mapping.physicalPoint(
                        at: value.location,
                        domainWidth: model.snapshot.domainWidth,
                        domainHeight: model.snapshot.domainHeight
                      ) else { return }
                if model.tool == .raise || model.tool == .lower {
                    if brushIsActive {
                        model.moveBrush(to: point)
                    } else {
                        brushIsActive = true
                        model.beginBrush(at: point)
                    }
                }
            }
            .onEnded { value in
                guard let mapping else { return }
                if brushIsActive {
                    brushIsActive = false
                    model.endBrush()
                } else if model.tool == .polygon,
                          let point = mapping.physicalPoint(
                            at: value.location,
                            domainWidth: model.snapshot.domainWidth,
                            domainHeight: model.snapshot.domainHeight
                          ) {
                    model.addPolygonPoint(point)
                }
            }
    }
}

enum MosaicRaster {
    static func image(
        snapshot: SimulationSnapshot,
        mode: DisplayMode,
        palette: ColorPalette
    ) -> CGImage? {
        let width = snapshot.width
        let height = snapshot.height
        guard width > 0, height > 0 else { return nil }
        let values = snapshot.values(for: mode)
        guard values.count == width * height else { return nil }
        let range = ScalarRange.finiteRange(of: values, signed: mode == .surfaceDeviation)
        let lookup = (0..<256).map { index in
            let t = Float(index) / 255
            let value = range.minimum + (range.maximum - range.minimum) * t
            return ColorMap.map(value, range: range, palette: palette)
        }
        let denominator = range.maximum - range.minimum
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for displayRow in 0..<height {
            let engineRow = height - displayRow - 1
            for column in 0..<width {
                let sourceIndex = engineRow * width + column
                let value = values[sourceIndex]
                let color: RGBA
                if value.isFinite, denominator > 0 {
                    let normalized = max(0, min((value - range.minimum) / denominator, 1))
                    color = lookup[Int((normalized * 255).rounded())]
                } else if value.isFinite {
                    color = lookup[128]
                } else {
                    color = ColorMap.invalid
                }
                let destination = (displayRow * width + column) * 4
                pixels[destination] = color.red
                pixels[destination + 1] = color.green
                pixels[destination + 2] = color.blue
                pixels[destination + 3] = color.alpha
            }
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
