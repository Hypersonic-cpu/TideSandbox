import Foundation

struct SceneSeed: Sendable {
    let width: Int
    let height: Int
    let domainWidth: Double
    let domainHeight: Double
    let bedElevation: [Float]
    let waterDepth: [Float]
    let worldLimits: SceneWorldLimits

    init(
        width: Int,
        height: Int,
        domainWidth: Double,
        domainHeight: Double,
        bedElevation: [Float],
        waterDepth: [Float],
        worldLimits: SceneWorldLimits = .defaults
    ) {
        self.width = width
        self.height = height
        self.domainWidth = domainWidth
        self.domainHeight = domainHeight
        self.bedElevation = bedElevation
        self.waterDepth = waterDepth
        self.worldLimits = worldLimits
    }

    nonisolated var bedData: Data { bedElevation.binaryData }
    nonisolated var depthData: Data { waterDepth.binaryData }
}

enum SimulationPreset: String, CaseIterable, Identifiable, Sendable {
    case flat16
    case centerBump32
    case unevenBed128
    case coastChannel512

    var id: Self { self }

    var title: String {
        switch self {
        case .flat16: "16 × 16 Flat"
        case .centerBump32: "32 × 32 Center Bump"
        case .unevenBed128: "128 × 128 Uneven Bed"
        case .coastChannel512: "512 × 512 Coast Channel"
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
            return Self.levelLake(size: 512, surfaceLevel: 2.0) { x, y in
                let coast = -0.25 + 0.9 * x
                let channelDistance = (y - 0.52) / 0.075
                let channel = 0.55 * exp(-(channelDistance * channelDistance))
                let shoals = 0.05 * sin(y * .pi * 14) * (1 - x)
                return coast - channel + shoals
            }
        }
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
