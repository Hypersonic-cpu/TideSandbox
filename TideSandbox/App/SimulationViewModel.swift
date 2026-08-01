import CoreGraphics
import Combine
import Foundation

enum TerrainTool: String, CaseIterable, Identifiable {
    case inspect
    case addSand
    case removeSand
    case addWater
    case removeWater
    case polygon

    var id: Self { self }

    var title: String {
        switch self {
        case .inspect: "Inspect"
        case .addSand: "Add sand"
        case .removeSand: "Remove sand"
        case .addWater: "Add water"
        case .removeWater: "Remove water"
        case .polygon: "Polygon"
        }
    }

    var systemImage: String {
        switch self {
        case .inspect: "cursorarrow"
        case .addSand: "mountain.2"
        case .removeSand: "eraser"
        case .addWater: "drop.fill"
        case .removeWater: "drop"
        case .polygon: "point.3.connected.trianglepath.dotted"
        }
    }

    var operation: WSMaterialOperation? {
        switch self {
        case .inspect, .polygon: nil
        case .addSand: .addSand
        case .removeSand: .removeSand
        case .addWater: .addWater
        case .removeWater: .removeWater
        }
    }
}

enum SaveStateSource: String, CaseIterable, Identifiable {
    case initialState
    case pausedCurrentState

    var id: Self { self }
    var title: String {
        self == .initialState ? "Stored initial state" : "Paused current state"
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
    @Published private(set) var cameraPreset: CameraPreset? = .isometric
    @Published private(set) var cameraYawDegrees = 45.0
    @Published private(set) var cameraPitchDegrees = -35.0
    @Published private(set) var cameraSessionState: OrbitCameraState?
    @Published private(set) var cameraFitRequestID: UInt64 = 0
    @Published var verticalExaggeration = 6.0
    @Published var waterOpacity = 0.72
    @Published var wireframeTerrain = false
    @Published var wireframeWater = false
    @Published var showDomainBounds = false
    @Published var showSurfaceNormals = false
    @Published var showWetCellMask = false
    @Published var showCameraTarget = false
    @Published var selectedPreset: SimulationPreset = .centerBump32
    @Published var displayMode: DisplayMode = .decorativeComposite
    @Published var palette: ColorPalette = .blueWhite
    @Published var resolutionPolicy: DisplayResolutionPolicy = .identicalCells
    @Published var tool: TerrainTool = .inspect {
        didSet {
            if tool != .inspect {
                pause()
            }
            if tool.operation == nil {
                brushPreviewPoint = nil
            }
        }
    }
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
    @Published var editTarget: WSEditTarget = .initialState
    @Published var polygonOperation: WSMaterialOperation = .addSand
    @Published var polygonAmount = 0.25
    @Published var saveStateSource: SaveStateSource = .initialState
    @Published var minimumBedElevation = SceneWorldLimits.defaults.minimumBedElevation
    @Published var maximumSurfaceElevation = SceneWorldLimits.defaults.maximumSurfaceElevation
    @Published var showMapAnnotations = true
    @Published private(set) var polygonPoints: [CGPoint] = []
    @Published private(set) var brushPreviewPoint: CGPoint?
    @Published private(set) var currentScene: SceneDocument?
    @Published private(set) var isDirty = false
    @Published private(set) var isDiscardWarningPresented = false

    private let runtime: SimulationRuntime
    private var pendingDiscardAction: PendingDiscardAction?
    private var nextSnapshotGeneration: UInt64 = 1
    private var storedInitialBedElevation = [Float]()
    private var storedInitialWaterDepth = [Float]()
    @Published private(set) var decorativeMapConfiguration = DecorativeMapConfiguration.default

    init() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-test-fast-material-brush") {
            brushRadius = 5
            brushStrength = 3
            brushFalloff = .constant
        }
#endif
        let seed = SimulationPreset.centerBump32.makeSeed()
        storedInitialBedElevation = seed.bedElevation
        storedInitialWaterDepth = seed.waterDepth
        decorativeMapConfiguration = DecorativeMapConfiguration.stableScene(
            bedElevation: seed.bedElevation,
            waterDepth: seed.waterDepth,
            visualWetThreshold: 1.0e-6
        )
        runtime = SimulationRuntime(seed: seed)
        runtime.setSnapshotHandler { [weak self] snapshot, initialStateChanged in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.snapshot = snapshot.withGeneration(nextSnapshotGeneration)
                if initialStateChanged {
                    storedInitialBedElevation = snapshot.bedElevation
                    storedInitialWaterDepth = snapshot.waterDepth
                }
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
        brushPreviewPoint = nil
        runtime.reset()
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
        let bedElevation = saveStateSource == .initialState
            ? storedInitialBedElevation : snapshot.bedElevation
        let waterDepth = saveStateSource == .initialState
            ? storedInitialWaterDepth : snapshot.waterDepth
        guard bedElevation.count == snapshot.width * snapshot.height,
              waterDepth.count == snapshot.width * snapshot.height else {
            throw ScenePackageError.invalidDimensions
        }
        let preview = try ScenePreviewRenderer.pngData(
            width: snapshot.width,
            height: snapshot.height,
            waterDepth: waterDepth
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
            worldLimits: SceneWorldLimits(
                minimumBedElevation: minimumBedElevation,
                maximumSurfaceElevation: maximumSurfaceElevation
            ),
            resources: base?.manifest.resources ?? .standard,
            source: base?.manifest.source ?? .user,
            description: base?.manifest.description,
            tags: base?.manifest.tags ?? []
        )
        return SceneDocument(
            manifest: manifest,
            bedElevation: bedElevation,
            initialWaterDepth: waterDepth,
            previewPNG: preview,
            notesMarkdown: base?.notesMarkdown,
            packageURL: base?.packageURL,
            isReadOnly: base?.isReadOnly ?? false
        )
    }

