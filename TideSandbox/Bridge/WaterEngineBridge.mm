#import "WaterEngineBridge.hh"

#include "../Accelerated/CpuBackend.hh"
#include "../Accelerated/MPSGraphAutomaticBackend.hh"
#include "../Accelerated/MetalGPUBackend.hh"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <limits>
#include <memory>
#include <span>
#include <string>
#include <type_traits>
#include <variant>
#include <vector>

using namespace tide::swe;
using namespace tide::accelerated;

namespace {

using BackendStorage = std::variant<CpuBackend, MPSGraphAutomaticBackend, MetalGPUBackend>;

struct BridgeImplementation final {
    SolverConfiguration configuration;
    BackendStorage backend;
    RequestedSimulationBackend requestedBackend =
        RequestedSimulationBackend::automaticAccelerated;
    WSBackendFailureInjection failureInjection = WSBackendFailureInjectionNone;
    std::string resolutionReason;
    std::string fallbackReason;
    bool requestedBackendFailed = false;
    bool running = false;
};

[[nodiscard]] BridgeImplementation& implementation(void *pointer) noexcept {
    return *static_cast<BridgeImplementation *>(pointer);
}

[[nodiscard]] WSEngineStepStatus bridgeStatus(const StepStatus status) noexcept {
    switch (status) {
    case StepStatus::success: return WSEngineStepStatusSuccess;
    case StepStatus::invalidConfiguration: return WSEngineStepStatusInvalidConfiguration;
    case StepStatus::invalidTimeStep: return WSEngineStepStatusInvalidTimeStep;
    case StepStatus::nonFiniteState: return WSEngineStepStatusNonFiniteState;
    case StepStatus::velocityBoundExceeded: return WSEngineStepStatusVelocityBoundExceeded;
    case StepStatus::substepLimitReached: return WSEngineStepStatusSubstepLimitReached;
    }
}

[[nodiscard]] BrushFalloff engineFalloff(const WSBrushFalloff falloff) noexcept {
    switch (falloff) {
    case WSBrushFalloffConstant: return BrushFalloff::constant;
    case WSBrushFalloffLinear: return BrushFalloff::linear;
    case WSBrushFalloffSmooth: return BrushFalloff::smooth;
    }
}

[[nodiscard]] EditTarget engineTarget(const WSEditTarget target) noexcept {
    return target == WSEditTargetPausedCurrentState
        ? EditTarget::pausedCurrentState : EditTarget::initialState;
}

[[nodiscard]] MaterialOperation engineOperation(const WSMaterialOperation operation) noexcept {
    switch (operation) {
    case WSMaterialOperationAddSand: return MaterialOperation::addSand;
    case WSMaterialOperationRemoveSand: return MaterialOperation::removeSand;
    case WSMaterialOperationAddWater: return MaterialOperation::addWater;
    case WSMaterialOperationRemoveWater: return MaterialOperation::removeWater;
    }
}

[[nodiscard]] BoundaryType engineBoundaryType(const WSBoundaryType type) noexcept {
    switch (type) {
    case WSBoundaryTypeReflective: return BoundaryType::reflective;
    case WSBoundaryTypeFreeOpen: return BoundaryType::freeOpen;
    case WSBoundaryTypeDrivenHeight: return BoundaryType::drivenHeight;
    }
    return BoundaryType::reflective;
}

[[nodiscard]] WSBoundaryType bridgeBoundaryType(const BoundaryType type) noexcept {
    switch (type) {
    case BoundaryType::reflective: return WSBoundaryTypeReflective;
    case BoundaryType::freeOpen: return WSBoundaryTypeFreeOpen;
    case BoundaryType::drivenHeight: return WSBoundaryTypeDrivenHeight;
    }
    return WSBoundaryTypeReflective;
}

[[nodiscard]] RequestedSimulationBackend engineRequestedBackend(
    const WSRequestedSimulationBackend backend) noexcept {
    switch (backend) {
    case WSRequestedSimulationBackendAutomaticAccelerated:
        return RequestedSimulationBackend::automaticAccelerated;
    case WSRequestedSimulationBackendMetalGPU:
        return RequestedSimulationBackend::metalGPU;
    case WSRequestedSimulationBackendCPUReference:
        return RequestedSimulationBackend::cpuReference;
    }
}

[[nodiscard]] WSRequestedSimulationBackend bridgeRequestedBackend(
    const RequestedSimulationBackend backend) noexcept {
    switch (backend) {
    case RequestedSimulationBackend::automaticAccelerated:
        return WSRequestedSimulationBackendAutomaticAccelerated;
    case RequestedSimulationBackend::metalGPU:
        return WSRequestedSimulationBackendMetalGPU;
    case RequestedSimulationBackend::cpuReference:
        return WSRequestedSimulationBackendCPUReference;
    }
}

[[nodiscard]] WSResolvedSimulationBackend bridgeResolvedBackend(
    const ResolvedSimulationBackend backend) noexcept {
    switch (backend) {
    case ResolvedSimulationBackend::mpsGraphAutomatic:
        return WSResolvedSimulationBackendMPSGraphAutomatic;
    case ResolvedSimulationBackend::metalGPU:
        return WSResolvedSimulationBackendMetalGPU;
    case ResolvedSimulationBackend::cpuReference:
        return WSResolvedSimulationBackendCPUReference;
    }
}

struct FreeDeleter final {
    void operator()(void *pointer) const noexcept { std::free(pointer); }
};

template <typename Value>
class OwnedSnapshotBuffer final {
public:
    explicit OwnedSnapshotBuffer(const std::size_t count)
        : bytes_(static_cast<Value *>(std::malloc(count * sizeof(Value)))), count_(count) {
        if (bytes_ == nullptr && count_ != 0) {
            std::abort();
        }
    }

