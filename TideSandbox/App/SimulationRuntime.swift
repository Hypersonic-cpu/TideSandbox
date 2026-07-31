import CoreGraphics
import Foundation

struct ActiveBrush: Sendable {
    let point: CGPoint
    let radius: Double
    let strengthPerSecond: Double
    let falloff: WSBrushFalloff
    let minimumBed: Double
    let maximumBed: Double
}

nonisolated final class SimulationRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "WaterSandbox.EngineRuntime", qos: .userInteractive)
    private let engine: WSWaterEngineBridge
    private var snapshotHandler: (@Sendable (SimulationSnapshot) -> Void)?
    private var timer: DispatchSourceTimer?
    private var activeBrush: ActiveBrush?
    private var lastTick = DispatchTime.now()
    private var tickCount: UInt = 0
    private var playbackSpeed = 1.0
    private var isShutDown = false

    init(seed: SceneSeed) {
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
            waterDepth: seed.depthData
        )
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

    func setSnapshotHandler(_ handler: @escaping @Sendable (SimulationSnapshot) -> Void) {
        queue.async { [weak self] in
            guard let self, !isShutDown else { return }
            snapshotHandler = handler
            publishSnapshot()
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
                waterDepth: seed.depthData
            )
            lastTick = .now()
            publishSnapshot()
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

    func beginBrush(_ brush: ActiveBrush) {
        queue.async { [weak self] in
            guard let self, !isShutDown else { return }
            engine.isRunning = false
            activeBrush = brush
            lastTick = .now()
        }
    }

    func moveBrush(to point: CGPoint) {
        queue.async { [weak self] in
            guard let self, let current = activeBrush, !isShutDown else { return }
            activeBrush = ActiveBrush(
                point: point,
                radius: current.radius,
                strengthPerSecond: current.strengthPerSecond,
                falloff: current.falloff,
                minimumBed: current.minimumBed,
                maximumBed: current.maximumBed
            )
        }
    }

    func endBrush() {
        queue.async { [weak self] in
            guard let self else { return }
            activeBrush = nil
            publishSnapshot()
        }
    }

    func applyPolygon(
        points: [CGPoint],
        mode: WSPolygonMode,
        elevation: Double,
        minimumBed: Double,
        maximumBed: Double
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
            _ = engine.applyPolygon(
                xyCoordinates: data,
                mode: mode,
                elevation: elevation,
                minimumBed: minimumBed,
                maximumBed: maximumBed
            )
            publishSnapshot()
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
            _ = engine.applyBrush(
                x: Double(brush.point.x),
                y: Double(brush.point.y),
                radius: brush.radius,
                strength: brush.strengthPerSecond * elapsed,
                falloff: brush.falloff,
                minimumBed: brush.minimumBed,
                maximumBed: brush.maximumBed
            )
            changed = true
        }
        tickCount &+= 1
        if changed, tickCount.isMultiple(of: 2) {
            publishSnapshot()
        }
    }

    private func publishSnapshot() {
        let snapshot = SimulationSnapshot(engine.snapshot())
        snapshotHandler?(snapshot)
    }
}
