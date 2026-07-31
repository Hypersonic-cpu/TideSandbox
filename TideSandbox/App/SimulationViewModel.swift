import CoreGraphics
import Combine
import Foundation

enum TerrainTool: String, CaseIterable, Identifiable {
    case inspect
    case raise
    case lower
    case polygon

    var id: Self { self }

    var title: String {
        switch self {
        case .inspect: "Inspect"
        case .raise: "Raise"
        case .lower: "Lower"
        case .polygon: "Polygon"
        }
    }

    var systemImage: String {
        switch self {
        case .inspect: "cursorarrow"
        case .raise: "mountain.2"
        case .lower: "eraser"
        case .polygon: "point.3.connected.trianglepath.dotted"
        }
    }
}

@MainActor
final class SimulationViewModel: ObservableObject {
    @Published private(set) var snapshot: SimulationSnapshot = .empty
    @Published private(set) var isPlaying = false
    @Published var selectedPreset: SimulationPreset = .centerBump32
    @Published var displayMode: DisplayMode = .waterDepth
    @Published var palette: ColorPalette = .blueWhite
    @Published var tool: TerrainTool = .inspect
    @Published var showGrid = true
    @Published var speed = 1.0
    @Published var gravity = 9.81
    @Published var linearDamping = 0.08
    @Published var cflNumber = 0.3
    @Published var minimumWetDepth = 1.0e-6
    @Published var workerCount = 0
    @Published var brushRadius = 2.5
    @Published var brushStrength = 0.5
    @Published var brushFalloff: WSBrushFalloff = .smooth
    @Published var polygonMode: WSPolygonMode = .add
    @Published var polygonElevation = 0.25
    @Published private(set) var polygonPoints: [CGPoint] = []
    @Published private(set) var brushPreviewPoint: CGPoint?

    private let runtime: SimulationRuntime

    init() {
        runtime = SimulationRuntime(seed: SimulationPreset.centerBump32.makeSeed())
        runtime.setSnapshotHandler { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.snapshot = snapshot
            }
        }
    }

    deinit {
        runtime.shutdown()
    }

    func togglePlayback() {
        isPlaying.toggle()
        runtime.setPlaybackSpeed(speed)
        runtime.setPlaying(isPlaying)
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        runtime.setPlaying(false)
    }

    func step() {
        pause()
        runtime.advanceOneFrame(speed: speed)
    }

    func reset() {
        pause()
        polygonPoints.removeAll(keepingCapacity: true)
        runtime.reset()
    }

    func loadSelectedPreset() {
        pause()
        polygonPoints.removeAll(keepingCapacity: true)
        displayMode = .waterDepth
        palette = displayMode.preferredPalette
        runtime.load(selectedPreset.makeSeed())
    }

    func selectDisplayMode(_ mode: DisplayMode) {
        displayMode = mode
        palette = mode.preferredPalette
    }

    func applyConfiguration() {
        runtime.updateConfiguration(
            gravity: gravity,
            linearDamping: linearDamping,
            cflNumber: cflNumber,
            minimumWetDepth: minimumWetDepth,
            workerCount: workerCount
        )
    }

    func updatePlaybackSpeed() {
        runtime.setPlaybackSpeed(speed)
    }

    func beginBrush(at point: CGPoint) {
        guard tool == .raise || tool == .lower else { return }
        pause()
        brushPreviewPoint = point
        let direction = tool == .raise ? 1.0 : -1.0
        runtime.beginBrush(ActiveBrush(
            point: point,
            radius: brushRadius,
            strengthPerSecond: direction * brushStrength,
            falloff: brushFalloff,
            minimumBed: -100,
            maximumBed: 100
        ))
    }

    func moveBrush(to point: CGPoint) {
        guard tool == .raise || tool == .lower else { return }
        brushPreviewPoint = point
        runtime.moveBrush(to: point)
    }

    func endBrush() {
        brushPreviewPoint = nil
        runtime.endBrush()
    }

    func addPolygonPoint(_ point: CGPoint) {
        guard tool == .polygon else { return }
        pause()
        polygonPoints.append(point)
    }

    func completePolygon() {
        guard polygonPoints.count >= 3 else { return }
        runtime.applyPolygon(
            points: polygonPoints,
            mode: polygonMode,
            elevation: polygonElevation,
            minimumBed: -100,
            maximumBed: 100
        )
        polygonPoints.removeAll(keepingCapacity: true)
    }

    func cancelPolygon() {
        polygonPoints.removeAll(keepingCapacity: true)
    }
}
