import SwiftUI

struct MainWindowView: View {
    @StateObject private var model = SimulationViewModel()

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .top) {
                MosaicGridView(model: model)
                simulationToolbar
                    .padding(14)
            }
            Divider()
            InspectorView(model: model)
                .frame(width: 300)
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
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
            Divider().frame(height: 20)
            Picker("Tool", selection: $model.tool) {
                ForEach(TerrainTool.allCases) { tool in
                    Label(tool.title, systemImage: tool.systemImage).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 360)
            .accessibilityIdentifier("terrain-tool-picker")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

private struct InspectorView: View {
    @ObservedObject var model: SimulationViewModel

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
            Picker("Preset", selection: $model.selectedPreset) {
                ForEach(SimulationPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .accessibilityIdentifier("preset-picker")
            Button("Load preset", action: model.loadSelectedPreset)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("load-preset-button")
        }
    }

    private var displaySection: some View {
        InspectorSection(title: "Display", systemImage: "square.grid.3x3") {
            Picker("Quantity", selection: Binding(
                get: { model.displayMode },
                set: model.selectDisplayMode
            )) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Picker("Colors", selection: $model.palette) {
                ForEach(ColorPalette.allCases) { palette in
                    Text(palette.title).tag(palette)
                }
            }
            Toggle("Grid lines", isOn: $model.showGrid)
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
            if model.tool == .raise || model.tool == .lower {
                LabeledSlider(title: "Radius", value: $model.brushRadius, range: 0.5...12,
                              format: "%.1f m")
                LabeledSlider(title: "Strength", value: $model.brushStrength, range: 0.05...3,
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
                Picker("Mode", selection: $model.polygonMode) {
                    Text("Add").tag(WSPolygonMode.add)
                    Text("Set").tag(WSPolygonMode.set)
                }
                LabeledSlider(title: "Elevation", value: $model.polygonElevation,
                              range: -2...2, format: "%.2f m")
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
            DiagnosticRow(label: "Volume", value: String(format: "%.6g m³", diagnostics.totalVolume))
            DiagnosticRow(label: "Depth", value: String(
                format: "%.3g…%.3g m", diagnostics.minimumDepth, diagnostics.maximumDepth
            ))
            DiagnosticRow(label: "Max speed", value: String(
                format: "%.3g m/s",
                hypot(diagnostics.maximumAbsVelocityX, diagnostics.maximumAbsVelocityY)
            ))
            DiagnosticRow(label: "Wet cells", value: "\(diagnostics.wetCellCount)")
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
