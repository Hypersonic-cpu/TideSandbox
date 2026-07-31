import MetalKit

final class HeightFieldRenderer: NSObject, MTKViewDelegate {
    private struct FrameUniforms {
        let viewProjection: simd_float4x4
        let cameraPosition: SIMD4<Float>
        let domainAndCellSize: SIMD4<Float>
        let gridSize: SIMD4<UInt32>
        let elevationRange: SIMD4<Float>
        let lightDirection: SIMD4<Float>
        let waterParameters: SIMD4<Float>
        let cameraTarget: SIMD4<Float>
        let debugFlags: SIMD4<UInt32>
    }

    private struct ScalarBufferSet {
        let bedElevation: MTLBuffer
        let waterDepth: MTLBuffer
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let diagnosticPipeline: MTLRenderPipelineState
    private let terrainPipeline: MTLRenderPipelineState
    private let waterPipeline: MTLRenderPipelineState
    private let debugLinePipeline: MTLRenderPipelineState
    private let terrainDepthState: MTLDepthStencilState
    private let waterDepthState: MTLDepthStencilState
    private var resourceTracker = HeightFieldResourceTracker()
    private var mesh: HeightFieldMesh?
    private var indexBuffer: MTLBuffer?
    private var scalarBufferSets: [ScalarBufferSet] = []
    private var activeScalarBufferIndex = 0
    private var orbitCamera = OrbitCamera()
    private var settings = Render3DSettings()
    private var domainWidth: Float = 1
    private var domainHeight: Float = 1
    private var minimumBedElevation: Float = 0
    private var maximumBedElevation: Float = 0
    private var maximumWaterDepth: Float = 0
    private var maximumAbsoluteElevation: Float = 0
    private var minimumWetDepth: Float = 1.0e-6
    private var hasFittedCamera = false
    private var pendingCameraState: OrbitCameraState?
    private(set) var snapshotGeneration: UInt64 = .max
    private(set) var drawableSize: CGSize = .zero
    var onCameraChange: ((OrbitCameraState, CameraChangeReason) -> Void)?

    var cameraState: OrbitCameraState { orbitCamera.state }

    init?(view: MTKView) {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "diagnosticVertex"),
              let fragmentFunction = library.makeFunction(name: "diagnosticFragment"),
              let terrainVertex = library.makeFunction(name: "terrainVertex"),
              let terrainFragment = library.makeFunction(name: "terrainFragment"),
              let waterVertex = library.makeFunction(name: "waterVertex"),
              let waterFragment = library.makeFunction(name: "waterFragment"),
              let debugLineVertex = library.makeFunction(name: "debugLineVertex"),
              let debugLineFragment = library.makeFunction(name: "debugLineFragment") else {
            return nil
        }

        let diagnosticDescriptor = MTLRenderPipelineDescriptor()
        diagnosticDescriptor.label = "3D diagnostic triangle"
        diagnosticDescriptor.vertexFunction = vertexFunction
        diagnosticDescriptor.fragmentFunction = fragmentFunction
        diagnosticDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        diagnosticDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat

        let terrainDescriptor = MTLRenderPipelineDescriptor()
        terrainDescriptor.label = "3D terrain"
        terrainDescriptor.vertexFunction = terrainVertex
        terrainDescriptor.fragmentFunction = terrainFragment
        terrainDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        terrainDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat

        let waterDescriptor = MTLRenderPipelineDescriptor()
        waterDescriptor.label = "3D water"
        waterDescriptor.vertexFunction = waterVertex
        waterDescriptor.fragmentFunction = waterFragment
        waterDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        waterDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        guard let waterColor = waterDescriptor.colorAttachments[0] else {
            return nil
        }
        waterColor.isBlendingEnabled = true
        waterColor.rgbBlendOperation = .add
        waterColor.alphaBlendOperation = .add
        waterColor.sourceRGBBlendFactor = .one
        waterColor.sourceAlphaBlendFactor = .one
        waterColor.destinationRGBBlendFactor = .oneMinusSourceAlpha
        waterColor.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let debugLineDescriptor = MTLRenderPipelineDescriptor()
        debugLineDescriptor.label = "3D debug lines"
        debugLineDescriptor.vertexFunction = debugLineVertex
        debugLineDescriptor.fragmentFunction = debugLineFragment
        debugLineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        debugLineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.label = "Terrain depth"
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        let waterDepthDescriptor = MTLDepthStencilDescriptor()
        waterDepthDescriptor.label = "Water depth"
        waterDepthDescriptor.depthCompareFunction = .lessEqual
        waterDepthDescriptor.isDepthWriteEnabled = false
        do {
            diagnosticPipeline = try device.makeRenderPipelineState(
                descriptor: diagnosticDescriptor
            )
            terrainPipeline = try device.makeRenderPipelineState(descriptor: terrainDescriptor)
            waterPipeline = try device.makeRenderPipelineState(descriptor: waterDescriptor)
            debugLinePipeline = try device.makeRenderPipelineState(
                descriptor: debugLineDescriptor
            )
        } catch {
            return nil
        }
        guard let terrainDepthState = device.makeDepthStencilState(
            descriptor: depthDescriptor
        ),
              let waterDepthState = device.makeDepthStencilState(
                descriptor: waterDepthDescriptor
        ) else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.terrainDepthState = terrainDepthState
        self.waterDepthState = waterDepthState
        super.init()
        resize(drawableSize: view.drawableSize)
    }

