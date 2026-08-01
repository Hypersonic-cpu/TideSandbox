import SwiftUI

struct MainWindowView: View {
    @StateObject private var model = SimulationViewModel()
    @StateObject private var library = SceneLibrary()
    @State private var isGalleryPresented = false
    @State private var isSaveAsPresented = false
    @State private var saveAsName = ""

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .top) {
                SimulationViewport(model: model)
                simulationToolbar
                    .padding(14)
            }
            Divider()
            InspectorView(
                model: model,
                library: library,
                showGallery: { isGalleryPresented = true },
                save: saveCurrentScene,
                saveAs: presentSaveAs,
                restore: model.requestRestoreScene
            )
                .frame(width: 300)
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isGalleryPresented) {
            SceneGalleryView(library: library, model: model)
        }
        .alert("Save Scene As", isPresented: $isSaveAsPresented) {
            TextField("Scene name", text: $saveAsName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = saveAsName
                Task { _ = await library.save(model: model, name: name, duplicate: true) }
            }
        } message: {
            Text("Create a separate editable scene package.")
        }
        .alert(
            "Scene Error",
            isPresented: Binding(
                get: { library.errorMessage != nil && !isGalleryPresented },
                set: { if !$0 { library.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "Unknown scene error")
        }
        .confirmationDialog(
            "Discard unsaved changes?",
            isPresented: Binding(
                get: { model.isDiscardWarningPresented },
                set: { if !$0 { model.cancelDiscardChanges() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive, action: model.confirmDiscardChanges)
            Button("Cancel", role: .cancel, action: model.cancelDiscardChanges)
        } message: {
            Text("The current terrain, water state, or solver changes have not been saved.")
        }
    }

    private var simulationToolbar: some View {
        HStack(spacing: 8) {
            Button(action: model.togglePlayback) {
                Label(model.isPlaying ? "Pause" : "Play",
                      systemImage: model.isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityIdentifier("play-pause-button")
            .help(model.isPlaying ? "Pause simulation" : "Play simulation")
            Button(action: model.step) {
                Label("Step", systemImage: "forward.frame.fill")
            }
            .accessibilityIdentifier("step-button")
            .help("Advance one display frame")
            Button(action: model.reset) {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .accessibilityIdentifier("reset-button")
            .help("Restore the scene's initial state")
            Button {
                isGalleryPresented = true
            } label: {
                Label("Gallery", systemImage: "square.grid.2x2")
            }
            .accessibilityIdentifier("gallery-button")
            .help("Open the scene gallery")
            Divider().frame(height: 20)
            Picker("Tool", selection: $model.tool) {
                ForEach(TerrainTool.allCases) { tool in
                    Label(tool.title, systemImage: tool.systemImage).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 360)
            .accessibilityIdentifier("terrain-tool-picker")
            .disabled(model.viewportMode == .heightField3D)
            .help(model.viewportMode == .heightField3D
                  ? "Terrain editing is available in 2D mode."
                  : "Choose a terrain editing tool")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    private func saveCurrentScene() {
        let name = model.currentSceneName
        Task { _ = await library.save(model: model, name: name, duplicate: false) }
    }

    private func presentSaveAs() {
        saveAsName = "\(model.currentSceneName) Copy"
        isSaveAsPresented = true
    }
}

private struct InspectorView: View {
    @ObservedObject var model: SimulationViewModel
    @ObservedObject var library: SceneLibrary
    @State private var is3DDebugExpanded = false
    let showGallery: () -> Void
    let save: () -> Void
    let saveAs: () -> Void
    let restore: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                sceneSection
                displaySection
                simulationSection
                terrainSection
                diagnosticsSection
            }
            .padding(18)
        }
        .background(.ultraThinMaterial)
    }

    private var sceneSection: some View {
        InspectorSection(title: "Scene", systemImage: "map") {
            HStack {
                Text(model.currentSceneName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if model.isDirty {
                    Label("Unsaved", systemImage: "circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 7))
                        .foregroundStyle(.orange)
                        .help("Unsaved changes")
                }
            }
            Picker("Preset", selection: $model.selectedPreset) {
                ForEach(SimulationPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .accessibilityIdentifier("preset-picker")
            Button("Load preset", action: model.requestLoadSelectedPreset)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("load-preset-button")
            Picker("Save state", selection: $model.saveStateSource) {
                ForEach(SaveStateSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .help("Saving the paused current state explicitly makes it the scene's new initial state.")
            HStack {
                Button("Gallery…", action: showGallery)
                Spacer()
                Button("Restore", action: restore)
                    .disabled(model.currentScene == nil)
                Menu("Save") {
                    Button("Save", action: save)
                    Button("Save As…", action: saveAs)
                }
                .disabled(model.snapshot.width == 0 || library.isBusy)
                .accessibilityIdentifier("save-scene-menu")
            }
        }
    }

    private var displaySection: some View {
        InspectorSection(title: "Display", systemImage: "square.grid.3x3") {
            Picker("View", selection: $model.viewportMode) {
                ForEach(ViewportMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("viewport-mode-picker")
            if model.viewportMode == .heightField3D {
                Picker("Camera", selection: Binding(
                    get: { model.cameraPreset },
                    set: model.selectCameraPreset
                )) {
                    Text("Custom").tag(CameraPreset?.none)
                    ForEach(CameraPreset.allCases) { preset in
                        Text(preset.title).tag(CameraPreset?.some(preset))
                    }
                }
                .accessibilityIdentifier("camera-preset-picker")
                Button("Fit view", systemImage: "viewfinder", action: model.requestCameraFit)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("fit-camera-button")
                    .help("Fit the whole terrain and water domain")
                LabeledSlider(
                    title: "Yaw",
                    value: Binding(
                        get: { model.cameraYawDegrees },
                        set: model.setCameraYawDegrees
                    ),
                    range: 0...360,
                    format: "%.0f°",
                    accessibilityIdentifier: "camera-yaw-slider"
                )
                LabeledSlider(
                    title: "Pitch",
                    value: Binding(
                        get: { model.cameraPitchDegrees },
                        set: model.setCameraPitchDegrees
                    ),
                    range: -89 ... -5,
                    format: "%.0f°",
                    accessibilityIdentifier: "camera-pitch-slider"
                )
                LabeledSlider(
                    title: "Vertical exaggeration",
                    value: Binding(
                        get: { model.verticalExaggeration },
                        set: model.setVerticalExaggeration
                    ),
                    range: 1...20,
                    format: "%.1f×",
                    accessibilityIdentifier: "vertical-exaggeration-slider"
                )
                LabeledSlider(
                    title: "Water opacity",
                    value: Binding(
                        get: { model.waterOpacity * 100 },
                        set: { model.waterOpacity = $0 / 100 }
                    ),
                    range: 20...100,
                    format: "%.0f%%",
                    accessibilityIdentifier: "water-opacity-slider"
                )
                Button {
                    is3DDebugExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: is3DDebugExpanded
                              ? "chevron.down"
                              : "chevron.right")
                            .font(.caption.weight(.semibold))
                        Text("3D Debug")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("debug-3d-disclosure")
                .accessibilityValue(is3DDebugExpanded ? "Expanded" : "Collapsed")
                if is3DDebugExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Wireframe terrain", isOn: $model.wireframeTerrain)
                            .accessibilityIdentifier("wireframe-terrain-toggle")
                        Toggle("Wireframe water", isOn: $model.wireframeWater)
                            .accessibilityIdentifier("wireframe-water-toggle")
                        Toggle("Domain bounds", isOn: $model.showDomainBounds)
                            .accessibilityIdentifier("domain-bounds-toggle")
                        Toggle("Surface normals", isOn: $model.showSurfaceNormals)
                            .accessibilityIdentifier("surface-normals-toggle")
                        Toggle("Wet-cell mask", isOn: $model.showWetCellMask)
                            .accessibilityIdentifier("wet-cell-mask-toggle")
                        Toggle("Camera target", isOn: $model.showCameraTarget)
                            .accessibilityIdentifier("camera-target-toggle")
                    }
                    .padding(.top, 6)
                }
            } else {
                Picker("Quantity", selection: Binding(
                    get: { model.displayMode },
                    set: model.selectDisplayMode
                )) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                if model.displayMode != .decorativeComposite {
                    Picker("Colors", selection: $model.palette) {
                        ForEach(ColorPalette.allCases) { palette in
                            Text(palette.title).tag(palette)
                        }
                    }
                }
                Picker("Sampling", selection: $model.resolutionPolicy) {
                    ForEach(DisplayResolutionPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .accessibilityIdentifier("resolution-policy-picker")
                Toggle("Grid lines", isOn: $model.showGrid)
                Toggle("Map annotations", isOn: $model.showMapAnnotations)
                    .accessibilityIdentifier("map-annotations-toggle")
            }
        }
    }

    private var simulationSection: some View {
        InspectorSection(title: "Simulation", systemImage: "waveform.path.ecg") {
            LabeledSlider(title: "Speed", value: $model.speed, range: 0.1...4,
                          format: "%.1f×")
                .onChange(of: model.speed) { _, _ in model.updatePlaybackSpeed() }
            LabeledSlider(title: "Gravity", value: $model.gravity, range: 0.1...20,
                          format: "%.2f")
            LabeledSlider(title: "Damping", value: $model.linearDamping, range: 0...2,
                          format: "%.2f")
            LabeledSlider(title: "CFL", value: $model.cflNumber, range: 0.1...0.5,
                          format: "%.2f")
            Picker("Workers", selection: $model.workerCount) {
                Text("Automatic").tag(0)
                Text("1").tag(1)
                Text("2").tag(2)
                Text("4").tag(4)
            }
            Button("Apply parameters", action: model.applyConfiguration)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var terrainSection: some View {
        InspectorSection(title: "Terrain", systemImage: "mountain.2") {
            Picker("Edit state", selection: $model.editTarget) {
                Text("Initial").tag(WSEditTarget.initialState)
                Text("Paused current").tag(WSEditTarget.pausedCurrentState)
            }
            if model.tool.operation != nil {
                LabeledSlider(title: "Radius", value: $model.brushRadius, range: 0.5...12,
                              format: "%.1f m")
                LabeledSlider(title: "Rate", value: $model.brushStrength, range: 0.05...3,
                              format: "%.2f m/s")
                Picker("Falloff", selection: $model.brushFalloff) {
                    Text("Constant").tag(WSBrushFalloff.constant)
                    Text("Linear").tag(WSBrushFalloff.linear)
                    Text("Smooth").tag(WSBrushFalloff.smooth)
                }
                Text("Press and drag, or hold still, to paint. Editing pauses the simulation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.tool == .polygon {
                Picker("Material", selection: $model.polygonOperation) {
                    Text("Add sand").tag(WSMaterialOperation.addSand)
                    Text("Remove sand").tag(WSMaterialOperation.removeSand)
                    Text("Add water").tag(WSMaterialOperation.addWater)
                    Text("Remove water").tag(WSMaterialOperation.removeWater)
                }
                LabeledSlider(title: "Amount", value: $model.polygonAmount,
                              range: 0.01...2, format: "%.2f m")
                HStack {
                    Text("\(model.polygonPoints.count) vertices")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: model.cancelPolygon)
                    Button("Apply", action: model.completePolygon)
                        .disabled(model.polygonPoints.count < 3)
                }
            } else {
                Text("Choose a terrain tool, then interact directly with the mosaic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var diagnosticsSection: some View {
        let diagnostics = model.snapshot.diagnostics
        return InspectorSection(title: "Diagnostics", systemImage: "gauge.with.dots.needle.67percent") {
            DiagnosticRow(label: "Grid", value: "\(model.snapshot.width) × \(model.snapshot.height)")
                .accessibilityIdentifier("grid-diagnostic")
            DiagnosticRow(label: "Time", value: String(format: "%.3f s", diagnostics.simulatedTime))
                .accessibilityIdentifier("time-diagnostic")
            DiagnosticRow(label: "Volume", value: String(format: "%.6g m³", diagnostics.totalVolume))
                .accessibilityIdentifier("volume-diagnostic")
            DiagnosticRow(label: "Depth", value: String(
                format: "%.3g…%.3g m", diagnostics.minimumDepth, diagnostics.maximumDepth
            ))
            .accessibilityIdentifier("depth-diagnostic")
            DiagnosticRow(label: "Max speed", value: String(
                format: "%.3g m/s",
                hypot(diagnostics.maximumAbsVelocityX, diagnostics.maximumAbsVelocityY)
            ))
            DiagnosticRow(label: "Wet cells", value: "\(diagnostics.wetCellCount)")
                .accessibilityIdentifier("wet-cells-diagnostic")
            DiagnosticRow(label: "Substeps", value: "\(diagnostics.substepCount)")
            if !diagnostics.isFinite {
                Label("Non-finite numerical state", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var accessibilityIdentifier = ""

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}

private struct DiagnosticRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}
