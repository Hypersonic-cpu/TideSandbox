import simd
import XCTest
@testable import TideSandbox

@MainActor
final class Render3DTests: XCTestCase {
    func testTopologyCountsIndexBoundsAndUpwardWindingAtRequiredScales() throws {
        for (width, height) in [(2, 2), (3, 2), (16, 16), (512, 512)] {
            let mesh = try HeightFieldMesh(width: width, height: height)
            XCTAssertEqual(mesh.vertexCount, width * height)
            XCTAssertEqual(mesh.indexCount, (width - 1) * (height - 1) * 6)
            XCTAssertTrue(mesh.indices.allSatisfy { Int($0) < mesh.vertexCount })

            for triangleStart in stride(from: 0, to: mesh.indices.count, by: 3) {
                let positions = try (0..<3).map { offset -> SIMD3<Float> in
                    let index = Int(mesh.indices[triangleStart + offset])
                    return try XCTUnwrap(HeightFieldMesh.worldPosition(
                        column: index % width,
                        row: index / width,
                        width: width,
                        height: height,
                        domainWidth: Float(width),
                        domainHeight: Float(height),
                        elevation: 0,
                        verticalScale: 1
                    ))
                }
                let normal = simd_cross(
                    positions[1] - positions[0],
                    positions[2] - positions[0]
                )
                XCTAssertGreaterThan(normal.y, 0)
                XCTAssertEqual(normal.x, 0, accuracy: Float.ulpOfOne)
                XCTAssertEqual(normal.z, 0, accuracy: Float.ulpOfOne)
            }
        }
    }

    func testCellCenterMappingKeepsEngineRowsPositiveZAndCentersDomain() throws {
        let lowerLeft = try XCTUnwrap(HeightFieldMesh.worldPosition(
            column: 0,
            row: 0,
            width: 4,
            height: 2,
            domainWidth: 8,
            domainHeight: 6,
            elevation: -2,
            verticalScale: 3
        ))
        let upperRight = try XCTUnwrap(HeightFieldMesh.worldPosition(
            column: 3,
            row: 1,
            width: 4,
            height: 2,
            domainWidth: 8,
            domainHeight: 6,
            elevation: 1,
            verticalScale: 3
        ))
        XCTAssertEqual(lowerLeft, SIMD3<Float>(-3, -6, -1.5))
        XCTAssertEqual(upperRight, SIMD3<Float>(3, 3, 1.5))
        XCTAssertGreaterThan(upperRight.z, lowerLeft.z)
    }

    func testSurfaceAndWetDrySemanticsAtThresholdNeighborhood() {
        XCTAssertEqual(
            HeightFieldScalar.surfaceElevation(bedElevation: -0.25, waterDepth: 0.75),
            0.5
        )
        XCTAssertEqual(
            HeightFieldScalar.surfaceElevation(bedElevation: 2, waterDepth: -1),
            2
        )
        let threshold: Float = 1.0e-6
        XCTAssertFalse(HeightFieldScalar.isWet(
            waterDepth: threshold.nextDown,
            minimumWetDepth: threshold
        ))
        XCTAssertFalse(HeightFieldScalar.isWet(
            waterDepth: threshold,
            minimumWetDepth: threshold
        ))
        XCTAssertTrue(HeightFieldScalar.isWet(
            waterDepth: threshold.nextUp,
            minimumWetDepth: threshold
        ))
    }

    func testElevationStatisticsMatchAnalyticalExtremaAndRejectInvalidFields() throws {
        let statistics = try XCTUnwrap(HeightFieldStatistics(
            bedElevation: [-2, 0.5, 1],
            waterDepth: [0.5, -0.25, 3]
        ))
        XCTAssertEqual(statistics.minimumBedElevation, -2)
        XCTAssertEqual(statistics.maximumBedElevation, 1)
        XCTAssertEqual(statistics.maximumWaterDepth, 3)
        XCTAssertEqual(statistics.maximumAbsoluteElevation, 4)

        XCTAssertNil(HeightFieldStatistics(bedElevation: [], waterDepth: []))
        XCTAssertNil(HeightFieldStatistics(bedElevation: [0], waterDepth: [0, 1]))
        XCTAssertNil(HeightFieldStatistics(bedElevation: [.nan], waterDepth: [1]))
        XCTAssertNil(HeightFieldStatistics(bedElevation: [0], waterDepth: [.infinity]))
        XCTAssertNil(HeightFieldStatistics(
            bedElevation: [.greatestFiniteMagnitude],
            waterDepth: [.greatestFiniteMagnitude]
        ))
    }

