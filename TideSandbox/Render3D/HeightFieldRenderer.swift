import MetalKit

final class HeightFieldRenderer: NSObject, MTKViewDelegate {
    private struct FrameUniforms {
        let viewProjection: simd_float4x4
        let cameraPosition: SIMD4<Float>
        let domainAndCellSize: SIMD4<Float>
        let gridSize: SIMD4<UInt32>
        let elevationRange: SIMD4<Float>
        let lightDirection: SIMD4<Float>
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let diagnosticPipeline: MTLRenderPipelineState
    private let terrainPipeline: MTLRenderPipelineState
    private let terrainDepthState: MTLDepthStencilState
    private var resourceTracker = HeightFieldResourceTracker()
    private var mesh: HeightFieldMesh?
    private var indexBuffer: MTLBuffer?
    private var bedElevationBuffers: [MTLBuffer] = []
    private var activeScalarBufferIndex = 0
    private var orbitCamera = OrbitCamera()
    private var cameraPreset: CameraPreset = .isometric
    private var settings = Render3DSettings()
    private var domainWidth: Float = 1
    private var domainHeight: Float = 1
    private var minimumBedElevation: Float = 0
    private var maximumBedElevation: Float = 0
    private var maximumAbsoluteElevation: Float = 0
    private(set) var snapshotGeneration: UInt64 = .max
    private(set) var drawableSize: CGSize = .zero

    init?(view: MTKView) {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "diagnosticVertex"),
              let fragmentFunction = library.makeFunction(name: "diagnosticFragment"),
              let terrainVertex = library.makeFunction(name: "terrainVertex"),
              let terrainFragment = library.makeFunction(name: "terrainFragment") else {
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

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.label = "Terrain depth"
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        do {
            diagnosticPipeline = try device.makeRenderPipelineState(
                descriptor: diagnosticDescriptor
            )
            terrainPipeline = try device.makeRenderPipelineState(descriptor: terrainDescriptor)
        } catch {
            return nil
        }
        guard let terrainDepthState = device.makeDepthStencilState(
            descriptor: depthDescriptor
        ) else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.terrainDepthState = terrainDepthState
        super.init()
        orbitCamera.apply(cameraPreset)
        resize(drawableSize: view.drawableSize)
    }

    func update(snapshot: SimulationSnapshot) {
        guard snapshot.generation != snapshotGeneration else { return }
        guard let counts = try? HeightFieldMesh.validatedCounts(
            width: snapshot.width,
            height: snapshot.height
        ),
              snapshot.bedElevation.count == counts.vertexCount,
              let firstElevation = snapshot.bedElevation.first,
              firstElevation.isFinite else {
            return
        }

        var minimum = firstElevation
        var maximum = firstElevation
        for value in snapshot.bedElevation.dropFirst() {
            guard value.isFinite else { return }
            minimum = min(minimum, value)
            maximum = max(maximum, value)
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

        guard !bedElevationBuffers.isEmpty else { return }
        activeScalarBufferIndex = (activeScalarBufferIndex + 1) % bedElevationBuffers.count
        let destination = bedElevationBuffers[activeScalarBufferIndex].contents()
        snapshot.bedElevation.withUnsafeBytes { source in
            if let baseAddress = source.baseAddress {
                memcpy(destination, baseAddress, source.count)
            }
        }
        minimumBedElevation = minimum
        maximumBedElevation = maximum
        maximumAbsoluteElevation = max(abs(minimum), abs(maximum))
        domainWidth = newDomainWidth
        domainHeight = newDomainHeight
        if dimensionsChanged {
            fitCamera()
        }
        snapshotGeneration = snapshot.generation
    }

    func setCameraPreset(_ preset: CameraPreset) {
        guard cameraPreset != preset else { return }
        cameraPreset = preset
        orbitCamera.apply(preset)
    }

    func resize(drawableSize: CGSize) {
        self.drawableSize = drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        orbitCamera.updateAspectRatio(Float(drawableSize.width / drawableSize.height))
        if mesh != nil {
            fitCamera()
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
           !bedElevationBuffers.isEmpty {
            encoder.label = "3D terrain pass"
            encoder.setRenderPipelineState(terrainPipeline)
            encoder.setDepthStencilState(terrainDepthState)
            encoder.setCullMode(.back)
            encoder.setFrontFacing(.counterClockwise)
            encoder.setTriangleFillMode(settings.wireframeTerrain ? .lines : .fill)
            encoder.setVertexBuffer(
                bedElevationBuffers[activeScalarBufferIndex],
                offset: 0,
                index: 0
            )
            let uniforms = frameUniforms(mesh: mesh)
            withUnsafeBytes(of: uniforms) { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                encoder.setVertexBytes(
                    baseAddress,
                    length: bytes.count,
                    index: 1
                )
                encoder.setFragmentBytes(
                    baseAddress,
                    length: bytes.count,
                    index: 1
                )
            }
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: mesh.indexCount,
                indexType: .uint32,
                indexBuffer: indexBuffer,
                indexBufferOffset: 0
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
        let newBedBuffers = (0..<3).compactMap { index -> MTLBuffer? in
            let buffer = device.makeBuffer(
                length: scalarByteCount,
                options: .storageModeShared
            )
            buffer?.label = "Bed elevation \(index)"
            return buffer
        }
        guard let newIndexBuffer, newBedBuffers.count == 3 else { return false }
        newIndexBuffer.label = "Height-field indices"
        mesh = newMesh
        indexBuffer = newIndexBuffer
        bedElevationBuffers = newBedBuffers
        activeScalarBufferIndex = 0
        return true
    }

    private func fitCamera() {
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        orbitCamera.fitToDomain(
            domainWidth: domainWidth,
            domainHeight: domainHeight,
            maximumAbsoluteElevation: maximumAbsoluteElevation,
            verticalScale: settings.verticalScale,
            aspectRatio: Float(drawableSize.width / drawableSize.height)
        )
        orbitCamera.apply(cameraPreset)
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
                0
            ),
            lightDirection: SIMD4<Float>(settings.lightDirection, 0)
        )
    }
}
