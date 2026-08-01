import CoreGraphics
import Foundation

nonisolated extension SceneBoundarySide {
    var bridgeConfiguration: WSBoundarySideConfiguration {
        let bridgeType: WSBoundaryType = switch type {
        case .reflective: .reflective
        case .freeOpen: .freeOpen
        case .drivenHeight: .drivenHeight
        }
        return WSBoundarySideConfiguration(
            type: bridgeType,
            meanSurfaceElevation: meanSurfaceElevation ?? 0,
            amplitude: amplitude ?? 0,
            periodSeconds: periodSeconds ?? 1,
            phaseRadians: phaseRadians ?? 0,
            rampSeconds: rampSeconds ?? 0
        )
    }
}

nonisolated extension SceneBoundaryConfiguration {
    var bridgeConfiguration: WSBoundaryConfiguration {
        WSBoundaryConfiguration(
            left: left.bridgeConfiguration,
            right: right.bridgeConfiguration,
            bottom: bottom.bridgeConfiguration,
            top: top.bridgeConfiguration
        )
    }
}

struct ActiveBrush: Sendable {
    let point: CGPoint
    let radius: Double
    let operation: WSMaterialOperation
    let amountPerSecond: Double
    let falloff: WSBrushFalloff
    let target: WSEditTarget
}

