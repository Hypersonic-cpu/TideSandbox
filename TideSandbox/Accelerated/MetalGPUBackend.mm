#import "MetalGPUBackend.hh"

#import <Metal/Metal.h>
#import <os/signpost.h>

#include <algorithm>
#include <array>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <span>
#include <type_traits>
#include <utility>

namespace tide::accelerated {

namespace {

using Clock = std::chrono::steady_clock;
const os_log_t performanceLog = os_log_create("Potassium.TideSandbox", "SWEAccelerated");

struct GPUBoundaryParameters final {
    std::uint32_t type = 0;
    float meanSurfaceElevation = 0.0F;
    float amplitude = 0.0F;
    float periodSeconds = 1.0F;
    float phaseRadians = 0.0F;
    float rampSeconds = 0.0F;
};

struct GPUParameters final {
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    float dx = 0.0F;
    float dy = 0.0F;
    float gravity = 0.0F;
    float damping = 0.0F;
    float minimumWetDepth = 0.0F;
    float dt = 0.0F;
    float time = 0.0F;
    float minimumBed = 0.0F;
    float maximumSurface = 0.0F;
    float cfl = 0.0F;
    float debugVelocityBound = 0.0F;
    std::array<GPUBoundaryParameters, swe::boundaryEdgeCount> boundaries{};
};

struct GPUStableTimeStepResult final {
    float maximumDepth = 0.0F;
    float maximumAbsVelX = 0.0F;
    float maximumAbsVelY = 0.0F;
    float stableDt = 0.0F;
    std::uint32_t finite = 0;
};

struct GPUDiagnosticResult final {
    float totalVolume = 0.0F;
    float minimumDepth = 0.0F;
    float maximumDepth = 0.0F;
    float maximumAbsVelX = 0.0F;
    float maximumAbsVelY = 0.0F;
    float maximumWaveSpeed = 0.0F;
    float correctionVolume = 0.0F;
    std::uint32_t wetCellCount = 0;
    std::uint32_t correctionCount = 0;
    std::uint32_t finite = 0;
};

struct GPUStablePartial final {
    float maximumDepth;
    float maximumAbsVelX;
    float maximumAbsVelY;
    std::uint32_t finite;
};

struct GPUDiagnosticPartial final {
    float depthSum;
    float minimumDepth;
    float maximumDepth;
    float maximumAbsVelX;
    float maximumAbsVelY;
    float correctionVolume;
    std::uint32_t wetCellCount;
    std::uint32_t correctionCount;
    std::uint32_t finite;
};

constexpr std::size_t reductionThreadgroupCapacity = 256;

static_assert(sizeof(GPUBoundaryParameters) == 24);
static_assert(sizeof(GPUParameters) == 148);
static_assert(sizeof(GPUStableTimeStepResult) == 20);
static_assert(sizeof(GPUDiagnosticResult) == 40);
static_assert(sizeof(GPUStablePartial) == 16);
static_assert(sizeof(GPUDiagnosticPartial) == 36);

[[nodiscard]] double millisecondsSince(const Clock::time_point start) noexcept {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

[[nodiscard]] std::string errorText(NSError * const error, const std::string& fallback) {
    if (error == nil) {
        return fallback;
    }
    const char * const description = error.localizedDescription.UTF8String;
    return description == nullptr ? fallback : std::string(description);
}

[[nodiscard]] std::uint32_t gpuBoundaryType(const swe::BoundaryType type) noexcept {
    switch (type) {
    case swe::BoundaryType::reflective: return 0;
    case swe::BoundaryType::freeOpen: return 1;
    case swe::BoundaryType::drivenHeight: return 2;
    }
}

[[nodiscard]] GPUBoundaryParameters gpuBoundary(const swe::BoundarySide& source) noexcept {
    return {
        .type = gpuBoundaryType(source.type),
        .meanSurfaceElevation = static_cast<float>(source.driven.meanSurfaceElevation),
        .amplitude = static_cast<float>(source.driven.amplitude),
        .periodSeconds = static_cast<float>(source.driven.periodSeconds),
        .phaseRadians = static_cast<float>(source.driven.phaseRadians),
        .rampSeconds = static_cast<float>(source.driven.rampSeconds),
    };
}

template <typename Destination, typename Source>
void convertValues(const std::span<Destination> destination,
                   const std::span<const Source> source) {
    std::transform(source.begin(), source.end(), destination.begin(),
                   [](const Source value) { return static_cast<Destination>(value); });
}

[[nodiscard]] swe::Diagnostics initialDiagnostics(const BackendState& state,
                                                  const swe::SolverConfiguration& configuration) {
    swe::Diagnostics result;
    result.minimumDepth = std::numeric_limits<double>::max();
    double depthSum = 0.0;
    for (const double depth : state.waterDepth) {
        depthSum += depth;
        result.minimumDepth = std::min(result.minimumDepth, depth);
        result.maximumDepth = std::max(result.maximumDepth, depth);
        result.wetCellCount += depth > configuration.minimumWetDepth ? 1 : 0;
    }
    result.totalVolume = depthSum * state.geometry.dx() * state.geometry.dy();
    result.maximumWaveSpeed = std::sqrt(configuration.gravity * result.maximumDepth);
    for (const double velocity : state.velX) {
        result.maximumAbsVelX = std::max(result.maximumAbsVelX, std::abs(velocity));
    }
    for (const double velocity : state.velY) {
        result.maximumAbsVelY = std::max(result.maximumAbsVelY, std::abs(velocity));
    }
    result.simulatedTime = state.time;
    result.cumulativeBoundaryOutwardVolume = state.cumulativeBoundaryVolume;
    double cumulativeOutflow = 0.0;
    for (const double volume : state.cumulativeBoundaryVolume) {
        cumulativeOutflow += volume;
    }
    result.accountedExpectedVolume = state.initialWaterVolume +
        state.accumulatedEditWaterVolume - cumulativeOutflow;
    result.accountingError = result.totalVolume - result.accountedExpectedVolume;
    return result;
}

} // namespace

class MetalGPUBackend::Implementation final {
public:
    [[nodiscard]] bool load(const BackendState& state,
                            const swe::SolverConfiguration configuration,
                            std::string& failureReason) {
        if (!state.isValid() || !configuration.isValid()) {
            failureReason = "Invalid state or solver configuration";
            return false;
        }
        const std::size_t width = state.geometry.width;
        const std::size_t height = state.geometry.height;
        const std::size_t maximumKernelIndex = std::numeric_limits<std::uint32_t>::max();
        if (width > maximumKernelIndex || height > maximumKernelIndex ||
            width * height > maximumKernelIndex ||
            (width + 1) * height > maximumKernelIndex ||
            width * (height + 1) > maximumKernelIndex) {
            failureReason = "Grid exceeds the Metal kernel index range";
            return false;
        }
        const auto compileStart = Clock::now();
        if (!prepareMetal(failureReason)) {
            return false;
        }

        configuration_ = configuration;
        cellCount_ = width * height;
        xFaceCount_ = (width + 1) * height;
        yFaceCount_ = width * (height + 1);
        reductionElementCount_ = std::max({cellCount_, xFaceCount_, yFaceCount_});
        reductionGroupCount_ = (reductionElementCount_ + reductionThreadgroupWidth_ - 1) /
                               reductionThreadgroupWidth_;
        boundaryReductionElementCount_ = std::max(width, height);
        boundaryReductionGroupCount_ =
            (boundaryReductionElementCount_ + reductionThreadgroupWidth_ - 1) /
            reductionThreadgroupWidth_;
        if (!allocateBuffers(failureReason)) {
            return false;
        }

        uploadState(state);
        diagnostics_ = initialDiagnostics(state, configuration);
        status_ = {
            .requested = RequestedSimulationBackend::metalGPU,
            .resolved = ResolvedSimulationBackend::metalGPU,
            .ready = true,
            .fallbackReason = {},
            .statePrecision = "Float32",
            .graphCompileMilliseconds = millisecondsSince(compileStart),
        };
        return true;
    }

