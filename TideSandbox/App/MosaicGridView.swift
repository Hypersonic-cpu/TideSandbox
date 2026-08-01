import CoreGraphics
import Foundation
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
                    decorativeConfiguration: model.decorativeMapConfiguration,
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
                    if model.showMapAnnotations {
                        MapAnnotationsOverlay(
                            mode: model.displayMode,
                            configuration: model.decorativeMapConfiguration,
                            domainWidth: model.snapshot.domainWidth,
                            displayedWidth: mapping.contentFrame.width
                        )
                        .frame(
                            width: mapping.contentFrame.width,
                            height: mapping.contentFrame.height
                        )
                        .position(x: mapping.contentFrame.midX, y: mapping.contentFrame.midY)
                        .allowsHitTesting(false)
                    }
                } else {
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
            .gesture(pointerGesture(mapping: mapping))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("2D mosaic viewport")
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
               model.tool.operation != nil {
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
                if model.tool.operation != nil {
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

struct MapScaleBarSpecification: Equatable, Sendable {
    let lengthMeters: Double
    let widthFraction: Double
    let midpointLabel: String
    let endpointLabel: String

    static func make(domainWidth: Double, displayedWidth: CGFloat) -> MapScaleBarSpecification? {
        guard domainWidth.isFinite, domainWidth > 0,
              displayedWidth.isFinite, displayedWidth > 0 else { return nil }
        let targetLength = domainWidth * 0.28
        let exponent = floor(log10(targetLength))
        let power = pow(10, exponent)
        let multiplier = [5.0, 2.0, 1.0].first { $0 * power <= targetLength } ?? 1.0
        let length = multiplier * power
        guard length > 0, length <= domainWidth else { return nil }
        return MapScaleBarSpecification(
            lengthMeters: length,
            widthFraction: length / domainWidth,
            midpointLabel: label(for: length / 2),
            endpointLabel: label(for: length)
        )
    }

    private static func label(for meters: Double) -> String {
        if meters >= 1_000 {
            return String(format: meters.truncatingRemainder(dividingBy: 1_000) == 0
                          ? "%.0f km" : "%.1f km", meters / 1_000)
        }
        return String(format: meters.rounded() == meters ? "%.0f m" : "%.1f m", meters)
    }
}

private struct MapAnnotationsOverlay: View {
    let mode: DisplayMode
    let configuration: DecorativeMapConfiguration
    let domainWidth: Double
    let displayedWidth: CGFloat

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                if mode == .decorativeComposite {
                    decorativeLegend
                } else if mode == .waterDepth {
                    quantitativeWaterLegend
                }
                Spacer(minLength: 0)
                if let specification = MapScaleBarSpecification.make(
                    domainWidth: domainWidth,
                    displayedWidth: displayedWidth
                ) {
                    scaleBar(specification, availableWidth: proxy.size.width)
                }
            }
            .padding(10)
            .padding(.top, 82)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("map-annotations-overlay")
        }
    }

    private var decorativeLegend: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Land elevation")
                .font(.caption.weight(.semibold))
            legendStrip([ColorMap.landLow, ColorMap.landMiddle, ColorMap.landHigh])
            HStack {
                Text(valueLabel(configuration.landElevationMinimum))
                Spacer()
                Text(valueLabel(configuration.landElevationMaximum))
            }
            .font(.caption2)
            Text("Water depth")
                .font(.caption.weight(.semibold))
            legendStrip([
                ColorMap.waterVeryShallow, ColorMap.waterShallow,
                ColorMap.waterMedium, ColorMap.waterDeep,
            ])
            HStack {
                Text("0 m")
                Spacer()
                Text(valueLabel(configuration.waterDepthMaximum))
            }
            .font(.caption2)
            HStack(spacing: 6) {
                Circle().fill(ColorMap.wetSand.color).frame(width: 10, height: 10)
                Text("Wet sand")
                Circle().fill(ColorMap.shoreCyan.color).frame(width: 10, height: 10)
                Text("Water edge")
            }
            .font(.caption2)
            Text("Shallow water is translucent.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
    }

    private var quantitativeWaterLegend: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Water depth (m)")
                .font(.caption.weight(.semibold))
            legendStrip([ColorMap.waterDeep, ColorMap.waterVeryShallow])
            HStack {
                Text("0 m")
                Spacer()
                Text(valueLabel(configuration.waterDepthMaximum))
            }
            .font(.caption2)
        }
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
    }

    private func legendStrip(_ colors: [RGBA]) -> some View {
        LinearGradient(
            colors: colors.map(\.color),
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 142, height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func scaleBar(_ specification: MapScaleBarSpecification,
                          availableWidth: CGFloat) -> some View {
        let lineWidth = max(1, min(availableWidth * CGFloat(specification.widthFraction),
                                   availableWidth * 0.35))
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text("0").frame(width: 12, alignment: .leading)
                Spacer(minLength: 0)
                Text(specification.midpointLabel)
                Spacer(minLength: 0)
                Text(specification.endpointLabel)
            }
            .font(.caption2)
            .frame(width: lineWidth)
            HStack(spacing: 0) {
                Rectangle().fill(.primary).frame(width: 1, height: 8)
                Rectangle().fill(.primary).frame(height: 2)
                Rectangle().fill(.primary).frame(width: 1, height: 8)
            }
            .frame(width: lineWidth, height: 8)
        }
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scale bar from 0 to \(specification.endpointLabel)")
    }

    private func valueLabel(_ value: Float) -> String {
        String(format: abs(value) >= 10 ? "%.0f m" : "%.2g m", value)
    }
}

enum MosaicRaster {
    static func image(
        snapshot: SimulationSnapshot,
        mode: DisplayMode,
        palette: ColorPalette,
        decorativeConfiguration: DecorativeMapConfiguration = .default,
        policy: DisplayResolutionPolicy = .identicalCells,
        targetPixelSize: CGSize? = nil
    ) -> CGImage? {
        ViewportRenderActivity.recordMosaicRasterization()
        if mode == .decorativeComposite {
            return DecorativeCompositeRasterizer.image(
                bedElevation: snapshot.bedElevation,
                waterDepth: snapshot.waterDepth,
                width: snapshot.width,
                height: snapshot.height,
                configuration: decorativeConfiguration,
                policy: policy,
                targetPixelSize: targetPixelSize
            )
        }
        return ScalarRasterizer.image(
            engineValues: snapshot.values(for: mode),
            width: snapshot.width,
            height: snapshot.height,
            signed: mode == .surfaceDeviation,
            palette: palette,
            range: mode == .waterDepth
                ? ScalarRange(minimum: 0, maximum: decorativeConfiguration.waterDepthMaximum)
                : nil,
            policy: policy,
            targetPixelSize: targetPixelSize
        )
    }
}
