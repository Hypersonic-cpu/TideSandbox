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

    func testDecorativeCompositeUsesOpticalWaterAndTwoSidedShorelines() throws {
        let configuration = DecorativeMapConfiguration(
            landElevationMinimum: 0,
            landElevationMaximum: 1,
            waterDepthMaximum: 2,
            hClear: 0.6,
            hShallow: 0.1,
            hDeep: 1.7,
            hShallowAccent: 0.3,
            visualWetThreshold: 0.01,
            shoreHighlightStrength: 0.35,
            wetSandStrength: 0.2,
            autoRangeEnabled: false
        )
        XCTAssertTrue(configuration.isValid)
        XCTAssertEqual(ColorMap.terrainBase(0, configuration: configuration), ColorMap.landLow)
        XCTAssertEqual(ColorMap.terrainBase(1, configuration: configuration), ColorMap.landHigh)
        let middleLand = ColorMap.terrainBase(0.5, configuration: configuration)
        XCTAssertGreaterThan(middleLand.red, 180)
        XCTAssertGreaterThan(middleLand.green, 180)
        XCTAssertGreaterThan(middleLand.blue, 140)
        let submergedMiddle = ColorMap.submergedTerrainBase(
            0.5,
            configuration: configuration
        )
        XCTAssertNotEqual(submergedMiddle, middleLand)
        XCTAssertNotEqual(submergedMiddle, ColorMap.submergedBed)
        XCTAssertEqual(configuration.submergedBedCoolingStrength, 0.15)
        XCTAssertEqual(ColorMap.waterOpticalOpacity(depth: 0, configuration: configuration), 0)
        XCTAssertGreaterThan(
            ColorMap.waterOpticalOpacity(depth: 0.2, configuration: configuration), 0
        )
        XCTAssertLessThan(
            ColorMap.waterOpticalOpacity(depth: 0.2, configuration: configuration),
            ColorMap.waterOpticalOpacity(depth: 1.5, configuration: configuration)
        )
        let opacitySamples = (0...100).map {
            ColorMap.waterOpticalOpacity(
                depth: Float($0) * configuration.waterDepthMaximum / 100,
                configuration: configuration
            )
        }
        XCTAssertTrue(zip(opacitySamples, opacitySamples.dropFirst()).allSatisfy {
            $0.0 <= $0.1
        })
        let dry = ColorMap.decorativeComposite(
            bedElevation: 0.5,
            waterDepth: 0,
            configuration: configuration
        )
        let shallow = ColorMap.decorativeComposite(
            bedElevation: 0.5,
            waterDepth: 0.08,
            configuration: configuration
        )
        let deep = ColorMap.decorativeComposite(
            bedElevation: 0.5,
            waterDepth: 2,
            configuration: configuration
        )
        XCTAssertEqual(dry, middleLand)
        XCTAssertNotEqual(shallow, dry, "shallow water retains but does not replace bed color")
        XCTAssertNotEqual(
            shallow,
            ColorMap.waterGradient(depth: 0.08, configuration: configuration),
            "shallow water must retain a visible submerged-bed contribution"
        )
        XCTAssertLessThan(deep.red, shallow.red)
        XCTAssertLessThan(deep.green, shallow.green)
        XCTAssertLessThan(deep.blue, shallow.blue)
        XCTAssertEqual(
            ColorMap.decorativeComposite(
                bedElevation: .nan,
                waterDepth: 1,
                configuration: configuration
            ),
            ColorMap.invalid
        )

        var bed = [Float](repeating: 0.5, count: 25)
        var depth = [Float](repeating: 0, count: 25)
        for row in 1...3 {
            for column in 1...3 {
                depth[row * 5 + column] = 1
            }
        }
        let snapshot = SimulationSnapshot(
            width: 5,
            height: 5,
            domainWidth: 5,
            domainHeight: 5,
            bedElevation: bed,
            waterDepth: depth,
            surfaceElevation: zip(bed, depth).map { $0 + $1 },
            surfaceDeviation: [Float](repeating: 0, count: 25),
            velocityMagnitude: [Float](repeating: 0, count: 25),
            wetMask: depth.map { $0 > configuration.visualWetThreshold ? 1 : 0 },
            diagnostics: .empty
        )
        let image = try XCTUnwrap(MosaicRaster.image(
            snapshot: snapshot,
            mode: .decorativeComposite,
            palette: .grayscale,
            decorativeConfiguration: configuration
        ))
        let providerData = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(providerData))
        func pixel(_ column: Int, _ row: Int) -> RGBA {
            let offset = (row * 5 + column) * 4
            return RGBA(red: bytes[offset], green: bytes[offset + 1],
                        blue: bytes[offset + 2], alpha: bytes[offset + 3])
        }
        let wetInterior = ColorMap.decorativeComposite(
            bedElevation: 0.5, waterDepth: 1, configuration: configuration
        )
        XCTAssertEqual(pixel(2, 2), wetInterior)
        let wetEdge = ColorMap.decorativeShoreline(
            wetInterior, isWet: true, wetEdge: true, dryEdge: false, configuration: configuration
        )
        XCTAssertEqual(pixel(1, 2), wetEdge)
        let dryBase = ColorMap.decorativeComposite(
            bedElevation: 0.5, waterDepth: 0, configuration: configuration
        )
        let dryEdge = ColorMap.decorativeShoreline(
            dryBase, isWet: false, wetEdge: false, dryEdge: true, configuration: configuration
        )
        XCTAssertEqual(pixel(0, 2), dryEdge)
        XCTAssertEqual(pixel(0, 0), dryBase)
        XCTAssertGreaterThan(pixel(1, 2).red, 40, "shoreline uses a light cyan, never a dark outline")

        let almostClear = ColorMap.decorativeComposite(
            bedElevation: 0.5,
            waterDepth: configuration.visualWetThreshold.nextUp,
            configuration: configuration
        )
        let highlightedAlmostClear = ColorMap.decorativeShoreline(
            almostClear,
            isWet: true,
            wetEdge: true,
            dryEdge: false,
            configuration: configuration
        )
        XCTAssertNotEqual(highlightedAlmostClear, almostClear)
        XCTAssertGreaterThan(highlightedAlmostClear.red, 100)
        XCTAssertGreaterThan(highlightedAlmostClear.green, 100)
        XCTAssertGreaterThan(highlightedAlmostClear.blue, 100)

        bed = [Float](repeating: 0.5, count: 9)
        depth = [Float](repeating: 0, count: 9)
        for (column, row) in [(1, 1), (0, 1), (2, 1), (1, 0), (1, 2)] {
            depth[row * 3 + column] = 1
        }
        let diagonalOnly = try XCTUnwrap(DecorativeCompositeRasterizer.image(
            bedElevation: bed,
            waterDepth: depth,
            width: 3,
            height: 3,
            configuration: configuration,
            policy: .identicalCells
        ))
        let diagonalData = try XCTUnwrap(diagonalOnly.dataProvider?.data)
        let diagonalBytes = try XCTUnwrap(CFDataGetBytePtr(diagonalData))
        let centerOffset = (1 * 3 + 1) * 4
        XCTAssertEqual(
            RGBA(red: diagonalBytes[centerOffset], green: diagonalBytes[centerOffset + 1],
                 blue: diagonalBytes[centerOffset + 2], alpha: diagonalBytes[centerOffset + 3]),
            wetInterior,
            "diagonal-only dry contact does not create a 4-neighbor shoreline"
        )
    }

    func testDecorativeLegendRangesAndScaleBarUseStableConfiguration() throws {
        let configuration = DecorativeMapConfiguration(
            landElevationMinimum: -2,
            landElevationMaximum: 6,
            waterDepthMaximum: 4,
            hClear: 1.2,
            hShallow: 0.2,
            hDeep: 3.4,
            hShallowAccent: 0.6,
            visualWetThreshold: 1.0e-6,
            shoreHighlightStrength: 0.35,
            wetSandStrength: 0.2,
            autoRangeEnabled: false
        )
        let snapshot = SimulationSnapshot(
            width: 2,
            height: 1,
            domainWidth: 2,
            domainHeight: 1,
            bedElevation: [0, 0],
            waterDepth: [0, 2],
            surfaceElevation: [0, 2],
            surfaceDeviation: [0, 0],
            velocityMagnitude: [0, 0],
            wetMask: [0, 1],
            diagnostics: .empty
        )
        let image = try XCTUnwrap(MosaicRaster.image(
            snapshot: snapshot,
            mode: .waterDepth,
            palette: .blueWhite,
            decorativeConfiguration: configuration
        ))
        let providerData = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(providerData))
        XCTAssertEqual(
            RGBA(red: bytes[4], green: bytes[5], blue: bytes[6], alpha: bytes[7]),
            ColorMap.map(2, range: ScalarRange(minimum: 0, maximum: 4), palette: .blueWhite)
        )
        let specification = try XCTUnwrap(MapScaleBarSpecification.make(
            domainWidth: 1_000,
            displayedWidth: 1_000
        ))
        XCTAssertEqual(specification.lengthMeters, 200)
        XCTAssertEqual(specification.widthFraction, 0.2)
        XCTAssertEqual(specification.midpointLabel, "100 m")
        XCTAssertEqual(specification.endpointLabel, "200 m")
        XCTAssertTrue([1, 2, 5].contains(
            specification.lengthMeters / pow(10, floor(log10(specification.lengthMeters)))
        ))
        for domainWidth in [0.1, 1.0, 37.0, 1_000.0, 25_000.0] {
            for displayedWidth in [240.0, 800.0, 2_400.0] {
                let resized = try XCTUnwrap(MapScaleBarSpecification.make(
                    domainWidth: domainWidth,
                    displayedWidth: displayedWidth
                ))
                XCTAssertGreaterThan(resized.widthFraction, 0)
                XCTAssertLessThanOrEqual(resized.widthFraction, 0.28 + 1.0e-12)
                let normalized = resized.lengthMeters /
                    pow(10, floor(log10(resized.lengthMeters)))
                XCTAssertTrue([1, 2, 5].contains { abs($0 - normalized) < 1.0e-12 })
            }
        }
    }

    func testMandatoryCompositeTransitionSequenceThroughPolygonEngineEdits() throws {
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
        let configuration = DecorativeMapConfiguration(
            landElevationMinimum: 0,
            landElevationMaximum: 4,
            waterDepthMaximum: 4,
            hClear: 1.2,
            hShallow: 0.2,
            hDeep: 3.4,
            hShallowAccent: 0.6,
            visualWetThreshold: 1.0e-6,
            shoreHighlightStrength: 0.35,
            wetSandStrength: 0.2,
            autoRangeEnabled: false
        )
        let polygon = [4.0, 4.0, 12.0, 4.0, 12.0, 12.0, 4.0, 12.0]
        let polygonData = polygon.withUnsafeBytes { Data($0) }
        let centerIndex = 8 * seed.width + 8

        func stateAndColor() throws -> (SimulationSnapshot, RGBA) {
            let snapshot = SimulationSnapshot(bridge.snapshot())
            let image = try XCTUnwrap(MosaicRaster.image(
                snapshot: snapshot,
                mode: .decorativeComposite,
                palette: .blueWhite,
                decorativeConfiguration: configuration
            ))
            let data = try XCTUnwrap(image.dataProvider?.data)
            let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
            let displayRow = seed.height - 8 - 1
            let offset = (displayRow * seed.width + 8) * 4
            return (snapshot, RGBA(
                red: bytes[offset],
                green: bytes[offset + 1],
                blue: bytes[offset + 2],
                alpha: bytes[offset + 3]
            ))
        }

        let (deepState, deepColor) = try stateAndColor()
        XCTAssertEqual(deepState.waterDepth[centerIndex], 4)
        XCTAssertLessThan(deepColor.red, deepColor.blue)

        let submergedResult = bridge.applyMaterialPolygon(
            xyCoordinates: polygonData,
            operation: .addSand,
            amount: 1,
            target: .initialState
        )
        XCTAssertTrue(submergedResult.isChanged)
        let (submergedState, submergedColor) = try stateAndColor()
        XCTAssertEqual(submergedState.bedElevation[centerIndex], 1)
        XCTAssertEqual(submergedState.waterDepth[centerIndex], 3)
        XCTAssertNotEqual(submergedColor, deepColor)
        XCTAssertEqual(submergedState.diagnostics.simulatedTime, 0)

        let dryResult = bridge.applyMaterialPolygon(
            xyCoordinates: polygonData,
            operation: .addSand,
            amount: 3,
            target: .initialState
        )
        XCTAssertTrue(dryResult.isChanged)
        let (dryState, dryColor) = try stateAndColor()
        XCTAssertEqual(dryState.bedElevation[centerIndex], 4)
        XCTAssertEqual(dryState.waterDepth[centerIndex], 0)
        XCTAssertEqual(dryColor, ColorMap.landHigh)
        XCTAssertEqual(dryState.diagnostics.simulatedTime, 0)

        let rewettedResult = bridge.applyMaterialPolygon(
            xyCoordinates: polygonData,
            operation: .addWater,
            amount: 0.25,
            target: .initialState
        )
        XCTAssertTrue(rewettedResult.isChanged)
        let (rewettedState, rewettedColor) = try stateAndColor()
        XCTAssertEqual(rewettedState.bedElevation[centerIndex], 4)
        XCTAssertEqual(rewettedState.waterDepth[centerIndex], 0.25)
        XCTAssertNotEqual(rewettedColor, dryColor)
        XCTAssertNotEqual(
            rewettedColor,
            ColorMap.waterGradient(depth: 0.25, configuration: configuration)
        )
        XCTAssertEqual(rewettedState.diagnostics.simulatedTime, 0)
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

    func test2DRenderingCountersDoNotPerformMetalWork() throws {
        ViewportRenderActivity.reset()
        let snapshot = SimulationSnapshot(
            width: 2,
            height: 2,
            domainWidth: 2,
            domainHeight: 2,
            bedElevation: [0, 0, 0, 0],
            waterDepth: [0, 1, 0, 1],
            surfaceElevation: [0, 1, 0, 1],
            surfaceDeviation: [0, 0, 0, 0],
            velocityMagnitude: [0, 0, 0, 0],
            wetMask: [0, 1, 0, 1],
            diagnostics: .empty
        )
        XCTAssertNotNil(MosaicRaster.image(
            snapshot: snapshot,
            mode: .decorativeComposite,
            palette: .blueWhite
        ))
        #if DEBUG
        XCTAssertEqual(ViewportRenderActivity.counters.mosaicRasterizations, 1)
        XCTAssertGreaterThanOrEqual(ViewportRenderActivity.counters.scalarResamples, 2)
        XCTAssertEqual(ViewportRenderActivity.counters.metalSnapshotUpdates, 0)
        XCTAssertEqual(ViewportRenderActivity.counters.metalDraws, 0)
        #else
        XCTAssertEqual(ViewportRenderActivity.counters, .init())
        #endif
    }

    func testResolutionPoliciesMatchAnalyticalSamplingDefinitions() throws {
        let exactInput: [Float] = [0, 1, 2, 10, 11, 12]
        XCTAssertEqual(
            ScalarResampler.values(
                engineValues: exactInput,
                width: 3,
                height: 2,
                outputWidth: 3,
                outputHeight: 2,
                policy: .identicalCells
            ),
            [10, 11, 12, 0, 1, 2]
        )
        XCTAssertNil(ScalarResampler.values(
            engineValues: exactInput,
            width: 3,
            height: 2,
            outputWidth: 6,
            outputHeight: 4,
            policy: .identicalCells
        ))

        let nearest = try XCTUnwrap(ScalarResampler.values(
            engineValues: [1, 2, 3, 4],
            width: 2,
            height: 2,
            outputWidth: 4,
            outputHeight: 4,
            policy: .nearestCell
        ))
        XCTAssertEqual(nearest, [
            3, 3, 4, 4,
            3, 3, 4, 4,
            1, 1, 2, 2,
            1, 1, 2, 2,
        ])

        // Samples of f(x, y) = 2x + 3y must remain exact under bilinear interpolation.
        let planarTopDown: [Float] = [
            0, 2, 4, 6,
            3, 5, 7, 9,
            6, 8, 10, 12,
            9, 11, 13, 15,
        ]
        let planarEngineOrder = (0..<4).reversed().flatMap { row in
            Array(planarTopDown[(row * 4)..<((row + 1) * 4)])
        }
        let bilinear = try XCTUnwrap(ScalarResampler.values(
            engineValues: planarEngineOrder,
            width: 4,
            height: 4,
            outputWidth: 2,
            outputHeight: 2,
            policy: .bilinearScalar
        ))
        XCTAssertEqual(bilinear[0], 2.5, accuracy: 8 * Float.ulpOfOne)
        XCTAssertEqual(bilinear[1], 6.5, accuracy: 8 * Float.ulpOfOne)
        XCTAssertEqual(bilinear[2], 8.5, accuracy: 8 * Float.ulpOfOne)
        XCTAssertEqual(bilinear[3], 12.5, accuracy: 8 * Float.ulpOfOne)

        let areaAverage = try XCTUnwrap(ScalarResampler.values(
            engineValues: [2, 4, 6, 8, 10, 20, 30, 40],
            width: 4,
            height: 2,
            outputWidth: 2,
            outputHeight: 1,
            policy: .areaAverage
        ))
        XCTAssertEqual(areaAverage, [9, 21])
    }

    func testAreaAverageConservesMeanAndSamplingNeverMutatesEngineValues() throws {
        let input = (0..<15).map { Float($0 * $0 - 3 * $0) }
        let original = input
        let downsampled = try XCTUnwrap(ScalarResampler.values(
            engineValues: input,
            width: 5,
            height: 3,
            outputWidth: 3,
            outputHeight: 2,
            policy: .areaAverage
        ))
        let inputMean = input.reduce(0, +) / Float(input.count)
        let outputMean = downsampled.reduce(0, +) / Float(downsampled.count)
        XCTAssertEqual(outputMean, inputMean, accuracy: 32 * Float.ulpOfOne * abs(inputMean))
        XCTAssertEqual(input, original, "display resampling must not feed back into Engine data")

        let withInvalid: [Float] = [1, 2, 3, .nan]
        let averagedInvalid = try XCTUnwrap(ScalarResampler.values(
            engineValues: withInvalid,
            width: 2,
            height: 2,
            outputWidth: 1,
            outputHeight: 1,
            policy: .areaAverage
        ))
        XCTAssertTrue(averagedInvalid[0].isNaN)
        let bilinearInvalid = try XCTUnwrap(ScalarResampler.values(
            engineValues: withInvalid,
            width: 2,
            height: 2,
            outputWidth: 1,
            outputHeight: 1,
            policy: .bilinearScalar
        ))
        XCTAssertTrue(bilinearInvalid[0].isNaN)
    }

    func testRasterDimensionsFollowPolicyWithoutImplicitInterpolation() throws {
        let values = (0..<32).map(Float.init)
        for policy in DisplayResolutionPolicy.allCases {
            let image = try XCTUnwrap(ScalarRasterizer.image(
                engineValues: values,
                width: 8,
                height: 4,
                signed: false,
                palette: .grayscale,
                policy: policy,
                targetPixelSize: CGSize(width: 37, height: 23)
            ))
            XCTAssertEqual(image.width, policy == .nearestCell || policy == .bilinearScalar ? 37 : 8)
            XCTAssertEqual(image.height, policy == .nearestCell || policy == .bilinearScalar ? 23 : 4)
            XCTAssertFalse(image.shouldInterpolate)
        }
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
    func testEveryBuiltInPresetHasValidatedHydrographyAndLoadsThroughBridge() throws {
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
            switch preset {
            case .flat16, .centerBump32, .unevenBed128:
                XCTAssertLessThanOrEqual(abs(surfaceRange), 4 * Double(Float.ulpOfOne))
                XCTAssertEqual(try XCTUnwrap(wetSurfaces.min()), 4,
                               accuracy: 4 * Double(Float.ulpOfOne))
                XCTAssertEqual(try XCTUnwrap(wetSurfaces.max()), 4,
                               accuracy: 4 * Double(Float.ulpOfOne))
                XCTAssertGreaterThan(try XCTUnwrap(seed.waterDepth.min()), 3.5)
            case .coastChannel512, .drivenOceanWave512:
                let dryFraction = Double(seed.waterDepth.lazy.filter { $0 == 0 }.count) /
                    Double(count)
                XCTAssertGreaterThanOrEqual(dryFraction, 0.02)
                XCTAssertLessThanOrEqual(dryFraction, 0.35)
                if preset == .coastChannel512 {
                    XCTAssertGreaterThanOrEqual(abs(surfaceRange), 0.50)
                    let leftMean = meanWetSurface(seed: seed, columns: 0..<384)
                    let rightMean = meanWetSurface(seed: seed, columns: 420..<512)
                    XCTAssertGreaterThanOrEqual(rightMean - leftMean, 0.45)
                    XCTAssertTrue(hasWetConnectionFromRaisedBand(seed: seed))
                    XCTAssertEqual(seed.boundaries, .reflective)
                } else {
                    XCTAssertLessThanOrEqual(abs(surfaceRange), 8 * Double(Float.ulpOfOne))
                    XCTAssertEqual(seed.boundaries.right.type, .drivenHeight)
                    XCTAssertEqual(seed.boundaries.right.meanSurfaceElevation, 1.2)
                    XCTAssertEqual(seed.boundaries.right.amplitude, 0.25)
                    XCTAssertEqual(seed.boundaries.right.periodSeconds, 8)
                    XCTAssertEqual(seed.boundaries.right.rampSeconds, 2)
                }
            }

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
                waterDepth: seed.depthData,
                minimumBed: seed.worldLimits.minimumBedElevation,
                maximumSurface: seed.worldLimits.maximumSurfaceElevation,
                boundaries: seed.boundaries.bridgeConfiguration
            ))
            let snapshot = SimulationSnapshot(bridge.snapshot())
            XCTAssertEqual(snapshot.width, seed.width)
            XCTAssertEqual(snapshot.height, seed.height)
            XCTAssertEqual(snapshot.bedElevation.count, count)
            XCTAssertEqual(snapshot.waterDepth.count, count)
            XCTAssertEqual(snapshot.wetMask.count, count)
            XCTAssertTrue(snapshot.diagnostics.isFinite)
            XCTAssertTrue(snapshot.velocityMagnitude.allSatisfy { $0 == 0 })
        }
    }

    private func meanWetSurface(seed: SceneSeed, columns: Range<Int>) -> Double {
        var sum = 0.0
        var count = 0
        for row in 0..<seed.height {
            for column in columns {
                precondition(column < seed.width)
                let index = row * seed.width + column
                guard seed.waterDepth[index] > 0 else { continue }
                sum += Double(seed.bedElevation[index] + seed.waterDepth[index])
                count += 1
            }
        }
        return sum / Double(count)
    }

    private func hasWetConnectionFromRaisedBand(seed: SceneSeed) -> Bool {
        var visited = [Bool](repeating: false, count: seed.width * seed.height)
        var queue = [Int]()
        for row in 0..<seed.height {
            for column in Int(Double(seed.width) * 0.82)..<seed.width {
                let index = row * seed.width + column
                if seed.waterDepth[index] > 0 {
                    visited[index] = true
                    queue.append(index)
                }
            }
        }
        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let column = index % seed.width
            let row = index / seed.width
            if Double(column) / Double(seed.width) <= 0.75 { return true }
            let neighbors = [
                (column - 1, row), (column + 1, row),
                (column, row - 1), (column, row + 1),
            ]
            for (nextColumn, nextRow) in neighbors
            where nextColumn >= 0 && nextColumn < seed.width &&
                nextRow >= 0 && nextRow < seed.height {
                let next = nextRow * seed.width + nextColumn
                if !visited[next], seed.waterDepth[next] > 0 {
                    visited[next] = true
                    queue.append(next)
                }
            }
        }
        return false
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
        XCTAssertTrue(bridge.applyMaterialBrush(
            x: 8.5,
            y: 8.5,
            radius: 2,
            operation: .addSand,
            amount: 0.5,
            falloff: .constant,
            target: .pausedCurrentState
        ).isChanged)
        let polygon = [2.0, 2.0, 6.0, 2.0, 6.0, 6.0, 2.0, 6.0]
        let polygonData = polygon.withUnsafeBytes { Data($0) }
        XCTAssertTrue(bridge.applyMaterialPolygon(
            xyCoordinates: polygonData,
            operation: .removeSand,
            amount: 0.25,
            target: .pausedCurrentState
        ).isChanged)
        let edited = SimulationSnapshot(bridge.snapshot())
        XCTAssertEqual(edited.bedElevation[3 * 16 + 3], -0.25)
        bridge.reset()
        let reset = SimulationSnapshot(bridge.snapshot())
        XCTAssertEqual(reset.bedElevation[3 * 16 + 3], 0)
    }
}
