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

private enum PendingDiscardAction {
    case loadPreset
    case loadScene(SceneDocument)
    case restoreScene
}

@MainActor
final class SimulationViewModel: ObservableObject {
    @Published private(set) var snapshot: SimulationSnapshot = .empty
    @Published private(set) var isPlaying = false
    @Published var viewportMode: ViewportMode = .mosaic2D
    @Published var cameraPreset: CameraPreset = .isometric
    @Published var selectedPreset: SimulationPreset = .centerBump32
    @Published var displayMode: DisplayMode = .waterDepth
    @Published var palette: ColorPalette = .blueWhite
    @Published var resolutionPolicy: DisplayResolutionPolicy = .identicalCells
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
    @Published private(set) var currentScene: SceneDocument?
    @Published private(set) var isDirty = false
    @Published private(set) var isDiscardWarningPresented = false

    private let runtime: SimulationRuntime
    private var pendingDiscardAction: PendingDiscardAction?
    private var nextSnapshotGeneration: UInt64 = 1

    init() {
        runtime = SimulationRuntime(seed: SimulationPreset.centerBump32.makeSeed())
        runtime.setSnapshotHandler { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.snapshot = snapshot.withGeneration(nextSnapshotGeneration)
                nextSnapshotGeneration &+= 1
            }
        }
    }

    deinit {
        runtime.shutdown()
    }

    func togglePlayback() {
        isPlaying.toggle()
        if isPlaying { isDirty = true }
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
        isDirty = true
        runtime.advanceOneFrame(speed: speed)
    }

    func reset() {
        pause()
        polygonPoints.removeAll(keepingCapacity: true)
        if let currentScene {
            loadScene(currentScene)
        } else {
            runtime.reset()
            isDirty = false
        }
    }

    func requestLoadSelectedPreset() {
        requestDiscardingChanges(.loadPreset)
    }

    func requestLoadScene(_ document: SceneDocument) {
        requestDiscardingChanges(.loadScene(document))
    }

    func requestRestoreScene() {
        guard currentScene != nil else { return }
        requestDiscardingChanges(.restoreScene)
    }

    func confirmDiscardChanges() {
        let action = pendingDiscardAction
        pendingDiscardAction = nil
        isDiscardWarningPresented = false
        guard let action else { return }
        perform(action)
    }

    func cancelDiscardChanges() {
        pendingDiscardAction = nil
        isDiscardWarningPresented = false
    }

    func persistenceDocument(named name: String) throws -> SceneDocument {
        guard snapshot.width > 0,
              snapshot.height > 0,
              snapshot.bedElevation.count == snapshot.width * snapshot.height,
              snapshot.waterDepth.count == snapshot.width * snapshot.height else {
            throw ScenePackageError.invalidDimensions
        }
        let preview = try ScenePreviewRenderer.pngData(
            width: snapshot.width,
            height: snapshot.height,
            waterDepth: snapshot.waterDepth
        )
        let now = Date()
        let base = currentScene
        let manifest = SceneManifest(
            id: base?.manifest.id ?? UUID(),
            name: name,
            createdAt: base?.manifest.createdAt ?? now,
            modifiedAt: now,
            gridWidth: snapshot.width,
            gridHeight: snapshot.height,
            domainWidth: snapshot.domainWidth,
            domainHeight: snapshot.domainHeight,
            initializationMode: .explicitDepth,
            solver: solverParameters,
            resources: base?.manifest.resources ?? .standard,
            source: base?.manifest.source ?? .user,
            description: base?.manifest.description,
            tags: base?.manifest.tags ?? []
        )
        return SceneDocument(
            manifest: manifest,
            bedElevation: snapshot.bedElevation,
            initialWaterDepth: snapshot.waterDepth,
            previewPNG: preview,
            notesMarkdown: base?.notesMarkdown,
            packageURL: base?.packageURL,
            isReadOnly: base?.isReadOnly ?? false
        )
    }

    func acceptSavedScene(_ document: SceneDocument) {
        currentScene = document
        isDirty = false
    }

    var currentSceneName: String {
        currentScene?.manifest.name ?? selectedPreset.title
    }

    private var solverParameters: SceneSolverParameters {
        SceneSolverParameters(
            gravity: gravity,
            linearDamping: linearDamping,
            cflNumber: cflNumber,
            minimumWetDepth: minimumWetDepth,
            workerCount: workerCount
        )
    }

    private func loadSelectedPreset() {
        pause()
        polygonPoints.removeAll(keepingCapacity: true)
        displayMode = .waterDepth
        palette = displayMode.preferredPalette
        currentScene = nil
        isDirty = false
        runtime.load(selectedPreset.makeSeed())
    }

    private func loadScene(_ document: SceneDocument) {
        pause()
        polygonPoints.removeAll(keepingCapacity: true)
        brushPreviewPoint = nil
        currentScene = document
        gravity = document.manifest.solver.gravity
        linearDamping = document.manifest.solver.linearDamping
        cflNumber = document.manifest.solver.cflNumber
        minimumWetDepth = document.manifest.solver.minimumWetDepth
        workerCount = document.manifest.solver.workerCount
        displayMode = .waterDepth
        palette = displayMode.preferredPalette
        runtime.load(SceneSeed(
            width: document.manifest.gridWidth,
            height: document.manifest.gridHeight,
            domainWidth: document.manifest.domainWidth,
            domainHeight: document.manifest.domainHeight,
            bedElevation: document.bedElevation,
            waterDepth: document.initialWaterDepth
        ))
        runtime.updateConfiguration(
            gravity: gravity,
            linearDamping: linearDamping,
            cflNumber: cflNumber,
            minimumWetDepth: minimumWetDepth,
            workerCount: workerCount
        )
        isDirty = false
    }

    private func requestDiscardingChanges(_ action: PendingDiscardAction) {
        guard isDirty else {
            perform(action)
            return
        }
        pendingDiscardAction = action
        isDiscardWarningPresented = true
    }

    private func perform(_ action: PendingDiscardAction) {
        switch action {
        case .loadPreset:
            loadSelectedPreset()
        case let .loadScene(document):
            loadScene(document)
        case .restoreScene:
            if let currentScene { loadScene(currentScene) }
        }
    }

    func selectDisplayMode(_ mode: DisplayMode) {
        displayMode = mode
        palette = mode.preferredPalette
    }

    func applyConfiguration() {
        isDirty = true
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
        isDirty = true
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
        isDirty = true
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
