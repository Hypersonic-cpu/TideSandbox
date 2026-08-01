import Foundation

struct SceneSeed: Sendable {
    let width: Int
    let height: Int
    let domainWidth: Double
    let domainHeight: Double
    let bedElevation: [Float]
    let waterDepth: [Float]
    let worldLimits: SceneWorldLimits
    let boundaries: SceneBoundaryConfiguration

    init(
        width: Int,
        height: Int,
        domainWidth: Double,
        domainHeight: Double,
        bedElevation: [Float],
        waterDepth: [Float],
        worldLimits: SceneWorldLimits = .defaults,
        boundaries: SceneBoundaryConfiguration = .reflective
    ) {
        self.width = width
        self.height = height
        self.domainWidth = domainWidth
        self.domainHeight = domainHeight
        self.bedElevation = bedElevation
        self.waterDepth = waterDepth
        self.worldLimits = worldLimits
        self.boundaries = boundaries
    }

    nonisolated var bedData: Data { bedElevation.binaryData }
    nonisolated var depthData: Data { waterDepth.binaryData }
}

enum SimulationPreset: String, CaseIterable, Identifiable, Sendable {
    case flat16
    case centerBump32
    case unevenBed128
    case coastChannel512
    case drivenOceanWave512

    var id: Self { self }

    var title: String {
        switch self {
        case .flat16: "16 × 16 Flat"
        case .centerBump32: "32 × 32 Center Bump"
        case .unevenBed128: "128 × 128 Uneven Bed"
        case .coastChannel512: "512 × 512 Coast Channel"
        case .drivenOceanWave512: "512 × 512 Driven Ocean Wave"
        }
    }

    func makeSeed() -> SceneSeed {
        switch self {
        case .flat16:
            return Self.levelLake(size: 16) { _, _ in 0 }
        case .centerBump32:
            return Self.levelLake(size: 32) { x, y in
                let dx = x - 0.5
                let dy = y - 0.5
                return 0.45 * exp(-(dx * dx + dy * dy) / 0.018)
            }
        case .unevenBed128:
            return Self.levelLake(size: 128) { x, y in
                0.18 * sin(x * .pi * 4) * cos(y * .pi * 3) +
                    0.08 * sin((x + y) * .pi * 7)
            }
        case .coastChannel512:
            return Self.coastalWaveSeed(hasInitialStep: true)
        case .drivenOceanWave512:
            return Self.coastalWaveSeed(hasInitialStep: false)
        }
    }

    private static func coastalWaveSeed(hasInitialStep: Bool) -> SceneSeed {
        let size = 512
        var bedElevation = [Float](repeating: 0, count: size * size)
        var waterDepth = [Float](repeating: 0, count: size * size)
        for row in 0..<size {
            let y = (Double(row) + 0.5) / Double(size)
            for column in 0..<size {
                let x = (Double(column) + 0.5) / Double(size)
                let coastalSlope = -1.25 + 3.10 * x
                let channelCoordinate = (y - 0.52) / 0.065
                let channel = 0.95 * exp(-(channelCoordinate * channelCoordinate))
                let sandbarCoordinate = (x - 0.64) / 0.055
                let sandbar = 0.45 * exp(-(sandbarCoordinate * sandbarCoordinate)) *
                    (0.65 + 0.35 * cos(6 * .pi * y))
                let shoals = 0.12 * sin(14 * .pi * y) * (0.25 + 0.75 * x)
                let bed = coastalSlope - channel + sandbar + shoals
                precondition(bed.isFinite)
                let rightStep = hasInitialStep ? 0.55 * smoothstep(0.79, 0.81, x) : 0
                let surface = 1.20 + rightStep
                let index = row * size + column
                bedElevation[index] = Float(bed)
                waterDepth[index] = Float(max(surface - bed, 0))
            }
        }
        let boundaries: SceneBoundaryConfiguration = hasInitialStep ? .reflective :
            SceneBoundaryConfiguration(
                left: .reflective,
                right: .drivenHeight(
                    meanSurfaceElevation: 1.20,
                    amplitude: 0.25,
                    periodSeconds: 8.0,
                    phaseRadians: 0.0,
                    rampSeconds: 2.0
                ),
                bottom: .reflective,
                top: .reflective
            )
        return SceneSeed(
            width: size,
            height: size,
            domainWidth: Double(size),
            domainHeight: Double(size),
            bedElevation: bedElevation,
            waterDepth: waterDepth,
            boundaries: boundaries
        )
    }

    private static func smoothstep(_ lower: Double, _ upper: Double, _ value: Double) -> Double {
        let normalized = min(max((value - lower) / (upper - lower), 0), 1)
        return normalized * normalized * (3 - 2 * normalized)
    }

    private static func levelLake(
        size: Int,
        surfaceLevel: Double = 4,
        bed: (_ normalizedX: Double, _ normalizedY: Double) -> Double
    ) -> SceneSeed {
        let count = size * size
        var bedElevation = [Float](repeating: 0, count: count)
        var waterDepth = [Float](repeating: 0, count: count)
        for row in 0..<size {
            let y = (Double(row) + 0.5) / Double(size)
            for column in 0..<size {
                let x = (Double(column) + 0.5) / Double(size)
                let index = row * size + column
                let elevation = bed(x, y)
                bedElevation[index] = Float(elevation)
                waterDepth[index] = Float(max(surfaceLevel - elevation, 0))
            }
        }
        return SceneSeed(
            width: size,
            height: size,
            domainWidth: Double(size),
            domainHeight: Double(size),
            bedElevation: bedElevation,
            waterDepth: waterDepth
        )
    }
}

private extension Array where Element == Float {
    nonisolated var binaryData: Data {
        withUnsafeBytes { Data($0) }
    }
}
