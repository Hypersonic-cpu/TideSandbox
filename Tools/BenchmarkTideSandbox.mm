#import <Foundation/Foundation.h>

#import "../TideSandbox/Bridge/WaterEngineBridge.hh"

#include "../TideSandbox/Engine/SimulationState.hh"
#include "../TideSandbox/Engine/WeakNonlinearSolver.hh"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <numeric>
#include <thread>
#include <utility>
#include <vector>

using namespace tide::swe;

namespace {

using Clock = std::chrono::steady_clock;

struct SampleSummary final {
    double medianMilliseconds = 0.0;
    double medianAbsoluteDeviationMilliseconds = 0.0;
};

struct AcceleratedSummary final {
    SampleSummary totalStep;
    SampleSummary stableReduction;
    SampleSummary substepCompute;
    SampleSummary snapshotReadback;
    SampleSummary snapshotWall;
    SampleSummary directBufferHandoff;
    double coldGraphCompileMilliseconds = 0.0;
    std::size_t stateSizedAllocationCount = 0;
    WSResolvedSimulationBackend resolvedBackend = WSResolvedSimulationBackendCPUReference;
};

[[nodiscard]] SampleSummary summarize(std::vector<double> samples) {
    std::ranges::sort(samples);
    const double median = samples[samples.size() / 2];
    std::vector<double> deviations(samples.size());
    std::ranges::transform(samples, deviations.begin(),
                           [median](const double value) { return std::abs(value - median); });
    std::ranges::sort(deviations);
    return {median, deviations[deviations.size() / 2]};
}

[[nodiscard]] SimulationState makeState(const std::size_t size) {
    const GridGeometry geometry{size, size, static_cast<double>(size),
                                static_cast<double>(size)};
    std::vector<double> bed(size * size);
    std::vector<double> depth(size * size);
    for (std::size_t row = 0; row < size; ++row) {
        for (std::size_t column = 0; column < size; ++column) {
            const std::size_t index = row * size + column;
            const double terrain = 0.08 * std::sin(static_cast<double>(column) * 0.17) *
                                   std::cos(static_cast<double>(row) * 0.13);
            const double perturbation = 0.03 *
                std::exp(-0.002 * (std::pow(static_cast<double>(column) -
                                           static_cast<double>(size) * 0.47, 2.0) +
                                    std::pow(static_cast<double>(row) -
                                           static_cast<double>(size) * 0.53, 2.0)));
            bed[index] = terrain;
            depth[index] = 2.0 - terrain + perturbation;
        }
    }
    SimulationState state;
    if (!state.initializeDepth(geometry, bed, depth)) {
        std::abort();
    }
    return state;
}

[[nodiscard]] std::size_t iterationCount(const std::size_t size) noexcept {
    if (size <= 16) { return 400; }
    if (size <= 32) { return 250; }
    if (size <= 128) { return 40; }
    return 8;
}

[[nodiscard]] SampleSummary benchmarkSolver(const std::size_t size,
                                            const std::size_t workers) {
    constexpr std::size_t repetitions = 5;
    constexpr std::size_t warmupIterations = 4;
    const std::size_t iterations = iterationCount(size);
    std::vector<double> samples;
    samples.reserve(repetitions);
    for (std::size_t repetition = 0; repetition < repetitions; ++repetition) {
        SimulationState state = makeState(size);
        SolverConfiguration configuration;
        configuration.workerCount = workers;
        WeakNonlinearSolver solver(state, configuration);
        for (std::size_t index = 0; index < warmupIterations; ++index) {
            if (solver.stepOnce(0.001) != StepStatus::success) { std::abort(); }
        }
        const auto start = Clock::now();
        for (std::size_t index = 0; index < iterations; ++index) {
            if (solver.stepOnce(0.001) != StepStatus::success) { std::abort(); }
        }
        const double milliseconds = std::chrono::duration<double, std::milli>(
            Clock::now() - start).count() / static_cast<double>(iterations);
        samples.push_back(milliseconds);
    }
    return summarize(std::move(samples));
}

void profileSolver(const std::size_t size, const std::size_t workers) {
    const std::size_t iterations = std::max<std::size_t>(iterationCount(size), 20);
    SimulationState state = makeState(size);
    SolverConfiguration configuration;
    configuration.workerCount = workers;
    configuration.collectPerformanceCounters = true;
    WeakNonlinearSolver solver(state, configuration);
    if (solver.stepOnce(0.001) != StepStatus::success) { std::abort(); }
    solver.resetPerformanceCounters();
    for (std::size_t index = 0; index < iterations; ++index) {
        if (solver.stepOnce(0.001) != StepStatus::success) { std::abort(); }
    }
    const auto& p = solver.performanceCounters();
    const double divisor = static_cast<double>(p.profiledSubsteps) / 1'000.0;
    std::printf(
        "PASSES,%zu,%zu,%zu,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f\n",
        size, workers, p.profiledSubsteps,
        p.stableTimeStepSeconds / divisor,
        p.surfaceSeconds / divisor,
        p.pressureSeconds / divisor,
        p.dampingSeconds / divisor,
        p.fluxSeconds / divisor,
        p.limiterScaleSeconds / divisor,
        p.fluxLimitSeconds / divisor,
        p.continuitySeconds / divisor,
        p.cleanupSeconds / divisor,
        p.dryVelocitySeconds / divisor,
        p.validationSeconds / divisor,
        p.diagnosticsSeconds / divisor,
        p.totalSubstepSeconds / divisor);
}

[[nodiscard]] SampleSummary benchmarkSnapshot(const std::size_t size) {
    constexpr std::size_t repetitions = 5;
    const std::size_t iterations = std::max<std::size_t>(2, iterationCount(size) / 4);
    const std::size_t count = size * size;
    std::vector<float> bed(count);
    std::vector<float> depth(count);
    for (std::size_t index = 0; index < count; ++index) {
        bed[index] = 0.05F * std::sin(static_cast<float>(index % size) * 0.1F);
        depth[index] = 2.0F - bed[index];
    }
    NSData * const bedData = [NSData dataWithBytes:bed.data() length:count * sizeof(float)];
    NSData * const depthData = [NSData dataWithBytes:depth.data() length:count * sizeof(float)];
    const double domainSize = static_cast<double>(size);
    WSWaterEngineBridge * const bridge = [[WSWaterEngineBridge alloc]
        initWithWidth:size height:size domainWidth:domainSize domainHeight:domainSize];
    if (![bridge setRequestedBackend:WSRequestedSimulationBackendCPUReference] ||
        ![bridge loadWidth:size height:size domainWidth:domainSize domainHeight:domainSize
                bedElevation:bedData waterDepth:depthData]) {
        std::abort();
    }
    @autoreleasepool { (void)[bridge snapshot]; }
    std::vector<double> samples;
    samples.reserve(repetitions);
    std::size_t observedBytes = 0;
    for (std::size_t repetition = 0; repetition < repetitions; ++repetition) {
        const auto start = Clock::now();
        for (std::size_t index = 0; index < iterations; ++index) {
            @autoreleasepool {
                WSEngineSnapshot * const snapshot = [bridge snapshot];
                observedBytes += snapshot.waterDepth.length;
            }
        }
        samples.push_back(std::chrono::duration<double, std::milli>(Clock::now() - start).count() /
                          static_cast<double>(iterations));
    }
    if (observedBytes == 0) { std::abort(); }
    return summarize(std::move(samples));
}

[[nodiscard]] AcceleratedSummary benchmarkBridge(
    const std::size_t width,
    const std::size_t height,
    const WSRequestedSimulationBackend requestedBackend
) {
    constexpr std::size_t repetitions = 5;
    constexpr std::size_t warmupIterations = 20;
    const std::size_t cells = width * height;
    const std::size_t iterations = cells <= 16'384 ? 30 : (cells <= 65'536 ? 12 : 5);
    std::vector<float> bed(cells);
    std::vector<float> depth(cells);
    for (std::size_t row = 0; row < height; ++row) {
        for (std::size_t column = 0; column < width; ++column) {
            const std::size_t index = row * width + column;
            const float terrain = 0.08F * std::sin(static_cast<float>(column) * 0.17F) *
                                  std::cos(static_cast<float>(row) * 0.13F);
            const float x = static_cast<float>(column) - static_cast<float>(width) * 0.47F;
            const float y = static_cast<float>(row) - static_cast<float>(height) * 0.53F;
            bed[index] = terrain;
            depth[index] = 2.0F - terrain + 0.03F * std::exp(-0.002F * (x * x + y * y));
        }
    }
    NSData * const bedData = [NSData dataWithBytes:bed.data()
                                              length:cells * sizeof(float)];
    NSData * const depthData = [NSData dataWithBytes:depth.data()
                                                length:cells * sizeof(float)];
    std::vector<double> totalSamples;
    std::vector<double> stableSamples;
    std::vector<double> substepSamples;
    std::vector<double> readbackSamples;
    std::vector<double> snapshotWallSamples;
    std::vector<double> directHandoffSamples;
    totalSamples.reserve(repetitions * iterations);
    stableSamples.reserve(repetitions * iterations);
    substepSamples.reserve(repetitions * iterations);
    readbackSamples.reserve(repetitions);
    snapshotWallSamples.reserve(repetitions);
    directHandoffSamples.reserve(repetitions);
    AcceleratedSummary result;
    for (std::size_t repetition = 0; repetition < repetitions; ++repetition) {
        WSWaterEngineBridge * const bridge = [[WSWaterEngineBridge alloc]
            initWithWidth:8 height:8 domainWidth:8.0 domainHeight:8.0];
        if (![bridge setRequestedBackend:requestedBackend] ||
            ![bridge loadWidth:width height:height domainWidth:static_cast<double>(width)
                    domainHeight:static_cast<double>(height) bedElevation:bedData
                    waterDepth:depthData]) {
            std::abort();
        }
        result.coldGraphCompileMilliseconds = std::max(
            result.coldGraphCompileMilliseconds,
            bridge.backendStatus.graphCompileMilliseconds);
        for (std::size_t index = 0; index < warmupIterations; ++index) {
            if ([bridge stepOnce:0.001] != WSEngineStepStatusSuccess) { std::abort(); }
        }
        for (std::size_t index = 0; index < iterations; ++index) {
            const auto start = Clock::now();
            if ([bridge stepOnce:0.001] != WSEngineStepStatusSuccess) { std::abort(); }
            totalSamples.push_back(std::chrono::duration<double, std::milli>(
                Clock::now() - start).count());
            WSBackendStatus * const status = bridge.backendStatus;
            stableSamples.push_back(status.lastStableDtMilliseconds);
            substepSamples.push_back(status.lastSubstepMilliseconds);
        }
        const auto readbackStart = Clock::now();
        @autoreleasepool { (void)[bridge snapshot]; }
        snapshotWallSamples.push_back(std::chrono::duration<double, std::milli>(
            Clock::now() - readbackStart).count());
        readbackSamples.push_back(bridge.backendStatus.lastReadbackMilliseconds);
        constexpr std::size_t handoffIterations = 500;
        std::uint64_t observedGeneration = 0;
        const auto handoffStart = Clock::now();
        for (std::size_t index = 0; index < handoffIterations; ++index) {
            @autoreleasepool {
                WSAcceleratedFieldBuffers * const buffers = bridge.acceleratedFieldBuffers;
                observedGeneration += buffers.generation;
            }
        }
        directHandoffSamples.push_back(std::chrono::duration<double, std::milli>(
            Clock::now() - handoffStart).count() / static_cast<double>(handoffIterations));
        if (bridge.resolvedBackend != WSResolvedSimulationBackendCPUReference &&
            observedGeneration == 0) {
            std::abort();
        }
        result.stateSizedAllocationCount = bridge.backendStatus.stateSizedAllocationCount;
        result.resolvedBackend = bridge.resolvedBackend;
    }
    result.totalStep = summarize(std::move(totalSamples));
    result.stableReduction = summarize(std::move(stableSamples));
    result.substepCompute = summarize(std::move(substepSamples));
    result.snapshotReadback = summarize(std::move(readbackSamples));
    result.snapshotWall = summarize(std::move(snapshotWallSamples));
    result.directBufferHandoff = summarize(std::move(directHandoffSamples));
    return result;
}

} // namespace