    void uploadState(const BackendState& state) {
        metadata_ = state;
        copyToBuffer(state.bedElevation, bed_);
        copyToBuffer(state.waterDepth, depth_[0]);
        copyToBuffer(state.waterDepth, depth_[1]);
        copyToBuffer(state.velX, velX_[0]);
        copyToBuffer(state.velX, velX_[1]);
        copyToBuffer(state.velY, velY_[0]);
        copyToBuffer(state.velY, velY_[1]);
        auto reference = std::span(static_cast<float *>(referenceSurface_.contents), cellCount_);
        for (std::size_t index = 0; index < cellCount_; ++index) {
            reference[index] = static_cast<float>(state.initialBedElevation[index] +
                                                   state.initialWaterDepth[index]);
        }
        currentIndex_ = 0;
        ++bufferGeneration_;
    }

    [[nodiscard]] bool reset(std::string& failureReason) {
        if (!status_.ready) {
            failureReason = "Metal backend is not ready";
            return false;
        }
        copyToBuffer(metadata_.initialBedElevation, bed_);
        copyToBuffer(metadata_.initialWaterDepth, depth_[0]);
        copyToBuffer(metadata_.initialWaterDepth, depth_[1]);
        std::memset(velX_[0].contents, 0, velX_[0].length);
        std::memset(velX_[1].contents, 0, velX_[1].length);
        std::memset(velY_[0].contents, 0, velY_[0].length);
        std::memset(velY_[1].contents, 0, velY_[1].length);
        currentIndex_ = 0;
        ++bufferGeneration_;
        metadata_.bedElevation = metadata_.initialBedElevation;
        metadata_.waterDepth = metadata_.initialWaterDepth;
        std::fill(metadata_.velX.begin(), metadata_.velX.end(), 0.0);
        std::fill(metadata_.velY.begin(), metadata_.velY.end(), 0.0);
        metadata_.time = 0.0;
        metadata_.cumulativeBoundaryVolume.fill(0.0);
        metadata_.accumulatedEditWaterVolume = 0.0;
        diagnostics_ = initialDiagnostics(metadata_, configuration_);
        return true;
    }

    [[nodiscard]] swe::StepStatus advance(const double frameDeltaTime,
                                          std::string& failureReason) {
        const auto frameStart = Clock::now();
        resetFrameDiagnostics();
        if (!std::isfinite(frameDeltaTime) || frameDeltaTime <= 0.0) {
            diagnostics_.status = swe::StepStatus::invalidTimeStep;
            return diagnostics_.status;
        }
        double remaining = frameDeltaTime;
        while (remaining > std::numeric_limits<double>::epsilon() * frameDeltaTime) {
            if (diagnostics_.substepCount == configuration_.maximumSubsteps) {
                diagnostics_.status = swe::StepStatus::substepLimitReached;
                return diagnostics_.status;
            }
            const double stable = stableTimeStep(failureReason);
            if (!(stable > 0.0)) {
                diagnostics_.status = swe::StepStatus::nonFiniteState;
                diagnostics_.finite = false;
                return diagnostics_.status;
            }
            const double dt = std::min(remaining, stable);
            diagnostics_.selectedTimeStep = diagnostics_.substepCount == 0
                ? dt : std::min(diagnostics_.selectedTimeStep, dt);
            const swe::StepStatus result = substep(dt, failureReason);
            if (result != swe::StepStatus::success) {
                diagnostics_.status = result;
                return result;
            }
            remaining -= dt;
            ++diagnostics_.substepCount;
        }
        status_.substepCount = diagnostics_.substepCount;
        status_.lastFramePhysicsMilliseconds = millisecondsSince(frameStart);
        diagnostics_.status = swe::StepStatus::success;
        return diagnostics_.status;
    }

    [[nodiscard]] swe::StepStatus stepOnce(const double timeStep,
                                           std::string& failureReason) {
        resetFrameDiagnostics();
        if (!std::isfinite(timeStep) || timeStep <= 0.0) {
            diagnostics_.status = swe::StepStatus::invalidTimeStep;
            return diagnostics_.status;
        }
        const double stable = stableTimeStep(failureReason);
        if (!(stable > 0.0) || timeStep > stable * (1.0 + 1.0e-6)) {
            diagnostics_.status = swe::StepStatus::invalidTimeStep;
            return diagnostics_.status;
        }
        diagnostics_.selectedTimeStep = timeStep;
        const swe::StepStatus result = substep(timeStep, failureReason);
        diagnostics_.substepCount = result == swe::StepStatus::success ? 1 : 0;
        status_.substepCount = diagnostics_.substepCount;
        return result;
    }

