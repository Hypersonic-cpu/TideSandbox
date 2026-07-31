import AppKit
import MetalKit
import SwiftUI

struct HeightFieldMetalView: NSViewRepresentable {
    let snapshot: SimulationSnapshot

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> InteractiveMTKView {
        let view = InteractiveMTKView(
            frame: .zero,
            device: MTLCreateSystemDefaultDevice()
        )
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 1
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.clearColor = MTLClearColor(red: 0.075, green: 0.09, blue: 0.11, alpha: 1)

        if let renderer = HeightFieldRenderer(view: view) {
            context.coordinator.renderer = renderer
            view.delegate = renderer
            renderer.update(snapshot: snapshot)
        }
        return view
    }

    func updateNSView(_ view: InteractiveMTKView, context: Context) {
        context.coordinator.renderer?.update(snapshot: snapshot)
        view.setNeedsDisplay(view.bounds)
    }

    final class Coordinator {
        var renderer: HeightFieldRenderer?
    }
}

final class InteractiveMTKView: MTKView {
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
        }
    }
}
