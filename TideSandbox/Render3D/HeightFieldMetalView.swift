import AppKit
import MetalKit
import SwiftUI

struct HeightFieldMetalView: NSViewRepresentable {
    let snapshot: SimulationSnapshot
    let isPlaying: Bool
    let cameraSessionState: OrbitCameraState?
    let cameraYawDegrees: Float
    let cameraPitchDegrees: Float
    let cameraFitRequestID: UInt64
    let minimumWetDepth: Float
    let settings: Render3DSettings
    let onCameraChange: (OrbitCameraState, CameraChangeReason) -> Void

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
        Self.configureFramePacing(view, isPlaying: isPlaying)
        view.clearColor = MTLClearColor(red: 0.075, green: 0.09, blue: 0.11, alpha: 1)

        if let renderer = HeightFieldRenderer(view: view) {
            context.coordinator.renderer = renderer
            context.coordinator.lastCameraFitRequestID = cameraFitRequestID
            view.delegate = renderer
            renderer.setMinimumWetDepth(minimumWetDepth)
            renderer.setSettings(settings)
            renderer.update(snapshot: snapshot)
            if let cameraSessionState {
                renderer.restoreCameraState(cameraSessionState)
            }
            renderer.setCameraOrientation(
                yawDegrees: cameraYawDegrees,
                pitchDegrees: cameraPitchDegrees
            )
            context.coordinator.lastInspectorYawDegrees = cameraYawDegrees
            context.coordinator.lastInspectorPitchDegrees = cameraPitchDegrees
            renderer.onCameraChange = context.coordinator.cameraChangeHandler(
                onCameraChange
            )
            view.renderer = renderer
        }
        return view
    }

    func updateNSView(_ view: InteractiveMTKView, context: Context) {
        Self.configureFramePacing(view, isPlaying: isPlaying)
        let renderer = context.coordinator.renderer
        renderer?.setMinimumWetDepth(minimumWetDepth)
        if context.coordinator.lastInspectorYawDegrees != cameraYawDegrees ||
                context.coordinator.lastInspectorPitchDegrees != cameraPitchDegrees {
            renderer?.setCameraOrientation(
                yawDegrees: cameraYawDegrees,
                pitchDegrees: cameraPitchDegrees
            )
            context.coordinator.lastInspectorYawDegrees = cameraYawDegrees
            context.coordinator.lastInspectorPitchDegrees = cameraPitchDegrees
        }
        renderer?.setSettings(settings)
        renderer?.update(snapshot: snapshot)
        if context.coordinator.lastCameraFitRequestID != cameraFitRequestID {
            context.coordinator.lastCameraFitRequestID = cameraFitRequestID
            renderer?.fitCameraToDomain(reportChange: false)
        }
        renderer?.onCameraChange = context.coordinator.cameraChangeHandler(
            onCameraChange
        )
        view.setNeedsDisplay(view.bounds)
    }

    private static func configureFramePacing(_ view: MTKView, isPlaying: Bool) {
        view.enableSetNeedsDisplay = !isPlaying
        view.isPaused = !isPlaying
    }

    final class Coordinator {
        var renderer: HeightFieldRenderer?
        var lastCameraFitRequestID: UInt64 = 0
        var lastInspectorYawDegrees: Float?
        var lastInspectorPitchDegrees: Float?
        private var pendingCameraChange: DispatchWorkItem?

        func cameraChangeHandler(
            _ handler: @escaping (OrbitCameraState, CameraChangeReason) -> Void
        ) -> (OrbitCameraState, CameraChangeReason) -> Void {
            { [weak self] state, reason in
                self?.scheduleCameraChange(state, reason: reason, handler: handler)
            }
        }

        private func scheduleCameraChange(
            _ state: OrbitCameraState,
            reason: CameraChangeReason,
            handler: @escaping (OrbitCameraState, CameraChangeReason) -> Void
        ) {
            pendingCameraChange?.cancel()
            let workItem = DispatchWorkItem {
                handler(state, reason)
            }
            pendingCameraChange = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 1.0 / 60.0,
                execute: workItem
            )
        }
    }
}

final class InteractiveMTKView: MTKView {
    weak var renderer: HeightFieldRenderer?
    private var lastDragLocation: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            renderer?.fitCameraToDomain()
            setNeedsDisplay(bounds)
            lastDragLocation = nil
        } else {
            lastDragLocation = convert(event.locationInWindow, from: nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let lastDragLocation else {
            self.lastDragLocation = location
            return
        }
        let deltaX = Float(location.x - lastDragLocation.x)
        let deltaY = Float(location.y - lastDragLocation.y)
        if event.modifierFlags.contains(.shift) {
            renderer?.panCamera(
                deltaX: deltaX,
                deltaY: deltaY,
                viewportHeight: Float(bounds.height)
            )
        } else {
            renderer?.orbitCamera(deltaX: deltaX, deltaY: -deltaY)
        }
        self.lastDragLocation = location
        setNeedsDisplay(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        lastDragLocation = nil
        super.mouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastDragLocation = convert(event.locationInWindow, from: nil)
    }

    override func otherMouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let lastDragLocation else {
            self.lastDragLocation = location
            return
        }
        renderer?.panCamera(
            deltaX: Float(location.x - lastDragLocation.x),
            deltaY: Float(location.y - lastDragLocation.y),
            viewportHeight: Float(bounds.height)
        )
        self.lastDragLocation = location
        setNeedsDisplay(bounds)
    }

    override func otherMouseUp(with event: NSEvent) {
        lastDragLocation = nil
        super.otherMouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        renderer?.zoomCamera(scrollDelta: Float(event.scrollingDeltaY))
        setNeedsDisplay(bounds)
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f":
            renderer?.fitCameraToDomain()
        case "1":
            renderer?.applyCameraPreset(.top)
        case "2":
            renderer?.applyCameraPreset(.isometric)
        case "3":
            renderer?.applyCameraPreset(.lowOblique)
        case "4":
            renderer?.applyCameraPreset(.oppositeOblique)
        default:
            super.keyDown(with: event)
            return
        }
        setNeedsDisplay(bounds)
    }
}