    func update(snapshot: SimulationSnapshot) {
        guard snapshot.generation != snapshotGeneration else { return }
        guard let counts = try? HeightFieldMesh.validatedCounts(
            width: snapshot.width,
            height: snapshot.height
        ),
              snapshot.bedElevation.count == counts.vertexCount,
              snapshot.waterDepth.count == counts.vertexCount,
              let statistics = HeightFieldStatistics(
                bedElevation: snapshot.bedElevation,
                waterDepth: snapshot.waterDepth
              ) else {
            return
        }
        let newDomainWidth = Float(snapshot.domainWidth)
        let newDomainHeight = Float(snapshot.domainHeight)
        guard newDomainWidth.isFinite, newDomainWidth > 0,
              newDomainHeight.isFinite, newDomainHeight > 0 else {
            return
        }

        let dimensionsChanged = resourceTracker.width != snapshot.width ||
            resourceTracker.height != snapshot.height
        if dimensionsChanged {
            guard rebuildResources(width: snapshot.width, height: snapshot.height) else {
                return
            }
            do {
                _ = try resourceTracker.register(
                    width: snapshot.width,
                    height: snapshot.height
                )
            } catch {
                return
            }
        }

        guard !scalarBufferSets.isEmpty else { return }
        activeScalarBufferIndex = (activeScalarBufferIndex + 1) % scalarBufferSets.count
        let activeBuffers = scalarBufferSets[activeScalarBufferIndex]
        Self.copy(snapshot.bedElevation, to: activeBuffers.bedElevation)
        Self.copy(snapshot.waterDepth, to: activeBuffers.waterDepth)
        minimumBedElevation = statistics.minimumBedElevation
        maximumBedElevation = statistics.maximumBedElevation
        maximumWaterDepth = statistics.maximumWaterDepth
        maximumAbsoluteElevation = statistics.maximumAbsoluteElevation
        domainWidth = newDomainWidth
        domainHeight = newDomainHeight
        if dimensionsChanged {
            pendingCameraState = nil
            _ = fitCamera()
        }
        snapshotGeneration = snapshot.generation
    }

    func setCameraOrientation(yawDegrees: Float, pitchDegrees: Float) {
        orbitCamera.setOrientation(
            yawDegrees: yawDegrees,
            pitchDegrees: pitchDegrees
        )
        if var pendingCameraState {
            pendingCameraState.yaw = yawDegrees * .pi / 180
            pendingCameraState.pitch = min(max(pitchDegrees, -89), -5) * .pi / 180
            self.pendingCameraState = pendingCameraState
        }
    }

    func restoreCameraState(_ state: OrbitCameraState) {
        if hasFittedCamera {
            _ = orbitCamera.restore(state)
        } else {
            pendingCameraState = state
        }
    }

    func orbitCamera(deltaX: Float, deltaY: Float) {
        orbitCamera.orbit(deltaX: deltaX, deltaY: deltaY)
        reportCameraChange(.interaction)
    }

    func panCamera(deltaX: Float, deltaY: Float, viewportHeight: Float) {
        orbitCamera.pan(
            deltaX: deltaX,
            deltaY: deltaY,
            viewportHeight: viewportHeight
        )
        reportCameraChange(.interaction)
    }

    func zoomCamera(scrollDelta: Float) {
        orbitCamera.zoom(scrollDelta: scrollDelta)
        reportCameraChange(.interaction)
    }