    OwnedSnapshotBuffer(const OwnedSnapshotBuffer&) = delete;
    OwnedSnapshotBuffer& operator=(const OwnedSnapshotBuffer&) = delete;

    [[nodiscard]] std::span<Value> values() noexcept { return {bytes_.get(), count_}; }

    [[nodiscard]] NSData *consumeAsData() noexcept {
        void * const storage = bytes_.release();
        return [NSData dataWithBytesNoCopy:storage
                                    length:count_ * sizeof(Value)
                              freeWhenDone:YES];
    }

private:
    std::unique_ptr<Value, FreeDeleter> bytes_;
    const std::size_t count_;
};

[[nodiscard]] std::vector<double> doubleValues(NSData *data, const std::size_t count) {
    if (data.length != count * sizeof(float)) {
        return {};
    }
    const auto values = std::span(static_cast<const float *>(data.bytes), count);
    std::vector<double> result(count);
    std::transform(values.begin(), values.end(), result.begin(),
                   [](const float value) { return static_cast<double>(value); });
    return result;
}

[[nodiscard]] bool validDimensions(const std::size_t width,
                                   const std::size_t height) noexcept {
    const std::size_t maximum = std::numeric_limits<std::size_t>::max();
    return width >= 8 && height >= 8 && width != maximum && height != maximum &&
        width <= maximum / height && width + 1 <= maximum / height &&
        height + 1 <= maximum / width;
}

} // namespace

@interface WSBackendStatus ()

@property(nonatomic, readwrite) WSRequestedSimulationBackend requestedBackend;
@property(nonatomic, readwrite) WSResolvedSimulationBackend resolvedBackend;
@property(nonatomic, readwrite, getter=isReady) BOOL ready;
@property(nonatomic, readwrite) NSString *resolutionReason;
@property(nonatomic, readwrite) NSString *fallbackReason;
@property(nonatomic, readwrite) NSString *statePrecision;
@property(nonatomic, readwrite) double graphCompileMilliseconds;
@property(nonatomic, readwrite) double lastStableDtMilliseconds;
@property(nonatomic, readwrite) double lastFramePhysicsMilliseconds;
@property(nonatomic, readwrite) double lastSubstepMilliseconds;
@property(nonatomic, readwrite) double lastReadbackMilliseconds;
@property(nonatomic, readwrite) NSUInteger substepCount;
@property(nonatomic, readwrite) NSUInteger stateSizedAllocationCount;

@end

@implementation WSBackendStatus
@end

@interface WSAcceleratedFieldBuffers ()

@property(nonatomic, readwrite) id<MTLDevice> device;
@property(nonatomic, readwrite) id<MTLBuffer> bedElevation;
@property(nonatomic, readwrite) id<MTLBuffer> waterDepth;
@property(nonatomic, readwrite) NSUInteger width;
@property(nonatomic, readwrite) NSUInteger height;
@property(nonatomic, readwrite) uint64_t generation;

@end

@implementation WSAcceleratedFieldBuffers
@end

@interface WSBoundarySideConfiguration ()

@property(nonatomic, readwrite) WSBoundaryType type;
@property(nonatomic, readwrite) double meanSurfaceElevation;
@property(nonatomic, readwrite) double amplitude;
@property(nonatomic, readwrite) double periodSeconds;
@property(nonatomic, readwrite) double phaseRadians;
@property(nonatomic, readwrite) double rampSeconds;

@end

@implementation WSBoundarySideConfiguration

- (instancetype)initWithType:(WSBoundaryType)type
         meanSurfaceElevation:(double)meanSurfaceElevation
                    amplitude:(double)amplitude
                periodSeconds:(double)periodSeconds
                 phaseRadians:(double)phaseRadians
                  rampSeconds:(double)rampSeconds {
    self = [super init];
    if (self != nil) {
        _type = type;
        _meanSurfaceElevation = meanSurfaceElevation;
        _amplitude = amplitude;
        _periodSeconds = periodSeconds;
        _phaseRadians = phaseRadians;
        _rampSeconds = rampSeconds;
    }
    return self;
}

@end


@interface WSBoundaryConfiguration ()

@property(nonatomic, readwrite) WSBoundarySideConfiguration *left;
@property(nonatomic, readwrite) WSBoundarySideConfiguration *right;
@property(nonatomic, readwrite) WSBoundarySideConfiguration *bottom;
@property(nonatomic, readwrite) WSBoundarySideConfiguration *top;

@end


@implementation WSBoundaryConfiguration

- (instancetype)initWithLeft:(WSBoundarySideConfiguration *)left
                        right:(WSBoundarySideConfiguration *)right
                       bottom:(WSBoundarySideConfiguration *)bottom
                          top:(WSBoundarySideConfiguration *)top {
    self = [super init];
    if (self != nil) {
        _left = left;
        _right = right;
        _bottom = bottom;
        _top = top;
    }
    return self;
}

