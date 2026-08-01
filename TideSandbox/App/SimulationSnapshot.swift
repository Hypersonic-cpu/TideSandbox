import Foundation
import Metal

nonisolated final class AcceleratedFieldBuffers: @unchecked Sendable {
    let device: any MTLDevice
    let bedElevation: any MTLBuffer
    let waterDepth: any MTLBuffer
    let width: Int
    let height: Int
    let generation: UInt64

    init(_ source: WSAcceleratedFieldBuffers) {
        device = source.device
        bedElevation = source.bedElevation
        waterDepth = source.waterDepth
        width = Int(source.width)
        height = Int(source.height)
        generation = source.generation
    }
}

enum RequestedSimulationBackend: Int, CaseIterable, Identifiable, Sendable {
    case automaticAccelerated
    case metalGPU
    case cpuReference

    var id: Self { self }
    var title: String {
        switch self {
        case .automaticAccelerated: "Automatic Accelerated"
        case .metalGPU: "Metal GPU"
        case .cpuReference: "CPU Reference"
        }
    }

    nonisolated var bridgeValue: WSRequestedSimulationBackend {
        switch self {
        case .automaticAccelerated: .automaticAccelerated
        case .metalGPU: .metalGPU
        case .cpuReference: .cpuReference
        }
    }

    nonisolated init(_ source: WSRequestedSimulationBackend) {
        switch source {
        case .automaticAccelerated: self = .automaticAccelerated
        case .metalGPU: self = .metalGPU
        case .cpuReference: self = .cpuReference
        @unknown default: self = .automaticAccelerated
        }
    }
}

enum ResolvedSimulationBackend: Sendable, Equatable {
    case mpsGraphAutomatic
    case metalGPU
    case cpuReference

    var diagnosticTitle: String {
        switch self {
        case .mpsGraphAutomatic: "MPSGraph GPU"
        case .metalGPU: "Metal GPU"
        case .cpuReference: "CPU Reference"
        }
    }

    nonisolated init(_ source: WSResolvedSimulationBackend) {
        switch source {
        case .mpsGraphAutomatic: self = .mpsGraphAutomatic
        case .metalGPU: self = .metalGPU
        case .cpuReference: self = .cpuReference
        @unknown default: self = .cpuReference
        }
    }
}

struct SimulationBackendStatus: Sendable, Equatable {
    let requested: RequestedSimulationBackend
    let resolved: ResolvedSimulationBackend
    let isReady: Bool
    let resolutionReason: String
    let fallbackReason: String
    let statePrecision: String
    let graphCompileMilliseconds: Double
    let lastStableDtMilliseconds: Double
    let lastFramePhysicsMilliseconds: Double
    let lastSubstepMilliseconds: Double
    let lastReadbackMilliseconds: Double
    let substepCount: Int
    let stateSizedAllocationCount: Int

    nonisolated init(_ source: WSBackendStatus) {
        requested = RequestedSimulationBackend(source.requestedBackend)
        resolved = ResolvedSimulationBackend(source.resolvedBackend)
        isReady = source.isReady
        resolutionReason = source.resolutionReason
        fallbackReason = source.fallbackReason
        statePrecision = source.statePrecision
        graphCompileMilliseconds = source.graphCompileMilliseconds
        lastStableDtMilliseconds = source.lastStableDtMilliseconds
        lastFramePhysicsMilliseconds = source.lastFramePhysicsMilliseconds
        lastSubstepMilliseconds = source.lastSubstepMilliseconds
        lastReadbackMilliseconds = source.lastReadbackMilliseconds
        substepCount = Int(source.substepCount)
        stateSizedAllocationCount = Int(source.stateSizedAllocationCount)
    }

    nonisolated static let empty = SimulationBackendStatus(
        requested: .automaticAccelerated,
        resolved: .cpuReference,
        isReady: false,
        resolutionReason: "",
        fallbackReason: "",
        statePrecision: "",
        graphCompileMilliseconds: 0,
        lastStableDtMilliseconds: 0,
        lastFramePhysicsMilliseconds: 0,
        lastSubstepMilliseconds: 0,
        lastReadbackMilliseconds: 0,
        substepCount: 0,
        stateSizedAllocationCount: 0
    )

    private nonisolated init(
        requested: RequestedSimulationBackend,
        resolved: ResolvedSimulationBackend,
        isReady: Bool,
        resolutionReason: String,
        fallbackReason: String,
        statePrecision: String,
        graphCompileMilliseconds: Double,
        lastStableDtMilliseconds: Double,
        lastFramePhysicsMilliseconds: Double,
        lastSubstepMilliseconds: Double,
        lastReadbackMilliseconds: Double,
        substepCount: Int,
        stateSizedAllocationCount: Int
    ) {
        self.requested = requested
        self.resolved = resolved
        self.isReady = isReady
        self.resolutionReason = resolutionReason
        self.fallbackReason = fallbackReason
        self.statePrecision = statePrecision
        self.graphCompileMilliseconds = graphCompileMilliseconds
        self.lastStableDtMilliseconds = lastStableDtMilliseconds
        self.lastFramePhysicsMilliseconds = lastFramePhysicsMilliseconds
        self.lastSubstepMilliseconds = lastSubstepMilliseconds
        self.lastReadbackMilliseconds = lastReadbackMilliseconds
        self.substepCount = substepCount
        self.stateSizedAllocationCount = stateSizedAllocationCount
    }
}

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
    let instantaneousBoundaryOutflowRate: [Double]
    let cumulativeBoundaryOutwardVolume: [Double]
    let netBoundaryOutflowRate: Double
    let accountedExpectedVolume: Double
    let accountingError: Double
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
        instantaneousBoundaryOutflowRate: [Double] = [0, 0, 0, 0],
        cumulativeBoundaryOutwardVolume: [Double] = [0, 0, 0, 0],
        netBoundaryOutflowRate: Double = 0,
        accountedExpectedVolume: Double = 0,
        accountingError: Double = 0,
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
        self.instantaneousBoundaryOutflowRate = instantaneousBoundaryOutflowRate
        self.cumulativeBoundaryOutwardVolume = cumulativeBoundaryOutwardVolume
        self.netBoundaryOutflowRate = netBoundaryOutflowRate
        self.accountedExpectedVolume = accountedExpectedVolume
        self.accountingError = accountingError
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
        instantaneousBoundaryOutflowRate = source.instantaneousBoundaryOutflowRate.map(\.doubleValue)
        cumulativeBoundaryOutwardVolume = source.cumulativeBoundaryOutwardVolume.map(\.doubleValue)
        netBoundaryOutflowRate = source.netBoundaryOutflowRate
        accountedExpectedVolume = source.accountedExpectedVolume
        accountingError = source.accountingError
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
    let backendStatus: SimulationBackendStatus
    let acceleratedFieldBuffers: AcceleratedFieldBuffers?

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
        diagnostics: EngineDiagnostics,
        backendStatus: SimulationBackendStatus = .empty,
        acceleratedFieldBuffers: AcceleratedFieldBuffers? = nil
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
        self.backendStatus = backendStatus
        self.acceleratedFieldBuffers = acceleratedFieldBuffers
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
        backendStatus = SimulationBackendStatus(source.backendStatus)
        acceleratedFieldBuffers = source.acceleratedFieldBuffers.map(AcceleratedFieldBuffers.init)
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
            diagnostics: diagnostics,
            backendStatus: backendStatus,
            acceleratedFieldBuffers: acceleratedFieldBuffers
        )
    }

    func values(for mode: DisplayMode) -> [Float] {
        switch mode {
        case .decorativeComposite: waterDepth
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
