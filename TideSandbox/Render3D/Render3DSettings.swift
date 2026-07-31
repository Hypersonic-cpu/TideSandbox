import simd

struct Render3DSettings: Sendable, Equatable {
    var verticalScale: Float = 1
    var waterOpacity: Float = 0.72
    var lightDirection = SIMD3<Float>(-0.35, 0.85, 0.4)
    var shorelineBand: Float = 4
    var renderBias: Float = 0.002
    var wireframeTerrain = false
    var wireframeWater = false
    var showDomainBounds = false
    var showSurfaceNormals = false
    var showWetCellMask = false
    var showCameraTarget = false
}
