import CoreGraphics
import MetalKit
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

    func testHeightFieldPickerUsesVisibleTopSurfaceAndRejectsMisses() throws {
        var lastContext: HeightFieldPickContext?
        for size in [16, 32, 128, 512] {
            let snapshot = Self.pickingSnapshot(size: size, waterDepth: 1)
            let currentContext = try XCTUnwrap(HeightFieldPickContext(
                snapshot: snapshot,
                verticalScale: 2,
                renderBias: 0.001,
                minimumWetDepth: 1.0e-6
            ))
            let center = try XCTUnwrap(currentContext.physicalPoint(for: HeightFieldPickRay(
                origin: SIMD3<Float>(0, 10, 0),
                direction: SIMD3<Float>(0, -1, 0)
            )))
            XCTAssertEqual(center.x, CGFloat(size) / 2, accuracy: 1.0e-5)
            XCTAssertEqual(center.y, CGFloat(size) / 2, accuracy: 1.0e-5)
            lastContext = currentContext
        }
        let context = try XCTUnwrap(lastContext)
        let cameraContext = try XCTUnwrap(HeightFieldPickContext(
            snapshot: Self.pickingSnapshot(size: 16, waterDepth: 1),
            verticalScale: 2,
            renderBias: 0.001,
            minimumWetDepth: 1.0e-6
        ))
        XCTAssertNil(context.physicalPoint(for: HeightFieldPickRay(
            origin: SIMD3<Float>(1_000, 10, 1_000),
            direction: SIMD3<Float>(0, -1, 0)
        )))

        for preset in CameraPreset.allCases {
            var camera = OrbitCamera()
            camera.apply(preset)
            camera.fitToDomain(
                domainWidth: 16,
                domainHeight: 16,
                maximumAbsoluteElevation: 1,
                verticalScale: 2,
                aspectRatio: 4 / 3
            )
            let point = try XCTUnwrap(HeightFieldPicker.physicalPoint(
                at: CGPoint(x: 400, y: 300),
                drawableSize: CGSize(width: 800, height: 600),
                viewProjection: camera.matrices().viewProjection,
                context: cameraContext
            ), "\(preset) camera must pick a visible cell")
            XCTAssertGreaterThanOrEqual(point.x, 0)
            XCTAssertLessThanOrEqual(point.x, 16)
            XCTAssertGreaterThanOrEqual(point.y, 0)
            XCTAssertLessThanOrEqual(point.y, 16)
        }

        var pannedCamera = OrbitCamera()
        pannedCamera.apply(.isometric)
        pannedCamera.fitToDomain(
            domainWidth: 16,
            domainHeight: 16,
            maximumAbsoluteElevation: 1,
            verticalScale: 2,
            aspectRatio: 4 / 3
        )
        pannedCamera.pan(deltaX: 10, deltaY: -8, viewportHeight: 600)
        pannedCamera.zoom(scrollDelta: -1)
        XCTAssertNotNil(HeightFieldPicker.physicalPoint(
            at: CGPoint(x: 400, y: 300),
            drawableSize: CGSize(width: 800, height: 600),
            viewProjection: pannedCamera.matrices().viewProjection,
            context: cameraContext
        ))

        let mixedSnapshot = SimulationSnapshot(
            width: 2,
            height: 2,
            domainWidth: 2,
            domainHeight: 2,
            bedElevation: [0, 0, 0, 0],
            waterDepth: [1, 0, 0, 0],
            surfaceElevation: [1, 0, 0, 0],
            surfaceDeviation: [0, 0, 0, 0],
            velocityMagnitude: [0, 0, 0, 0],
            wetMask: [1, 0, 0, 0],
            diagnostics: .empty
        )
        let mixedContext = try XCTUnwrap(HeightFieldPickContext(
            snapshot: mixedSnapshot,
            verticalScale: 1,
            renderBias: 0.002,
            minimumWetDepth: 1.0e-6
        ))
        let dryTriangleHit = try XCTUnwrap(mixedContext.physicalPoint(
            for: HeightFieldPickRay(
                origin: SIMD3<Float>(0.2, 10, 0.4),
                direction: simd_normalize(SIMD3<Float>(0.01, -1, 0))
            )
        ))
        XCTAssertEqual(dryTriangleHit.x, 1.3, accuracy: 1.0e-6)
        XCTAssertEqual(dryTriangleHit.y, 1.4, accuracy: 1.0e-6)
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

    func testOrbitPanAndZoomFollowAnalyticalCameraTransformsAndBounds() {
        var camera = OrbitCamera()
        camera.apply(.isometric)
        camera.fitToDomain(
            domainWidth: 80,
            domainHeight: 40,
            maximumAbsoluteElevation: 3,
            verticalScale: 2,
            aspectRatio: 1.5
        )
        let fittedState = camera.state

        camera.orbit(deltaX: 100, deltaY: -1_000)
        XCTAssertEqual(camera.state.target, fittedState.target)
        XCTAssertEqual(camera.state.distance, fittedState.distance)
        XCTAssertEqual(camera.state.yaw, fittedState.yaw + 0.6, accuracy: 1.0e-6)
        XCTAssertEqual(camera.state.pitch, -89 * .pi / 180, accuracy: 1.0e-6)

        camera.restore(fittedState)
        let matrices = camera.matrices()
        let forward = simd_normalize(camera.state.target - matrices.position)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_normalize(simd_cross(right, forward))
        let delta = SIMD2<Float>(32, -18)
        let viewportHeight: Float = 720
        let unitsPerPoint = 2 * fittedState.distance *
            tan(fittedState.fieldOfViewY * 0.5) / viewportHeight
        let expectedTarget = fittedState.target +
            (-right * delta.x - up * delta.y) * unitsPerPoint
        camera.pan(
            deltaX: delta.x,
            deltaY: delta.y,
            viewportHeight: viewportHeight
        )
        XCTAssertEqual(camera.state.target.x, expectedTarget.x, accuracy: 1.0e-6)
        XCTAssertEqual(camera.state.target.y, expectedTarget.y, accuracy: 1.0e-6)
        XCTAssertEqual(camera.state.target.z, expectedTarget.z, accuracy: 1.0e-6)
        XCTAssertEqual(camera.state.yaw, fittedState.yaw)
        XCTAssertEqual(camera.state.pitch, fittedState.pitch)
        XCTAssertEqual(camera.state.distance, fittedState.distance)

        camera.restore(fittedState)
        camera.zoom(scrollDelta: 1)
        XCTAssertEqual(
            camera.state.distance,
            fittedState.distance * exp(0.06),
            accuracy: 1.0e-5
        )
        camera.zoom(scrollDelta: -10_000)
        XCTAssertEqual(camera.state.distance, camera.minimumDistance)
        camera.zoom(scrollDelta: 10_000)
        XCTAssertEqual(camera.state.distance, camera.maximumDistance)
    }

    func testCameraRestoreRejectsInvalidStateWithoutMutation() {
        var camera = OrbitCamera()
        camera.fitToDomain(
            domainWidth: 64,
            domainHeight: 32,
            maximumAbsoluteElevation: 2,
            verticalScale: 4,
            aspectRatio: 1
        )
        let original = camera.state
        var invalidStates: [OrbitCameraState] = []

        var invalidTarget = original
        invalidTarget.target.x = .nan
        invalidStates.append(invalidTarget)
        var invalidYaw = original
        invalidYaw.yaw = .infinity
        invalidStates.append(invalidYaw)
        var invalidDistance = original
        invalidDistance.distance = 0
        invalidStates.append(invalidDistance)
        var invalidFieldOfView = original
        invalidFieldOfView.fieldOfViewY = .pi
        invalidStates.append(invalidFieldOfView)

        for invalidState in invalidStates {
            XCTAssertFalse(camera.restore(invalidState))
            XCTAssertEqual(camera.state, original)
        }
    }

    func testCameraSessionStoresOneTypedStateAndTracksInteractionSemantics() {
        let model = SimulationViewModel()
        let fitted = OrbitCameraState(
            target: SIMD3<Float>(3, -1, 7),
            yaw: -Float.pi / 2,
            pitch: -Float.pi / 4,
            distance: 42,
            fieldOfViewY: 50 * .pi / 180
        )
        model.acceptCameraState(fitted, reason: .interaction)
        XCTAssertEqual(model.cameraSessionState, fitted)
        XCTAssertNil(model.cameraPreset)
        XCTAssertEqual(model.cameraYawDegrees, 270, accuracy: 1.0e-9)
        XCTAssertEqual(model.cameraPitchDegrees, -45, accuracy: 1.0e-5)

        model.setCameraYawDegrees(120)
        model.setCameraPitchDegrees(-22)
        XCTAssertEqual(
            model.cameraSessionState?.yaw ?? .nan,
            Float(120) * .pi / 180,
            accuracy: 1.0e-6
        )
        XCTAssertEqual(
            model.cameraSessionState?.pitch ?? .nan,
            Float(-22) * .pi / 180,
            accuracy: 1.0e-6
        )

        let requestBeforeScale = model.cameraFitRequestID
        model.setVerticalExaggeration(9)
        XCTAssertEqual(model.verticalExaggeration, 9)
        XCTAssertNil(model.cameraSessionState)
        XCTAssertEqual(model.cameraFitRequestID, requestBeforeScale + 1)

        model.acceptCameraState(fitted, reason: .interaction)
        let requestBeforeFit = model.cameraFitRequestID
        model.requestCameraFit()
        XCTAssertNil(model.cameraSessionState)
        XCTAssertEqual(model.cameraFitRequestID, requestBeforeFit + 1)

        let requestBeforePreset = model.cameraFitRequestID
        model.selectCameraPreset(.oppositeOblique)
        XCTAssertEqual(model.cameraPreset, .oppositeOblique)
        XCTAssertEqual(model.cameraFitRequestID, requestBeforePreset + 1)
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

    func testRendererUpdatesOnlyScalarBuffersAndPreservesTopologyAndCamera() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        let view = InteractiveMTKView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            device: device
        )
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.drawableSize = CGSize(width: 800, height: 600)
        let renderer = try XCTUnwrap(HeightFieldRenderer(view: view))
        view.renderer = renderer
        ViewportRenderActivity.reset()

        let count = 16 * 16
        let originalBed = [Float](repeating: 0, count: count)
        let originalDepth = [Float](repeating: 1, count: count)
        let original = Self.snapshot(
            size: 16,
            bedElevation: originalBed,
            waterDepth: originalDepth,
            generation: 1
        )
        renderer.update(snapshot: original)
        let originalCamera = renderer.cameraState
        XCTAssertEqual(renderer.topologyRebuildCount, 1)
        XCTAssertEqual(renderer.currentScalarValues()?.bedElevation, originalBed)
        XCTAssertEqual(renderer.currentScalarValues()?.waterDepth, originalDepth)

        var editedBed = originalBed
        var editedDepth = originalDepth
        editedBed[8 * 16 + 8] = 0.75
        editedDepth[8 * 16 + 8] = 0.25
        editedDepth[3 * 16 + 4] = 0
        renderer.update(snapshot: Self.snapshot(
            size: 16,
            bedElevation: editedBed,
            waterDepth: editedDepth,
            generation: 2
        ))
        XCTAssertEqual(renderer.snapshotGeneration, 2)
        XCTAssertEqual(renderer.topologyRebuildCount, 1)
        XCTAssertEqual(renderer.cameraState, originalCamera)
        XCTAssertEqual(renderer.currentScalarValues()?.bedElevation, editedBed)
        XCTAssertEqual(renderer.currentScalarValues()?.waterDepth, editedDepth)

        view.terrainTool = .removeWater
        view.brushRadius = 2
        view.brushPreviewPoint = CGPoint(x: 8, y: 8)
        view.updatePreviewOverlay()
        let brushBounds = try XCTUnwrap(view.previewPath).boundingBox
        XCTAssertGreaterThan(brushBounds.width, 20)
        XCTAssertGreaterThan(brushBounds.height, 20)
        XCTAssertLessThan(brushBounds.width, 400)
        XCTAssertLessThan(brushBounds.height, 400)

        view.terrainTool = .polygon
        view.brushPreviewPoint = nil
        view.polygonPoints = [
            CGPoint(x: 5, y: 5),
            CGPoint(x: 11, y: 5),
            CGPoint(x: 11, y: 11),
        ]
        view.updatePreviewOverlay()
        let polygonBounds = try XCTUnwrap(view.previewPath).boundingBox
        XCTAssertGreaterThan(polygonBounds.width, 0)
        XCTAssertGreaterThan(polygonBounds.height, 0)

        renderer.update(snapshot: Self.snapshot(
            size: 32,
            bedElevation: [Float](repeating: -0.5, count: 32 * 32),
            waterDepth: [Float](repeating: 1.5, count: 32 * 32),
            generation: 3
        ))
        XCTAssertEqual(renderer.topologyRebuildCount, 2)
        #if DEBUG
        XCTAssertEqual(ViewportRenderActivity.counters.metalSnapshotUpdates, 3)
        XCTAssertEqual(ViewportRenderActivity.counters.mosaicRasterizations, 0)
        XCTAssertEqual(ViewportRenderActivity.counters.scalarResamples, 0)
        #else
        XCTAssertEqual(ViewportRenderActivity.counters, .init())
        #endif
    }

    func testRendererConsumesAcceleratedFieldBuffersWithoutReupload() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        let view = InteractiveMTKView(
            frame: CGRect(x: 0, y: 0, width: 640, height: 480),
            device: device
        )
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.drawableSize = CGSize(width: 640, height: 480)
        let renderer = try XCTUnwrap(HeightFieldRenderer(view: view))
        let bridge = WSWaterEngineBridge(
            width: 16, height: 16, domainWidth: 16, domainHeight: 16
        )
        XCTAssertTrue(bridge.setRequestedBackend(.metalGPU))
        let accelerated = SimulationSnapshot(bridge.snapshot()).withGeneration(1)
        XCTAssertNotNil(accelerated.acceleratedFieldBuffers)

        renderer.update(snapshot: accelerated)
        XCTAssertTrue(renderer.isUsingAcceleratedFieldBuffers)
        XCTAssertEqual(renderer.currentScalarValues()?.bedElevation,
                       accelerated.bedElevation)
        XCTAssertEqual(renderer.currentScalarValues()?.waterDepth,
                       accelerated.waterDepth)

        XCTAssertTrue(bridge.setRequestedBackend(.cpuReference))
        let cpu = SimulationSnapshot(bridge.snapshot()).withGeneration(2)
        renderer.update(snapshot: cpu)
        XCTAssertFalse(renderer.isUsingAcceleratedFieldBuffers)
        XCTAssertEqual(renderer.topologyRebuildCount, 1)
        XCTAssertEqual(renderer.currentScalarValues()?.waterDepth, cpu.waterDepth)
    }

    func testEditToolPausesImmediatelyAndPolygonSurvivesViewportSwitches() {
        let model = SimulationViewModel()
        model.togglePlayback()
        XCTAssertTrue(model.isPlaying)
        model.tool = .addWater
        XCTAssertFalse(model.isPlaying)

        model.tool = .polygon
        let points = [CGPoint(x: 4, y: 4), CGPoint(x: 12, y: 4), CGPoint(x: 8, y: 12)]
        points.forEach(model.addPolygonPoint)
        model.viewportMode = .heightField3D
        XCTAssertEqual(model.tool, .polygon)
        XCTAssertEqual(model.polygonPoints, points)
        model.viewportMode = .mosaic2D
        XCTAssertEqual(model.tool, .polygon)
        XCTAssertEqual(model.polygonPoints, points)
    }

    func testTwoDAndThreeDEditRoutesPublishIdenticalSharedState() async throws {
        for target in [WSEditTarget.initialState, .pausedCurrentState] {
            for operation in [WSMaterialOperation.addSand, .removeSand, .addWater, .removeWater] {
                let twoDModel = SimulationViewModel()
                let threeDModel = SimulationViewModel()
                try await Self.waitForInitialSnapshot(twoDModel)
                try await Self.waitForInitialSnapshot(threeDModel)
                if target == .pausedCurrentState {
                    let twoDGeneration = twoDModel.snapshot.generation
                    let threeDGeneration = threeDModel.snapshot.generation
                    twoDModel.step()
                    threeDModel.step()
                    try await Self.waitForGeneration(after: twoDGeneration, in: twoDModel)
                    try await Self.waitForGeneration(after: threeDGeneration, in: threeDModel)
                }

                twoDModel.viewportMode = .mosaic2D
                threeDModel.viewportMode = .heightField3D
                for model in [twoDModel, threeDModel] {
                    model.tool = .polygon
                    model.editTarget = target
                    model.polygonOperation = operation
                    model.polygonAmount = 0.2
                }
                let polygon = [
                    CGPoint(x: 8, y: 8),
                    CGPoint(x: 24, y: 8),
                    CGPoint(x: 24, y: 24),
                    CGPoint(x: 8, y: 24),
                ]
                polygon.forEach(twoDModel.addPolygonPoint)
                polygon.forEach(threeDModel.addPolygonPoint)
                let twoDGeneration = twoDModel.snapshot.generation
                let threeDGeneration = threeDModel.snapshot.generation
                twoDModel.completePolygon()
                threeDModel.completePolygon()
                try await Self.waitForGeneration(after: twoDGeneration, in: twoDModel)
                try await Self.waitForGeneration(after: threeDGeneration, in: threeDModel)

                let twoD = twoDModel.snapshot
                let threeD = threeDModel.snapshot
                XCTAssertEqual(twoD.bedElevation, threeD.bedElevation)
                XCTAssertEqual(twoD.waterDepth, threeD.waterDepth)
                XCTAssertEqual(twoD.surfaceElevation, threeD.surfaceElevation)
                XCTAssertEqual(twoD.surfaceDeviation, threeD.surfaceDeviation)
                XCTAssertEqual(twoD.velocityMagnitude, threeD.velocityMagnitude)
                XCTAssertEqual(twoD.wetMask, threeD.wetMask)
                XCTAssertEqual(twoD.diagnostics, threeD.diagnostics)
            }
        }
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
        model.wireframeTerrain = true
        model.wireframeWater = true
        model.showDomainBounds = true
        model.showSurfaceNormals = true
        model.showWetCellMask = true
        model.showCameraTarget = true
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

    private static func pickingSnapshot(size: Int, waterDepth: Float) -> SimulationSnapshot {
        let count = size * size
        return SimulationSnapshot(
            width: size,
            height: size,
            domainWidth: Double(size),
            domainHeight: Double(size),
            bedElevation: [Float](repeating: 0, count: count),
            waterDepth: [Float](repeating: waterDepth, count: count),
            surfaceElevation: [Float](repeating: waterDepth, count: count),
            surfaceDeviation: [Float](repeating: 0, count: count),
            velocityMagnitude: [Float](repeating: 0, count: count),
            wetMask: [UInt8](repeating: 1, count: count),
            diagnostics: .empty
        )
    }

    private static func snapshot(
        size: Int,
        bedElevation: [Float],
        waterDepth: [Float],
        generation: UInt64
    ) -> SimulationSnapshot {
        let surfaceElevation = zip(bedElevation, waterDepth).map {
            $0.0 + max($0.1, 0)
        }
        let wetMask: [UInt8] = waterDepth.map { $0 > 1.0e-6 ? 1 : 0 }
        return SimulationSnapshot(
            generation: generation,
            width: size,
            height: size,
            domainWidth: Double(size),
            domainHeight: Double(size),
            bedElevation: bedElevation,
            waterDepth: waterDepth,
            surfaceElevation: surfaceElevation,
            surfaceDeviation: [Float](repeating: 0, count: size * size),
            velocityMagnitude: [Float](repeating: 0, count: size * size),
            wetMask: wetMask,
            diagnostics: .empty
        )
    }

    private static func waitForInitialSnapshot(_ model: SimulationViewModel) async throws {
        for _ in 0..<400 where model.snapshot.width == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.snapshot.width, 32)
    }

    private static func waitForGeneration(
        after generation: UInt64,
        in model: SimulationViewModel
    ) async throws {
        for _ in 0..<400 where model.snapshot.generation <= generation {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(model.snapshot.generation, generation)
    }
}