    [[nodiscard]] bool setConfiguration(const swe::SolverConfiguration configuration) noexcept {
        if (!configuration.isValid()) {
            return false;
        }
        configuration_ = configuration;
        return true;
    }

    [[nodiscard]] bool setBoundaryConfiguration(
        const swe::BoundaryConfiguration boundaries,
        std::string& failureReason) noexcept {
        if (!boundaries.isValid(metadata_.worldLimits.minimumBedElevation,
                                metadata_.worldLimits.maximumSurfaceElevation)) {
            failureReason = "Invalid boundary configuration";
            return false;
        }
        metadata_.boundaries = boundaries;
        diagnostics_.instantaneousBoundaryOutflowRate.fill(0.0);
        diagnostics_.netBoundaryOutflowRate = 0.0;
        return true;
    }

    template <typename Command>
    [[nodiscard]] swe::TerrainEditResult applyMaterial(
        const Command& command, std::string& failureReason) {
        const BackendState synchronized = synchronizeToHost(failureReason);
        swe::SimulationState hostState;
        if (!synchronized.isValid() || !importState(synchronized, hostState)) {
            failureReason = "Could not synchronize Metal state for editing";
            return {.status = swe::TerrainEditStatus::invalidCommand};
        }
        swe::TerrainEditor editor(hostState, configuration_.minimumWetDepth);
        swe::TerrainEditResult result;
        if constexpr (std::is_same_v<Command, swe::BrushCommand>) {
            result = editor.applyBrush(command);
        } else {
            result = editor.applyPolygon(command);
        }
        if (!result.changed()) { return result; }
        const BackendState edited = exportState(hostState);
        uploadState(edited);
        diagnostics_ = initialDiagnostics(edited, configuration_);
        status_.fallbackReason.clear();
        return result;
    }

    [[nodiscard]] BackendState synchronizeToHost(std::string& failureReason) {
        if (!status_.ready) {
            failureReason = "Metal backend is not ready";
            return {};
        }
        const auto start = Clock::now();
        copyFromBuffer(bed_, metadata_.bedElevation, cellCount_);
        copyFromBuffer(depth_[currentIndex_], metadata_.waterDepth, cellCount_);
        copyFromBuffer(velX_[currentIndex_], metadata_.velX, xFaceCount_);
        copyFromBuffer(velY_[currentIndex_], metadata_.velY, yFaceCount_);
        status_.lastReadbackMilliseconds = millisecondsSince(start);
        return metadata_;
    }

    [[nodiscard]] BackendSnapshot makeSnapshot(std::string& failureReason) {
        BackendSnapshot snapshot;
        if (!status_.ready) {
            failureReason = "Metal backend is not ready";
            return snapshot;
        }
        const auto start = Clock::now();
        os_signpost_interval_begin(performanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                   "SnapshotReadback", "backend=Metal cells=%zu", cellCount_);
        snapshotStagingIndex_ = (snapshotStagingIndex_ + 1) % snapshotStaging_.size();
        SnapshotStaging& staging = snapshotStaging_[snapshotStagingIndex_];
        const GPUParameters parameters = makeParameters(0.0);
        id<MTLCommandBuffer> const commandBuffer = [queue_ commandBuffer];
        commandBuffer.label = @"TideSandbox snapshot derivation";
        id<MTLComputeCommandEncoder> const encoder = [commandBuffer computeCommandEncoder];
        encoder.label = @"Derived snapshot fields";
        [encoder setComputePipelineState:pipelines_.derivedSnapshot];
        [encoder setBuffer:bed_ offset:0 atIndex:0];
        [encoder setBuffer:depth_[currentIndex_] offset:0 atIndex:1];
        [encoder setBuffer:velX_[currentIndex_] offset:0 atIndex:2];
        [encoder setBuffer:velY_[currentIndex_] offset:0 atIndex:3];
        [encoder setBuffer:referenceSurface_ offset:0 atIndex:4];
        [encoder setBuffer:staging.surfaceElevation offset:0 atIndex:5];
        [encoder setBuffer:staging.surfaceDeviation offset:0 atIndex:6];
        [encoder setBuffer:staging.velocityMagnitude offset:0 atIndex:7];
        [encoder setBuffer:staging.wetMask offset:0 atIndex:8];
        [encoder setBytes:&parameters length:sizeof(parameters) atIndex:9];
        dispatch(encoder, pipelines_.derivedSnapshot, cellCount_);
        [encoder endEncoding];
        id<MTLBlitCommandEncoder> const blit = [commandBuffer blitCommandEncoder];
        blit.label = @"Snapshot staging copies";
        [blit copyFromBuffer:bed_ sourceOffset:0
                    toBuffer:staging.bedElevation destinationOffset:0
                        size:cellCount_ * sizeof(float)];
        [blit copyFromBuffer:depth_[currentIndex_] sourceOffset:0
                    toBuffer:staging.waterDepth destinationOffset:0
                        size:cellCount_ * sizeof(float)];
        [blit endEncoding];
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        os_signpost_interval_end(performanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                 "SnapshotReadback");
        if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
            failureReason = errorText(commandBuffer.error, "Metal snapshot command failed");
            status_.fallbackReason = failureReason;
            return {};
        }
        snapshot.width = metadata_.geometry.width;
        snapshot.height = metadata_.geometry.height;
        snapshot.domainWidth = metadata_.geometry.domainWidth;
        snapshot.domainHeight = metadata_.geometry.domainHeight;
        copyFloatBuffer(staging.bedElevation, snapshot.bedElevation, cellCount_);
        copyFloatBuffer(staging.waterDepth, snapshot.waterDepth, cellCount_);
        copyFloatBuffer(staging.surfaceElevation, snapshot.surfaceElevation, cellCount_);
        copyFloatBuffer(staging.surfaceDeviation, snapshot.surfaceDeviation, cellCount_);
        copyFloatBuffer(staging.velocityMagnitude, snapshot.velocityMagnitude, cellCount_);
        snapshot.wetMask.resize(cellCount_);
        std::memcpy(snapshot.wetMask.data(), staging.wetMask.contents, cellCount_);
        snapshot.diagnostics = diagnostics_;
        status_.lastReadbackMilliseconds = millisecondsSince(start);
        return snapshot;
    }

