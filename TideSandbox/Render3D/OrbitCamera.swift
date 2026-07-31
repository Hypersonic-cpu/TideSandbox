import CoreGraphics
import simd

enum CameraPreset: String, CaseIterable, Identifiable {
    case top
    case isometric
    case lowOblique
    case oppositeOblique

    var id: Self { self }

    var title: String {
        switch self {
        case .top: "Top"
        case .isometric: "Isometric"
        case .lowOblique: "Low oblique"
        case .oppositeOblique: "Opposite oblique"
        }
    }

    var yawDegrees: Float {
        switch self {
        case .top: 0
        case .isometric: 45
        case .lowOblique: 135
        case .oppositeOblique: 225
        }
    }

    var pitchDegrees: Float {
        switch self {
        case .top: -89
        case .isometric: -35
        case .lowOblique: -18
        case .oppositeOblique: -35
        }
    }
}

struct OrbitCameraState: Sendable, Equatable {
    var target = SIMD3<Float>(repeating: 0)
    var yaw: Float = .pi / 4
    var pitch: Float = -35 * .pi / 180
    var distance: Float = 10
    var fieldOfViewY: Float = 50 * .pi / 180
}

struct CameraMatrices: Sendable {
    let view: simd_float4x4
    let projection: simd_float4x4
    let viewProjection: simd_float4x4
    let position: SIMD3<Float>
    let nearPlane: Float
    let farPlane: Float
}

struct OrbitCamera: Sendable {
    private(set) var state = OrbitCameraState()
    private(set) var minimumDistance: Float = 0.01
    private(set) var maximumDistance: Float = 1_000
    private(set) var fittedRadius: Float = 1
    private(set) var aspectRatio: Float = 1

    mutating func apply(_ preset: CameraPreset) {
        setOrientation(
            yawDegrees: preset.yawDegrees,
            pitchDegrees: preset.pitchDegrees
        )
    }

    mutating func setOrientation(yawDegrees: Float, pitchDegrees: Float) {
        guard yawDegrees.isFinite, pitchDegrees.isFinite else { return }
        state.yaw = yawDegrees * .pi / 180
        state.pitch = pitchDegrees * .pi / 180
        clampState()
    }

    mutating func fitToDomain(
        domainWidth: Float,
        domainHeight: Float,
        maximumAbsoluteElevation: Float,
        verticalScale: Float,
        aspectRatio: Float
    ) {
        let safeAspect = max(aspectRatio.isFinite ? aspectRatio : 1, 0.001)
        self.aspectRatio = safeAspect
        let verticalExtent = 2 * abs(maximumAbsoluteElevation * verticalScale)
        let diameter = simd_length(SIMD3<Float>(
            max(domainWidth, 0),
            verticalExtent,
            max(domainHeight, 0)
        ))
        fittedRadius = max(diameter * 0.5, 0.001)
        let verticalHalfAngle = state.fieldOfViewY * 0.5
        let horizontalHalfAngle = atan(tan(verticalHalfAngle) * safeAspect)
        let limitingHalfAngle = max(min(verticalHalfAngle, horizontalHalfAngle), 0.001)
        let fittedDistance = fittedRadius / sin(limitingHalfAngle) * 1.08
        minimumDistance = max(fittedRadius * 1.01, 0.01)
        maximumDistance = max(fittedDistance * 50, minimumDistance * 2)
        state.target = SIMD3<Float>(repeating: 0)
        state.distance = min(max(fittedDistance, minimumDistance), maximumDistance)
        clampState()
    }

    mutating func updateAspectRatio(_ aspectRatio: Float) {
        self.aspectRatio = max(aspectRatio.isFinite ? aspectRatio : 1, 0.001)
    }

    mutating func orbit(deltaX: Float, deltaY: Float) {
        state.yaw += deltaX * 0.006
        state.pitch += deltaY * 0.006
        clampState()
    }

    mutating func zoom(scrollDelta: Float) {
        state.distance *= exp(scrollDelta * 0.06)
        clampState()
    }

    mutating func pan(deltaX: Float, deltaY: Float, viewportHeight: Float) {
        let matrices = matrices()
        let viewHeight = max(viewportHeight, 1)
        let unitsPerPoint = 2 * state.distance * tan(state.fieldOfViewY * 0.5) / viewHeight
        let forward = simd_normalize(state.target - matrices.position)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_normalize(simd_cross(right, forward))
        state.target += (-right * deltaX + up * deltaY) * unitsPerPoint
    }

    func matrices() -> CameraMatrices {
        let horizontalDistance = state.distance * cos(state.pitch)
        let position = state.target + SIMD3<Float>(
            sin(state.yaw) * horizontalDistance,
            -sin(state.pitch) * state.distance,
            cos(state.yaw) * horizontalDistance
        )
        let view = Self.lookAt(position: position, target: state.target)
        let nearPlane = max(state.distance - fittedRadius * 1.25, fittedRadius * 0.001)
        let farPlane = max(state.distance + fittedRadius * 2.5, nearPlane + 1)
        let projection = Self.perspective(
            fieldOfViewY: state.fieldOfViewY,
            aspectRatio: aspectRatio,
            nearPlane: nearPlane,
            farPlane: farPlane
        )
        return CameraMatrices(
            view: view,
            projection: projection,
            viewProjection: projection * view,
            position: position,
            nearPlane: nearPlane,
            farPlane: farPlane
        )
    }

    private mutating func clampState() {
        let minimumPitch = -89 * Float.pi / 180
        let maximumPitch = -5 * Float.pi / 180
        state.pitch = min(max(state.pitch, minimumPitch), maximumPitch)
        state.distance = min(max(state.distance, minimumDistance), maximumDistance)
        if abs(state.yaw) > 2 * .pi {
            state.yaw.formTruncatingRemainder(dividingBy: 2 * .pi)
        }
    }

    private static func lookAt(
        position: SIMD3<Float>,
        target: SIMD3<Float>
    ) -> simd_float4x4 {
        let backward = simd_normalize(position - target)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), backward))
        let up = simd_cross(backward, right)
        return simd_float4x4(columns: (
            SIMD4<Float>(right.x, up.x, backward.x, 0),
            SIMD4<Float>(right.y, up.y, backward.y, 0),
            SIMD4<Float>(right.z, up.z, backward.z, 0),
            SIMD4<Float>(
                -simd_dot(right, position),
                -simd_dot(up, position),
                -simd_dot(backward, position),
                1
            )
        ))
    }

    private static func perspective(
        fieldOfViewY: Float,
        aspectRatio: Float,
        nearPlane: Float,
        farPlane: Float
    ) -> simd_float4x4 {
        let yScale = 1 / tan(fieldOfViewY * 0.5)
        let xScale = yScale / max(aspectRatio, 0.001)
        let zScale = farPlane / (nearPlane - farPlane)
        let wzScale = nearPlane * farPlane / (nearPlane - farPlane)
        return simd_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, -1),
            SIMD4<Float>(0, 0, wzScale, 0)
        ))
    }
}
