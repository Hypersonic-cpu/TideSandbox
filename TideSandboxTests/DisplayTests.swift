import CoreGraphics
import XCTest
@testable import TideSandbox

@MainActor
final class DisplayTests: XCTestCase {
    func testExactCellMappingAtEveryRequiredScale() throws {
        for size in [16, 32, 128, 512] {
            let viewSize = CGSize(width: 900, height: 700)
            let mapping = try XCTUnwrap(GridDisplayMapping(
                gridWidth: size,
                gridHeight: size,
                viewSize: viewSize
            ))
            XCTAssertEqual(mapping.contentFrame.width, 700, accuracy: 1e-12)
            XCTAssertEqual(mapping.contentFrame.height, 700, accuracy: 1e-12)
            XCTAssertEqual(
                mapping.cell(at: CGPoint(x: mapping.contentFrame.minX + 0.25 * mapping.tileSize,
                                         y: mapping.contentFrame.minY + 0.25 * mapping.tileSize)),
                GridCell(column: 0, row: size - 1)
            )
            XCTAssertEqual(
                mapping.cell(at: CGPoint(x: mapping.contentFrame.maxX - 0.25 * mapping.tileSize,
                                         y: mapping.contentFrame.maxY - 0.25 * mapping.tileSize)),
                GridCell(column: size - 1, row: 0)
            )
            XCTAssertNil(mapping.cell(at: CGPoint(x: mapping.contentFrame.maxX,
                                                   y: mapping.contentFrame.midY)))
            for cell in [GridCell(column: 0, row: 0),
                         GridCell(column: size / 2, row: size / 3),
                         GridCell(column: size - 1, row: size - 1)] {
                let rect = try XCTUnwrap(mapping.tileRect(column: cell.column, row: cell.row))
                XCTAssertEqual(mapping.cell(at: CGPoint(x: rect.midX, y: rect.midY)), cell)
            }
        }
    }

    func testNonSquareResizeAndPhysicalCoordinateMapping() throws {
        let mapping = try XCTUnwrap(GridDisplayMapping(
            gridWidth: 32,
            gridHeight: 16,
            viewSize: CGSize(width: 640, height: 480)
        ))
        XCTAssertEqual(mapping.contentFrame, CGRect(x: 0, y: 80, width: 640, height: 320))
        let physical = try XCTUnwrap(mapping.physicalPoint(
            at: CGPoint(x: 160, y: 160),
            domainWidth: 64,
            domainHeight: 16
        ))
        XCTAssertEqual(physical.x, 16, accuracy: 1e-12)
        XCTAssertEqual(physical.y, 12, accuracy: 1e-12)
        let roundTrip = mapping.viewPoint(
            forPhysicalPoint: physical,
            domainWidth: 64,
            domainHeight: 16
        )
        XCTAssertEqual(roundTrip.x, 160, accuracy: 1e-12)
        XCTAssertEqual(roundTrip.y, 160, accuracy: 1e-12)
    }

    func testColorMapsHaveAnalyticalEndpointsAndInvalidColor() {
        let range = ScalarRange(minimum: -1, maximum: 1)
        XCTAssertEqual(
            ColorMap.map(-1, range: range, palette: .grayscale),
            RGBA(red: 0, green: 0, blue: 0, alpha: 255)
        )
        XCTAssertEqual(
            ColorMap.map(1, range: range, palette: .grayscale),
            RGBA(red: 255, green: 255, blue: 255, alpha: 255)
        )
        XCTAssertEqual(
            ColorMap.map(0, range: range, palette: .diverging),
            RGBA(red: 241, green: 241, blue: 236, alpha: 255)
        )
        XCTAssertEqual(ColorMap.map(.nan, range: range, palette: .sand), ColorMap.invalid)
        XCTAssertEqual(
            ScalarRange.finiteRange(of: [-2, 0.5, .nan], signed: true),
            ScalarRange(minimum: -2, maximum: 2)
        )
    }