    [[nodiscard]] const swe::Diagnostics& diagnostics() const noexcept {
        return diagnostics_;
    }

    [[nodiscard]] const BackendStatus& status() const noexcept { return status_; }
    [[nodiscard]] std::size_t stateSizedAllocationCount() const noexcept {
        return stateSizedAllocationCount_;
    }

    [[nodiscard]] AcceleratedFieldBufferSnapshot fieldBufferSnapshot() const noexcept {
        if (!status_.ready) { return {}; }
        return {
            .device = (__bridge void *)device_,
            .bedElevation = (__bridge void *)bed_,
            .waterDepth = (__bridge void *)depth_[currentIndex_],
            .width = metadata_.geometry.width,
            .height = metadata_.geometry.height,
            .generation = bufferGeneration_,
        };
    }

private:
    struct SnapshotStaging final {
        id<MTLBuffer> bedElevation;
        id<MTLBuffer> waterDepth;
        id<MTLBuffer> surfaceElevation;
        id<MTLBuffer> surfaceDeviation;
        id<MTLBuffer> velocityMagnitude;
        id<MTLBuffer> wetMask;
    };

    struct Pipelines final {
        id<MTLComputePipelineState> surface;
        id<MTLComputePipelineState> stableTimeStepPartials;
        id<MTLComputePipelineState> stableTimeStepFinalize;
        id<MTLComputePipelineState> velocityX;
        id<MTLComputePipelineState> velocityY;
        id<MTLComputePipelineState> dampingX;
        id<MTLComputePipelineState> dampingY;
        id<MTLComputePipelineState> fluxX;
        id<MTLComputePipelineState> fluxY;
        id<MTLComputePipelineState> outgoingScale;
        id<MTLComputePipelineState> limitFluxX;
        id<MTLComputePipelineState> limitFluxY;
        id<MTLComputePipelineState> updateDepth;
        id<MTLComputePipelineState> cleanupDepth;
        id<MTLComputePipelineState> cleanupVelocityX;
        id<MTLComputePipelineState> cleanupVelocityY;
        id<MTLComputePipelineState> boundaryRatePartials;
        id<MTLComputePipelineState> boundaryRatesFinalize;
        id<MTLComputePipelineState> diagnosticPartials;
        id<MTLComputePipelineState> diagnosticsFinalize;
        id<MTLComputePipelineState> derivedSnapshot;
    } pipelines_;

    [[nodiscard]] bool prepareMetal(std::string& failureReason) {
        if (device_ != nil) {
            return true;
        }
        device_ = MTLCreateSystemDefaultDevice();
        if (device_ == nil) {
            failureReason = "No Metal device is available";
            return false;
        }
        queue_ = [device_ newCommandQueue];
        if (queue_ == nil) {
            failureReason = "Could not create the Metal command queue";
            return false;
        }
        id<MTLLibrary> const library = [device_ newDefaultLibrary];
        if (library == nil) {
            failureReason = "Could not load the default Metal library";
            return false;
        }
        struct PipelineBinding final {
            __strong id<MTLComputePipelineState> *destination;
            NSString *name;
        };
        const std::array bindings{
            PipelineBinding{&pipelines_.surface, @"sweComputeSurface"},
            PipelineBinding{&pipelines_.stableTimeStepPartials,
                            @"sweStableTimeStepPartials"},
            PipelineBinding{&pipelines_.stableTimeStepFinalize,
                            @"sweFinalizeStableTimeStep"},
            PipelineBinding{&pipelines_.velocityX, @"sweUpdateVelocityX"},
            PipelineBinding{&pipelines_.velocityY, @"sweUpdateVelocityY"},
            PipelineBinding{&pipelines_.dampingX, @"sweApplyDampingX"},
            PipelineBinding{&pipelines_.dampingY, @"sweApplyDampingY"},
            PipelineBinding{&pipelines_.fluxX, @"sweComputeFluxX"},
            PipelineBinding{&pipelines_.fluxY, @"sweComputeFluxY"},
            PipelineBinding{&pipelines_.outgoingScale, @"sweComputeOutgoingScale"},
            PipelineBinding{&pipelines_.limitFluxX, @"sweLimitFluxX"},
            PipelineBinding{&pipelines_.limitFluxY, @"sweLimitFluxY"},
            PipelineBinding{&pipelines_.updateDepth, @"sweUpdateDepth"},
            PipelineBinding{&pipelines_.cleanupDepth, @"sweCleanupDepth"},
            PipelineBinding{&pipelines_.cleanupVelocityX, @"sweCleanupDryVelocityX"},
            PipelineBinding{&pipelines_.cleanupVelocityY, @"sweCleanupDryVelocityY"},
            PipelineBinding{&pipelines_.boundaryRatePartials,
                            @"sweReduceBoundaryRatePartials"},
            PipelineBinding{&pipelines_.boundaryRatesFinalize,
                            @"sweFinalizeBoundaryRates"},
            PipelineBinding{&pipelines_.diagnosticPartials,
                            @"sweReduceDiagnosticPartials"},
            PipelineBinding{&pipelines_.diagnosticsFinalize,
                            @"sweFinalizeDiagnostics"},
            PipelineBinding{&pipelines_.derivedSnapshot, @"sweMakeDerivedSnapshot"},
        };
        for (const PipelineBinding& binding : bindings) {
            id<MTLFunction> const function = [library newFunctionWithName:binding.name];
            if (function == nil) {
                failureReason = "Missing Metal function " +
                    std::string(binding.name.UTF8String);
                return false;
            }
            NSError *error = nil;
            *binding.destination = [device_ newComputePipelineStateWithFunction:function
                                                                            error:&error];
            if (*binding.destination == nil) {
                failureReason = errorText(error, "Metal pipeline compilation failed");
                return false;
            }
        }
        const NSUInteger maximumReductionWidth = std::min({
            static_cast<NSUInteger>(reductionThreadgroupCapacity),
            pipelines_.stableTimeStepPartials.maxTotalThreadsPerThreadgroup,
            pipelines_.boundaryRatePartials.maxTotalThreadsPerThreadgroup,
            pipelines_.diagnosticPartials.maxTotalThreadsPerThreadgroup,
        });
        reductionThreadgroupWidth_ = std::bit_floor(
            static_cast<std::size_t>(maximumReductionWidth));
        const NSUInteger requiredSIMDWidth = std::max({
            pipelines_.stableTimeStepPartials.threadExecutionWidth,
            pipelines_.boundaryRatePartials.threadExecutionWidth,
            pipelines_.diagnosticPartials.threadExecutionWidth,
        });
        if (reductionThreadgroupWidth_ < requiredSIMDWidth ||
            reductionThreadgroupWidth_ < 2) {
            failureReason = "Metal device cannot provide a power-of-two reduction threadgroup";
            return false;
        }
        return true;
    }