    func acceptSavedScene(_ document: SceneDocument) {
        if saveStateSource == .pausedCurrentState {
            loadScene(document)
        }
        currentScene = document
        saveStateSource = .initialState
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
        resetCameraFraming()
        polygonPoints.removeAll(keepingCapacity: true)
        brushPreviewPoint = nil
        displayMode = .decorativeComposite
        palette = displayMode.preferredPalette
        currentScene = nil
        isDirty = false
        let seed = selectedPreset.makeSeed()
        storedInitialBedElevation = seed.bedElevation
        storedInitialWaterDepth = seed.waterDepth
        minimumBedElevation = seed.worldLimits.minimumBedElevation
        maximumSurfaceElevation = seed.worldLimits.maximumSurfaceElevation
        decorativeMapConfiguration = DecorativeMapConfiguration.stableScene(
            bedElevation: seed.bedElevation,
            waterDepth: seed.waterDepth,
            visualWetThreshold: Float(minimumWetDepth)
        )
        runtime.load(seed)
    }

    private func loadScene(_ document: SceneDocument) {
        pause()
        resetCameraFraming()
        polygonPoints.removeAll(keepingCapacity: true)
        brushPreviewPoint = nil
        currentScene = document
        gravity = document.manifest.solver.gravity
        linearDamping = document.manifest.solver.linearDamping
        cflNumber = document.manifest.solver.cflNumber
        minimumWetDepth = document.manifest.solver.minimumWetDepth
        workerCount = document.manifest.solver.workerCount
        minimumBedElevation = document.manifest.resolvedWorldLimits.minimumBedElevation
        maximumSurfaceElevation = document.manifest.resolvedWorldLimits.maximumSurfaceElevation
        displayMode = .decorativeComposite
        palette = displayMode.preferredPalette
        storedInitialBedElevation = document.bedElevation
        storedInitialWaterDepth = document.initialWaterDepth
        decorativeMapConfiguration = DecorativeMapConfiguration.stableScene(
            bedElevation: document.bedElevation,
            waterDepth: document.initialWaterDepth,
            visualWetThreshold: Float(minimumWetDepth)
        )
        runtime.load(SceneSeed(
            width: document.manifest.gridWidth,
            height: document.manifest.gridHeight,
            domainWidth: document.manifest.domainWidth,
            domainHeight: document.manifest.domainHeight,
            bedElevation: document.bedElevation,
            waterDepth: document.initialWaterDepth,
            worldLimits: document.manifest.resolvedWorldLimits
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

    func selectCameraPreset(_ preset: CameraPreset?) {
        guard let preset else { return }
        cameraPreset = preset
        cameraYawDegrees = Double(preset.yawDegrees)
        cameraPitchDegrees = Double(preset.pitchDegrees)
        cameraSessionState = nil
        cameraFitRequestID &+= 1
    }

    func setCameraYawDegrees(_ value: Double) {
        cameraPreset = nil
        cameraYawDegrees = min(max(value.isFinite ? value : 45, 0), 360)
        updateSessionOrientation()
    }

    func setCameraPitchDegrees(_ value: Double) {
        cameraPreset = nil
        cameraPitchDegrees = min(max(value.isFinite ? value : -35, -89), -5)
        updateSessionOrientation()
    }

    func requestCameraFit() {
        cameraSessionState = nil
        cameraFitRequestID &+= 1
    }

    func setVerticalExaggeration(_ value: Double) {
        verticalExaggeration = min(max(value.isFinite ? value : 6, 1), 20)
        resetCameraFraming()
    }

    func acceptCameraState(_ state: OrbitCameraState, reason: CameraChangeReason) {
        cameraSessionState = state
        let degrees = Double(state.yaw * 180 / .pi)
        cameraYawDegrees = (degrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        cameraPitchDegrees = min(max(Double(state.pitch * 180 / .pi), -89), -5)
        switch reason {
        case .fit:
            break
        case .interaction:
            cameraPreset = nil
        case let .preset(preset):
            cameraPreset = preset
        }
    }

    private func updateSessionOrientation() {
        guard var state = cameraSessionState else { return }
        state.yaw = Float(cameraYawDegrees) * .pi / 180
        state.pitch = Float(cameraPitchDegrees) * .pi / 180
        cameraSessionState = state
    }

    private func resetCameraFraming() {
        cameraSessionState = nil
        cameraFitRequestID &+= 1
    }

    var render3DSettings: Render3DSettings {
        var settings = Render3DSettings()
        settings.verticalScale = Float(verticalExaggeration)
        settings.waterOpacity = Float(waterOpacity)
        settings.wireframeTerrain = wireframeTerrain
        settings.wireframeWater = wireframeWater
        settings.showDomainBounds = showDomainBounds
        settings.showSurfaceNormals = showSurfaceNormals
        settings.showWetCellMask = showWetCellMask
        settings.showCameraTarget = showCameraTarget
        return settings
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
        guard let operation = tool.operation else { return }
        pause()
        isDirty = true
        brushPreviewPoint = point
        runtime.beginBrush(ActiveBrush(
            point: point,
            radius: brushRadius,
            operation: operation,
            amountPerSecond: brushStrength,
            falloff: brushFalloff,
            target: editTarget
        ))
    }

    func moveBrush(to point: CGPoint) {
        guard tool.operation != nil else { return }
        brushPreviewPoint = point
        runtime.moveBrush(to: point)
    }

    func endBrush() {
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
            operation: polygonOperation,
            amount: polygonAmount,
            target: editTarget
        )
        polygonPoints.removeAll(keepingCapacity: true)
    }

    func cancelPolygon() {
        polygonPoints.removeAll(keepingCapacity: true)
    }
}