nonisolated final class SimulationRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TideSandbox.EngineRuntime", qos: .userInteractive)
    private let engine: WSWaterEngineBridge
    private var snapshotHandler: (@Sendable (SimulationSnapshot, Bool) -> Void)?
    private var timer: DispatchSourceTimer?
    private var activeBrush: ActiveBrush?
    private var lastTick = DispatchTime.now()
    private var tickCount: UInt = 0
    private var playbackSpeed = 1.0
    private var isShutDown = false

    init(
        seed: SceneSeed,
        requestedBackend: RequestedSimulationBackend = .automaticAccelerated
    ) {
        engine = WSWaterEngineBridge(
            width: UInt(seed.width),
            height: UInt(seed.height),
            domainWidth: seed.domainWidth,
            domainHeight: seed.domainHeight
        )
        _ = engine.load(
            width: UInt(seed.width),
            height: UInt(seed.height),
            domainWidth: seed.domainWidth,
            domainHeight: seed.domainHeight,
            bedElevation: seed.bedData,
            waterDepth: seed.depthData,
            minimumBed: seed.worldLimits.minimumBedElevation,
            maximumSurface: seed.worldLimits.maximumSurfaceElevation,
            boundaries: seed.boundaries.bridgeConfiguration
        )
        if requestedBackend != .automaticAccelerated {
            _ = engine.setRequestedBackend(requestedBackend.bridgeValue)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.setEventHandler {}
        timer?.cancel()
    }

    func setSnapshotHandler(
        _ handler: @escaping @Sendable (SimulationSnapshot, Bool) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, !isShutDown else { return }
            snapshotHandler = handler
            publishSnapshot(initialStateChanged: true)
        }
    }

    func requestSnapshot() {
        queue.async { [weak self] in self?.publishSnapshot() }
    }

    func setPlaying(_ playing: Bool) {
        queue.async { [weak self] in
            guard let self, !isShutDown else { return }
            engine.isRunning = playing
            lastTick = .now()
            publishSnapshot()
        }
    }

    func load(_ seed: SceneSeed) {
        queue.async { [weak self] in
            guard let self, !isShutDown else { return }
            engine.isRunning = false
            activeBrush = nil
            _ = engine.load(
                width: UInt(seed.width),
                height: UInt(seed.height),
                domainWidth: seed.domainWidth,
                domainHeight: seed.domainHeight,
                bedElevation: seed.bedData,
                waterDepth: seed.depthData,
                minimumBed: seed.worldLimits.minimumBedElevation,
                maximumSurface: seed.worldLimits.maximumSurfaceElevation,
                boundaries: seed.boundaries.bridgeConfiguration
            )
            lastTick = .now()
            publishSnapshot(initialStateChanged: true)
        }
    }

    func advanceOneFrame(speed: Double) {
        queue.async { [weak self] in
            guard let self, !isShutDown else { return }
            _ = engine.advance(max(speed, 0.01) / 60.0)
            publishSnapshot()
        }
    }

    func setPlaybackSpeed(_ speed: Double) {
        queue.async { [weak self] in
            self?.playbackSpeed = max(speed, 0.01)
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self, !isShutDown else { return }
            engine.reset()
            activeBrush = nil
            publishSnapshot()
        }
    }

    func updateConfiguration(
        gravity: Double,
        linearDamping: Double,
        cflNumber: Double,
        minimumWetDepth: Double,
        workerCount: Int
    ) {
        queue.async { [weak self] in
            guard let self, !isShutDown else { return }
            _ = engine.updateConfiguration(
                gravity: gravity,
                linearDamping: linearDamping,
                cflNumber: cflNumber,
                minimumWetDepth: minimumWetDepth,
                workerCount: UInt(workerCount)
            )
            publishSnapshot()
        }
    }

    func updateBoundaryConfiguration(_ configuration: SceneBoundaryConfiguration) {
        queue.async { [weak self] in
            guard let self, !isShutDown else { return }
            engine.isRunning = false
            activeBrush = nil
            _ = engine.setBoundaryConfiguration(configuration.bridgeConfiguration)
            lastTick = .now()
            publishSnapshot()
        }
    }

    func updateRequestedBackend(_ backend: RequestedSimulationBackend) {
        queue.async { [weak self] in
            guard let self, !isShutDown else { return }
            engine.isRunning = false
            activeBrush = nil
            _ = engine.setRequestedBackend(backend.bridgeValue)
            lastTick = .now()
            publishSnapshot()
        }
    }

    func beginBrush(_ brush: ActiveBrush) {
        queue.async { [weak self] in
            guard let self, !isShutDown else { return }
            engine.isRunning = false
            activeBrush = brush
            lastTick = .now()
            if apply(brush: brush, amount: brush.amountPerSecond / 60) {
                publishSnapshot(initialStateChanged: brush.target == .initialState)
            }
        }
    }

    func moveBrush(to point: CGPoint) {
        queue.async { [weak self] in
            guard let self, let current = activeBrush, !isShutDown else { return }
            activeBrush = ActiveBrush(
                point: point,
                radius: current.radius,
                operation: current.operation,
                amountPerSecond: current.amountPerSecond,
                falloff: current.falloff,
                target: current.target
            )
        }
    }

    func endBrush() {
        queue.async { [weak self] in
            guard let self else { return }
            activeBrush = nil
        }
    }

    func applyPolygon(
        points: [CGPoint],
        operation: WSMaterialOperation,
        amount: Double,
        target: WSEditTarget
    ) {
        var coordinates = [Double]()
        coordinates.reserveCapacity(points.count * 2)
        for point in points {
            coordinates.append(Double(point.x))
            coordinates.append(Double(point.y))
        }
        let data = coordinates.withUnsafeBytes { Data($0) }
        queue.async { [weak self] in
            guard let self, !isShutDown else { return }
            engine.isRunning = false
            let result = engine.applyMaterialPolygon(
                xyCoordinates: data,
                operation: operation,
                amount: amount,
                target: target
            )
            if result.isChanged {
                publishSnapshot(initialStateChanged: target == .initialState)
            }
        }
    }

    func shutdown() {
        queue.sync {
            guard !isShutDown else { return }
            isShutDown = true
            engine.isRunning = false
            activeBrush = nil
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
        }
    }

    private func tick() {
        guard !isShutDown else { return }
        let now = DispatchTime.now()
        let elapsedNanoseconds = now.uptimeNanoseconds - lastTick.uptimeNanoseconds
        let elapsed = min(Double(elapsedNanoseconds) / 1_000_000_000, 1.0 / 15.0)
        lastTick = now
        var changed = false
        if engine.isRunning {
            _ = engine.advance(elapsed * playbackSpeed)
            changed = true
        }
        if let brush = activeBrush {
            let brushChanged = apply(brush: brush, amount: brush.amountPerSecond * elapsed)
            if brushChanged {
                publishSnapshot(initialStateChanged: brush.target == .initialState)
            }
        }
        tickCount &+= 1
        if changed, activeBrush == nil, tickCount.isMultiple(of: 2) {
            publishSnapshot()
        }
    }

    private func apply(brush: ActiveBrush, amount: Double) -> Bool {
        engine.applyMaterialBrush(
            x: Double(brush.point.x),
            y: Double(brush.point.y),
            radius: brush.radius,
            operation: brush.operation,
            amount: amount,
            falloff: brush.falloff,
            target: brush.target
        ).isChanged
    }

    private func publishSnapshot(initialStateChanged: Bool = false) {
        let snapshot = SimulationSnapshot(engine.snapshot())
        snapshotHandler?(snapshot, initialStateChanged)
    }
}