    [[nodiscard]] bool allocateBuffers(std::string& failureReason) {
        stateSizedAllocationCount_ = 0;
        const auto make = [&](const std::size_t bytes, NSString *label,
                              const bool stateSized = true) -> id<MTLBuffer> {
            id<MTLBuffer> const result = [device_ newBufferWithLength:bytes
                                                              options:MTLResourceStorageModeShared];
            result.label = label;
            stateSizedAllocationCount_ += result != nil && stateSized ? 1 : 0;
            return result;
        };
        const std::size_t cellsBytes = cellCount_ * sizeof(float);
        const std::size_t xBytes = xFaceCount_ * sizeof(float);
        const std::size_t yBytes = yFaceCount_ * sizeof(float);
        bed_ = make(cellsBytes, @"SWE bed");
        depth_[0] = make(cellsBytes, @"SWE depth A");
        depth_[1] = make(cellsBytes, @"SWE depth B");
        velX_[0] = make(xBytes, @"SWE X velocity A");
        velX_[1] = make(xBytes, @"SWE X velocity B");
        velY_[0] = make(yBytes, @"SWE Y velocity A");
        velY_[1] = make(yBytes, @"SWE Y velocity B");
        fluxX_ = make(xBytes, @"SWE X flux");
        fluxY_ = make(yBytes, @"SWE Y flux");
        outgoingScale_ = make(cellsBytes, @"SWE outgoing scale");
        correction_ = make(cellsBytes, @"SWE correction");
        referenceSurface_ = make(cellsBytes, @"SWE reference surface");
        for (std::size_t index = 0; index < snapshotStaging_.size(); ++index) {
            SnapshotStaging& staging = snapshotStaging_[index];
            NSString * const suffix = [NSString stringWithFormat:@"%zu", index];
            staging.bedElevation = make(cellsBytes,
                [@"SWE snapshot bed " stringByAppendingString:suffix]);
            staging.waterDepth = make(cellsBytes,
                [@"SWE snapshot depth " stringByAppendingString:suffix]);
            staging.surfaceElevation = make(cellsBytes,
                [@"SWE snapshot surface " stringByAppendingString:suffix]);
            staging.surfaceDeviation = make(cellsBytes,
                [@"SWE snapshot deviation " stringByAppendingString:suffix]);
            staging.velocityMagnitude = make(cellsBytes,
                [@"SWE snapshot velocity " stringByAppendingString:suffix]);
            staging.wetMask = make(cellCount_,
                [@"SWE snapshot wet mask " stringByAppendingString:suffix]);
        }
        stableResult_ = make(sizeof(GPUStableTimeStepResult), @"SWE stable dt result", false);
        stablePartials_ = make(reductionGroupCount_ * sizeof(GPUStablePartial),
                               @"SWE stable dt partials", false);
        diagnosticResult_ = make(sizeof(GPUDiagnosticResult), @"SWE diagnostic result", false);
        diagnosticPartials_ = make(reductionGroupCount_ * sizeof(GPUDiagnosticPartial),
                                   @"SWE diagnostic partials", false);
        boundaryRates_ = make(swe::boundaryEdgeCount * sizeof(float),
                              @"SWE boundary rates", false);
        boundaryRatePartials_ = make(boundaryReductionGroupCount_ * 4 * sizeof(float),
                                     @"SWE boundary rate partials", false);
        if (bed_ == nil || depth_[0] == nil || depth_[1] == nil ||
            velX_[0] == nil || velX_[1] == nil || velY_[0] == nil || velY_[1] == nil ||
            fluxX_ == nil || fluxY_ == nil || outgoingScale_ == nil ||
            correction_ == nil || referenceSurface_ == nil ||
            stableResult_ == nil || stablePartials_ == nil || diagnosticResult_ == nil ||
            diagnosticPartials_ == nil || boundaryRates_ == nil ||
            boundaryRatePartials_ == nil) {
            failureReason = "Could not allocate persistent Metal solver buffers";
            return false;
        }
        for (const SnapshotStaging& staging : snapshotStaging_) {
            if (staging.bedElevation == nil || staging.waterDepth == nil ||
                staging.surfaceElevation == nil || staging.surfaceDeviation == nil ||
                staging.velocityMagnitude == nil || staging.wetMask == nil) {
                failureReason = "Could not allocate the Metal snapshot staging ring";
                return false;
            }
        }
        return true;
    }

    [[nodiscard]] GPUParameters makeParameters(const double dt) const noexcept {
        GPUParameters result{
            .width = static_cast<std::uint32_t>(metadata_.geometry.width),
            .height = static_cast<std::uint32_t>(metadata_.geometry.height),
            .dx = static_cast<float>(metadata_.geometry.dx()),
            .dy = static_cast<float>(metadata_.geometry.dy()),
            .gravity = static_cast<float>(configuration_.gravity),
            .damping = static_cast<float>(configuration_.linearDamping),
            .minimumWetDepth = static_cast<float>(configuration_.minimumWetDepth),
            .dt = static_cast<float>(dt),
            .time = static_cast<float>(metadata_.time),
            .minimumBed = static_cast<float>(metadata_.worldLimits.minimumBedElevation),
            .maximumSurface = static_cast<float>(metadata_.worldLimits.maximumSurfaceElevation),
            .cfl = static_cast<float>(configuration_.cflNumber),
            .debugVelocityBound = static_cast<float>(configuration_.debugVelocityBound),
        };
        result.boundaries[0] = gpuBoundary(metadata_.boundaries.left);
        result.boundaries[1] = gpuBoundary(metadata_.boundaries.right);
        result.boundaries[2] = gpuBoundary(metadata_.boundaries.bottom);
        result.boundaries[3] = gpuBoundary(metadata_.boundaries.top);
        return result;
    }