    func testCameraPresetsRemainFiniteAtExtremeAspectRatiosAndFitCorners() {
        let aspects: [Float] = [0.01, 0.1, 1, 10, 100]
        for preset in CameraPreset.allCases {
            for aspect in aspects {
                var camera = OrbitCamera()
                camera.apply(preset)
                camera.fitToDomain(
                    domainWidth: 64,
                    domainHeight: 32,
                    maximumAbsoluteElevation: 3,
                    verticalScale: 2,
                    aspectRatio: aspect
                )
                let matrices = camera.matrices()
                XCTAssertTrue(Self.isFinite(matrices.view))
                XCTAssertTrue(Self.isFinite(matrices.projection))
                XCTAssertTrue(Self.isFinite(matrices.viewProjection))
                XCTAssertTrue(matrices.position.x.isFinite)
                XCTAssertTrue(matrices.position.y.isFinite)
                XCTAssertTrue(matrices.position.z.isFinite)
                XCTAssertGreaterThan(matrices.nearPlane, 0)
                XCTAssertGreaterThan(matrices.farPlane, matrices.nearPlane)

                for x: Float in [-32, 32] {
                    for y: Float in [-6, 6] {
                        for z: Float in [-16, 16] {
                            let clip = matrices.viewProjection * SIMD4<Float>(x, y, z, 1)
                            XCTAssertGreaterThan(clip.w, 0)
                            let normalized = clip / clip.w
                            XCTAssertLessThanOrEqual(abs(normalized.x), 1.0001)
                            XCTAssertLessThanOrEqual(abs(normalized.y), 1.0001)
                            XCTAssertGreaterThanOrEqual(normalized.z, -0.0001)
                            XCTAssertLessThanOrEqual(normalized.z, 1.0001)
                        }
                    }
                }
            }
        }
    }

    func testPresetSelectionSynchronizesYawAndPitchAndPitchRemainsBounded() {
        let model = SimulationViewModel()
        for preset in CameraPreset.allCases {
            model.selectCameraPreset(preset)
            XCTAssertEqual(model.cameraPreset, preset)
            XCTAssertEqual(model.cameraYawDegrees, Double(preset.yawDegrees))
            XCTAssertEqual(model.cameraPitchDegrees, Double(preset.pitchDegrees))
        }
        model.setCameraYawDegrees(203)
        model.setCameraPitchDegrees(-27)
        XCTAssertNil(model.cameraPreset)
        XCTAssertEqual(model.cameraYawDegrees, 203)
        XCTAssertEqual(model.cameraPitchDegrees, -27)

        var camera = OrbitCamera()
        camera.setOrientation(yawDegrees: 180, pitchDegrees: -40)
        XCTAssertEqual(camera.state.yaw, .pi, accuracy: Float.ulpOfOne * 4)
        XCTAssertEqual(camera.state.pitch, -40 * .pi / 180, accuracy: Float.ulpOfOne * 4)
        camera.setOrientation(yawDegrees: 90, pitchDegrees: 30)
        XCTAssertEqual(camera.state.pitch, -5 * .pi / 180, accuracy: Float.ulpOfOne * 4)
        camera.setOrientation(yawDegrees: 90, pitchDegrees: -120)
        XCTAssertEqual(camera.state.pitch, -89 * .pi / 180, accuracy: Float.ulpOfOne * 4)
    }

    func testResourceTrackerRebuildsOnlyForDimensionChanges() throws {
        var tracker = HeightFieldResourceTracker()
        XCTAssertTrue(try tracker.register(width: 16, height: 16))
        XCTAssertFalse(try tracker.register(width: 16, height: 16))
        XCTAssertTrue(try tracker.register(width: 512, height: 512))
        XCTAssertFalse(try tracker.register(width: 512, height: 512))
        XCTAssertTrue(try tracker.register(width: 16, height: 32))
        XCTAssertEqual(tracker.rebuildCount, 3)
        XCTAssertThrowsError(try tracker.register(width: 1, height: 16))
    }

    func testViewportModeAndCameraChangesDoNotMutatePublishedSnapshot() async throws {
        let model = SimulationViewModel()
        for _ in 0..<200 where model.snapshot.width == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.snapshot.width, 32)
        let before = model.snapshot

        model.viewportMode = .heightField3D
        model.selectCameraPreset(.top)
        model.selectCameraPreset(.oppositeOblique)
        model.setCameraYawDegrees(205)
        model.setCameraPitchDegrees(-24)
        model.verticalExaggeration = 8
        model.waterOpacity = 0.6
        model.viewportMode = .mosaic2D

        let after = model.snapshot
        XCTAssertEqual(after.generation, before.generation)
        XCTAssertEqual(after.width, before.width)
        XCTAssertEqual(after.height, before.height)
        XCTAssertEqual(after.domainWidth, before.domainWidth)
        XCTAssertEqual(after.domainHeight, before.domainHeight)
        XCTAssertEqual(after.bedElevation, before.bedElevation)
        XCTAssertEqual(after.waterDepth, before.waterDepth)
        XCTAssertEqual(after.surfaceElevation, before.surfaceElevation)
        XCTAssertEqual(after.surfaceDeviation, before.surfaceDeviation)
        XCTAssertEqual(after.velocityMagnitude, before.velocityMagnitude)
        XCTAssertEqual(after.wetMask, before.wetMask)
        XCTAssertEqual(after.diagnostics, before.diagnostics)
    }

    private static func isFinite(_ matrix: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { column in
            let values = matrix[column]
            return values.x.isFinite && values.y.isFinite &&
                values.z.isFinite && values.w.isFinite
        }
    }
}