@end


namespace {

[[nodiscard]] BoundarySide engineBoundarySide(WSBoundarySideConfiguration *source) noexcept {
    return {
        .type = engineBoundaryType(source.type),
        .driven = {
            .meanSurfaceElevation = source.meanSurfaceElevation,
            .amplitude = source.amplitude,
            .periodSeconds = source.periodSeconds,
            .phaseRadians = source.phaseRadians,
            .rampSeconds = source.rampSeconds,
        },
    };
}

[[nodiscard]] BoundaryConfiguration engineBoundaryConfiguration(
    WSBoundaryConfiguration *source) noexcept {
    return {
        .left = engineBoundarySide(source.left),
        .right = engineBoundarySide(source.right),
        .bottom = engineBoundarySide(source.bottom),
        .top = engineBoundarySide(source.top),
    };
}

[[nodiscard]] WSBoundarySideConfiguration *bridgeBoundarySide(const BoundarySide& source) {
    return [[WSBoundarySideConfiguration alloc]
        initWithType:bridgeBoundaryType(source.type)
        meanSurfaceElevation:source.driven.meanSurfaceElevation
        amplitude:source.driven.amplitude
        periodSeconds:source.driven.periodSeconds
        phaseRadians:source.driven.phaseRadians
        rampSeconds:source.driven.rampSeconds];
}

[[nodiscard]] WSBoundaryConfiguration *bridgeBoundaryConfiguration(
    const BoundaryConfiguration& source) {
    return [[WSBoundaryConfiguration alloc]
        initWithLeft:bridgeBoundarySide(source.left)
        right:bridgeBoundarySide(source.right)
        bottom:bridgeBoundarySide(source.bottom)
        top:bridgeBoundarySide(source.top)];
}

[[nodiscard]] NSArray<NSNumber *> *bridgeBoundaryValues(const BoundaryValues& source) {
    return @[@(source[0]), @(source[1]), @(source[2]), @(source[3])];
}

[[nodiscard]] const BackendStatus& currentBackendStatus(
    const BridgeImplementation& implementation) noexcept {
    return std::visit([](const auto& backend) -> const BackendStatus& {
        return backend.status();
    }, implementation.backend);
}

[[nodiscard]] BackendState currentBackendState(BridgeImplementation& implementation,
                                               std::string& failureReason) {
    return std::visit([&failureReason](auto& backend) {
        return backend.synchronizeToHost(failureReason);
    }, implementation.backend);
}

[[nodiscard]] std::size_t currentAllocationCount(
    const BridgeImplementation& implementation) noexcept {
    return std::visit([](const auto& backend) -> std::size_t {
        using Backend = std::decay_t<decltype(backend)>;
        if constexpr (std::is_same_v<Backend, MetalGPUBackend> ||
                      std::is_same_v<Backend, MPSGraphAutomaticBackend>) {
            return backend.stateSizedAllocationCount();
        }
        return 0;
    }, implementation.backend);
}

[[nodiscard]] WSAcceleratedFieldBuffers *currentFieldBuffers(
    const BridgeImplementation& implementation) {
    const AcceleratedFieldBufferSnapshot source = std::visit([](const auto& backend) {
        using Backend = std::decay_t<decltype(backend)>;
        if constexpr (std::is_same_v<Backend, MetalGPUBackend> ||
                      std::is_same_v<Backend, MPSGraphAutomaticBackend>) {
            return backend.fieldBufferSnapshot();
        }
        return AcceleratedFieldBufferSnapshot{};
    }, implementation.backend);
    if (source.device == nullptr || source.bedElevation == nullptr ||
        source.waterDepth == nullptr) {
        return nil;
    }
    WSAcceleratedFieldBuffers *result = [[WSAcceleratedFieldBuffers alloc] init];
    result.device = (__bridge id<MTLDevice>)source.device;
    result.bedElevation = (__bridge id<MTLBuffer>)source.bedElevation;
    result.waterDepth = (__bridge id<MTLBuffer>)source.waterDepth;
    result.width = source.width;
    result.height = source.height;
    result.generation = source.generation;
    return result;
}

[[nodiscard]] std::size_t estimatedSubstepWork(const BackendState& state) noexcept {
    const std::size_t cells = state.geometry.width * state.geometry.height;
    const std::size_t faces = (state.geometry.width + 1) * state.geometry.height +
                              state.geometry.width * (state.geometry.height + 1);
    return 8 * cells + 6 * faces;
}

enum class PreferredAccelerator : std::uint8_t {
    mpsGraphAutomatic,
    metalGPU,
};

struct AutomaticBackendPolicy final {
    std::size_t acceleratedWorkThreshold;
    PreferredAccelerator preferredAccelerator;
    const char *deviceFamily;
};

[[nodiscard]] AutomaticBackendPolicy automaticBackendPolicy() noexcept {
    id<MTLDevice> const device = MTLCreateSystemDefaultDevice();
    if (device != nil && [device supportsFamily:MTLGPUFamilyApple9]) {
        // The archived M4 Release sweep brackets break-even between 128² (329,216 work)
        // and 256² (1,313,792 work). The conservative rounded interpolation is 1,000,000.
        // Metal was faster than MPSGraph at every accelerated sample on this family.
        return {1'000'000, PreferredAccelerator::metalGPU, "Apple9"};
    }
    // Unknown families use the first sampled accelerated workload as a conservative gate and
    // retain the capability-first MPSGraph order until family-specific measurements exist.
    return {1'313'792, PreferredAccelerator::mpsGraphAutomatic, "generic"};
}

[[nodiscard]] bool loadCPU(BridgeImplementation& implementation,
                           const BackendState& state,
                           std::string& failureReason) {
    implementation.backend.emplace<CpuBackend>();
    return std::get<CpuBackend>(implementation.backend).load(
        state, implementation.configuration, failureReason);
}

[[nodiscard]] bool loadMetal(BridgeImplementation& implementation,
                             const BackendState& state,
                             std::string& failureReason) {
    if (implementation.failureInjection == WSBackendFailureInjectionMetalPreparation ||
        implementation.failureInjection == WSBackendFailureInjectionAllAcceleratedPreparation) {
        failureReason = "Injected Metal preparation failure";
        return false;
    }
    implementation.backend.emplace<MetalGPUBackend>();
    return std::get<MetalGPUBackend>(implementation.backend).load(
        state, implementation.configuration, failureReason);
}

[[nodiscard]] bool loadMPSGraph(BridgeImplementation& implementation,
                                const BackendState& state,
                                std::string& failureReason) {
    if (implementation.failureInjection == WSBackendFailureInjectionMPSGraphPreparation ||
        implementation.failureInjection == WSBackendFailureInjectionAllAcceleratedPreparation) {
        failureReason = "Injected MPSGraph preparation failure";
        return false;
    }
    implementation.backend.emplace<MPSGraphAutomaticBackend>();
    return std::get<MPSGraphAutomaticBackend>(implementation.backend).load(
        state, implementation.configuration, failureReason);
}

[[nodiscard]] bool resolveBackend(BridgeImplementation& implementation,
                                  const BackendState& state) {
    implementation.running = false;
    implementation.resolutionReason.clear();
    implementation.fallbackReason.clear();
    implementation.requestedBackendFailed = false;
    std::string failureReason;
    if (implementation.requestedBackend == RequestedSimulationBackend::cpuReference) {
        const bool result = loadCPU(implementation, state, failureReason);
        implementation.resolutionReason = result
            ? "CPU Reference was selected explicitly."
            : "CPU Reference could not be prepared.";
        implementation.fallbackReason = result ? std::string{} : failureReason;
        return result;
    }
    if (implementation.requestedBackend == RequestedSimulationBackend::metalGPU) {
        if (loadMetal(implementation, state, failureReason)) {
            implementation.resolutionReason = "Metal GPU was selected explicitly.";
            return true;
        }
        implementation.resolutionReason =
            "Forced Metal GPU preparation failed; a CPU copy is retained only for recovery.";
        implementation.fallbackReason = failureReason;
        implementation.requestedBackendFailed = true;
        std::string recoveryReason;
        (void)loadCPU(implementation, state, recoveryReason);
        return false;
    }

    const AutomaticBackendPolicy policy = automaticBackendPolicy();
    const std::size_t estimatedWork = estimatedSubstepWork(state);
    if (estimatedWork < policy.acceleratedWorkThreshold) {
        implementation.resolutionReason = "Estimated work " + std::to_string(estimatedWork) +
            " is below the measured " + policy.deviceFamily +
            " acceleration threshold " +
            std::to_string(policy.acceleratedWorkThreshold) + ".";
        return loadCPU(implementation, state, failureReason);
    }

    // MPSGraph-preparation injection deliberately exercises its compile-failure fallback even on
    // a family whose measured production preference is Metal.
    const bool preferMetal =
        policy.preferredAccelerator == PreferredAccelerator::metalGPU &&
        implementation.failureInjection != WSBackendFailureInjectionMPSGraphPreparation;
    std::string mpsReason;
    std::string metalReason;
    if (preferMetal) {
        if (loadMetal(implementation, state, metalReason)) {
            implementation.resolutionReason = "Estimated work " +
                std::to_string(estimatedWork) + " meets the measured " +
                policy.deviceFamily +
                " threshold; Metal GPU is the fastest validated backend.";
            return true;
        }
        if (loadMPSGraph(implementation, state, mpsReason)) {
            implementation.resolutionReason =
                "Preferred Metal GPU was unavailable; Apple Automatic is ready.";
            implementation.fallbackReason = "Metal: " + metalReason;
            return true;
        }
    } else {
        if (loadMPSGraph(implementation, state, mpsReason)) {
            implementation.resolutionReason = "Estimated work " +
                std::to_string(estimatedWork) + " meets the " + policy.deviceFamily +
                " acceleration threshold; Apple Automatic is ready.";
            return true;
        }
        if (loadMetal(implementation, state, metalReason)) {
            implementation.resolutionReason =
                "Apple Automatic was unavailable; Metal GPU is the accelerated fallback.";
            implementation.fallbackReason = "MPSGraph: " + mpsReason;
            return true;
        }
    }
    implementation.fallbackReason = "MPSGraph: " + mpsReason + "; Metal: " + metalReason;
    implementation.resolutionReason =
        "Both accelerated backends were unavailable; CPU Reference is the safe fallback.";
    std::string cpuReason;
    return loadCPU(implementation, state, cpuReason);
}

[[nodiscard]] TerrainEditResult applyCPUBrush(BridgeImplementation& implementation,
                                              const BrushCommand& command) {
    implementation.running = false;
    std::string failureReason;
    const TerrainEditResult result = std::visit([&](auto& backend) {
        using Backend = std::decay_t<decltype(backend)>;
        if constexpr (std::is_same_v<Backend, CpuBackend>) {
            return backend.applyMaterialBrush(command);
        } else {
            return backend.applyMaterialBrush(command, failureReason);
        }
    }, implementation.backend);
    implementation.fallbackReason = failureReason;
    return result;
}

[[nodiscard]] TerrainEditResult applyCPUPolygon(BridgeImplementation& implementation,
                                                const PolygonCommand& command) {
    implementation.running = false;
    std::string failureReason;
    const TerrainEditResult result = std::visit([&](auto& backend) {
        using Backend = std::decay_t<decltype(backend)>;
        if constexpr (std::is_same_v<Backend, CpuBackend>) {
            return backend.applyMaterialPolygon(command);
        } else {
            return backend.applyMaterialPolygon(command, failureReason);
        }
    }, implementation.backend);
    implementation.fallbackReason = failureReason;
    return result;
}

} // namespace

