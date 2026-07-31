import Metal
import SwiftUI

struct HeightField3DView: View {
    @ObservedObject var model: SimulationViewModel

    var body: some View {
        ZStack {
            HeightFieldMetalView(
                snapshot: model.snapshot,
                cameraSessionState: model.cameraSessionState,
                cameraYawDegrees: Float(model.cameraYawDegrees),
                cameraPitchDegrees: Float(model.cameraPitchDegrees),
                cameraFitRequestID: model.cameraFitRequestID,
                minimumWetDepth: Float(model.minimumWetDepth),
                settings: model.render3DSettings,
                onCameraChange: model.acceptCameraState
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