    static void dispatch(id<MTLComputeCommandEncoder> encoder,
                         id<MTLComputePipelineState> pipeline,
                         const std::size_t count) {
        const NSUInteger preferred = std::max<NSUInteger>(pipeline.threadExecutionWidth, 1);
        const NSUInteger width = std::min<NSUInteger>(pipeline.maxTotalThreadsPerThreadgroup,
                                                      preferred * 4);
        [encoder dispatchThreads:MTLSizeMake(count, 1, 1)
          threadsPerThreadgroup:MTLSizeMake(std::max<NSUInteger>(width, 1), 1, 1)];
    }

    void dispatchReductionGroups(id<MTLComputeCommandEncoder> encoder,
                                 const std::size_t groupCount) const {
        [encoder dispatchThreadgroups:MTLSizeMake(groupCount, 1, 1)
                 threadsPerThreadgroup:MTLSizeMake(reductionThreadgroupWidth_, 1, 1)];
    }

    [[nodiscard]] double stableTimeStep(std::string& failureReason) {
        const auto start = Clock::now();
        os_signpost_interval_begin(performanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                   "StableDtReduction", "backend=Metal");
        const GPUParameters parameters = makeParameters(0.0);
        id<MTLCommandBuffer> const commandBuffer = [queue_ commandBuffer];
        commandBuffer.label = @"TideSandbox stable time step";
        id<MTLComputeCommandEncoder> const encoder = [commandBuffer computeCommandEncoder];
        encoder.label = @"Stable time-step reduction";
        [encoder setComputePipelineState:pipelines_.stableTimeStepPartials];
        [encoder setBuffer:bed_ offset:0 atIndex:0];
        [encoder setBuffer:depth_[currentIndex_] offset:0 atIndex:1];
        [encoder setBuffer:velX_[currentIndex_] offset:0 atIndex:2];
        [encoder setBuffer:velY_[currentIndex_] offset:0 atIndex:3];
        [encoder setBuffer:stablePartials_ offset:0 atIndex:4];
        [encoder setBytes:&parameters length:sizeof(parameters) atIndex:5];
        dispatchReductionGroups(encoder, reductionGroupCount_);
        const auto partialCount = static_cast<std::uint32_t>(reductionGroupCount_);
        [encoder setComputePipelineState:pipelines_.stableTimeStepFinalize];
        [encoder setBuffer:stablePartials_ offset:0 atIndex:0];
        [encoder setBuffer:stableResult_ offset:0 atIndex:1];
        [encoder setBytes:&parameters length:sizeof(parameters) atIndex:2];
        [encoder setBytes:&partialCount length:sizeof(partialCount) atIndex:3];
        dispatch(encoder, pipelines_.stableTimeStepFinalize, 1);
        [encoder endEncoding];
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        status_.lastStableDtMilliseconds = millisecondsSince(start);
        os_signpost_interval_end(performanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                 "StableDtReduction");
        if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
            failureReason = errorText(commandBuffer.error, "Metal stable-dt command failed");
            status_.fallbackReason = failureReason;
            return 0.0;
        }
        const auto& result = *static_cast<const GPUStableTimeStepResult *>(stableResult_.contents);
        diagnostics_.maximumAbsVelX = result.maximumAbsVelX;
        diagnostics_.maximumAbsVelY = result.maximumAbsVelY;
        diagnostics_.maximumWaveSpeed = std::sqrt(configuration_.gravity * result.maximumDepth);
        if (result.finite == 0 || !std::isfinite(result.stableDt) || result.stableDt <= 0.0F) {
            failureReason = "Metal stable-dt reduction reported a non-finite state";
            return 0.0;
        }
        return result.stableDt;
    }