@interface WSTerrainEditResult ()

@property(nonatomic, readwrite) BOOL succeeded;
@property(nonatomic, readwrite, getter=isChanged) BOOL changed;
@property(nonatomic, readwrite) NSUInteger changedCells;
@property(nonatomic, readwrite) NSUInteger changedFaces;
@property(nonatomic, readwrite) double sandVolumeDelta;
@property(nonatomic, readwrite) double waterVolumeDelta;
@property(nonatomic, readwrite, getter=isClamped) BOOL clamped;
@property(nonatomic, readwrite) NSUInteger newlyWetCells;
@property(nonatomic, readwrite) NSUInteger newlyDryCells;

@end

@implementation WSTerrainEditResult
@end

namespace {

[[nodiscard]] WSTerrainEditResult *bridgeEditResult(const TerrainEditResult& source) {
    WSTerrainEditResult *result = [[WSTerrainEditResult alloc] init];
    result.succeeded = source.status == TerrainEditStatus::success;
    result.changed = source.changed();
    result.changedCells = source.changedCells;
    result.changedFaces = source.changedFaces;
    result.sandVolumeDelta = source.sandVolumeDelta;
    result.waterVolumeDelta = source.waterVolumeDelta;
    result.clamped = source.clamped;
    result.newlyWetCells = source.newlyWetCells;
    result.newlyDryCells = source.newlyDryCells;
    return result;
}

} // namespace

