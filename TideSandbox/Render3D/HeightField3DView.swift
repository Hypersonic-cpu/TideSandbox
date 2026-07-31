import Metal
import SwiftUI

struct HeightField3DView: View {
    @ObservedObject var model: SimulationViewModel

    var body: some View {
        ZStack {
            HeightFieldMetalView(
                snapshot: model.snapshot,
                cameraYawDegrees: Float(model.cameraYawDegrees),
                cameraPitchDegrees: Float(model.cameraPitchDegrees),
                minimumWetDepth: Float(model.minimumWetDepth),
                verticalScale: Float(model.verticalExaggeration),
                waterOpacity: Float(model.waterOpacity)
            )
            if MTLCreateSystemDefaultDevice() == nil {
                ContentUnavailableView(
                    "Metal unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This Mac cannot create a Metal rendering device.")
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Interactive 3D height field")
        .accessibilityIdentifier("height-field-3d")
    }
}