    [[nodiscard]] swe::StepStatus substep(const double timeStep,
                                          std::string& failureReason) {
        const auto start = Clock::now();
        os_signpost_interval_begin(performanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                   "SWESubstep", "backend=Metal cells=%zu", cellCount_);
        const GPUParameters parameters = makeParameters(timeStep);
        const std::size_t nextIndex = 1 - currentIndex_;
        id<MTLCommandBuffer> const commandBuffer = [queue_ commandBuffer];
        commandBuffer.label = @"TideSandbox SWE substep";
        id<MTLComputeCommandEncoder> const encoder = [commandBuffer computeCommandEncoder];
        encoder.label = @"SWE solver passes";

        const auto select = [&](id<MTLComputePipelineState> pipeline) {
            [encoder setComputePipelineState:pipeline];
        };
        select(pipelines_.velocityX);
        [encoder setBuffer:bed_ offset:0 atIndex:0];
        [encoder setBuffer:depth_[currentIndex_] offset:0 atIndex:1];
        [encoder setBuffer:velX_[currentIndex_] offset:0 atIndex:2];
        [encoder setBuffer:velX_[nextIndex] offset:0 atIndex:3];
        [encoder setBytes:&parameters length:sizeof(parameters) atIndex:4];
        dispatch(encoder, pipelines_.velocityX, xFaceCount_);

        select(pipelines_.velocityY);
        [encoder setBuffer:bed_ offset:0 atIndex:0];
        [encoder setBuffer:depth_[currentIndex_] offset:0 atIndex:1];
        [encoder setBuffer:velY_[currentIndex_] offset:0 atIndex:2];
        [encoder setBuffer:velY_[nextIndex] offset:0 atIndex:3];
        [encoder setBytes:&parameters length:sizeof(parameters) atIndex:4];
        dispatch(encoder, pipelines_.velocityY, yFaceCount_);

        select(pipelines_.fluxX);
        [encoder setBuffer:bed_ offset:0 atIndex:0];
        [encoder setBuffer:depth_[currentIndex_] offset:0 atIndex:1];
        [encoder setBuffer:velX_[nextIndex] offset:0 atIndex:2];
        [encoder setBuffer:fluxX_ offset:0 atIndex:3];
        [encoder setBytes:&parameters length:sizeof(parameters) atIndex:4];
        dispatch(encoder, pipelines_.fluxX, xFaceCount_);

        select(pipelines_.fluxY);
        [encoder setBuffer:bed_ offset:0 atIndex:0];
        [encoder setBuffer:depth_[currentIndex_] offset:0 atIndex:1];
        [encoder setBuffer:velY_[nextIndex] offset:0 atIndex:2];
        [encoder setBuffer:fluxY_ offset:0 atIndex:3];
        [encoder setBytes:&parameters length:sizeof(parameters) atIndex:4];
        dispatch(encoder, pipelines_.fluxY, yFaceCount_);

        select(pipelines_.outgoingScale);
        [encoder setBuffer:depth_[currentIndex_] offset:0 atIndex:0];
        [encoder setBuffer:fluxX_ offset:0 atIndex:1];
        [encoder setBuffer:fluxY_ offset:0 atIndex:2];
        [encoder setBuffer:outgoingScale_ offset:0 atIndex:3];
        [encoder setBytes:&parameters length:sizeof(parameters) atIndex:4];
        dispatch(encoder, pipelines_.outgoingScale, cellCount_);

        select(pipelines_.limitFluxX);
        [encoder setBuffer:fluxX_ offset:0 atIndex:0];
        [encoder setBuffer:outgoingScale_ offset:0 atIndex:1];
        [encoder setBytes:&parameters length:sizeof(parameters) atIndex:2];
        dispatch(encoder, pipelines_.limitFluxX, xFaceCount_);

        select(pipelines_.limitFluxY);
        [encoder setBuffer:fluxY_ offset:0 atIndex:0];
        [encoder setBuffer:outgoingScale_ offset:0 atIndex:1];
        [encoder setBytes:&parameters length:sizeof(parameters) atIndex:2];
        dispatch(encoder, pipelines_.limitFluxY, yFaceCount_);

        select(pipelines_.updateDepth);
        [encoder setBuffer:depth_[currentIndex_] offset:0 atIndex:0];
        [encoder setBuffer:fluxX_ offset:0 atIndex:1];
        [encoder setBuffer:fluxY_ offset:0 atIndex:2];
        [encoder setBuffer:depth_[nextIndex] offset:0 atIndex:3];
        [encoder setBuffer:correction_ offset:0 atIndex:4];
        [encoder setBytes:&parameters length:sizeof(parameters) atIndex:5];
        dispatch(encoder, pipelines_.updateDepth, cellCount_);

        select(pipelines_.boundaryRatePartials);
        [encoder setBuffer:fluxX_ offset:0 atIndex:0];
        [encoder setBuffer:fluxY_ offset:0 atIndex:1];
        [encoder setBuffer:boundaryRatePartials_ offset:0 atIndex:2];
        [encoder setBytes:&parameters length:sizeof(parameters) atIndex:3];
        dispatchReductionGroups(encoder, boundaryReductionGroupCount_);
        const auto boundaryPartialCount =
            static_cast<std::uint32_t>(boundaryReductionGroupCount_);
        select(pipelines_.boundaryRatesFinalize);
        [encoder setBuffer:boundaryRatePartials_ offset:0 atIndex:0];
        [encoder setBuffer:boundaryRates_ offset:0 atIndex:1];
        [encoder setBytes:&boundaryPartialCount length:sizeof(boundaryPartialCount) atIndex:2];
        dispatch(encoder, pipelines_.boundaryRatesFinalize, 1);

        select(pipelines_.diagnosticPartials);
        [encoder setBuffer:bed_ offset:0 atIndex:0];
        [encoder setBuffer:depth_[nextIndex] offset:0 atIndex:1];
        [encoder setBuffer:velX_[nextIndex] offset:0 atIndex:2];
        [encoder setBuffer:velY_[nextIndex] offset:0 atIndex:3];
        [encoder setBuffer:correction_ offset:0 atIndex:4];
        [encoder setBuffer:diagnosticPartials_ offset:0 atIndex:5];
        [encoder setBytes:&parameters length:sizeof(parameters) atIndex:6];
        dispatchReductionGroups(encoder, reductionGroupCount_);
        const auto diagnosticPartialCount = static_cast<std::uint32_t>(reductionGroupCount_);
        select(pipelines_.diagnosticsFinalize);
        [encoder setBuffer:diagnosticPartials_ offset:0 atIndex:0];
        [encoder setBuffer:diagnosticResult_ offset:0 atIndex:1];
        [encoder setBytes:&parameters length:sizeof(parameters) atIndex:2];
        [encoder setBytes:&diagnosticPartialCount length:sizeof(diagnosticPartialCount)
                  atIndex:3];
        dispatch(encoder, pipelines_.diagnosticsFinalize, 1);

        [encoder endEncoding];
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        os_signpost_interval_end(performanceLog, OS_SIGNPOST_ID_EXCLUSIVE, "SWESubstep");
        status_.lastSubstepMilliseconds = millisecondsSince(start);
        if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
            failureReason = errorText(commandBuffer.error, "Metal SWE command failed");
            status_.fallbackReason = failureReason;
            return swe::StepStatus::nonFiniteState;
        }
        const auto& raw = *static_cast<const GPUDiagnosticResult *>(diagnosticResult_.contents);
        if (raw.finite == 0) {
            failureReason = "Metal SWE diagnostics rejected the candidate state";
            status_.fallbackReason = failureReason;
            return swe::StepStatus::nonFiniteState;
        }