@interface WSEngineDiagnostics ()

@property(nonatomic, readwrite) double totalVolume;
@property(nonatomic, readwrite) double minimumDepth;
@property(nonatomic, readwrite) double maximumDepth;
@property(nonatomic, readwrite) double maximumAbsVelocityX;
@property(nonatomic, readwrite) double maximumAbsVelocityY;
@property(nonatomic, readwrite) double maximumWaveSpeed;
@property(nonatomic, readwrite) double selectedTimeStep;
@property(nonatomic, readwrite) double simulatedTime;
@property(nonatomic, readwrite) double correctionVolume;
@property(nonatomic, readwrite) NSUInteger substepCount;
@property(nonatomic, readwrite) NSUInteger wetCellCount;
@property(nonatomic, readwrite) NSUInteger correctionCount;
@property(nonatomic, readwrite) NSArray<NSNumber *> *instantaneousBoundaryOutflowRate;
@property(nonatomic, readwrite) NSArray<NSNumber *> *cumulativeBoundaryOutwardVolume;
@property(nonatomic, readwrite) double netBoundaryOutflowRate;
@property(nonatomic, readwrite) double accountedExpectedVolume;
@property(nonatomic, readwrite) double accountingError;
@property(nonatomic, readwrite, getter=isFinite) BOOL finite;
@property(nonatomic, readwrite) WSEngineStepStatus status;

@end

@implementation WSEngineDiagnostics
@end

@interface WSEngineSnapshot ()

@property(nonatomic, readwrite) NSUInteger width;
@property(nonatomic, readwrite) NSUInteger height;
@property(nonatomic, readwrite) double domainWidth;
@property(nonatomic, readwrite) double domainHeight;
@property(nonatomic, readwrite) NSData *bedElevation;
@property(nonatomic, readwrite) NSData *waterDepth;
@property(nonatomic, readwrite) NSData *surfaceElevation;
@property(nonatomic, readwrite) NSData *surfaceDeviation;
@property(nonatomic, readwrite) NSData *velocityMagnitude;
@property(nonatomic, readwrite) NSData *wetMask;
@property(nonatomic, readwrite) WSEngineDiagnostics *diagnostics;
@property(nonatomic, readwrite) WSBackendStatus *backendStatus;
@property(nonatomic, readwrite, nullable) WSAcceleratedFieldBuffers *acceleratedFieldBuffers;

@end

@implementation WSEngineSnapshot
@end

@implementation WSWaterEngineBridge

- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  domainWidth:(double)domainWidth
                 domainHeight:(double)domainHeight {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    if (!validDimensions(width, height)) {
        return nil;
    }
    _implementation = new BridgeImplementation();
    const std::vector<float> bed(width * height, 0.0F);
    const std::vector<float> depth(width * height, 1.0F);
    NSData * const bedData = [NSData dataWithBytes:bed.data() length:bed.size() * sizeof(float)];
    NSData * const depthData = [NSData dataWithBytes:depth.data() length:depth.size() * sizeof(float)];
    if (![self loadWidth:width height:height domainWidth:domainWidth domainHeight:domainHeight
             bedElevation:bedData waterDepth:depthData]) {
        delete static_cast<BridgeImplementation *>(_implementation);
        _implementation = nullptr;
        return nil;
    }
    return self;
}

- (void)dealloc {
    delete static_cast<BridgeImplementation *>(_implementation);
}

- (BOOL)isRunning {
    return implementation(_implementation).running;
}

- (void)setRunning:(BOOL)running {
    implementation(_implementation).running = running;
}

- (WSRequestedSimulationBackend)requestedBackend {
    return bridgeRequestedBackend(implementation(_implementation).requestedBackend);
}

- (WSResolvedSimulationBackend)resolvedBackend {
    return bridgeResolvedBackend(currentBackendStatus(
        implementation(_implementation)).resolved);
}

- (WSBackendStatus *)backendStatus {
    const auto& impl = implementation(_implementation);
    const BackendStatus& source = currentBackendStatus(impl);
    WSBackendStatus *result = [[WSBackendStatus alloc] init];
    result.requestedBackend = bridgeRequestedBackend(impl.requestedBackend);
    result.resolvedBackend = bridgeResolvedBackend(source.resolved);
    result.ready = source.ready && !impl.requestedBackendFailed;
    result.resolutionReason = [NSString stringWithUTF8String:
        (impl.resolutionReason.empty() ? source.resolutionReason :
                                        impl.resolutionReason).c_str()];
    result.fallbackReason = [NSString stringWithUTF8String:
        (impl.fallbackReason.empty() ? source.fallbackReason : impl.fallbackReason).c_str()];
    result.statePrecision = [NSString stringWithUTF8String:source.statePrecision.c_str()];
    result.graphCompileMilliseconds = source.graphCompileMilliseconds;
    result.lastStableDtMilliseconds = source.lastStableDtMilliseconds;
    result.lastFramePhysicsMilliseconds = source.lastFramePhysicsMilliseconds;
    result.lastSubstepMilliseconds = source.lastSubstepMilliseconds;
    result.lastReadbackMilliseconds = source.lastReadbackMilliseconds;
    result.substepCount = source.substepCount;
    result.stateSizedAllocationCount = currentAllocationCount(impl);
    return result;
}

- (WSAcceleratedFieldBuffers *)acceleratedFieldBuffers {
    return currentFieldBuffers(implementation(_implementation));
}

- (BOOL)setRequestedBackend:(WSRequestedSimulationBackend)backend {
    auto& impl = implementation(_implementation);
    impl.running = false;
    std::string failureReason;
    const BackendState state = currentBackendState(impl, failureReason);
    if (!state.isValid()) {
        impl.fallbackReason = failureReason;
        return NO;
    }
    impl.requestedBackend = engineRequestedBackend(backend);
    return resolveBackend(impl, state);
}

- (void)setBackendFailureInjection:(WSBackendFailureInjection)failure {
    implementation(_implementation).failureInjection = failure;
}

