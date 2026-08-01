#import <Foundation/Foundation.h>

#import "../TideSandbox/Bridge/WaterEngineBridge.hh"

#include "../TideSandbox/Engine/SimulationState.hh"
#include "../TideSandbox/Engine/WeakNonlinearSolver.hh"

#include <algorithm>
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
    if (![bridge loadWidth:size height:size domainWidth:domainSize domainHeight:domainSize
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
    }
    return 0;
}
