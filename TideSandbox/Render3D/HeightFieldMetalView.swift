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
    let terrainTool: TerrainTool
    let brushPreviewPoint: CGPoint?
    let brushRadius: Double
    let polygonPoints: [CGPoint]
    let onBrushBegin: (CGPoint) -> Void
    let onBrushMove: (CGPoint) -> Void
    let onBrushEnd: () -> Void
    let onPolygonPoint: (CGPoint) -> Void
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
        view.terrainTool = terrainTool
        view.brushPreviewPoint = brushPreviewPoint
        view.brushRadius = brushRadius
        view.polygonPoints = polygonPoints
        view.onBrushBegin = onBrushBegin
        view.onBrushMove = onBrushMove
        view.onBrushEnd = onBrushEnd
        view.onPolygonPoint = onPolygonPoint
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
            view.updatePreviewOverlay()
        }
        return view
    }

    func updateNSView(_ view: InteractiveMTKView, context: Context) {
        Self.configureFramePacing(view, isPlaying: isPlaying)
        view.terrainTool = terrainTool
        view.brushPreviewPoint = brushPreviewPoint
        view.brushRadius = brushRadius
        view.polygonPoints = polygonPoints
        view.onBrushBegin = onBrushBegin
        view.onBrushMove = onBrushMove
        view.onBrushEnd = onBrushEnd
        view.onPolygonPoint = onPolygonPoint
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
        view.updatePreviewOverlay()
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
    var terrainTool: TerrainTool = .inspect
    var brushPreviewPoint: CGPoint? { didSet { updatePreviewOverlay() } }
    var brushRadius: Double = 1 { didSet { updatePreviewOverlay() } }
    var polygonPoints = [CGPoint]() { didSet { updatePreviewOverlay() } }
    var onBrushBegin: ((CGPoint) -> Void)?
    var onBrushMove: ((CGPoint) -> Void)?
    var onBrushEnd: (() -> Void)?
    var onPolygonPoint: ((CGPoint) -> Void)?
    private var lastDragLocation: CGPoint?
    private var primaryCameraInteraction = false
    private var brushEditing = false
    private var polygonClickCandidate = false
    private let previewLayer = CAShapeLayer()
    private var previewLayerInstalled = false

    var previewPath: CGPath? { previewLayer.path }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        installPreviewLayerIfNeeded()
        previewLayer.frame = bounds
        updatePreviewOverlay()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        primaryCameraInteraction = terrainTool == .inspect || event.modifierFlags.contains(.option)
        if event.clickCount == 2, primaryCameraInteraction {
            renderer?.fitCameraToDomain()
            setNeedsDisplay(bounds)
            lastDragLocation = nil
            primaryCameraInteraction = false
        } else if primaryCameraInteraction {
            lastDragLocation = location
        } else if terrainTool.operation != nil,
                  let point = physicalPoint(at: location) {
            brushEditing = true
            onBrushBegin?(point)
        } else if terrainTool == .polygon {
            polygonClickCandidate = true
            lastDragLocation = location
        } else {
            lastDragLocation = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let lastDragLocation else {
            if brushEditing, let point = physicalPoint(at: location) {
                onBrushMove?(point)
            }
            return
        }
        if brushEditing {
            if let point = physicalPoint(at: location) {
                onBrushMove?(point)
            }
            self.lastDragLocation = location
            return
        }
        if terrainTool == .polygon, !primaryCameraInteraction {
            polygonClickCandidate = false
            self.lastDragLocation = location
            return
        }
        guard primaryCameraInteraction else {
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
        if brushEditing {
            brushEditing = false
            onBrushEnd?()
        } else if polygonClickCandidate,
                  terrainTool == .polygon,
                  let point = physicalPoint(at: convert(event.locationInWindow, from: nil)) {
            onPolygonPoint?(point)
        }
        lastDragLocation = nil
        primaryCameraInteraction = false
        polygonClickCandidate = false
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

    private func physicalPoint(at point: CGPoint) -> CGPoint? {
        let scale = window?.backingScaleFactor ?? 1
        return renderer?.physicalPoint(
            at: CGPoint(x: point.x * scale, y: point.y * scale),
            drawableSize: drawableSize
        )
    }

    func updatePreviewOverlay() {
        installPreviewLayerIfNeeded()
        guard let renderer else {
            previewLayer.path = nil
            return
        }
        let scale = window?.backingScaleFactor ?? 1
        func viewPoint(_ physicalPoint: CGPoint) -> CGPoint? {
            guard let projected = renderer.project(physicalPoint: physicalPoint) else { return nil }
            return CGPoint(x: projected.x / scale, y: projected.y / scale)
        }
        let path = CGMutablePath()
        if terrainTool.operation != nil,
           let brushPreviewPoint {
            let outline = renderer.projectedBrushOutline(
                center: brushPreviewPoint,
                radius: brushRadius
            ).map { CGPoint(x: $0.x / scale, y: $0.y / scale) }
            for (index, point) in outline.enumerated() {
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            if outline.count > 2 {
                path.closeSubpath()
            }
        }
        let projectedPolygon = polygonPoints.compactMap(viewPoint)
        for (index, point) in projectedPolygon.enumerated() {
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            path.addEllipse(in: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
        }
        previewLayer.path = path.isEmpty ? nil : path
    }

    private func installPreviewLayerIfNeeded() {
        guard !previewLayerInstalled else { return }
        wantsLayer = true
        previewLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        previewLayer.fillColor = NSColor.clear.cgColor
        previewLayer.lineWidth = 2
        previewLayer.lineDashPattern = [5, 4]
        previewLayer.lineJoin = .round
        layer?.addSublayer(previewLayer)
        previewLayerInstalled = true
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
