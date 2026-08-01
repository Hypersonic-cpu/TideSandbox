import SwiftUI

struct SceneGalleryView: View {
    @ObservedObject var library: SceneLibrary
    @ObservedObject var model: SimulationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var importing = false

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scene Gallery").font(.title2.bold())
                    Text("Built-ins are read-only; saving one creates an editable copy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(library.scenes.count) scenes")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("gallery-count")
                Spacer()
                Button("Import…") { importing = true }
                    .accessibilityIdentifier("import-scene-button")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()

            if library.scenes.isEmpty, library.isBusy {
                Spacer()
                ProgressView("Loading scenes…")
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(library.scenes) { scene in
                            Button {
                                selectedID = scene.id
                            } label: {
                                SceneCard(
                                    scene: scene,
                                    preview: library.previews[scene.id],
                                    isSelected: selectedID == scene.id
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("scene-card-\(scene.id.uuidString)")
                            .accessibilityLabel("\(scene.name), \(scene.gridWidth) by \(scene.gridHeight)")
                        }
                    }
                    .padding(20)
                }
            }

            Divider()
            HStack {
                if let selected = selectedScene {
                    Text("\(selected.gridWidth) × \(selected.gridHeight) · \(sourceLabel(selected.source))")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select a scene to open it")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open") {
                    if let selectedScene { open(selectedScene) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedScene == nil || library.isBusy)
                .accessibilityIdentifier("open-scene-button")
            }
            .padding(16)
        }
        .frame(minWidth: 760, minHeight: 560)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.tideSandboxScene],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else {
                if case let .failure(error) = result {
                    library.errorMessage = error.localizedDescription
                }
                return
            }
            Task {
                if let imported = await library.importPackage(from: url) {
                    selectedID = imported.id
                }
            }
        }
        .alert(
            "Scene Error",
            isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "Unknown scene error")
        }
        .task { library.reload() }
    }

    private var selectedScene: SceneSummary? {
        library.scenes.first { $0.id == selectedID }
    }

    private func open(_ scene: SceneSummary) {
        Task {
            if await library.open(scene, in: model) {
                dismiss()
            }
        }
    }

    private func sourceLabel(_ source: SceneSourceType) -> String {
        switch source {
        case .builtIn: "Built-in"
        case .user: "My scene"
        case .imported: "Imported"
        }
    }
}

private struct SceneCard: View {
    let scene: SceneSummary
    let preview: NSImage?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay(Image(systemName: "water.waves").font(.largeTitle))
                }
            }
            .frame(height: 130)
            .clipped()
            .background(.black.opacity(0.08))

            HStack(alignment: .firstTextBaseline) {
                Text(scene.name).font(.headline).lineLimit(1)
                Spacer()
                if scene.isReadOnly {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help("Read-only built-in")
                }
            }
            Text("\(scene.gridWidth) × \(scene.gridHeight)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let description = scene.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