    func testRasterUsesOneUninterpolatedPixelPerCellAndFlipsOnlyDisplayAxis() throws {
        let snapshot = SimulationSnapshot(
            width: 2,
            height: 2,
            domainWidth: 2,
            domainHeight: 2,
            bedElevation: [0, 1, 2, 3],
            waterDepth: [0, 0, 0, 0],
            surfaceElevation: [0, 1, 2, 3],
            surfaceDeviation: [0, 0, 0, 0],
            velocityMagnitude: [0, 0, 0, 0],
            wetMask: [0, 0, 0, 0],
            diagnostics: .empty
        )
        let image = try XCTUnwrap(MosaicRaster.image(
            snapshot: snapshot,
            mode: .bedElevation,
            palette: .grayscale
        ))
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        XCTAssertFalse(image.shouldInterpolate)
        let providerData = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(providerData))
        XCTAssertEqual(bytes[0], 170, accuracy: 1) // Engine row 1, value 2/3.
        XCTAssertEqual(bytes[4], 255, accuracy: 1) // Engine row 1, value 3/3.
        XCTAssertEqual(bytes[8], 0, accuracy: 1)   // Engine row 0, value 0/3.
        XCTAssertEqual(bytes[12], 85, accuracy: 1) // Engine row 0, value 1/3.
    }

    func testBrushAndPolygonPointerMappingAtAllScales() throws {
        for size in [16, 32, 128, 512] {
            let mapping = try XCTUnwrap(GridDisplayMapping(
                gridWidth: size,
                gridHeight: size,
                viewSize: CGSize(width: 768, height: 700)
            ))
            let target = GridCell(column: size / 4, row: 3 * size / 4)
            let rect = try XCTUnwrap(mapping.tileRect(column: target.column, row: target.row))
            let point = try XCTUnwrap(mapping.physicalPoint(
                at: CGPoint(x: rect.midX, y: rect.midY),
                domainWidth: Double(size),
                domainHeight: Double(size)
            ))
            XCTAssertEqual(point.x, CGFloat(target.column) + 0.5, accuracy: 1e-10)
            XCTAssertEqual(point.y, CGFloat(target.row) + 0.5, accuracy: 1e-10)
            XCTAssertEqual(
                mapping.viewPoint(
                    forPhysicalPoint: point,
                    domainWidth: Double(size),
                    domainHeight: Double(size)
                ),
                CGPoint(x: rect.midX, y: rect.midY)
            )
        }
    }
}

@MainActor
final class BridgeTests: XCTestCase {
    func testEveryBuiltInPresetIsFiniteLevelWaterAndLoadsThroughBridge() throws {
        for preset in SimulationPreset.allCases {
            let seed = preset.makeSeed()
            let count = seed.width * seed.height

            XCTAssertEqual(seed.height, seed.width, "\(preset.title) must be square")
            XCTAssertEqual(seed.bedElevation.count, count)
            XCTAssertEqual(seed.waterDepth.count, count)
            XCTAssertTrue(seed.bedElevation.allSatisfy(\.isFinite))
            XCTAssertTrue(seed.waterDepth.allSatisfy { $0.isFinite && $0 >= 0 })

            let wetSurfaces = zip(seed.bedElevation, seed.waterDepth)
                .filter { $0.1 > 0 }
                .map { Double($0.0) + Double($0.1) }
            let surfaceRange = try XCTUnwrap(wetSurfaces.min()).distance(
                to: try XCTUnwrap(wetSurfaces.max())
            )
            XCTAssertLessThanOrEqual(
                abs(surfaceRange),
                4 * Double(Float.ulpOfOne),
                "\(preset.title) should initialize as level water"
            )

            let bridge = WSWaterEngineBridge(
                width: UInt(seed.width),
                height: UInt(seed.height),
                domainWidth: seed.domainWidth,
                domainHeight: seed.domainHeight
            )
            XCTAssertTrue(bridge.load(
                width: UInt(seed.width),
                height: UInt(seed.height),
                domainWidth: seed.domainWidth,
                domainHeight: seed.domainHeight,
                bedElevation: seed.bedData,
                waterDepth: seed.depthData
            ))
            let snapshot = SimulationSnapshot(bridge.snapshot())
            XCTAssertEqual(snapshot.width, seed.width)
            XCTAssertEqual(snapshot.height, seed.height)
            XCTAssertEqual(snapshot.bedElevation.count, count)
            XCTAssertEqual(snapshot.waterDepth.count, count)
            XCTAssertEqual(snapshot.wetMask.count, count)
            XCTAssertTrue(snapshot.diagnostics.isFinite)
        }
    }

    func testSnapshotControlsAndTerrainCommands() throws {
        let seed = SimulationPreset.flat16.makeSeed()
        let bridge = WSWaterEngineBridge(
            width: UInt(seed.width),
            height: UInt(seed.height),
            domainWidth: seed.domainWidth,
            domainHeight: seed.domainHeight
        )
        XCTAssertTrue(bridge.load(
            width: UInt(seed.width),
            height: UInt(seed.height),
            domainWidth: seed.domainWidth,
            domainHeight: seed.domainHeight,
            bedElevation: seed.bedData,
            waterDepth: seed.depthData
        ))
        XCTAssertEqual(bridge.advance(0.01), .success)
        XCTAssertEqual(bridge.snapshot().bedElevation.count, 16 * 16 * MemoryLayout<Float>.size)
        XCTAssertTrue(bridge.applyBrush(
            x: 8.5,
            y: 8.5,
            radius: 2,
            strength: 0.5,
            falloff: .constant,
            minimumBed: -1,
            maximumBed: 1
        ))
        let polygon = [2.0, 2.0, 6.0, 2.0, 6.0, 6.0, 2.0, 6.0]
        let polygonData = polygon.withUnsafeBytes { Data($0) }
        XCTAssertTrue(bridge.applyPolygon(
            xyCoordinates: polygonData,
            mode: .set,
            elevation: -0.25,
            minimumBed: -1,
            maximumBed: 1
        ))
        let edited = SimulationSnapshot(bridge.snapshot())
        XCTAssertEqual(edited.bedElevation[3 * 16 + 3], -0.25)
        bridge.reset()
        let reset = SimulationSnapshot(bridge.snapshot())
        XCTAssertEqual(reset.bedElevation[3 * 16 + 3], 0)
    }
}
