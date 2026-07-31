import CoreGraphics
import SwiftUI

struct MosaicGridView: View {
    @ObservedObject var model: SimulationViewModel
    @Environment(\.displayScale) private var displayScale
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
                    palette: model.palette,
                    policy: model.resolutionPolicy,
                    targetPixelSize: CGSize(
                        width: mapping.contentFrame.width * displayScale,
                        height: mapping.contentFrame.height * displayScale
                    )
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
        palette: ColorPalette,
        policy: DisplayResolutionPolicy = .identicalCells,
        targetPixelSize: CGSize? = nil
    ) -> CGImage? {
        ScalarRasterizer.image(
            engineValues: snapshot.values(for: mode),
            width: snapshot.width,
            height: snapshot.height,
            signed: mode == .surfaceDeviation,
            palette: palette,
            policy: policy,
            targetPixelSize: targetPixelSize
        )
    }
}
