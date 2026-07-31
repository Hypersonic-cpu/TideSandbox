import MetalKit

final class HeightFieldRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let diagnosticPipeline: MTLRenderPipelineState
    private(set) var snapshotGeneration: UInt64 = .max
    private(set) var drawableSize: CGSize = .zero

    init?(view: MTKView) {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "diagnosticVertex"),
              let fragmentFunction = library.makeFunction(name: "diagnosticFragment") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "3D diagnostic triangle"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        do {
            diagnosticPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }
        self.commandQueue = commandQueue
        super.init()
        resize(drawableSize: view.drawableSize)
    }

    func update(snapshot: SimulationSnapshot) {
        guard snapshot.generation != snapshotGeneration else { return }
        snapshotGeneration = snapshot.generation
    }

    func resize(drawableSize: CGSize) {
        self.drawableSize = drawableSize
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

        commandBuffer.label = "3D diagnostic frame"
        encoder.label = "3D diagnostic pass"
        encoder.setRenderPipelineState(diagnosticPipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