int main() {
    @autoreleasepool {
#ifdef NDEBUG
        constexpr const char *build = "Release";
#else
        constexpr const char *build = "Debug";
#endif
        constexpr std::size_t parallelWorkers = 4;
        std::printf("META,%s,%u,%zu\n", build, std::thread::hardware_concurrency(),
                    parallelWorkers);
        id<MTLDevice> const device = MTLCreateSystemDefaultDevice();
        const char * const deviceName = device.name.UTF8String;
        std::printf("DEVICE,%s,%llu\n", deviceName == nullptr ? "unavailable" : deviceName,
                    static_cast<unsigned long long>(device.registryID));
        std::printf("PASSES_HEADER,size,workers,substeps,stable_ms,surface_ms,pressure_ms,"
                    "damping_ms,flux_ms,limiter_scale_ms,flux_limit_ms,continuity_ms,cleanup_ms,"
                    "dry_velocity_ms,validation_ms,diagnostics_ms,total_substep_ms\n");
        for (const std::size_t size : {16UL, 32UL, 128UL, 512UL}) {
            const SampleSummary serial = benchmarkSolver(size, 1);
            const SampleSummary parallel = benchmarkSolver(size, parallelWorkers);
            SimulationState state = makeState(size);
            SolverConfiguration configuration;
            configuration.workerCount = 1;
            const WeakNonlinearSolver solver(state, configuration);
            const SampleSummary snapshot = benchmarkSnapshot(size);
            const double speedup = serial.medianMilliseconds / parallel.medianMilliseconds;
            const std::size_t snapshotBytes = size * size * (5 * sizeof(float) + sizeof(std::uint8_t));
            std::printf(
                "SOLVER,%zu,%zu,%.9f,%.9f,%.9f,%.9f,%.6f,%zu,%zu,%.9f,%.9f\n",
                size, iterationCount(size), serial.medianMilliseconds,
                serial.medianAbsoluteDeviationMilliseconds, parallel.medianMilliseconds,
                parallel.medianAbsoluteDeviationMilliseconds, speedup,
                solver.estimatedFieldStorageBytes(), snapshotBytes,
                snapshot.medianMilliseconds, snapshot.medianAbsoluteDeviationMilliseconds);
            profileSolver(size, 1);
            profileSolver(size, parallelWorkers);
        }
        std::printf("ACCEL_HEADER,width,height,backend,resolved,total_step_ms,stable_ms,"
                    "substep_ms,readback_ms,snapshot_wall_ms,direct_handoff_ms,"
                    "cold_compile_ms,state_allocations,speedup_vs_cpu\n");
        constexpr std::array shapes{
            std::pair{64UL, 64UL}, std::pair{128UL, 128UL},
            std::pair{256UL, 256UL}, std::pair{384UL, 384UL},
            std::pair{512UL, 512UL}, std::pair{256UL, 512UL},
        };
        for (const auto [width, height] : shapes) {
            const AcceleratedSummary cpu = benchmarkBridge(
                width, height, WSRequestedSimulationBackendCPUReference);
            const AcceleratedSummary metal = benchmarkBridge(
                width, height, WSRequestedSimulationBackendMetalGPU);
            const AcceleratedSummary automatic = benchmarkBridge(
                width, height, WSRequestedSimulationBackendAutomaticAccelerated);
            const double speedup = cpu.totalStep.medianMilliseconds /
                                   metal.totalStep.medianMilliseconds;
            const double automaticSpeedup = cpu.totalStep.medianMilliseconds /
                                            automatic.totalStep.medianMilliseconds;
            std::printf("ACCEL,%zu,%zu,CPU,%ld,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%zu,1.000000\n",
                        width, height, static_cast<long>(cpu.resolvedBackend),
                        cpu.totalStep.medianMilliseconds,
                        cpu.stableReduction.medianMilliseconds,
                        cpu.substepCompute.medianMilliseconds,
                        cpu.snapshotReadback.medianMilliseconds,
                        cpu.snapshotWall.medianMilliseconds,
                        cpu.directBufferHandoff.medianMilliseconds,
                        cpu.coldGraphCompileMilliseconds,
                        cpu.stateSizedAllocationCount);
            std::printf("ACCEL,%zu,%zu,Metal,%ld,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%zu,%.6f\n",
                        width, height, static_cast<long>(metal.resolvedBackend),
                        metal.totalStep.medianMilliseconds,
                        metal.stableReduction.medianMilliseconds,
                        metal.substepCompute.medianMilliseconds,
                        metal.snapshotReadback.medianMilliseconds,
                        metal.snapshotWall.medianMilliseconds,
                        metal.directBufferHandoff.medianMilliseconds,
                        metal.coldGraphCompileMilliseconds,
                        metal.stateSizedAllocationCount, speedup);
            std::printf("ACCEL,%zu,%zu,Automatic,%ld,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%zu,%.6f\n",
                        width, height, static_cast<long>(automatic.resolvedBackend),
                        automatic.totalStep.medianMilliseconds,
                        automatic.stableReduction.medianMilliseconds,
                        automatic.substepCompute.medianMilliseconds,
                        automatic.snapshotReadback.medianMilliseconds,
                        automatic.snapshotWall.medianMilliseconds,
                        automatic.directBufferHandoff.medianMilliseconds,
                        automatic.coldGraphCompileMilliseconds,
                        automatic.stateSizedAllocationCount, automaticSpeedup);
        }
    }
    return 0;
}
