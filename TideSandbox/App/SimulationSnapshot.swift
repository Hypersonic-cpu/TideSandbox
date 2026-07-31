import Foundation

struct EngineDiagnostics: Sendable, Equatable {
    let totalVolume: Double
    let minimumDepth: Double
    let maximumDepth: Double
    let maximumAbsVelocityX: Double
    let maximumAbsVelocityY: Double
    let maximumWaveSpeed: Double
    let selectedTimeStep: Double
    let simulatedTime: Double
    let correctionVolume: Double
    let substepCount: Int
    let wetCellCount: Int
    let correctionCount: Int
    let isFinite: Bool
    let status: WSEngineStepStatus

    nonisolated init(
        totalVolume: Double,
        minimumDepth: Double,
        maximumDepth: Double,
        maximumAbsVelocityX: Double,
        maximumAbsVelocityY: Double,
        maximumWaveSpeed: Double,
        selectedTimeStep: Double,
        simulatedTime: Double,
        correctionVolume: Double,
        substepCount: Int,
        wetCellCount: Int,
        correctionCount: Int,
        isFinite: Bool,
        status: WSEngineStepStatus
    ) {
        self.totalVolume = totalVolume
        self.minimumDepth = minimumDepth
        self.maximumDepth = maximumDepth
        self.maximumAbsVelocityX = maximumAbsVelocityX
        self.maximumAbsVelocityY = maximumAbsVelocityY
        self.maximumWaveSpeed = maximumWaveSpeed
        self.selectedTimeStep = selectedTimeStep
        self.simulatedTime = simulatedTime
        self.correctionVolume = correctionVolume
        self.substepCount = substepCount
        self.wetCellCount = wetCellCount
        self.correctionCount = correctionCount
        self.isFinite = isFinite
        self.status = status
    }

    nonisolated init(_ source: WSEngineDiagnostics) {
        totalVolume = source.totalVolume
        minimumDepth = source.minimumDepth
        maximumDepth = source.maximumDepth
        maximumAbsVelocityX = source.maximumAbsVelocityX
        maximumAbsVelocityY = source.maximumAbsVelocityY
        maximumWaveSpeed = source.maximumWaveSpeed
        selectedTimeStep = source.selectedTimeStep
        simulatedTime = source.simulatedTime
        correctionVolume = source.correctionVolume
        substepCount = Int(source.substepCount)
        wetCellCount = Int(source.wetCellCount)
        correctionCount = Int(source.correctionCount)
        isFinite = source.isFinite
        status = source.status
    }

    static let empty = EngineDiagnostics(
        totalVolume: 0,
        minimumDepth: 0,
        maximumDepth: 0,
        maximumAbsVelocityX: 0,
        maximumAbsVelocityY: 0,
        maximumWaveSpeed: 0,
        selectedTimeStep: 0,
        simulatedTime: 0,
        correctionVolume: 0,
        substepCount: 0,
        wetCellCount: 0,
        correctionCount: 0,
        isFinite: true,
        status: .success
    )
}

struct SimulationSnapshot: Sendable {
    let generation: UInt64
    let width: Int
    let height: Int
    let domainWidth: Double
    let domainHeight: Double
    let bedElevation: [Float]
    let waterDepth: [Float]
    let surfaceElevation: [Float]
    let surfaceDeviation: [Float]
    let velocityMagnitude: [Float]
    let wetMask: [UInt8]
    let diagnostics: EngineDiagnostics

    nonisolated init(
        generation: UInt64 = 0,
        width: Int,
        height: Int,
        domainWidth: Double,
        domainHeight: Double,
        bedElevation: [Float],
        waterDepth: [Float],
        surfaceElevation: [Float],
        surfaceDeviation: [Float],
        velocityMagnitude: [Float],
        wetMask: [UInt8],
        diagnostics: EngineDiagnostics
    ) {
        self.generation = generation
        self.width = width
        self.height = height
        self.domainWidth = domainWidth
        self.domainHeight = domainHeight
        self.bedElevation = bedElevation
        self.waterDepth = waterDepth
        self.surfaceElevation = surfaceElevation
        self.surfaceDeviation = surfaceDeviation
        self.velocityMagnitude = velocityMagnitude
        self.wetMask = wetMask
        self.diagnostics = diagnostics
    }

    nonisolated init(_ source: WSEngineSnapshot) {
        generation = 0
        width = Int(source.width)
        height = Int(source.height)
        domainWidth = source.domainWidth
        domainHeight = source.domainHeight
        let count = width * height
        bedElevation = source.bedElevation.floatArray(count: count)
        waterDepth = source.waterDepth.floatArray(count: count)
        surfaceElevation = source.surfaceElevation.floatArray(count: count)
        surfaceDeviation = source.surfaceDeviation.floatArray(count: count)
        velocityMagnitude = source.velocityMagnitude.floatArray(count: count)
        wetMask = Array(source.wetMask.prefix(count))
        diagnostics = EngineDiagnostics(source.diagnostics)
    }

    static let empty = SimulationSnapshot(
        width: 0,
        height: 0,
        domainWidth: 0,
        domainHeight: 0,
        bedElevation: [],
        waterDepth: [],
        surfaceElevation: [],
        surfaceDeviation: [],
        velocityMagnitude: [],
        wetMask: [],
        diagnostics: .empty
    )

    nonisolated func withGeneration(_ generation: UInt64) -> SimulationSnapshot {
        SimulationSnapshot(
            generation: generation,
            width: width,
            height: height,
            domainWidth: domainWidth,
            domainHeight: domainHeight,
            bedElevation: bedElevation,
            waterDepth: waterDepth,
            surfaceElevation: surfaceElevation,
            surfaceDeviation: surfaceDeviation,
            velocityMagnitude: velocityMagnitude,
            wetMask: wetMask,
            diagnostics: diagnostics
        )
    }

    func values(for mode: DisplayMode) -> [Float] {
        switch mode {
        case .bedElevation: bedElevation
        case .waterDepth: waterDepth
        case .surfaceElevation: surfaceElevation
        case .surfaceDeviation: surfaceDeviation
        case .velocityMagnitude: velocityMagnitude
        case .wetDry: wetMask.map(Float.init)
        }
    }
}

private extension Data {
    nonisolated func floatArray(count: Int) -> [Float] {
        guard self.count == count * MemoryLayout<Float>.size else { return [] }
        var result = [Float](repeating: 0, count: count)
        _ = result.withUnsafeMutableBytes { destination in
            copyBytes(to: destination)
        }
        return result
    }
}