    func fitCameraToDomain(reportChange: Bool = true) {
        pendingCameraState = nil
        if fitCamera(), reportChange {
            reportCameraChange(.fit)
        }
    }

    func applyCameraPreset(_ preset: CameraPreset) {
        pendingCameraState = nil
        orbitCamera.apply(preset)
        if fitCamera() {
            reportCameraChange(.preset(preset))
        }
    }

    func setMinimumWetDepth(_ value: Float) {
        minimumWetDepth = value.isFinite && value >= 0 ? value : 0
    }

    func setSettings(_ requestedSettings: Render3DSettings) {
        var newSettings = requestedSettings
        newSettings.verticalScale = min(max(
            requestedSettings.verticalScale.isFinite ? requestedSettings.verticalScale : 1,
            1
        ), 20)
        newSettings.waterOpacity = min(max(
            requestedSettings.waterOpacity.isFinite ? requestedSettings.waterOpacity : 0.72,
            0.2
        ), 1)
        guard settings != newSettings else { return }
        let verticalScaleChanged = settings.verticalScale != newSettings.verticalScale
        settings = newSettings
        if verticalScaleChanged, mesh != nil {
            _ = fitCamera()
        }
    }

    func resize(drawableSize: CGSize) {
        self.drawableSize = drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        orbitCamera.updateAspectRatio(Float(drawableSize.width / drawableSize.height))
        if mesh != nil {
            let stateToRestore = pendingCameraState ?? (hasFittedCamera ? cameraState : nil)
            if fitCamera(), let stateToRestore {
                _ = orbitCamera.restore(stateToRestore)
            }
            pendingCameraState = nil
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        resize(drawableSize: size)
    }

    func draw(in view: MTKView) {
        guard let passDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: passDescriptor
              ) else {
            return
        }

        commandBuffer.label = "3D height-field frame"
        if let mesh,
           let indexBuffer,
           !scalarBufferSets.isEmpty {
            let activeBuffers = scalarBufferSets[activeScalarBufferIndex]
            let uniforms = frameUniforms(mesh: mesh)
            withUnsafeBytes(of: uniforms) { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                encoder.setVertexBytes(baseAddress, length: bytes.count, index: 1)
                encoder.setFragmentBytes(baseAddress, length: bytes.count, index: 1)
            }

            encoder.label = "3D terrain pass"
            encoder.setRenderPipelineState(terrainPipeline)
            encoder.setDepthStencilState(terrainDepthState)
            encoder.setCullMode(.back)
            encoder.setFrontFacing(.counterClockwise)
            encoder.setTriangleFillMode(settings.wireframeTerrain ? .lines : .fill)
            encoder.setVertexBuffer(
                activeBuffers.bedElevation,
                offset: 0,
                index: 0
            )
            encoder.setVertexBuffer(activeBuffers.waterDepth, offset: 0, index: 2)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: mesh.indexCount,
                indexType: .uint32,
                indexBuffer: indexBuffer,
                indexBufferOffset: 0
            )

            encoder.label = "3D water pass"
            encoder.setRenderPipelineState(waterPipeline)
            encoder.setDepthStencilState(waterDepthState)
            encoder.setCullMode(.back)
            encoder.setFrontFacing(.counterClockwise)
            encoder.setTriangleFillMode(settings.wireframeWater ? .lines : .fill)
            encoder.setVertexBuffer(activeBuffers.waterDepth, offset: 0, index: 2)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: mesh.indexCount,
                indexType: .uint32,
                indexBuffer: indexBuffer,
                indexBufferOffset: 0
            )

