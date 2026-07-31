import SwiftUI

enum ViewportMode: String, CaseIterable, Identifiable {
    case mosaic2D
    case heightField3D

    var id: Self { self }

    var title: String {
        switch self {
        case .mosaic2D: "2D"
        case .heightField3D: "3D"
        }
    }
}

struct SimulationViewport: View {
    @ObservedObject var model: SimulationViewModel

    var body: some View {
        switch model.viewportMode {
        case .mosaic2D:
            MosaicGridView(model: model)
        case .heightField3D:
            HeightField3DPlaceholder()
        }
    }
}

private struct HeightField3DPlaceholder: View {
    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            ContentUnavailableView(
                "3D Height Field",
                systemImage: "view.3d",
                description: Text("The Metal viewport is being initialized.")
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("3D height-field placeholder")
        .accessibilityIdentifier("height-field-3d-placeholder")
    }
}