        currentIndex_ = nextIndex;
        ++bufferGeneration_;
        metadata_.time += timeStep;
        const auto rates = std::span(static_cast<const float *>(boundaryRates_.contents),
                                     swe::boundaryEdgeCount);
        diagnostics_.netBoundaryOutflowRate = 0.0;
        for (std::size_t edge = 0; edge < swe::boundaryEdgeCount; ++edge) {
            const double rate = rates[edge];
            diagnostics_.instantaneousBoundaryOutflowRate[edge] = rate;
            metadata_.cumulativeBoundaryVolume[edge] += timeStep * rate;
            diagnostics_.netBoundaryOutflowRate += rate;
        }
        updateDiagnostics(raw);
        diagnostics_.status = swe::StepStatus::success;
        return diagnostics_.status;
    }

    void updateDiagnostics(const GPUDiagnosticResult& raw) noexcept {
        diagnostics_.totalVolume = raw.totalVolume;
        diagnostics_.minimumDepth = raw.minimumDepth;
        diagnostics_.maximumDepth = raw.maximumDepth;
        diagnostics_.maximumAbsVelX = raw.maximumAbsVelX;
        diagnostics_.maximumAbsVelY = raw.maximumAbsVelY;
        diagnostics_.maximumWaveSpeed = raw.maximumWaveSpeed;
        diagnostics_.correctionVolume += raw.correctionVolume;
        diagnostics_.correctionCount += raw.correctionCount;
        diagnostics_.wetCellCount = raw.wetCellCount;
        diagnostics_.finite = raw.finite != 0;
        diagnostics_.simulatedTime = metadata_.time;
        diagnostics_.cumulativeBoundaryOutwardVolume = metadata_.cumulativeBoundaryVolume;
        double cumulativeOutflow = 0.0;
        for (const double volume : metadata_.cumulativeBoundaryVolume) {
            cumulativeOutflow += volume;
        }
        diagnostics_.accountedExpectedVolume = metadata_.initialWaterVolume +
            metadata_.accumulatedEditWaterVolume - cumulativeOutflow;
        diagnostics_.accountingError = diagnostics_.totalVolume -
            diagnostics_.accountedExpectedVolume;
    }

    void resetFrameDiagnostics() noexcept {
        const swe::BoundaryValues cumulative = metadata_.cumulativeBoundaryVolume;
        diagnostics_ = {};
        diagnostics_.finite = true;
        diagnostics_.simulatedTime = metadata_.time;
        diagnostics_.cumulativeBoundaryOutwardVolume = cumulative;
    }

    template <typename Source>
    static void copyToBuffer(const std::vector<Source>& source, id<MTLBuffer> destination) {
        auto values = std::span(static_cast<float *>(destination.contents), source.size());
        convertValues<float, Source>(values, source);
    }

    static void copyFromBuffer(id<MTLBuffer> source, std::vector<double>& destination,
                               const std::size_t count) {
        destination.resize(count);
        const auto values = std::span(static_cast<const float *>(source.contents), count);
        convertValues<double, float>(destination, values);
    }

    static void copyFloatBuffer(id<MTLBuffer> source, std::vector<float>& destination,
                                const std::size_t count) {
        destination.resize(count);
        std::memcpy(destination.data(), source.contents, count * sizeof(float));
    }

    id<MTLDevice> device_;
    id<MTLCommandQueue> queue_;
    id<MTLBuffer> bed_;
    std::array<id<MTLBuffer>, 2> depth_{};
    std::array<id<MTLBuffer>, 2> velX_{};
    std::array<id<MTLBuffer>, 2> velY_{};
    id<MTLBuffer> fluxX_;
    id<MTLBuffer> fluxY_;
    id<MTLBuffer> outgoingScale_;
    id<MTLBuffer> correction_;
    id<MTLBuffer> referenceSurface_;
    std::array<SnapshotStaging, 3> snapshotStaging_{};
    id<MTLBuffer> stableResult_;
    id<MTLBuffer> stablePartials_;
    id<MTLBuffer> diagnosticResult_;
    id<MTLBuffer> diagnosticPartials_;
    id<MTLBuffer> boundaryRates_;
    id<MTLBuffer> boundaryRatePartials_;
    BackendState metadata_;
    swe::SolverConfiguration configuration_;
    swe::Diagnostics diagnostics_;
    BackendStatus status_;
    std::size_t cellCount_ = 0;
    std::size_t xFaceCount_ = 0;
    std::size_t yFaceCount_ = 0;
    std::size_t reductionElementCount_ = 0;
    std::size_t reductionGroupCount_ = 0;
    std::size_t boundaryReductionElementCount_ = 0;
    std::size_t boundaryReductionGroupCount_ = 0;
    std::size_t reductionThreadgroupWidth_ = 0;
    std::size_t currentIndex_ = 0;
    std::size_t snapshotStagingIndex_ = 0;
    std::size_t stateSizedAllocationCount_ = 0;
    std::uint64_t bufferGeneration_ = 0;
};

MetalGPUBackend::MetalGPUBackend() : implementation_(std::make_unique<Implementation>()) {}
MetalGPUBackend::~MetalGPUBackend() = default;
MetalGPUBackend::MetalGPUBackend(MetalGPUBackend&&) noexcept = default;
MetalGPUBackend& MetalGPUBackend::operator=(MetalGPUBackend&&) noexcept = default;

bool MetalGPUBackend::load(const BackendState& state,
                           const swe::SolverConfiguration configuration,
                           std::string& failureReason) {
    return implementation_->load(state, configuration, failureReason);
}

bool MetalGPUBackend::reset(std::string& failureReason) {
    return implementation_->reset(failureReason);
}

swe::StepStatus MetalGPUBackend::advance(const double frameDeltaTime,
                                         std::string& failureReason) {
    return implementation_->advance(frameDeltaTime, failureReason);
}

swe::StepStatus MetalGPUBackend::stepOnce(const double timeStep,
                                          std::string& failureReason) {
    return implementation_->stepOnce(timeStep, failureReason);
}

bool MetalGPUBackend::setConfiguration(const swe::SolverConfiguration configuration) noexcept {
    return implementation_->setConfiguration(configuration);
}

bool MetalGPUBackend::setBoundaryConfiguration(const swe::BoundaryConfiguration boundaries,
                                               std::string& failureReason) noexcept {
    return implementation_->setBoundaryConfiguration(boundaries, failureReason);
}

swe::TerrainEditResult MetalGPUBackend::applyMaterialBrush(
    const swe::BrushCommand& command, std::string& failureReason) {
    return implementation_->applyMaterial(command, failureReason);
}

swe::TerrainEditResult MetalGPUBackend::applyMaterialPolygon(
    const swe::PolygonCommand& command, std::string& failureReason) {
    return implementation_->applyMaterial(command, failureReason);
}

BackendState MetalGPUBackend::synchronizeToHost(std::string& failureReason) {
    return implementation_->synchronizeToHost(failureReason);
}

BackendSnapshot MetalGPUBackend::makeSnapshot(std::string& failureReason) {
    return implementation_->makeSnapshot(failureReason);
}

const swe::Diagnostics& MetalGPUBackend::diagnostics() const noexcept {
    return implementation_->diagnostics();
}

const BackendStatus& MetalGPUBackend::status() const noexcept {
    return implementation_->status();
}

std::size_t MetalGPUBackend::stateSizedAllocationCount() const noexcept {
    return implementation_->stateSizedAllocationCount();
}

AcceleratedFieldBufferSnapshot MetalGPUBackend::fieldBufferSnapshot() const noexcept {
    return implementation_->fieldBufferSnapshot();
}

} // namespace tide::accelerated