            drawDebugLines(
                encoder: encoder,
                mesh: mesh,
                activeBuffers: activeBuffers
            )
        } else {
            encoder.label = "3D diagnostic pass"
            encoder.setRenderPipelineState(diagnosticPipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func rebuildResources(width: Int, height: Int) -> Bool {
        guard let newMesh = try? HeightFieldMesh(width: width, height: height) else {
            return false
        }
        let newIndexBuffer = newMesh.indices.withUnsafeBytes { bytes -> MTLBuffer? in
            guard let baseAddress = bytes.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: bytes.count,
                options: .storageModeShared
            )
        }
        let scalarByteCount = newMesh.vertexCount * MemoryLayout<Float>.stride
        let newScalarBufferSets = (0..<3).compactMap { index -> ScalarBufferSet? in
            guard let bedBuffer = device.makeBuffer(
                length: scalarByteCount,
                options: .storageModeShared
            ),
                  let waterBuffer = device.makeBuffer(
                    length: scalarByteCount,
                    options: .storageModeShared
                  ) else {
                return nil
            }
            bedBuffer.label = "Bed elevation \(index)"
            waterBuffer.label = "Water depth \(index)"
            return ScalarBufferSet(
                bedElevation: bedBuffer,
                waterDepth: waterBuffer
            )
        }
        guard let newIndexBuffer, newScalarBufferSets.count == 3 else { return false }
        newIndexBuffer.label = "Height-field indices"
        mesh = newMesh
        indexBuffer = newIndexBuffer
        scalarBufferSets = newScalarBufferSets
        activeScalarBufferIndex = 0
        return true
    }

    @discardableResult
    private func fitCamera() -> Bool {
        guard drawableSize.width > 0, drawableSize.height > 0 else { return false }
        orbitCamera.fitToDomain(
            domainWidth: domainWidth,
            domainHeight: domainHeight,
            maximumAbsoluteElevation: maximumAbsoluteElevation,
            verticalScale: settings.verticalScale,
            aspectRatio: Float(drawableSize.width / drawableSize.height)
        )
        hasFittedCamera = true
        return true
    }

    private func reportCameraChange(_ reason: CameraChangeReason) {
        onCameraChange?(cameraState, reason)
    }

    private func frameUniforms(mesh: HeightFieldMesh) -> FrameUniforms {
        let matrices = orbitCamera.matrices()
        return FrameUniforms(
            viewProjection: matrices.viewProjection,
            cameraPosition: SIMD4<Float>(matrices.position, 1),
            domainAndCellSize: SIMD4<Float>(
                domainWidth,
                domainHeight,
                domainWidth / Float(mesh.width),
                domainHeight / Float(mesh.height)
            ),
            gridSize: SIMD4<UInt32>(
                UInt32(mesh.width),
                UInt32(mesh.height),
                0,
                0
            ),
            elevationRange: SIMD4<Float>(
                settings.verticalScale,
                minimumBedElevation,
                maximumBedElevation,
                maximumWaterDepth
            ),
            lightDirection: SIMD4<Float>(settings.lightDirection, 0),
            waterParameters: SIMD4<Float>(
                minimumWetDepth,
                settings.shorelineBand,
                settings.waterOpacity,
                settings.renderBias
            ),
            cameraTarget: SIMD4<Float>(cameraState.target, 1),
            debugFlags: SIMD4<UInt32>(
                settings.showWetCellMask ? 1 : 0,
                settings.showDomainBounds ? 1 : 0,
                settings.showSurfaceNormals ? 1 : 0,
                settings.showCameraTarget ? 1 : 0
            )
        )
    }

    private func drawDebugLines(
        encoder: MTLRenderCommandEncoder,
        mesh: HeightFieldMesh,
        activeBuffers: ScalarBufferSet
    ) {
        guard settings.showDomainBounds || settings.showSurfaceNormals ||
                settings.showCameraTarget else {
            return
        }
        encoder.label = "3D debug line pass"
        encoder.setRenderPipelineState(debugLinePipeline)
        encoder.setDepthStencilState(waterDepthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(activeBuffers.bedElevation, offset: 0, index: 0)
        encoder.setVertexBuffer(activeBuffers.waterDepth, offset: 0, index: 2)

        if settings.showDomainBounds {
            var mode: UInt32 = 0
            encoder.setVertexBytes(&mode, length: MemoryLayout<UInt32>.stride, index: 3)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 24)
        }
        if settings.showSurfaceNormals {
            var mode: UInt32 = 1
            encoder.setVertexBytes(&mode, length: MemoryLayout<UInt32>.stride, index: 3)
            let columns = min(mesh.width, 16)
            let rows = min(mesh.height, 16)
            encoder.drawPrimitives(
                type: .line,
                vertexStart: 0,
                vertexCount: columns * rows * 2
            )
        }
        if settings.showCameraTarget {
            var mode: UInt32 = 2
            encoder.setVertexBytes(&mode, length: MemoryLayout<UInt32>.stride, index: 3)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 6)
        }
    }

    private static func copy(_ values: [Float], to buffer: MTLBuffer) {
        values.withUnsafeBytes { source in
            guard let baseAddress = source.baseAddress else { return }
            memcpy(buffer.contents(), baseAddress, source.count)
        }
    }
}