- (BOOL)loadWidth:(NSUInteger)width
            height:(NSUInteger)height
       domainWidth:(double)domainWidth
      domainHeight:(double)domainHeight
      bedElevation:(NSData *)bedElevation
         waterDepth:(NSData *)waterDepth {
    return [self loadWidth:width height:height domainWidth:domainWidth domainHeight:domainHeight
              bedElevation:bedElevation waterDepth:waterDepth minimumBed:-1'000.0
            maximumSurface:1'000.0];
}

- (BOOL)loadWidth:(NSUInteger)width
            height:(NSUInteger)height
       domainWidth:(double)domainWidth
      domainHeight:(double)domainHeight
      bedElevation:(NSData *)bedElevation
         waterDepth:(NSData *)waterDepth
         minimumBed:(double)minimumBed
     maximumSurface:(double)maximumSurface {
    const BoundaryConfiguration reflective;
    return [self loadWidth:width height:height domainWidth:domainWidth domainHeight:domainHeight
              bedElevation:bedElevation waterDepth:waterDepth minimumBed:minimumBed
            maximumSurface:maximumSurface boundaries:bridgeBoundaryConfiguration(reflective)];
}

- (BOOL)loadWidth:(NSUInteger)width
            height:(NSUInteger)height
       domainWidth:(double)domainWidth
      domainHeight:(double)domainHeight
      bedElevation:(NSData *)bedElevation
         waterDepth:(NSData *)waterDepth
         minimumBed:(double)minimumBed
     maximumSurface:(double)maximumSurface
         boundaries:(WSBoundaryConfiguration *)boundaries {
    if (!validDimensions(width, height)) {
        return NO;
    }
    const auto count = static_cast<std::size_t>(width * height);
    const auto bed = doubleValues(bedElevation, count);
    const auto depth = doubleValues(waterDepth, count);
    if (bed.size() != count || depth.size() != count) {
        return NO;
    }

    const GridGeometry geometry{static_cast<std::size_t>(width), static_cast<std::size_t>(height),
                                domainWidth, domainHeight};
    const BoundaryConfiguration engineBoundaries = engineBoundaryConfiguration(boundaries);
    SimulationState initialState;
    if (!initialState.initializeDepth(geometry, bed, depth, {minimumBed, maximumSurface},
                                      engineBoundaries)) {
        return NO;
    }
    auto& impl = implementation(_implementation);
    impl.running = false;
    return resolveBackend(impl, exportState(initialState));
}

- (WSBoundaryConfiguration *)boundaryConfiguration {
    auto& impl = implementation(_implementation);
    std::string failureReason;
    const BackendState state = currentBackendState(impl, failureReason);
    return bridgeBoundaryConfiguration(state.boundaries);
}

- (BOOL)setBoundaryConfiguration:(WSBoundaryConfiguration *)configuration {
    auto& impl = implementation(_implementation);
    std::string failureReason;
    const BOOL changed = std::visit([&](auto& backend) {
        return backend.setBoundaryConfiguration(engineBoundaryConfiguration(configuration),
                                                failureReason);
    }, impl.backend);
    if (changed) {
        impl.running = false;
        impl.fallbackReason.clear();
    } else {
        impl.fallbackReason = failureReason;
    }
    return changed;
}

- (void)reset {
    auto& impl = implementation(_implementation);
    std::string failureReason;
    (void)std::visit([&](auto& backend) { return backend.reset(failureReason); }, impl.backend);
    impl.fallbackReason = failureReason;
    impl.running = false;
}

- (WSEngineStepStatus)advance:(double)frameDeltaTime {
    auto& impl = implementation(_implementation);
    std::string failureReason;
    const bool accelerated = !std::holds_alternative<CpuBackend>(impl.backend);
    StepStatus result = impl.failureInjection == WSBackendFailureInjectionAcceleratedExecution &&
            accelerated
        ? StepStatus::nonFiniteState
        : std::visit([&](auto& backend) {
            return backend.advance(frameDeltaTime, failureReason);
        }, impl.backend);
    if (result != StepStatus::success && accelerated) {
        impl.running = false;
        impl.fallbackReason = failureReason.empty()
            ? "Injected accelerated execution failure" : failureReason;
        impl.requestedBackendFailed =
            impl.requestedBackend == RequestedSimulationBackend::metalGPU;
        if (impl.requestedBackend == RequestedSimulationBackend::automaticAccelerated) {
            BackendState validState = currentBackendState(impl, failureReason);
            const std::string executionReason = impl.fallbackReason;
            std::string cpuReason;
            if (loadCPU(impl, validState, cpuReason)) {
                impl.resolutionReason =
                    "Accelerated execution failed; CPU Reference recovered the last valid state.";
                impl.fallbackReason = executionReason;
                result = StepStatus::success;
            }
        }
    }
    return bridgeStatus(result);
}

- (WSEngineStepStatus)stepOnce:(double)timeStep {
    auto& impl = implementation(_implementation);
    std::string failureReason;
    const bool accelerated = !std::holds_alternative<CpuBackend>(impl.backend);
    StepStatus result = impl.failureInjection == WSBackendFailureInjectionAcceleratedExecution &&
            accelerated
        ? StepStatus::nonFiniteState
        : std::visit([&](auto& backend) {
            return backend.stepOnce(timeStep, failureReason);
        }, impl.backend);
    if (result != StepStatus::success && accelerated) {
        impl.running = false;
        impl.fallbackReason = failureReason.empty()
            ? "Injected accelerated execution failure" : failureReason;
        impl.requestedBackendFailed =
            impl.requestedBackend == RequestedSimulationBackend::metalGPU;
        if (impl.requestedBackend == RequestedSimulationBackend::automaticAccelerated) {
            const BackendState validState = currentBackendState(impl, failureReason);
            const std::string executionReason = impl.fallbackReason;
            std::string cpuReason;
            if (loadCPU(impl, validState, cpuReason)) {
                impl.resolutionReason =
                    "Accelerated execution failed; CPU Reference recovered the last valid state.";
                impl.fallbackReason = executionReason;
                result = StepStatus::success;
            }
        }
    } else if (result != StepStatus::success) {
        impl.running = false;
        impl.fallbackReason = failureReason;
    }
    return bridgeStatus(result);
}

- (WSEngineSnapshot *)snapshot {
    auto& impl = implementation(_implementation);
    std::string failureReason;
    const BackendSnapshot source = std::visit([&](auto& backend) {
        return backend.makeSnapshot(failureReason);
    }, impl.backend);
    if (!failureReason.empty()) {
        impl.fallbackReason = failureReason;
    }
    const auto count = source.width * source.height;
    OwnedSnapshotBuffer<float> bedElevation(count);
    OwnedSnapshotBuffer<float> waterDepth(count);
    OwnedSnapshotBuffer<float> surfaceElevation(count);
    OwnedSnapshotBuffer<float> surfaceDeviation(count);
    OwnedSnapshotBuffer<float> velocityMagnitude(count);
    OwnedSnapshotBuffer<std::uint8_t> wetMask(count);
    std::ranges::copy(source.bedElevation, bedElevation.values().begin());
    std::ranges::copy(source.waterDepth, waterDepth.values().begin());
    std::ranges::copy(source.surfaceElevation, surfaceElevation.values().begin());
    std::ranges::copy(source.surfaceDeviation, surfaceDeviation.values().begin());
    std::ranges::copy(source.velocityMagnitude, velocityMagnitude.values().begin());
    std::ranges::copy(source.wetMask, wetMask.values().begin());

    const auto& sourceDiagnostics = source.diagnostics;
    WSEngineDiagnostics *diagnostics = [[WSEngineDiagnostics alloc] init];
    diagnostics.totalVolume = sourceDiagnostics.totalVolume;
    diagnostics.minimumDepth = sourceDiagnostics.minimumDepth;
    diagnostics.maximumDepth = sourceDiagnostics.maximumDepth;
    diagnostics.maximumAbsVelocityX = sourceDiagnostics.maximumAbsVelX;
    diagnostics.maximumAbsVelocityY = sourceDiagnostics.maximumAbsVelY;
    diagnostics.maximumWaveSpeed = sourceDiagnostics.maximumWaveSpeed;
    diagnostics.selectedTimeStep = sourceDiagnostics.selectedTimeStep;
    diagnostics.simulatedTime = sourceDiagnostics.simulatedTime;
    diagnostics.correctionVolume = sourceDiagnostics.correctionVolume;
    diagnostics.substepCount = sourceDiagnostics.substepCount;
    diagnostics.wetCellCount = sourceDiagnostics.wetCellCount;
    diagnostics.correctionCount = sourceDiagnostics.correctionCount;
    diagnostics.instantaneousBoundaryOutflowRate = bridgeBoundaryValues(
        sourceDiagnostics.instantaneousBoundaryOutflowRate);
    diagnostics.cumulativeBoundaryOutwardVolume = bridgeBoundaryValues(
        sourceDiagnostics.cumulativeBoundaryOutwardVolume);
    diagnostics.netBoundaryOutflowRate = sourceDiagnostics.netBoundaryOutflowRate;
    diagnostics.accountedExpectedVolume = sourceDiagnostics.accountedExpectedVolume;
    diagnostics.accountingError = sourceDiagnostics.accountingError;
    diagnostics.finite = sourceDiagnostics.finite;
    diagnostics.status = bridgeStatus(sourceDiagnostics.status);

    WSEngineSnapshot *snapshot = [[WSEngineSnapshot alloc] init];
    snapshot.width = source.width;
    snapshot.height = source.height;
    snapshot.domainWidth = source.domainWidth;
    snapshot.domainHeight = source.domainHeight;
    snapshot.bedElevation = bedElevation.consumeAsData();
    snapshot.waterDepth = waterDepth.consumeAsData();
    snapshot.surfaceElevation = surfaceElevation.consumeAsData();
    snapshot.surfaceDeviation = surfaceDeviation.consumeAsData();
    snapshot.velocityMagnitude = velocityMagnitude.consumeAsData();
    snapshot.wetMask = wetMask.consumeAsData();
    snapshot.diagnostics = diagnostics;
    snapshot.backendStatus = self.backendStatus;
    snapshot.acceleratedFieldBuffers = self.acceleratedFieldBuffers;
    return snapshot;
}

- (BOOL)updateGravity:(double)gravity
        linearDamping:(double)linearDamping
             cflNumber:(double)cflNumber
       minimumWetDepth:(double)minimumWetDepth
           workerCount:(NSUInteger)workerCount {
    auto& impl = implementation(_implementation);
    auto configuration = impl.configuration;
    configuration.gravity = gravity;
    configuration.linearDamping = linearDamping;
    configuration.cflNumber = cflNumber;
    configuration.minimumWetDepth = minimumWetDepth;
    configuration.workerCount = workerCount;
    if (!configuration.isValid()) {
        return NO;
    }
    impl.configuration = configuration;
    return std::visit([&](auto& backend) {
        return backend.setConfiguration(configuration);
    }, impl.backend);
}

- (WSTerrainEditResult *)applyMaterialBrushAtX:(double)x
                                             y:(double)y
                                        radius:(double)radius
                                     operation:(WSMaterialOperation)operation
                                        amount:(double)amount
                                       falloff:(WSBrushFalloff)falloff
                                        target:(WSEditTarget)target {
    auto& impl = implementation(_implementation);
    const BrushCommand command{{{x, y}, radius, engineFalloff(falloff)},
                               {engineOperation(operation), amount, engineTarget(target)}};
    return bridgeEditResult(applyCPUBrush(impl, command));
}

- (WSTerrainEditResult *)applyMaterialPolygonWithXYCoordinates:(NSData *)xyCoordinates
                                                      operation:(WSMaterialOperation)operation
                                                         amount:(double)amount
                                                         target:(WSEditTarget)target {
    if (xyCoordinates.length % (2 * sizeof(double)) != 0) {
        return bridgeEditResult({.status = TerrainEditStatus::invalidCommand});
    }
    const std::size_t coordinateCount = xyCoordinates.length / sizeof(double);
    const auto coordinates = std::span(static_cast<const double *>(xyCoordinates.bytes),
                                       coordinateCount);
    std::vector<Point2D> points(coordinateCount / 2);
    for (std::size_t index = 0; index < points.size(); ++index) {
        points[index] = {coordinates[index * 2], coordinates[index * 2 + 1]};
    }
    auto& impl = implementation(_implementation);
    const PolygonCommand command{points,
                                 {engineOperation(operation), amount, engineTarget(target)}};
    return bridgeEditResult(applyCPUPolygon(impl, command));
}

@end
