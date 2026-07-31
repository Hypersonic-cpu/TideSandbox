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
            HeightField3DView(model: model)
        }
    }
}
