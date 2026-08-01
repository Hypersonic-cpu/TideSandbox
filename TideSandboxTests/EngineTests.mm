#import <XCTest/XCTest.h>

#include "../TideSandbox/Accelerated/MetalGPUBackend.hh"
#include "../TideSandbox/Accelerated/MPSGraphAutomaticBackend.hh"
#include "../TideSandbox/Engine/Grid.hh"
#include "../TideSandbox/Engine/SimulationState.hh"
#include "../TideSandbox/Engine/TerrainEdit.hh"
#include "../TideSandbox/Engine/WeakNonlinearSolver.hh"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <numeric>
#include <numbers>
#include <span>
#include <vector>

using namespace tide::swe;
using tide::accelerated::BackendSnapshot;
using tide::accelerated::BackendState;
using tide::accelerated::MetalGPUBackend;
using tide::accelerated::MPSGraphAutomaticBackend;

namespace {

[[nodiscard]] SimulationState makeState(std::size_t width, std::size_t height,
                                        double perturbation = 0.0) {
    const GridGeometry geometry{width, height, static_cast<double>(width),
                                static_cast<double>(height)};
    const std::vector<double> bed(width * height, 0.0);
    std::vector<double> depth(width * height, 1.0);
    depth[(height / 2) * width + width / 2] += perturbation;
    SimulationState state;
    const bool initialized = state.initializeDepth(geometry, bed, depth);
    assert(initialized);
    return state;
}

[[nodiscard]] SimulationState makeUnevenLake(std::size_t size) {
    const GridGeometry geometry{size, size, static_cast<double>(size),
                                static_cast<double>(size)};
    std::vector<double> bed(size * size);
    for (std::size_t row = 0; row < size; ++row) {
        for (std::size_t column = 0; column < size; ++column) {
            bed[row * size + column] = 0.15 * std::sin(static_cast<double>(column) * 0.17) +
                                       0.1 * std::cos(static_cast<double>(row) * 0.11);
        }
    }
    SimulationState state;
    const bool initialized = state.initializeLevelLake(geometry, bed, 2.0);
    assert(initialized);
    return state;
}

[[nodiscard]] SimulationState makeUnevenPerturbation(std::size_t size) {
    const GridGeometry geometry{size, size, static_cast<double>(size),
                                static_cast<double>(size)};
    std::vector<double> bed(size * size);
    std::vector<double> depth(size * size);
    for (std::size_t row = 0; row < size; ++row) {
        for (std::size_t column = 0; column < size; ++column) {
            const std::size_t index = row * size + column;
            bed[index] = 0.1 * std::sin(static_cast<double>(column) * 0.17) *
                         std::cos(static_cast<double>(row) * 0.13);
            depth[index] = 2.0 - bed[index];
        }
    }
    depth[(size / 2) * size + size / 2] += 0.2;
    SimulationState state;
    const bool initialized = state.initializeDepth(geometry, bed, depth);
    assert(initialized);
    return state;
}

[[nodiscard]] SimulationState makeMovableShoreline(const std::size_t size) {
    const GridGeometry geometry{size, size, static_cast<double>(size),
                                static_cast<double>(size)};
    std::vector<double> bed(size * size);
    std::vector<double> depth(size * size);
    for (std::size_t row = 0; row < size; ++row) {
        const double y = (static_cast<double>(row) + 0.5) / static_cast<double>(size);
        for (std::size_t column = 0; column < size; ++column) {
            const double x = (static_cast<double>(column) + 0.5) /
                             static_cast<double>(size);
            const std::size_t index = row * size + column;
            bed[index] = 0.45 + 1.10 * x + 0.04 * std::sin(6.0 * std::numbers::pi * y);
            const double pulseX = (x - 0.36) / 0.07;
            const double pulseY = (y - 0.52) / 0.18;
            const double surface = 1.0 + 0.12 * std::exp(-(pulseX * pulseX + pulseY * pulseY));
            depth[index] = std::max(surface - bed[index], 0.0);
        }
    }
    SimulationState state;
    const bool initialized = state.initializeDepth(geometry, bed, depth);
    assert(initialized);
    return state;
}

[[nodiscard]] SimulationState makeCoastalWaveState(const bool hasInitialStep) {
    constexpr std::size_t size = 512;
    constexpr double baseSurface = 1.20;
    const GridGeometry geometry{size, size, static_cast<double>(size),
                                static_cast<double>(size)};
    std::vector<double> bed(size * size);
    std::vector<double> depth(size * size);
    for (std::size_t row = 0; row < size; ++row) {
        const double y = (static_cast<double>(row) + 0.5) / static_cast<double>(size);
        for (std::size_t column = 0; column < size; ++column) {
            const double x = (static_cast<double>(column) + 0.5) /
                             static_cast<double>(size);
            const double coastalSlope = -1.25 + 3.10 * x;
            const double channelCoordinate = (y - 0.52) / 0.065;
            const double channel = 0.95 * std::exp(-channelCoordinate * channelCoordinate);
            const double sandbarCoordinate = (x - 0.64) / 0.055;
            const double sandbar = 0.45 * std::exp(-sandbarCoordinate * sandbarCoordinate) *
                (0.65 + 0.35 * std::cos(6.0 * std::numbers::pi * y));
            const double shoals = 0.12 * std::sin(14.0 * std::numbers::pi * y) *
                                  (0.25 + 0.75 * x);
            const double rawBed = coastalSlope - channel + sandbar + shoals;
            double normalizedStep = (x - 0.79) / 0.02;
            normalizedStep = std::clamp(normalizedStep, 0.0, 1.0);
            const double smoothStep = normalizedStep * normalizedStep *
                                      (3.0 - 2.0 * normalizedStep);
            const double surface = baseSurface + (hasInitialStep ? 0.55 * smoothStep : 0.0);
            const std::size_t index = row * size + column;
            // Built-in packages persist Float32 fields, so quantize this fixture at the same
            // boundary before comparing the Float64 oracle with an accelerated backend.
            const float storedBed = static_cast<float>(rawBed);
            const float storedDepth = static_cast<float>(
                std::max(surface - static_cast<double>(storedBed), 0.0));
            bed[index] = storedBed;
            depth[index] = storedDepth;
        }
    }
    BoundaryConfiguration boundaries;
    if (!hasInitialStep) {
        boundaries.right = {
            .type = BoundaryType::drivenHeight,
            .driven = {
                .meanSurfaceElevation = baseSurface,
                .amplitude = 0.25,
                .periodSeconds = 8.0,
                .phaseRadians = 0.0,
                .rampSeconds = 2.0,
            },
        };
    }
    SimulationState state;
    const bool initialized = state.initializeDepth(geometry, bed, depth, {}, boundaries);
    assert(initialized);
    return state;
}

[[nodiscard]] double volume(const SimulationState& state) noexcept {
    double depthSum = 0.0;
    for (const double depth : state.waterDepth().values()) {
        depthSum += depth;
    }
    return depthSum * state.geometry().dx() * state.geometry().dy();
}

[[nodiscard]] double volume(const BackendState& state) noexcept {
    double depthSum = 0.0;
    for (const double depth : state.waterDepth) { depthSum += depth; }
    return depthSum * state.geometry.dx() * state.geometry.dy();
}

[[nodiscard]] double maximumDifference(std::span<const double> first,
                                       std::span<const double> second) noexcept {
    assert(first.size() == second.size());
    double result = 0.0;
    for (std::size_t index = 0; index < first.size(); ++index) {
        result = std::max(result, std::abs(first[index] - second[index]));
    }
    return result;
}

[[nodiscard]] double meanAbsoluteDifference(std::span<const double> first,
                                            std::span<const double> second) noexcept {
    assert(first.size() == second.size());
    double sum = 0.0;
    for (std::size_t index = 0; index < first.size(); ++index) {
        sum += std::abs(first[index] - second[index]);
    }
    return sum / static_cast<double>(first.size());
}

[[nodiscard]] double maximumMagnitude(const std::span<const double> values) noexcept {
    double result = 0.0;
    for (const double value : values) {
        result = std::max(result, std::abs(value));
    }
    return result;
}

// Higham's gamma(n) bounds accumulated rounding for n Float32 operations when n*epsilon < 1.
// It gives each parity case a scale- and work-derived ceiling instead of unrelated literals.
[[nodiscard]] double floatForwardErrorBound(const std::size_t stepCount,
                                            const double valueScale,
                                            const std::size_t operationsPerStep = 32) noexcept {
    const double epsilon = std::numeric_limits<float>::epsilon();
    const double operationCount = static_cast<double>(64 + stepCount * operationsPerStep);
    const double accumulated = operationCount * epsilon;
    assert(accumulated < 1.0);
    return std::max(valueScale, 1.0) * accumulated / (1.0 - accumulated);
}

struct WetMaskDifference final {
    std::size_t count = 0;
    double largestDisputedDepth = 0.0;
};

[[nodiscard]] WetMaskDifference wetMaskDifference(
    const std::span<const double> reference,
    const std::span<const double> accelerated,
    const double minimumWetDepth
) noexcept {
    assert(reference.size() == accelerated.size());
    WetMaskDifference result;
    for (std::size_t index = 0; index < reference.size(); ++index) {
        const bool firstWet = reference[index] > minimumWetDepth;
        const bool secondWet = accelerated[index] > minimumWetDepth;
        if (firstWet == secondWet) { continue; }
        ++result.count;
        result.largestDisputedDepth = std::max(
            result.largestDisputedDepth,
            std::max(std::abs(reference[index]), std::abs(accelerated[index])));
    }
    return result;
}

[[nodiscard]] double surfaceProbe(const SimulationState& state,
                                  const std::size_t column) noexcept {
    const std::size_t width = state.geometry().width;
    const std::size_t height = state.geometry().height;
    assert(column < width);
    double sum = 0.0;
    for (std::size_t row = 0; row < height; ++row) {
        sum += state.bedElevation()(column, row) + state.waterDepth()(column, row);
    }
    return sum / static_cast<double>(height);
}

[[nodiscard]] double hannPeriodogramAmplitude(const std::span<const double> values,
                                               const std::size_t frequencyBin) noexcept {
    assert(values.size() > 1);
    double cosine = 0.0;
    double sine = 0.0;
    double weightSum = 0.0;
    for (std::size_t index = 0; index < values.size(); ++index) {
        const double phase = 2.0 * std::numbers::pi * static_cast<double>(frequencyBin * index) /
                             static_cast<double>(values.size());
        const double window = 0.5 - 0.5 * std::cos(
            2.0 * std::numbers::pi * static_cast<double>(index) /
            static_cast<double>(values.size() - 1));
        cosine += window * values[index] * std::cos(phase);
        sine += window * values[index] * std::sin(phase);
        weightSum += window;
    }
    return 2.0 * std::hypot(cosine, sine) / weightSum;
}

[[nodiscard]] bool allFinite(std::span<const double> values) noexcept {
    return std::ranges::all_of(values, [](const double value) { return std::isfinite(value); });
}

[[nodiscard]] double conservationTolerance(const SimulationState& state) noexcept {
    const double scale = std::max(volume(state), 1.0);
    const double operationCount = static_cast<double>(state.waterDepth().size());
    return 64.0 * std::numeric_limits<double>::epsilon() * operationCount * scale;
}

[[nodiscard]] bool restoreVelocities(SimulationState& state,
                                     const std::span<const double> velX,
                                     const std::span<const double> velY) {
    const std::vector<double> bed(state.bedElevation().values().begin(),
                                  state.bedElevation().values().end());
    const std::vector<double> depth(state.waterDepth().values().begin(),
                                    state.waterDepth().values().end());
    return state.restoreCurrentState(bed, depth, velX, velY, state.time(),
                                     state.cumulativeBoundaryVolume(),
                                     state.accumulatedEditWaterVolume());
}

[[nodiscard]] std::uint64_t fingerprint(const std::span<const double> values) noexcept {
    std::uint64_t hash = 1'469'598'103'934'665'603ULL;
    for (const double value : values) {
        const std::uint64_t bits = std::bit_cast<std::uint64_t>(value);
        for (unsigned int byte = 0; byte < 8; ++byte) {
            hash ^= (bits >> (byte * 8U)) & 0xFFU;
            hash *= 1'099'511'628'211ULL;
        }
    }
    return hash;
}

[[nodiscard]] SimulationState makeGoldenState(const std::size_t width,
                                              const std::size_t height) {
    const GridGeometry geometry{width, height, static_cast<double>(width),
                                static_cast<double>(height)};
    std::vector<double> bed(width * height);
    std::vector<double> depth(width * height);
    for (std::size_t row = 0; row < height; ++row) {
        for (std::size_t column = 0; column < width; ++column) {
            const std::size_t index = row * width + column;
            const auto pattern = static_cast<std::int64_t>((17 * column + 13 * row) % 11) - 5;
            bed[index] = static_cast<double>(pattern) * 0.01;
            depth[index] = 2.0 - bed[index];
        }
    }
    depth[(height / 2) * width + width / 2] += 0.125;
    SimulationState state;
    const bool initialized = state.initializeDepth(geometry, bed, depth);
    assert(initialized);
    return state;
}

} // namespace

@interface EngineTests : XCTestCase
@end

@implementation EngineTests

- (void)testFieldLayoutAndNonSquareInitialization {
    CellField cells(7, 5);
    const FaceField velX(8, 5);
    const FaceField velY(7, 6);
    XCTAssertEqual(cells.width(), 7UL);
    XCTAssertEqual(cells.height(), 5UL);
    XCTAssertEqual(velX.size(), 40UL);
    XCTAssertEqual(velY.size(), 42UL);
    cells(3, 2) = 9.0;
    XCTAssertEqual(cells.values()[17], 9.0);

    SimulationState state;
    const GridGeometry valid{16, 9, 8.0, 4.5};
    const std::vector<double> correctBed(16 * 9, 0.0);
    const std::vector<double> shortBed(16 * 9 - 1, 0.0);
    XCTAssertFalse(state.initializeLevelLake(valid, shortBed, 1.0));
    XCTAssertTrue(state.initializeLevelLake(valid, correctBed, 1.0));
    XCTAssertEqualWithAccuracy(state.geometry().dx(), 0.5, 0.0);
    XCTAssertEqualWithAccuracy(state.geometry().dy(), 0.5, 0.0);
    XCTAssertEqual(state.velX().width(), 17UL);
    XCTAssertEqual(state.velY().height(), 10UL);

    const GridGeometry secondGeometry{32, 17, 16.0, 8.5};
    const std::vector<double> secondBed(32 * 17, 0.25);
    XCTAssertTrue(state.initializeLevelLake(secondGeometry, secondBed, 1.0));
    XCTAssertEqual(state.waterDepth().size(), 32UL * 17UL);
    state.reset();
    XCTAssertEqualWithAccuracy(state.waterDepth()(31, 16), 0.75, 0.0);
}

- (void)testLakeAtRestFlatAndUneven {
    for (const std::size_t size : {16UL, 32UL, 128UL}) {
        for (const bool uneven : {false, true}) {
            SimulationState state = uneven ? makeUnevenLake(size) : makeState(size, size);
            SolverConfiguration configuration;
            configuration.workerCount = 4;
            WeakNonlinearSolver solver(state, configuration);
            XCTAssertEqual(solver.advance(0.25), StepStatus::success);
            XCTAssertLessThan(solver.diagnostics().maximumAbsVelX, 1.0e-12);
            XCTAssertLessThan(solver.diagnostics().maximumAbsVelY, 1.0e-12);
            XCTAssertTrue(solver.diagnostics().finite);
        }
    }
}

- (void)testMetalBackendPreservesRestStateAndPersistentAllocationCount {
    constexpr std::size_t size = 16;
    const SimulationState initialState = makeUnevenLake(size);
    const BackendState initial = tide::accelerated::exportState(initialState);
    SolverConfiguration configuration;
    configuration.workerCount = 1;
    MetalGPUBackend backend;
    std::string failureReason;
    if (!backend.load(initial, configuration, failureReason)) {
        XCTFail(@"%s", failureReason.c_str());
        return;
    }
    const std::size_t allocationCount = backend.stateSizedAllocationCount();
    XCTAssertGreaterThan(allocationCount, 0UL);
    for (std::size_t step = 0; step < 20; ++step) {
        XCTAssertEqual(backend.stepOnce(0.001, failureReason), StepStatus::success,
                       @"%s", failureReason.c_str());
        XCTAssertEqual(backend.stateSizedAllocationCount(), allocationCount);
    }
    for (std::size_t snapshotIndex = 0; snapshotIndex < 6; ++snapshotIndex) {
        const auto snapshot = backend.makeSnapshot(failureReason);
        XCTAssertEqual(snapshot.waterDepth.size(), size * size);
        XCTAssertEqual(snapshot.surfaceElevation.size(), size * size);
        XCTAssertEqual(snapshot.wetMask.size(), size * size);
        XCTAssertEqual(backend.stateSizedAllocationCount(), allocationCount,
                       @"snapshot staging must use its warmed-up persistent ring");
    }
    const BackendState result = backend.synchronizeToHost(failureReason);
    XCTAssertTrue(result.isValid(), @"%s", failureReason.c_str());
    XCTAssertLessThan(maximumDifference(result.waterDepth, initial.waterDepth), 1.0e-6);
    XCTAssertLessThan(maximumDifference(result.velX, initial.velX), 1.0e-6);
    XCTAssertLessThan(maximumDifference(result.velY, initial.velY), 1.0e-6);
    XCTAssertEqualWithAccuracy(result.time, 0.02, 1.0e-12);
    XCTAssertTrue(backend.diagnostics().finite);
}

- (void)testMetalBackendTracksCPUReferenceForSmallPerturbation {
    constexpr std::size_t size = 32;
    constexpr std::size_t stepCount = 100;
    constexpr double timeStep = 0.0005;
    SimulationState cpuState = makeState(size, size, 0.2);
    SolverConfiguration configuration;
    configuration.workerCount = 1;
    configuration.minimumWetDepth = 0.0;
    configuration.linearDamping = 0.02;
    WeakNonlinearSolver cpu(cpuState, configuration);

    MetalGPUBackend gpu;
    std::string failureReason;
    if (!gpu.load(tide::accelerated::exportState(cpuState), configuration,
                  failureReason)) {
        XCTFail(@"%s", failureReason.c_str());
        return;
    }
    for (std::size_t step = 0; step < stepCount; ++step) {
        XCTAssertEqual(cpu.stepOnce(timeStep), StepStatus::success);
        XCTAssertEqual(gpu.stepOnce(timeStep, failureReason), StepStatus::success,
                       @"%s", failureReason.c_str());
    }
    const BackendState gpuState = gpu.synchronizeToHost(failureReason);
    XCTAssertTrue(gpuState.isValid(), @"%s", failureReason.c_str());
    XCTAssertLessThan(maximumDifference(gpuState.waterDepth,
                                        cpuState.waterDepth().values()), 2.0e-5);
    XCTAssertLessThan(maximumDifference(gpuState.velX, cpuState.velX().values()), 2.0e-5);
    XCTAssertLessThan(maximumDifference(gpuState.velY, cpuState.velY().values()), 2.0e-5);
    XCTAssertEqualWithAccuracy(gpuState.time, cpuState.time(), 1.0e-12);
    XCTAssertEqualWithAccuracy(gpu.diagnostics().totalVolume, cpu.diagnostics().totalVolume,
                               2.0e-4);
}

- (void)testMPSGraphBackendExecutesCompleteReflectiveSolverWithinFloat32Tolerance {
    constexpr std::size_t size = 16;
    constexpr std::size_t stepCount = 40;
    constexpr double timeStep = 0.0005;
    SimulationState cpuState = makeUnevenPerturbation(size);
    SolverConfiguration configuration;
    configuration.workerCount = 1;
    configuration.minimumWetDepth = 0.0;
    configuration.linearDamping = 0.02;
    WeakNonlinearSolver cpu(cpuState, configuration);
    MPSGraphAutomaticBackend accelerated;
    std::string failureReason;
    XCTAssertTrue(accelerated.load(tide::accelerated::exportState(cpuState), configuration,
                                   failureReason), @"%s", failureReason.c_str());
    const std::size_t allocationCount = accelerated.stateSizedAllocationCount();
    XCTAssertGreaterThan(allocationCount, 0UL);
    const auto initialFieldBuffers = accelerated.fieldBufferSnapshot();
    XCTAssertNotEqual(initialFieldBuffers.device, nullptr);
    XCTAssertNotEqual(initialFieldBuffers.bedElevation, nullptr);
    XCTAssertNotEqual(initialFieldBuffers.waterDepth, nullptr);
    for (std::size_t step = 0; step < stepCount; ++step) {
        XCTAssertEqual(cpu.stepOnce(timeStep), StepStatus::success);
        XCTAssertEqual(accelerated.stepOnce(timeStep, failureReason), StepStatus::success,
                       @"step %zu: %s", step, failureReason.c_str());
        XCTAssertEqual(accelerated.stateSizedAllocationCount(), allocationCount);
    }
    XCTAssertGreaterThan(accelerated.fieldBufferSnapshot().generation,
                         initialFieldBuffers.generation);
    for (std::size_t snapshotIndex = 0; snapshotIndex < 6; ++snapshotIndex) {
        const BackendSnapshot snapshot = accelerated.makeSnapshot(failureReason);
        XCTAssertEqual(snapshot.waterDepth.size(), size * size);
        XCTAssertEqual(snapshot.surfaceElevation.size(), size * size);
        XCTAssertEqual(snapshot.surfaceDeviation.size(), size * size);
        XCTAssertEqual(snapshot.velocityMagnitude.size(), size * size);
        XCTAssertEqual(snapshot.wetMask.size(), size * size);
        XCTAssertEqual(accelerated.stateSizedAllocationCount(), allocationCount,
                       @"MPSGraph snapshots must reuse the three-slot staging ring");
    }
    const BackendState result = accelerated.synchronizeToHost(failureReason);
    XCTAssertTrue(result.isValid(), @"%s", failureReason.c_str());
    XCTAssertLessThan(meanAbsoluteDifference(result.waterDepth,
                                             cpuState.waterDepth().values()), 3.0e-6);
    XCTAssertLessThan(maximumDifference(result.waterDepth,
                                        cpuState.waterDepth().values()), 8.0e-5);
    XCTAssertLessThan(maximumDifference(result.velX, cpuState.velX().values()), 1.0e-4);
    XCTAssertLessThan(maximumDifference(result.velY, cpuState.velY().values()), 1.0e-4);
    XCTAssertEqualWithAccuracy(result.time, cpuState.time(), 1.0e-12);
    XCTAssertTrue(accelerated.diagnostics().finite);

    MPSGraphAutomaticBackend cacheProbe;
    XCTAssertTrue(cacheProbe.load(tide::accelerated::exportState(makeUnevenPerturbation(size)),
                                  configuration, failureReason), @"%s",
                  failureReason.c_str());
    XCTAssertEqual(cacheProbe.status().graphCompileMilliseconds, 0.0,
                   @"a fixed shape and boundary-type tuple must reuse its compiled graphs");
}

- (void)testMetalBackendTracksCPUForNonSquareDrivenBoundaryWave {
    constexpr std::size_t width = 128;
    constexpr std::size_t height = 64;
    constexpr std::size_t stepCount = 800;
    constexpr double timeStep = 0.005;
    const GridGeometry geometry{width, height, static_cast<double>(width),
                                static_cast<double>(height)};
    const std::vector<double> bed(width * height, 0.0);
    const std::vector<double> depth(width * height, 1.0);
    BoundaryConfiguration boundaries;
    boundaries.right = {
        .type = BoundaryType::drivenHeight,
        .driven = {
            .meanSurfaceElevation = 1.0,
            .amplitude = 0.10,
            .periodSeconds = 4.0,
            .phaseRadians = 0.0,
            .rampSeconds = 1.0,
        },
    };
    SimulationState cpuState;
    XCTAssertTrue(cpuState.initializeDepth(geometry, bed, depth, {}, boundaries));
    SolverConfiguration configuration;
    configuration.workerCount = 1;
    configuration.minimumWetDepth = 1.0e-8;
    configuration.linearDamping = 0.02;
    WeakNonlinearSolver cpu(cpuState, configuration);

    MetalGPUBackend gpu;
    std::string failureReason;
    XCTAssertTrue(gpu.load(tide::accelerated::exportState(cpuState), configuration,
                           failureReason), @"%s", failureReason.c_str());
    const std::size_t allocationCount = gpu.stateSizedAllocationCount();
    for (std::size_t step = 0; step < stepCount; ++step) {
        XCTAssertEqual(cpu.stepOnce(timeStep), StepStatus::success);
        XCTAssertEqual(gpu.stepOnce(timeStep, failureReason), StepStatus::success,
                       @"step %zu: %s", step, failureReason.c_str());
        XCTAssertEqual(gpu.stateSizedAllocationCount(), allocationCount);
    }

    const BackendState accelerated = gpu.synchronizeToHost(failureReason);
    XCTAssertTrue(accelerated.isValid(), @"%s", failureReason.c_str());
    XCTAssertEqualWithAccuracy(accelerated.time, cpuState.time(), 1.0e-12);
    XCTAssertLessThan(meanAbsoluteDifference(accelerated.waterDepth,
                                             cpuState.waterDepth().values()), 2.0e-6);
    XCTAssertLessThan(maximumDifference(accelerated.waterDepth,
                                        cpuState.waterDepth().values()), 8.0e-5);
    XCTAssertLessThan(meanAbsoluteDifference(accelerated.velX,
                                             cpuState.velX().values()), 3.0e-6);
    XCTAssertLessThan(maximumDifference(accelerated.velX,
                                        cpuState.velX().values()), 1.0e-4);
    XCTAssertLessThan(meanAbsoluteDifference(accelerated.velY,
                                             cpuState.velY().values()), 3.0e-6);
    XCTAssertLessThan(maximumDifference(accelerated.velY,
                                        cpuState.velY().values()), 1.0e-4);

    std::size_t wetMaskDifferences = 0;
    for (std::size_t index = 0; index < accelerated.waterDepth.size(); ++index) {
        const bool cpuWet = cpuState.waterDepth().values()[index] >
                            configuration.minimumWetDepth;
        const bool gpuWet = accelerated.waterDepth[index] > configuration.minimumWetDepth;
        wetMaskDifferences += cpuWet != gpuWet;
    }
    XCTAssertEqual(wetMaskDifferences, 0UL);
    for (std::size_t edge = 0; edge < boundaryEdgeCount; ++edge) {
        XCTAssertEqualWithAccuracy(accelerated.cumulativeBoundaryVolume[edge],
                                   cpuState.cumulativeBoundaryVolume()[edge], 3.0e-4);
    }
    // A Float32 tree reduction has O(epsilon * log2(N)) relative summation error.
    const double reductionLevels = std::ceil(std::log2(static_cast<double>(width * height)));
    const double diagnosticReductionTolerance =
        2.0 * std::numeric_limits<float>::epsilon() * reductionLevels *
        cpu.diagnostics().totalVolume;
    XCTAssertEqualWithAccuracy(gpu.diagnostics().totalVolume,
                               cpu.diagnostics().totalVolume,
                               diagnosticReductionTolerance);
    XCTAssertLessThanOrEqual(std::abs(gpu.diagnostics().accountingError),
                             diagnosticReductionTolerance);
    XCTAssertTrue(gpu.diagnostics().finite);
}

- (void)testMPSGraphTracksCPUForNonSquareDrivenBoundaryWithDynamicForcing {
    constexpr std::size_t width = 64;
    constexpr std::size_t height = 32;
    constexpr std::size_t stepCount = 160;
    constexpr double timeStep = 0.005;
    const GridGeometry geometry{width, height, static_cast<double>(width),
                                static_cast<double>(height)};
    const std::vector<double> bed(width * height, 0.0);
    const std::vector<double> depth(width * height, 1.0);
    BoundaryConfiguration boundaries;
    boundaries.right = {
        .type = BoundaryType::drivenHeight,
        .driven = {
            .meanSurfaceElevation = 1.0,
            .amplitude = 0.03,
            .periodSeconds = 0.5,
            .phaseRadians = 0.0,
            .rampSeconds = 0.1,
        },
    };
    SimulationState cpuState;
    XCTAssertTrue(cpuState.initializeDepth(geometry, bed, depth, {}, boundaries));
    SolverConfiguration configuration;
    configuration.workerCount = 1;
    configuration.minimumWetDepth = 1.0e-8;
    configuration.linearDamping = 0.02;
    WeakNonlinearSolver cpu(cpuState, configuration);

    MPSGraphAutomaticBackend automatic;
    std::string failureReason;
    XCTAssertTrue(automatic.load(tide::accelerated::exportState(cpuState), configuration,
                                 failureReason), @"%s", failureReason.c_str());
    const std::size_t allocationCount = automatic.stateSizedAllocationCount();
    bool observedInflow = false;
    bool observedOutflow = false;
    for (std::size_t step = 0; step < stepCount; ++step) {
        XCTAssertEqual(cpu.stepOnce(timeStep), StepStatus::success);
        XCTAssertEqual(automatic.stepOnce(timeStep, failureReason), StepStatus::success,
                       @"step %zu: %s", step, failureReason.c_str());
        XCTAssertEqual(automatic.stateSizedAllocationCount(), allocationCount);
        const double rate = automatic.diagnostics().instantaneousBoundaryOutflowRate[1];
        observedInflow = observedInflow || rate < 0.0;
        observedOutflow = observedOutflow || rate > 0.0;
    }

    const BackendState accelerated = automatic.synchronizeToHost(failureReason);
    XCTAssertTrue(accelerated.isValid(), @"%s", failureReason.c_str());
    XCTAssertEqualWithAccuracy(accelerated.time, cpuState.time(), 1.0e-12);
    const double depthBound = floatForwardErrorBound(
        stepCount, maximumMagnitude(cpuState.waterDepth().values()));
    const double xBound = floatForwardErrorBound(
        stepCount, maximumMagnitude(cpuState.velX().values()));
    const double yBound = floatForwardErrorBound(
        stepCount, maximumMagnitude(cpuState.velY().values()));
    XCTAssertLessThan(meanAbsoluteDifference(accelerated.waterDepth,
                                             cpuState.waterDepth().values()), depthBound);
    XCTAssertLessThan(maximumDifference(accelerated.waterDepth,
                                        cpuState.waterDepth().values()), depthBound);
    XCTAssertLessThan(meanAbsoluteDifference(accelerated.velX,
                                             cpuState.velX().values()), xBound);
    XCTAssertLessThan(maximumDifference(accelerated.velX,
                                        cpuState.velX().values()), xBound);
    XCTAssertLessThan(meanAbsoluteDifference(accelerated.velY,
                                             cpuState.velY().values()), yBound);
    XCTAssertLessThan(maximumDifference(accelerated.velY,
                                        cpuState.velY().values()), yBound);
    for (std::size_t edge = 0; edge < boundaryEdgeCount; ++edge) {
        const double boundaryScale = std::max(
            std::abs(cpuState.cumulativeBoundaryVolume()[edge]), 1.0);
        const double boundaryBound = floatForwardErrorBound(stepCount, boundaryScale, 16);
        XCTAssertEqualWithAccuracy(accelerated.cumulativeBoundaryVolume[edge],
                                   cpuState.cumulativeBoundaryVolume()[edge], boundaryBound);
    }
    XCTAssertTrue(observedInflow,
                  @"the positive reservoir phase must inject through the right face");
    XCTAssertTrue(observedOutflow,
                  @"the negative reservoir phase must remove water through the right face");
    XCTAssertTrue(automatic.diagnostics().finite);
    XCTAssertGreaterThanOrEqual(automatic.diagnostics().minimumDepth, 0.0);
}

- (void)testMetalBackendTracksCPUForMovableShoreline128 {
    constexpr std::size_t size = 128;
    constexpr std::size_t stepCount = 120;
    constexpr double timeStep = 0.01;
    SimulationState cpuState = makeMovableShoreline(size);
    const std::size_t initialWetCellCount = static_cast<std::size_t>(std::ranges::count_if(
        cpuState.waterDepth().values(), [](const double depth) { return depth > 1.0e-8; }));
    SolverConfiguration configuration;
    configuration.workerCount = 1;
    configuration.minimumWetDepth = 1.0e-8;
    configuration.linearDamping = 0.01;
    WeakNonlinearSolver cpu(cpuState, configuration);
    MetalGPUBackend accelerated;
    std::string failureReason;
    XCTAssertTrue(accelerated.load(tide::accelerated::exportState(cpuState), configuration,
                                   failureReason), @"%s", failureReason.c_str());
    const std::size_t allocationCount = accelerated.stateSizedAllocationCount();

    for (std::size_t step = 0; step < stepCount; ++step) {
        XCTAssertEqual(cpu.stepOnce(timeStep), StepStatus::success);
        XCTAssertEqual(accelerated.stepOnce(timeStep, failureReason), StepStatus::success,
                       @"step %zu: %s", step, failureReason.c_str());
        XCTAssertEqual(accelerated.stateSizedAllocationCount(), allocationCount);
    }
    const BackendState result = accelerated.synchronizeToHost(failureReason);
    XCTAssertTrue(result.isValid(), @"%s", failureReason.c_str());
    const double depthBound = floatForwardErrorBound(
        stepCount, maximumMagnitude(cpuState.waterDepth().values()));
    const double xBound = floatForwardErrorBound(
        stepCount, maximumMagnitude(cpuState.velX().values()));
    const double yBound = floatForwardErrorBound(
        stepCount, maximumMagnitude(cpuState.velY().values()));
    XCTAssertLessThan(meanAbsoluteDifference(result.waterDepth,
                                             cpuState.waterDepth().values()), depthBound);
    XCTAssertLessThan(maximumDifference(result.waterDepth,
                                        cpuState.waterDepth().values()), depthBound);
    XCTAssertLessThan(meanAbsoluteDifference(result.velX, cpuState.velX().values()), xBound);
    XCTAssertLessThan(maximumDifference(result.velX, cpuState.velX().values()), xBound);
    XCTAssertLessThan(meanAbsoluteDifference(result.velY, cpuState.velY().values()), yBound);
    XCTAssertLessThan(maximumDifference(result.velY, cpuState.velY().values()), yBound);

    const WetMaskDifference mask = wetMaskDifference(
        cpuState.waterDepth().values(), result.waterDepth,
        configuration.minimumWetDepth);
    XCTAssertLessThanOrEqual(mask.count, size,
                           @"Float32 may move at most one shoreline contour");
    XCTAssertLessThanOrEqual(mask.largestDisputedDepth, depthBound,
                            @"mask disagreements must remain inside the numerical error band");
    XCTAssertNotEqual(cpu.diagnostics().wetCellCount, initialWetCellCount,
                      @"the fixture must actually move its shoreline");
    for (std::size_t edge = 0; edge < boundaryEdgeCount; ++edge) {
        XCTAssertEqual(result.cumulativeBoundaryVolume[edge], 0.0);
        XCTAssertEqual(cpuState.cumulativeBoundaryVolume()[edge], 0.0);
    }
    const double volumeBound = depthBound * std::sqrt(static_cast<double>(size * size));
    XCTAssertEqualWithAccuracy(volume(result), volume(cpuState), volumeBound);
    XCTAssertTrue(accelerated.diagnostics().finite);
}

- (void)testMetalBackendTracksCPUForBothCoastalWaveScenarios512 {
    constexpr std::size_t size = 512;
    for (const bool hasInitialStep : {true, false}) {
        const std::size_t stepCount = hasInitialStep ? 20 : 100;
        const double timeStep = hasInitialStep ? 0.01 : 0.005;
        SimulationState cpuState = makeCoastalWaveState(hasInitialStep);
        SolverConfiguration configuration;
        configuration.workerCount = 1;
        configuration.minimumWetDepth = 1.0e-8;
        configuration.linearDamping = 0.02;
        WeakNonlinearSolver cpu(cpuState, configuration);
        MetalGPUBackend accelerated;
        std::string failureReason;
        XCTAssertTrue(accelerated.load(tide::accelerated::exportState(cpuState), configuration,
                                       failureReason), @"%s", failureReason.c_str());
        const std::size_t allocationCount = accelerated.stateSizedAllocationCount();
        for (std::size_t step = 0; step < stepCount; ++step) {
            XCTAssertEqual(cpu.stepOnce(timeStep), StepStatus::success);
            XCTAssertEqual(accelerated.stepOnce(timeStep, failureReason), StepStatus::success,
                           @"scenario=%d step=%zu: %s", hasInitialStep, step,
                           failureReason.c_str());
            XCTAssertEqual(accelerated.stateSizedAllocationCount(), allocationCount);
        }
        const BackendState result = accelerated.synchronizeToHost(failureReason);
        XCTAssertTrue(result.isValid(), @"%s", failureReason.c_str());
        const double depthBound = floatForwardErrorBound(
            stepCount, maximumMagnitude(cpuState.waterDepth().values()));
        const double xBound = floatForwardErrorBound(
            stepCount, maximumMagnitude(cpuState.velX().values()));
        const double yBound = floatForwardErrorBound(
            stepCount, maximumMagnitude(cpuState.velY().values()));
        XCTAssertLessThan(meanAbsoluteDifference(result.waterDepth,
                                                 cpuState.waterDepth().values()), depthBound);
        XCTAssertLessThan(maximumDifference(result.waterDepth,
                                            cpuState.waterDepth().values()), depthBound);
        XCTAssertLessThan(meanAbsoluteDifference(result.velX,
                                                 cpuState.velX().values()), xBound);
        XCTAssertLessThan(maximumDifference(result.velX,
                                            cpuState.velX().values()), xBound);
        XCTAssertLessThan(meanAbsoluteDifference(result.velY,
                                                 cpuState.velY().values()), yBound);
        XCTAssertLessThan(maximumDifference(result.velY,
                                            cpuState.velY().values()), yBound);
        const WetMaskDifference mask = wetMaskDifference(
            cpuState.waterDepth().values(), result.waterDepth,
            configuration.minimumWetDepth);
        XCTAssertLessThanOrEqual(mask.count, size,
                               @"Float32 may move at most one 512-cell shoreline contour");
        XCTAssertLessThanOrEqual(mask.largestDisputedDepth, depthBound);

        const double reductionLevels = std::ceil(std::log2(static_cast<double>(size * size)));
        const double reductionBound = 2.0 * std::numeric_limits<float>::epsilon() *
            reductionLevels * std::max(volume(cpuState), 1.0);
        const double stateSummationBound = depthBound * std::sqrt(
            static_cast<double>(size * size));
        XCTAssertEqualWithAccuracy(volume(result), volume(cpuState),
                                   reductionBound + stateSummationBound);
        for (std::size_t edge = 0; edge < boundaryEdgeCount; ++edge) {
            const double boundaryScale = std::max(
                std::abs(cpuState.cumulativeBoundaryVolume()[edge]), 1.0);
            const double boundaryBound = floatForwardErrorBound(
                stepCount, boundaryScale, 16);
            XCTAssertEqualWithAccuracy(result.cumulativeBoundaryVolume[edge],
                                       cpuState.cumulativeBoundaryVolume()[edge],
                                       boundaryBound);
        }
        if (hasInitialStep) {
            for (const double boundaryVolume : result.cumulativeBoundaryVolume) {
                XCTAssertEqual(boundaryVolume, 0.0);
            }
        } else {
            XCTAssertLessThan(cpuState.cumulativeBoundaryVolume()[1], 0.0,
                              @"the rising right reservoir must inject water through its face");
            XCTAssertLessThan(result.cumulativeBoundaryVolume[1], 0.0);
        }
        XCTAssertTrue(cpu.diagnostics().finite);
        XCTAssertTrue(accelerated.diagnostics().finite);
        XCTAssertGreaterThanOrEqual(accelerated.diagnostics().minimumDepth, 0.0);
    }
}

- (void)testDrivenWaveArrivalAndDominantPeriodMatchBoundaryForcing {
    constexpr std::size_t width = 128;
    constexpr std::size_t height = 64;
    constexpr double domainWidth = 32.0;
    constexpr double domainHeight = 16.0;
    constexpr double forcingAmplitude = 0.10;
    constexpr double forcingPeriod = 4.0;
    constexpr double timeStep = 0.01;
    constexpr std::size_t stepCount = 1'200;
    const GridGeometry geometry{width, height, domainWidth, domainHeight};
    const std::vector<double> bed(width * height, 0.0);
    const std::vector<double> depth(width * height, 1.0);
    BoundaryConfiguration boundaries;
    boundaries.right = {
        .type = BoundaryType::drivenHeight,
        .driven = {
            .meanSurfaceElevation = 1.0,
            .amplitude = forcingAmplitude,
            .periodSeconds = forcingPeriod,
            .phaseRadians = 0.0,
            .rampSeconds = 1.0,
        },
    };
    SimulationState state;
    XCTAssertTrue(state.initializeDepth(geometry, bed, depth, {}, boundaries));
    SolverConfiguration configuration;
    configuration.workerCount = 4;
    configuration.minimumWetDepth = 1.0e-8;
    configuration.linearDamping = 0.02;
    WeakNonlinearSolver solver(state, configuration);

    constexpr double responseThreshold = forcingAmplitude * 0.005;
    double firstNearRightResponse = std::numeric_limits<double>::infinity();
    double firstNearLeftResponse = std::numeric_limits<double>::infinity();
    std::vector<double> spectralWindow;
    spectralWindow.reserve(800);
    for (std::size_t step = 0; step < stepCount; ++step) {
        XCTAssertEqual(solver.stepOnce(timeStep), StepStatus::success);
        const double nearRight = surfaceProbe(state, width - 8) - 1.0;
        const double nearLeft = surfaceProbe(state, 8) - 1.0;
        if (!std::isfinite(firstNearRightResponse) &&
            std::abs(nearRight) >= responseThreshold) {
            firstNearRightResponse = state.time();
        }
        if (!std::isfinite(firstNearLeftResponse) &&
            std::abs(nearLeft) >= responseThreshold) {
            firstNearLeftResponse = state.time();
        }
        if (state.time() >= forcingPeriod) {
            spectralWindow.push_back(nearRight);
        }
    }
    XCTAssertTrue(std::isfinite(firstNearRightResponse));
    XCTAssertTrue(std::isfinite(firstNearLeftResponse));
    XCTAssertLessThan(firstNearRightResponse, firstNearLeftResponse,
                      @"a causal wave must reach the near-boundary probe first");

    const double signalMean = std::reduce(spectralWindow.begin(), spectralWindow.end()) /
                              static_cast<double>(spectralWindow.size());
    for (double& value : spectralWindow) { value -= signalMean; }
    std::size_t dominantBin = 0;
    double dominantAmplitude = 0.0;
    for (std::size_t bin = 1; bin <= 8; ++bin) {
        const double amplitude = hannPeriodogramAmplitude(spectralWindow, bin);
        if (amplitude > dominantAmplitude) {
            dominantAmplitude = amplitude;
            dominantBin = bin;
        }
    }
    const double measuredPeriod = static_cast<double>(spectralWindow.size()) * timeStep /
                                  static_cast<double>(dominantBin);
    XCTAssertEqual(dominantBin, 2UL,
                   @"two forcing cycles occupy the post-ramp eight-second spectrum");
    XCTAssertEqualWithAccuracy(measuredPeriod, forcingPeriod, 2.0 * timeStep);
    XCTAssertGreaterThan(dominantAmplitude, forcingAmplitude * 0.5);

    double waveEnergy = 0.0;
    for (std::size_t index = 0; index < state.waterDepth().size(); ++index) {
        const double surface = state.bedElevation().values()[index] +
                               state.waterDepth().values()[index];
        waveEnergy += (surface - 1.0) * (surface - 1.0);
    }
    for (const double velocity : state.velX().values()) { waveEnergy += velocity * velocity; }
    for (const double velocity : state.velY().values()) { waveEnergy += velocity * velocity; }
    XCTAssertTrue(std::isfinite(waveEnergy));
    XCTAssertGreaterThan(waveEnergy, 0.0);
    XCTAssertTrue(allFinite(state.waterDepth().values()));
    XCTAssertTrue(allFinite(state.velX().values()));
    XCTAssertTrue(allFinite(state.velY().values()));
    XCTAssertGreaterThanOrEqual(solver.diagnostics().minimumDepth, 0.0);
    XCTAssertLessThanOrEqual(std::abs(solver.diagnostics().accountingError),
                             conservationTolerance(state));
}

- (void)testCoastChannel512InitialStepMovesDisturbanceLeft {
    constexpr std::size_t size = 512;
    constexpr double baseSurface = 1.20;
    SimulationState state = makeCoastalWaveState(true);
    const auto anomalyCentroid = [&state]() {
        double weight = 0.0;
        double weightedX = 0.0;
        for (std::size_t row = 0; row < size; ++row) {
            for (std::size_t column = 0; column < size; ++column) {
                const double depth = state.waterDepth()(column, row);
                if (depth <= 1.0e-8) { continue; }
                const double anomaly = std::max(
                    state.bedElevation()(column, row) + depth - baseSurface, 0.0);
                weight += anomaly;
                weightedX += anomaly * (static_cast<double>(column) + 0.5);
            }
        }
        return weightedX / weight;
    };
    const double initialCentroid = anomalyCentroid();
    SolverConfiguration configuration;
    configuration.workerCount = 4;
    configuration.minimumWetDepth = 1.0e-8;
    configuration.linearDamping = 0.02;
    WeakNonlinearSolver solver(state, configuration);
    for (std::size_t frame = 0; frame < 80; ++frame) {
        XCTAssertEqual(solver.advance(0.05), StepStatus::success);
        XCTAssertNotEqual(solver.diagnostics().status, StepStatus::substepLimitReached);
    }
    const double evolvedCentroid = anomalyCentroid();
    XCTAssertLessThan(evolvedCentroid, initialCentroid - 0.1 * state.geometry().dx(),
                      @"the initial right-hand surface step must propagate inland (left)");
    XCTAssertTrue(solver.diagnostics().finite);
    XCTAssertGreaterThanOrEqual(solver.diagnostics().minimumDepth, 0.0);
    XCTAssertTrue(allFinite(state.waterDepth().values()));
    XCTAssertTrue(allFinite(state.velX().values()));
    XCTAssertTrue(allFinite(state.velY().values()));
}

- (void)testDrivenOceanWave512AlternatesBoundaryFlowAndReachesInterior {
    constexpr std::size_t size = 512;
    constexpr double forcingAmplitude = 0.25;
    SimulationState state = makeCoastalWaveState(false);
    const std::vector<double> initialBed(state.bedElevation().values().begin(),
                                         state.bedElevation().values().end());
    const std::vector<double> initialDepth(state.waterDepth().values().begin(),
                                           state.waterDepth().values().end());
    const double initialVolume = volume(state);
    const auto probeDeviation = [&](const std::size_t column) {
        double sum = 0.0;
        std::size_t wetSamples = 0;
        for (std::size_t row = 0; row < size; ++row) {
            const std::size_t index = row * size + column;
            if (initialDepth[index] == 0.0) { continue; }
            sum += state.bedElevation()(column, row) + state.waterDepth()(column, row) -
                   (initialBed[index] + initialDepth[index]);
            ++wetSamples;
        }
        return sum / static_cast<double>(wetSamples);
    };
    SolverConfiguration configuration;
    configuration.workerCount = 4;
    configuration.minimumWetDepth = 1.0e-8;
    configuration.linearDamping = 0.02;
    WeakNonlinearSolver solver(state, configuration);
    double minimumRightOutflowRate = 0.0;
    double maximumRightOutflowRate = 0.0;
    double nearBoundaryResponse = 0.0;
    double interiorResponse = 0.0;
    for (std::size_t frame = 0; frame < 240; ++frame) {
        XCTAssertEqual(solver.advance(0.05), StepStatus::success);
        const double rate = solver.diagnostics().instantaneousBoundaryOutflowRate[1];
        minimumRightOutflowRate = std::min(minimumRightOutflowRate, rate);
        maximumRightOutflowRate = std::max(maximumRightOutflowRate, rate);
        nearBoundaryResponse = std::max(nearBoundaryResponse,
                                        std::abs(probeDeviation(496)));
        interiorResponse = std::max(interiorResponse,
                                    std::abs(probeDeviation(480)));
    }
    XCTAssertLessThan(minimumRightOutflowRate, 0.0,
                      @"negative outward flow proves a driven-reservoir injection phase");
    XCTAssertGreaterThan(maximumRightOutflowRate, 0.0,
                         @"positive outward flow proves a driven-reservoir removal phase");
    XCTAssertGreaterThan(nearBoundaryResponse, forcingAmplitude * 0.1);
    XCTAssertGreaterThan(interiorResponse, forcingAmplitude * 1.0e-5,
                         @"a probe 32 cells inland must respond above numerical noise");
    const double expectedVolume = initialVolume -
        std::reduce(state.cumulativeBoundaryVolume().begin(),
                    state.cumulativeBoundaryVolume().end());
    XCTAssertEqualWithAccuracy(volume(state), expectedVolume,
                               conservationTolerance(state));
    XCTAssertEqualWithAccuracy(solver.diagnostics().accountedExpectedVolume,
                               expectedVolume, conservationTolerance(state));
    XCTAssertTrue(solver.diagnostics().finite);
    XCTAssertGreaterThanOrEqual(solver.diagnostics().minimumDepth, 0.0);
    XCTAssertTrue(allFinite(state.waterDepth().values()));
    XCTAssertTrue(allFinite(state.velX().values()));
    XCTAssertTrue(allFinite(state.velY().values()));
}

- (void)testClosedBoundaryConservationAndFiniteWave {
    for (const std::size_t size : {32UL, 128UL}) {
        for (const bool unevenTerrain : {false, true}) {
            SimulationState state = unevenTerrain ? makeUnevenPerturbation(size)
                                                  : makeState(size, size, 0.2);
            SolverConfiguration configuration;
            configuration.workerCount = 4;
            configuration.minimumWetDepth = 0.0;
            WeakNonlinearSolver solver(state, configuration);
            const double initialVolume = volume(state);
            const double tolerance = conservationTolerance(state);
            for (std::size_t step = 0; step < 100; ++step) {
                XCTAssertEqual(solver.advance(0.01), StepStatus::success);
            }
            XCTAssertEqualWithAccuracy(volume(state), initialVolume, tolerance);
            XCTAssertGreaterThanOrEqual(solver.diagnostics().minimumDepth, 0.0);
            XCTAssertTrue(allFinite(state.waterDepth().values()));
            XCTAssertTrue(allFinite(state.velX().values()));
            XCTAssertTrue(allFinite(state.velY().values()));
        }
    }
}

- (void)testReflectiveBoundariesAndCornersDoNotLeak {
    SimulationState state = makeState(32, 32, 1.0);
    SolverConfiguration configuration;
    configuration.workerCount = 2;
    configuration.minimumWetDepth = 0.0;
    WeakNonlinearSolver solver(state, configuration);
    const double initialVolume = volume(state);
    const double tolerance = conservationTolerance(state);
    for (std::size_t step = 0; step < 200; ++step) {
        XCTAssertEqual(solver.advance(0.01), StepStatus::success);
    }
    for (std::size_t row = 0; row < state.geometry().height; ++row) {
        XCTAssertEqual(state.velX()(0, row), 0.0);
        XCTAssertEqual(state.velX()(state.geometry().width, row), 0.0);
    }
    for (std::size_t column = 0; column < state.geometry().width; ++column) {
        XCTAssertEqual(state.velY()(column, 0), 0.0);
        XCTAssertEqual(state.velY()(column, state.geometry().height), 0.0);
    }
    XCTAssertEqualWithAccuracy(volume(state), initialVolume, tolerance);
    for (const double rate : solver.diagnostics().instantaneousBoundaryOutflowRate) {
        XCTAssertEqual(rate, 0.0);
    }
    for (const double boundaryVolume : solver.diagnostics().cumulativeBoundaryOutwardVolume) {
        XCTAssertEqual(boundaryVolume, 0.0);
    }
    XCTAssertEqualWithAccuracy(solver.diagnostics().accountingError, 0.0, tolerance);
}

- (void)testFreeOpenBoundaryCarriesSignedLimitedFluxAndAccountsVolume {
    constexpr std::size_t width = 32;
    constexpr std::size_t height = 16;
    constexpr double speed = 0.25;
    constexpr double timeStep = 0.01;
    const auto run = [&](const double rightVelocity) {
        SimulationState state = makeState(width, height);
        BoundaryConfiguration boundaries;
        boundaries.right.type = BoundaryType::freeOpen;
        XCTAssertTrue(state.setBoundaryConfiguration(boundaries));

        std::vector<double> velX((width + 1) * height, 0.0);
        const std::vector<double> velY(width * (height + 1), 0.0);
        for (std::size_t row = 0; row < height; ++row) {
            velX[row * (width + 1) + width] = rightVelocity;
        }
        XCTAssertTrue(restoreVelocities(state, velX, velY));

        SolverConfiguration configuration;
        configuration.workerCount = 4;
        configuration.linearDamping = 0.0;
        configuration.minimumWetDepth = 0.0;
        WeakNonlinearSolver solver(state, configuration);
        const double initialVolume = volume(state);
        XCTAssertEqual(solver.stepOnce(timeStep), StepStatus::success);

        const double expectedOutwardVolume = timeStep * static_cast<double>(height) * speed;
        const double signedExpected = std::copysign(expectedOutwardVolume, rightVelocity);
        const Diagnostics& diagnostics = solver.diagnostics();
        XCTAssertEqualWithAccuracy(
            diagnostics.cumulativeBoundaryOutwardVolume[boundaryIndex(BoundaryEdge::right)],
            signedExpected, conservationTolerance(state));
        XCTAssertEqualWithAccuracy(volume(state), initialVolume - signedExpected,
                                   conservationTolerance(state));
        XCTAssertEqualWithAccuracy(diagnostics.accountedExpectedVolume, volume(state),
                                   conservationTolerance(state));
        XCTAssertEqualWithAccuracy(diagnostics.accountingError, 0.0,
                                   conservationTolerance(state));
        XCTAssertEqual(std::signbit(diagnostics.instantaneousBoundaryOutflowRate[
                           boundaryIndex(BoundaryEdge::right)]),
                       std::signbit(rightVelocity));
        XCTAssertGreaterThanOrEqual(diagnostics.minimumDepth, 0.0);
        XCTAssertTrue(diagnostics.finite);
    };
    run(speed);
    run(-speed);
}

- (void)testDrivenHeightBoundaryUsesHydrostaticReservoirAndDrySegments {
    constexpr double pi = std::numbers::pi;
    const DrivenHeightBoundary forcing{
        .meanSurfaceElevation = 1.0,
        .amplitude = 0.2,
        .periodSeconds = 4.0,
        .phaseRadians = pi / 2.0,
        .rampSeconds = 1.0,
    };
    XCTAssertEqualWithAccuracy(forcing.surfaceElevation(0.0), 1.0, 1.0e-15);
    XCTAssertEqualWithAccuracy(forcing.surfaceElevation(0.5),
                               1.0 + 0.1 * std::sin(3.0 * pi / 4.0), 1.0e-15);
    XCTAssertEqualWithAccuracy(forcing.surfaceElevation(1.0), 1.0, 1.0e-15);
    XCTAssertFalse(DrivenHeightBoundary{.periodSeconds = 0.0}.isValid());

    const auto oneStepRate = [&](const double reservoirSurface) {
        SimulationState state = makeState(32, 16);
        BoundaryConfiguration boundaries;
        boundaries.right = {
            .type = BoundaryType::drivenHeight,
            .driven = {
                .meanSurfaceElevation = reservoirSurface,
                .amplitude = 0.0,
                .periodSeconds = 4.0,
                .phaseRadians = 0.0,
                .rampSeconds = 0.0,
            },
        };
        XCTAssertTrue(state.setBoundaryConfiguration(boundaries));
        SolverConfiguration configuration;
        configuration.workerCount = 4;
        configuration.linearDamping = 0.0;
        configuration.minimumWetDepth = 0.0;
        WeakNonlinearSolver solver(state, configuration);
        XCTAssertEqual(solver.stepOnce(0.005), StepStatus::success);
        XCTAssertEqualWithAccuracy(solver.diagnostics().accountingError, 0.0,
                                   conservationTolerance(state));
        return solver.diagnostics().instantaneousBoundaryOutflowRate[
            boundaryIndex(BoundaryEdge::right)];
    };
    XCTAssertEqual(oneStepRate(1.0), 0.0);
    XCTAssertLessThan(oneStepRate(1.2), 0.0);
    XCTAssertGreaterThan(oneStepRate(0.8), 0.0);

    constexpr std::size_t width = 32;
    constexpr std::size_t height = 16;
    const GridGeometry geometry{width, height, static_cast<double>(width),
                                static_cast<double>(height)};
    std::vector<double> bed(width * height, 0.0);
    std::vector<double> depth(width * height, 1.0);
    for (std::size_t row = height / 2; row < height; ++row) {
        bed[row * width + width - 1] = 2.0;
        depth[row * width + width - 1] = 0.0;
    }
    BoundaryConfiguration boundaries;
    boundaries.right = {
        .type = BoundaryType::drivenHeight,
        .driven = {
            .meanSurfaceElevation = 1.2,
            .amplitude = 0.0,
            .periodSeconds = 4.0,
            .phaseRadians = 0.0,
            .rampSeconds = 0.0,
        },
    };
    SimulationState drySegments;
    XCTAssertTrue(drySegments.initializeDepth(geometry, bed, depth, {}, boundaries));
    SolverConfiguration configuration;
    configuration.workerCount = 4;
    configuration.linearDamping = 0.0;
    configuration.minimumWetDepth = 0.0;
    WeakNonlinearSolver solver(drySegments, configuration);
    XCTAssertEqual(solver.stepOnce(0.005), StepStatus::success);
    for (std::size_t row = height / 2; row < height; ++row) {
        XCTAssertEqual(drySegments.velX()(width, row), 0.0);
    }
    XCTAssertLessThan(solver.diagnostics().instantaneousBoundaryOutflowRate[
                          boundaryIndex(BoundaryEdge::right)], 0.0);
    XCTAssertEqualWithAccuracy(solver.diagnostics().accountingError, 0.0,
                               conservationTolerance(drySegments));
}

- (void)testRightDrivenWaveHasCausalPeriodAndBoundaryAccountedVolume {
    constexpr std::size_t width = 128;
    constexpr std::size_t height = 64;
    constexpr double timeStep = 0.005;
    constexpr std::size_t stepCount = 2'800;
    const GridGeometry geometry{width, height, static_cast<double>(width),
                                static_cast<double>(height)};
    const std::vector<double> bed(width * height, 0.0);
    const std::vector<double> depth(width * height, 1.0);
    BoundaryConfiguration boundaries;
    boundaries.right = {
        .type = BoundaryType::drivenHeight,
        .driven = {
            .meanSurfaceElevation = 1.0,
            .amplitude = 0.10,
            .periodSeconds = 4.0,
            .phaseRadians = 0.0,
            .rampSeconds = 1.0,
        },
    };
    SimulationState state;
    XCTAssertTrue(state.initializeDepth(geometry, bed, depth, {}, boundaries));
    SolverConfiguration configuration;
    configuration.workerCount = 4;
    configuration.linearDamping = 0.02;
    configuration.minimumWetDepth = 1.0e-8;
    WeakNonlinearSolver solver(state, configuration);

    double nearArrival = std::numeric_limits<double>::infinity();
    double farArrival = std::numeric_limits<double>::infinity();
    bool observedInflow = false;
    bool observedOutflow = false;
    double previousDeviation = 0.0;
    std::vector<double> upwardCrossingTimes;
    upwardCrossingTimes.reserve(4);
    for (std::size_t step = 0; step < stepCount; ++step) {
        XCTAssertEqual(solver.stepOnce(timeStep), StepStatus::success);
        const double time = state.time();
        const double nearDeviation = state.waterDepth()(width - 4, height / 2) - 1.0;
        const double farDeviation = state.waterDepth()(4, height / 2) - 1.0;
        if (!std::isfinite(nearArrival) && std::abs(nearDeviation) > 1.0e-4) {
            nearArrival = time;
        }
        if (!std::isfinite(farArrival) && std::abs(farDeviation) > 1.0e-4) {
            farArrival = time;
        }
        if (time > 2.0 && previousDeviation <= 0.0 && nearDeviation > 0.0) {
            upwardCrossingTimes.push_back(time);
        }
        previousDeviation = nearDeviation;
        const double rightFlow = solver.diagnostics().instantaneousBoundaryOutflowRate[
            boundaryIndex(BoundaryEdge::right)];
        observedInflow = observedInflow || rightFlow < -1.0e-8;
        observedOutflow = observedOutflow || rightFlow > 1.0e-8;
        XCTAssertTrue(solver.diagnostics().finite);
        XCTAssertGreaterThanOrEqual(solver.diagnostics().minimumDepth, 0.0);
        XCTAssertLessThanOrEqual(std::abs(solver.diagnostics().accountingError),
                                 4.0 * conservationTolerance(state));
    }

    XCTAssertTrue(std::isfinite(nearArrival));
    XCTAssertLessThan(nearArrival, farArrival);
    XCTAssertTrue(observedInflow);
    XCTAssertTrue(observedOutflow);
    XCTAssertGreaterThanOrEqual(upwardCrossingTimes.size(), 2UL);
    const double measuredPeriod = upwardCrossingTimes.back() -
        upwardCrossingTimes[upwardCrossingTimes.size() - 2];
    XCTAssertEqualWithAccuracy(measuredPeriod, 4.0, 0.35);
    double waveEnergy = 0.0;
    for (const double value : state.waterDepth().values()) {
        const double deviation = value - 1.0;
        waveEnergy += deviation * deviation;
    }
    XCTAssertTrue(std::isfinite(waveEnergy));
    XCTAssertGreaterThan(waveEnergy, 0.0);
    XCTAssertLessThan(waveEnergy, 100.0);
}

- (void)testDampingCFLAndInvalidStepDetection {
    SimulationState undampedState = makeState(32, 32, 0.25);
    SimulationState dampedState = makeState(32, 32, 0.25);
    SolverConfiguration undampedConfiguration;
    undampedConfiguration.workerCount = 1;
    undampedConfiguration.linearDamping = 0.0;
    SolverConfiguration dampedConfiguration = undampedConfiguration;
    dampedConfiguration.linearDamping = 2.0;
    WeakNonlinearSolver undamped(undampedState, undampedConfiguration);
    WeakNonlinearSolver damped(dampedState, dampedConfiguration);
    const double expectedWaveSpeed = std::sqrt(undampedConfiguration.gravity * 1.25);
    const double expectedStableTimeStep = undampedConfiguration.cflNumber /
        (expectedWaveSpeed / undampedState.geometry().dx() +
         expectedWaveSpeed / undampedState.geometry().dy());
    XCTAssertEqualWithAccuracy(undamped.stableTimeStep(), expectedStableTimeStep,
                               8.0 * std::numeric_limits<double>::epsilon());
    const double timeStep = std::min(undamped.stableTimeStep(), damped.stableTimeStep()) * 0.5;
    XCTAssertEqual(undamped.stepOnce(timeStep), StepStatus::success);
    XCTAssertEqual(damped.stepOnce(timeStep), StepStatus::success);
    const double expectedDamping = std::exp(-dampedConfiguration.linearDamping * timeStep);
    for (std::size_t index = 0; index < undampedState.velX().size(); ++index) {
        XCTAssertEqualWithAccuracy(dampedState.velX().values()[index],
                                   undampedState.velX().values()[index] * expectedDamping,
                                   4.0 * std::numeric_limits<double>::epsilon());
    }
    for (std::size_t index = 0; index < undampedState.velY().size(); ++index) {
        XCTAssertEqualWithAccuracy(dampedState.velY().values()[index],
                                   undampedState.velY().values()[index] * expectedDamping,
                                   4.0 * std::numeric_limits<double>::epsilon());
    }
    XCTAssertEqual(undamped.stepOnce(undamped.stableTimeStep() * 1.1),
                   StepStatus::invalidTimeStep);
    XCTAssertEqual(undamped.stepOnce(0.0), StepStatus::invalidTimeStep);

    SolverConfiguration cappedConfiguration = undampedConfiguration;
    cappedConfiguration.maximumSubsteps = 1;
    SimulationState cappedState = makeState(32, 32, 0.25);
    WeakNonlinearSolver capped(cappedState, cappedConfiguration);
    XCTAssertEqual(capped.advance(1.0), StepStatus::substepLimitReached);
}

- (void)testPerformanceCountersPartitionOneSubstepAndReportStorage {
    SimulationState state = makeUnevenPerturbation(128);
    SolverConfiguration configuration;
    configuration.workerCount = 4;
    configuration.collectPerformanceCounters = true;
    WeakNonlinearSolver solver(state, configuration);
    solver.resetPerformanceCounters();

    XCTAssertEqual(solver.stepOnce(0.001), StepStatus::success);
    const auto& counters = solver.performanceCounters();
    XCTAssertEqual(counters.profiledSubsteps, 1UL);
    XCTAssertGreaterThan(counters.totalSubstepSeconds, 0.0);
    XCTAssertGreaterThanOrEqual(counters.stableTimeStepSeconds, 0.0);
    XCTAssertGreaterThanOrEqual(counters.diagnosticsSeconds, 0.0);
    const double partitionedSeconds = counters.surfaceSeconds + counters.pressureSeconds +
        counters.dampingSeconds + counters.fluxSeconds + counters.limiterScaleSeconds +
        counters.fluxLimitSeconds + counters.continuitySeconds + counters.cleanupSeconds +
        counters.dryVelocitySeconds + counters.validationSeconds;
    XCTAssertLessThanOrEqual(partitionedSeconds, counters.totalSubstepSeconds);

    const std::size_t size = 128;
    const std::size_t cellValues = size * size;
    const std::size_t xFaceValues = (size + 1) * size;
    const std::size_t yFaceValues = size * (size + 1);
    const std::size_t expectedBytes =
        (7 * cellValues + 2 * xFaceValues + 2 * yFaceValues) * sizeof(double);
    XCTAssertEqual(solver.estimatedFieldStorageBytes(), expectedBytes);

    solver.resetPerformanceCounters();
    XCTAssertEqual(solver.performanceCounters().profiledSubsteps, 0UL);
    XCTAssertEqual(solver.performanceCounters().totalSubstepSeconds, 0.0);
}

- (void)testCPUGoldenFingerprintsForFutureBackendComparison {
    struct GoldenCase final {
        std::size_t width;
        std::size_t height;
        std::size_t steps;
        std::uint64_t depth;
        std::uint64_t velX;
        std::uint64_t velY;
    };
    constexpr GoldenCase cases[] = {
        {16, 9, 25, 0x3ef7b3176d5a3cbcULL, 0xca38aaa11ba9cabdULL,
         0x293b69a8e22e4cd2ULL},
        {128, 128, 25, 0x1172bc020a14917cULL, 0xfd05c1f1b6db8c97ULL,
         0xf04457e3827d8d24ULL},
        {512, 512, 5, 0x0c772ed816c0e973ULL, 0x9896f9bbd2960747ULL,
         0xd0cb8529892dcaedULL},
    };
    for (const auto& golden : cases) {
        SimulationState state = makeGoldenState(golden.width, golden.height);
        SolverConfiguration configuration;
        configuration.workerCount = 1;
        configuration.linearDamping = 0.0;
        configuration.minimumWetDepth = 0.0;
        WeakNonlinearSolver solver(state, configuration);
        for (std::size_t step = 0; step < golden.steps; ++step) {
            XCTAssertEqual(solver.stepOnce(0.001), StepStatus::success);
        }
        XCTAssertEqual(fingerprint(state.waterDepth().values()), golden.depth);
        XCTAssertEqual(fingerprint(state.velX().values()), golden.velX);
        XCTAssertEqual(fingerprint(state.velY().values()), golden.velY);
    }
}

- (void)testWaterBumpAndDepressionHaveExactVolumeAndLaunchFiniteWaves {
    for (const std::size_t size : {32UL, 128UL}) {
        const Point2D region[]{
            {static_cast<double>(size) * 0.375, static_cast<double>(size) * 0.375},
            {static_cast<double>(size) * 0.625, static_cast<double>(size) * 0.375},
            {static_cast<double>(size) * 0.625, static_cast<double>(size) * 0.625},
            {static_cast<double>(size) * 0.375, static_cast<double>(size) * 0.625},
        };
        for (const MaterialOperation operation : {
                 MaterialOperation::addWater, MaterialOperation::removeWater}) {
            SimulationState state = makeState(size, size);
            TerrainEditor editor(state);
            const double before = volume(state);
            const TerrainEditResult edit = editor.applyPolygon({
                region, {operation, 0.2, EditTarget::initialState}
            });
            const double expectedSign = operation == MaterialOperation::addWater ? 1.0 : -1.0;
            const double expectedDelta = expectedSign * 0.2 *
                static_cast<double>(edit.changedCells) * state.geometry().dx() *
                state.geometry().dy();
            XCTAssertEqual(edit.status, TerrainEditStatus::success);
            XCTAssertEqualWithAccuracy(edit.waterVolumeDelta, expectedDelta,
                                       conservationTolerance(state));
            XCTAssertEqualWithAccuracy(volume(state) - before, expectedDelta,
                                       conservationTolerance(state));
            XCTAssertEqual(state.time(), 0.0);
            XCTAssertEqual(*std::max_element(state.velX().values().begin(),
                                             state.velX().values().end()), 0.0);

            SolverConfiguration configuration;
            configuration.workerCount = 4;
            configuration.minimumWetDepth = 1.0e-8;
            WeakNonlinearSolver solver(state, configuration);
            const double editedVolume = volume(state);
            for (std::size_t step = 0; step < 500; ++step) {
                XCTAssertEqual(solver.stepOnce(0.001), StepStatus::success);
            }
            XCTAssertGreaterThan(solver.diagnostics().maximumAbsVelX +
                                  solver.diagnostics().maximumAbsVelY, 0.0);
            XCTAssertEqualWithAccuracy(volume(state), editedVolume,
                                       conservationTolerance(state));
            XCTAssertTrue(allFinite(state.waterDepth().values()));
            XCTAssertGreaterThanOrEqual(solver.diagnostics().minimumDepth, 0.0);
        }
    }
}

- (void)testWetDryPositivityAndDonorLimiting {
    for (const std::size_t size : {32UL, 128UL}) {
        const GridGeometry geometry{size, size, static_cast<double>(size),
                                    static_cast<double>(size)};
        std::vector<double> bed(size * size, 1.5);
        std::vector<double> depth(size * size, 0.0);
        for (std::size_t row = size / 4; row < 3 * size / 4; ++row) {
            for (std::size_t column = size / 4; column < 3 * size / 4; ++column) {
                bed[row * size + column] = 0.0;
                depth[row * size + column] = 1.0;
            }
        }
        depth[(size / 2) * size + size / 2] = 8.0;
        SimulationState state;
        XCTAssertTrue(state.initializeDepth(geometry, bed, depth));
        SolverConfiguration configuration;
        configuration.workerCount = 4;
        configuration.minimumWetDepth = 1.0e-8;
        WeakNonlinearSolver solver(state, configuration);
        for (std::size_t step = 0; step < 100; ++step) {
            XCTAssertEqual(solver.advance(0.01), StepStatus::success);
            XCTAssertGreaterThanOrEqual(solver.diagnostics().minimumDepth, 0.0);
        }
    }
}

- (void)testSerialParallelConsistencyAtRequiredScales {
    for (const std::size_t size : {32UL, 128UL, 512UL}) {
        for (const std::size_t workers : {2UL, 4UL}) {
            SimulationState serialState = makeState(size, size, 0.2);
            SimulationState parallelState = makeState(size, size, 0.2);
            SolverConfiguration serialConfiguration;
            serialConfiguration.workerCount = 1;
            serialConfiguration.minimumWetDepth = 0.0;
            SolverConfiguration parallelConfiguration = serialConfiguration;
            parallelConfiguration.workerCount = workers;
            WeakNonlinearSolver serial(serialState, serialConfiguration);
            WeakNonlinearSolver parallel(parallelState, parallelConfiguration);
            const std::size_t stepCount = size == 512 ? 12 : 100;
            for (std::size_t step = 0; step < stepCount; ++step) {
                XCTAssertEqual(serial.advance(0.005), StepStatus::success);
                XCTAssertEqual(parallel.advance(0.005), StepStatus::success);
            }
            XCTAssertEqual(maximumDifference(serialState.waterDepth().values(),
                                             parallelState.waterDepth().values()), 0.0);
            XCTAssertEqual(maximumDifference(serialState.velX().values(),
                                             parallelState.velX().values()), 0.0);
            XCTAssertEqual(maximumDifference(serialState.velY().values(),
                                             parallelState.velY().values()), 0.0);
        }
    }
}

- (void)testSubmergedSandEditPreservesSurfaceAndDeletesExactWaterVolume {
    for (const std::size_t size : {32UL, 128UL}) {
        SimulationState state = makeUnevenLake(size);
        SolverConfiguration configuration;
        configuration.workerCount = 4;
        configuration.linearDamping = 0.0;
        WeakNonlinearSolver solver(state, configuration);
        for (std::size_t step = 0; step < 100; ++step) {
            XCTAssertEqual(solver.stepOnce(0.001), StepStatus::success);
        }
        TerrainEditor editor(state);
        const double center = static_cast<double>(size / 2) + 0.5;
        const double volumeBefore = volume(state);
        const BrushCommand command{
            {{center, center}, static_cast<double>(size) / 6.0, BrushFalloff::smooth},
            {MaterialOperation::addSand, 0.25, EditTarget::initialState},
        };
        const TerrainEditResult result = editor.applyBrush(command);
        XCTAssertEqual(result.status, TerrainEditStatus::success);
        XCTAssertGreaterThan(result.changedCells, 0UL);
        XCTAssertEqualWithAccuracy(result.waterVolumeDelta, -result.sandVolumeDelta,
                                   conservationTolerance(state));
        XCTAssertEqualWithAccuracy(volume(state) - volumeBefore, result.waterVolumeDelta,
                                   conservationTolerance(state));
        XCTAssertEqual(state.time(), 0.0);
        for (std::size_t index = 0; index < state.waterDepth().size(); ++index) {
            XCTAssertEqualWithAccuracy(state.bedElevation().values()[index] +
                                       state.waterDepth().values()[index], 2.0, 1.0e-12);
        }
        for (std::size_t step = 0; step < 1'000; ++step) {
            XCTAssertEqual(solver.stepOnce(0.001), StepStatus::success);
        }
        XCTAssertLessThan(solver.diagnostics().maximumAbsVelX, 1.0e-10);
        XCTAssertLessThan(solver.diagnostics().maximumAbsVelY, 1.0e-10);
    }
}

- (void)testBrushAndPolygonUseIdenticalMaterialKernelAndValidateAtomically {
    const Point2D concave[]{{4.0, 4.0}, {12.0, 4.0}, {12.0, 8.0},
                            {8.0, 8.0}, {8.0, 12.0}, {4.0, 12.0}};
    const Point2D reversed[]{{4.0, 12.0}, {8.0, 12.0}, {8.0, 8.0},
                             {12.0, 8.0}, {12.0, 4.0}, {4.0, 4.0}};
    for (const std::size_t size : {32UL, 128UL}) {
        SimulationState first = makeState(size, size);
        SimulationState second = makeState(size, size);
        TerrainEditor firstEditor(first);
        TerrainEditor secondEditor(second);
        const MaterialEdit edit{MaterialOperation::addWater, 0.5,
                                EditTarget::initialState};
        XCTAssertEqual(firstEditor.applyPolygon({concave, edit}).status,
                       TerrainEditStatus::success);
        XCTAssertEqual(secondEditor.applyPolygon({reversed, edit}).status,
                       TerrainEditStatus::success);
        XCTAssertEqual(maximumDifference(first.bedElevation().values(),
                                         second.bedElevation().values()), 0.0);
        XCTAssertEqual(maximumDifference(first.waterDepth().values(),
                                         second.waterDepth().values()), 0.0);
        XCTAssertEqual(first.waterDepth()(5, 5), 1.5);
        XCTAssertEqual(first.waterDepth()(10, 10), 1.0);

        const std::vector<double> before(first.waterDepth().values().begin(),
                                         first.waterDepth().values().end());
        const Point2D bowTie[]{{0.0, 0.0}, {4.0, 4.0}, {0.0, 4.0}, {4.0, 0.0}};
        XCTAssertEqual(firstEditor.applyPolygon({bowTie, edit}).status,
                       TerrainEditStatus::malformedPolygon);
        XCTAssertEqual(maximumDifference(before, first.waterDepth().values()), 0.0);
        const Point2D line[]{{0.0, 0.0}, {1.0, 1.0}, {2.0, 2.0}};
        XCTAssertEqual(firstEditor.applyPolygon({line, edit}).status,
                       TerrainEditStatus::malformedPolygon);
    }
}

- (void)testViewportAgnosticBrushAndPolygonRoutesAreNumericallyIdentical {
    constexpr Point2D polygon[]{{18.0, 18.0}, {26.0, 18.0},
                                {26.0, 26.0}, {18.0, 26.0}};
    for (const EditTarget target : {EditTarget::initialState,
                                    EditTarget::pausedCurrentState}) {
        for (const MaterialOperation operation : {
                 MaterialOperation::addSand, MaterialOperation::removeSand,
                 MaterialOperation::addWater, MaterialOperation::removeWater}) {
            SimulationState twoDState = makeState(32, 32, 0.4);
            SimulationState threeDState = makeState(32, 32, 0.4);
            if (target == EditTarget::pausedCurrentState) {
                SolverConfiguration configuration;
                configuration.workerCount = 1;
                configuration.minimumWetDepth = 1.0e-8;
                WeakNonlinearSolver twoDSolver(twoDState, configuration);
                WeakNonlinearSolver threeDSolver(threeDState, configuration);
                for (std::size_t step = 0; step < 100; ++step) {
                    XCTAssertEqual(twoDSolver.stepOnce(0.001), StepStatus::success);
                    XCTAssertEqual(threeDSolver.stepOnce(0.001), StepStatus::success);
                }
            }

            TerrainEditor twoDEditor(twoDState, 1.0e-8);
            TerrainEditor threeDEditor(threeDState, 1.0e-8);
            const BrushCommand brush{
                {{12.5, 12.5}, 3.5, BrushFalloff::smooth},
                {operation, 0.15, target},
            };
            const TerrainEditResult twoDBrush = twoDEditor.applyBrush(brush);
            const TerrainEditResult threeDBrush = threeDEditor.applyBrush(brush);

            const auto assertResultParity = [&](const TerrainEditResult& first,
                                                const TerrainEditResult& second) {
                XCTAssertEqual(first.status, second.status);
                XCTAssertEqual(first.changedCells, second.changedCells);
                XCTAssertEqual(first.changedFaces, second.changedFaces);
                XCTAssertEqual(first.sandVolumeDelta, second.sandVolumeDelta);
                XCTAssertEqual(first.waterVolumeDelta, second.waterVolumeDelta);
                XCTAssertEqual(first.clamped, second.clamped);
                XCTAssertEqual(first.newlyWetCells, second.newlyWetCells);
                XCTAssertEqual(first.newlyDryCells, second.newlyDryCells);
            };
            const auto assertStateParity = [&] {
                XCTAssertEqual(maximumDifference(twoDState.bedElevation().values(),
                                                 threeDState.bedElevation().values()), 0.0);
                XCTAssertEqual(maximumDifference(twoDState.waterDepth().values(),
                                                 threeDState.waterDepth().values()), 0.0);
                XCTAssertEqual(maximumDifference(twoDState.velX().values(),
                                                 threeDState.velX().values()), 0.0);
                XCTAssertEqual(maximumDifference(twoDState.velY().values(),
                                                 threeDState.velY().values()), 0.0);
                XCTAssertEqual(twoDState.time(), threeDState.time());
                XCTAssertEqual(volume(twoDState), volume(threeDState));
            };
            assertResultParity(twoDBrush, threeDBrush);
            assertStateParity();

            const PolygonCommand polygonCommand{
                polygon,
                {operation, 0.05, target},
            };
            const TerrainEditResult twoDPolygon = twoDEditor.applyPolygon(polygonCommand);
            const TerrainEditResult threeDPolygon = threeDEditor.applyPolygon(polygonCommand);
            assertResultParity(twoDPolygon, threeDPolygon);
            assertStateParity();

            twoDState.reset();
            threeDState.reset();
            assertStateParity();
        }
    }
}

- (void)testPausedMaterialEditsRetainTimeMixMomentumAndResetToEditedInitialState {
    for (const MaterialOperation operation : {
             MaterialOperation::addSand, MaterialOperation::removeSand,
             MaterialOperation::addWater, MaterialOperation::removeWater}) {
        SimulationState state = makeState(32, 32, 0.4);
        SolverConfiguration configuration;
        configuration.workerCount = 1;
        configuration.minimumWetDepth = 1.0e-8;
        WeakNonlinearSolver solver(state, configuration);
        for (std::size_t step = 0; step < 150; ++step) {
            XCTAssertEqual(solver.stepOnce(0.002), StepStatus::success);
        }
        const double editTime = state.time();
        const std::vector<double> velocityBefore(state.velX().values().begin(),
                                                 state.velX().values().end());
        const Point2D region[]{{8.0, 8.0}, {24.0, 8.0}, {24.0, 24.0}, {8.0, 24.0}};
        TerrainEditor editor(state, configuration.minimumWetDepth);
        const TerrainEditResult result = editor.applyPolygon({
            region, {operation, 0.1, EditTarget::pausedCurrentState}
        });
        XCTAssertEqual(result.status, TerrainEditStatus::success);
        XCTAssertGreaterThan(result.changedCells, 0UL);
        XCTAssertEqual(state.time(), editTime);
        if (operation == MaterialOperation::addSand ||
            operation == MaterialOperation::removeWater) {
            XCTAssertLessThanOrEqual(maximumDifference(velocityBefore, state.velX().values()),
                                     1.0e-12);
        } else {
            XCTAssertGreaterThan(maximumDifference(velocityBefore, state.velX().values()), 0.0);
        }
        for (std::size_t step = 0; step < 500; ++step) {
            XCTAssertEqual(solver.stepOnce(0.001), StepStatus::success);
        }
        XCTAssertTrue(allFinite(state.waterDepth().values()));
        XCTAssertTrue(allFinite(state.velX().values()));
        XCTAssertTrue(allFinite(state.velY().values()));
        XCTAssertGreaterThanOrEqual(solver.diagnostics().minimumDepth, 0.0);
    }

    SimulationState resetState = makeState(32, 32);
    TerrainEditor resetEditor(resetState);
    const BrushCommand initialEdit{
        {{16.5, 16.5}, 4.0, BrushFalloff::constant},
        {MaterialOperation::removeSand, 0.25, EditTarget::initialState},
    };
    XCTAssertTrue(resetEditor.applyBrush(initialEdit).changed());
    const std::vector<double> editedInitial(resetState.bedElevation().values().begin(),
                                            resetState.bedElevation().values().end());
    WeakNonlinearSolver resetSolver(resetState);
    XCTAssertEqual(resetSolver.advance(0.1), StepStatus::success);
    resetState.reset();
    XCTAssertEqual(maximumDifference(editedInitial, resetState.bedElevation().values()), 0.0);
    XCTAssertEqual(resetState.time(), 0.0);
}

- (void)testHydrostaticShorelineBlocksHighGroundAndInundatesLowGround {
    for (const std::size_t size : {32UL, 128UL}) {
        const GridGeometry geometry{size, size, static_cast<double>(size),
                                    static_cast<double>(size)};
        std::vector<double> islandBed(size * size, 0.0);
        std::vector<double> islandDepth(size * size, 1.0);
        for (std::size_t row = size / 3; row < 2 * size / 3; ++row) {
            for (std::size_t column = size / 3; column < 2 * size / 3; ++column) {
                islandBed[row * size + column] = 2.0;
                islandDepth[row * size + column] = 0.0;
            }
        }
        SimulationState island;
        XCTAssertTrue(island.initializeDepth(geometry, islandBed, islandDepth));
        SolverConfiguration configuration;
        configuration.workerCount = 4;
        configuration.minimumWetDepth = 1.0e-8;
        configuration.linearDamping = 0.0;
        WeakNonlinearSolver islandSolver(island, configuration);
        const double islandVolume = volume(island);
        for (std::size_t step = 0; step < 1'000; ++step) {
            XCTAssertEqual(islandSolver.stepOnce(0.001), StepStatus::success);
        }
        XCTAssertEqualWithAccuracy(volume(island), islandVolume, conservationTolerance(island));
        XCTAssertEqual(island.waterDepth()(size / 2, size / 2), 0.0);
        XCTAssertLessThan(islandSolver.diagnostics().maximumAbsVelX, 1.0e-12);
        XCTAssertLessThan(islandSolver.diagnostics().maximumAbsVelY, 1.0e-12);

        std::vector<double> lowBed(size * size, 0.0);
        std::vector<double> lowDepth(size * size, 0.0);
        for (std::size_t row = 0; row < size; ++row) {
            for (std::size_t column = 0; column < size / 2; ++column) {
                lowDepth[row * size + column] = 1.0;
            }
        }
        SimulationState inundation;
        XCTAssertTrue(inundation.initializeDepth(geometry, lowBed, lowDepth));
        WeakNonlinearSolver inundationSolver(inundation, configuration);
        for (std::size_t step = 0; step < 500; ++step) {
            XCTAssertEqual(inundationSolver.stepOnce(0.001), StepStatus::success);
        }
        XCTAssertGreaterThan(inundation.waterDepth()(size / 2, size / 2), 0.0);
        XCTAssertTrue(allFinite(inundation.waterDepth().values()));
    }
}

- (void)testShorelineRecessionReachesExactlyDryWithoutNegativeDepth {
    for (const std::size_t size : {32UL, 128UL}) {
        const GridGeometry geometry{size, size, static_cast<double>(size),
                                    static_cast<double>(size)};
        const std::vector<double> bed(size * size, 0.0);
        std::vector<double> depth(size * size, 0.0);
        for (std::size_t row = 0; row < size; ++row) {
            for (std::size_t column = 0; column < size / 2; ++column) {
                depth[row * size + column] = 0.125;
            }
        }
        SimulationState state;
        XCTAssertTrue(state.initializeDepth(geometry, bed, depth));
        TerrainEditor editor(state, 1.0e-8);
        const Point2D wetHalf[]{{0.0, 0.0}, {static_cast<double>(size) / 2.0, 0.0},
                                {static_cast<double>(size) / 2.0,
                                 static_cast<double>(size)},
                                {0.0, static_cast<double>(size)}};
        const double volumeBefore = volume(state);
        const TerrainEditResult result = editor.applyPolygon({
            wetHalf,
            {MaterialOperation::removeWater, 0.125, EditTarget::pausedCurrentState},
        });
        const std::size_t expectedDryCells = size * size / 2;
        XCTAssertEqual(result.status, TerrainEditStatus::success);
        XCTAssertEqual(result.changedCells, expectedDryCells);
        XCTAssertEqual(result.newlyDryCells, expectedDryCells);
        XCTAssertEqual(result.newlyWetCells, 0UL);
        XCTAssertEqualWithAccuracy(result.waterVolumeDelta, -volumeBefore,
                                   conservationTolerance(state));
        XCTAssertEqual(volume(state), 0.0);
        XCTAssertEqual(*std::min_element(state.waterDepth().values().begin(),
                                         state.waterDepth().values().end()), 0.0);
        XCTAssertEqual(*std::max_element(state.waterDepth().values().begin(),
                                         state.waterDepth().values().end()), 0.0);

        SolverConfiguration configuration;
        configuration.workerCount = 4;
        configuration.minimumWetDepth = 1.0e-8;
        WeakNonlinearSolver solver(state, configuration);
        solver.stateWasEdited();
        for (std::size_t step = 0; step < 500; ++step) {
            XCTAssertEqual(solver.stepOnce(0.001), StepStatus::success);
        }
        XCTAssertEqual(solver.diagnostics().minimumDepth, 0.0);
        XCTAssertEqual(solver.diagnostics().maximumDepth, 0.0);
        XCTAssertEqual(solver.diagnostics().maximumAbsVelX, 0.0);
        XCTAssertEqual(solver.diagnostics().maximumAbsVelY, 0.0);
        XCTAssertEqual(solver.diagnostics().correctionCount, 0UL);
    }
}

- (void)testCombinedPausedEditsResumeStablyAt512 {
    constexpr std::size_t size = 512;
    SimulationState state = makeState(size, size, 0.4);
    SolverConfiguration configuration;
    configuration.workerCount = 4;
    configuration.minimumWetDepth = 1.0e-8;
    configuration.linearDamping = 0.0;
    WeakNonlinearSolver solver(state, configuration);
    for (std::size_t step = 0; step < 20; ++step) {
        XCTAssertEqual(solver.stepOnce(0.001), StepStatus::success);
    }
    const double editTime = state.time();
    TerrainEditor editor(state, configuration.minimumWetDepth);
    constexpr double amount = 0.05;
    const Point2D regions[][4] = {
        {{48.0, 48.0}, {208.0, 48.0}, {208.0, 208.0}, {48.0, 208.0}},
        {{304.0, 48.0}, {464.0, 48.0}, {464.0, 208.0}, {304.0, 208.0}},
        {{48.0, 304.0}, {208.0, 304.0}, {208.0, 464.0}, {48.0, 464.0}},
        {{304.0, 304.0}, {464.0, 304.0}, {464.0, 464.0}, {304.0, 464.0}},
    };
    constexpr MaterialOperation operations[]{
        MaterialOperation::addSand,
        MaterialOperation::removeSand,
        MaterialOperation::addWater,
        MaterialOperation::removeWater,
    };
    for (std::size_t editIndex = 0; editIndex < std::size(operations); ++editIndex) {
        const double volumeBefore = volume(state);
        const TerrainEditResult result = editor.applyPolygon({
            regions[editIndex],
            {operations[editIndex], amount, EditTarget::pausedCurrentState},
        });
        XCTAssertEqual(result.status, TerrainEditStatus::success);
        XCTAssertEqual(result.changedCells, 160UL * 160UL);
        XCTAssertEqualWithAccuracy(volume(state) - volumeBefore, result.waterVolumeDelta,
                                   conservationTolerance(state));
        XCTAssertEqual(state.time(), editTime);
        solver.stateWasEdited();
        XCTAssertTrue(solver.diagnostics().finite);
        XCTAssertEqualWithAccuracy(solver.diagnostics().totalVolume, volume(state),
                                   conservationTolerance(state));
    }

    const double editedVolume = volume(state);
    const double freshStableTimeStep = solver.stableTimeStep();
    XCTAssertTrue(std::isfinite(freshStableTimeStep));
    XCTAssertGreaterThan(freshStableTimeStep, 0.0);
    for (std::size_t step = 0; step < 500; ++step) {
        XCTAssertEqual(solver.stepOnce(0.0005), StepStatus::success);
    }
    XCTAssertTrue(allFinite(state.waterDepth().values()));
    XCTAssertTrue(allFinite(state.velX().values()));
    XCTAssertTrue(allFinite(state.velY().values()));
    XCTAssertTrue(solver.diagnostics().finite);
    XCTAssertGreaterThanOrEqual(solver.diagnostics().minimumDepth, 0.0);
    XCTAssertEqual(solver.diagnostics().correctionCount, 0UL);
    XCTAssertEqualWithAccuracy(volume(state), editedVolume,
                               conservationTolerance(state));
}

- (void)testSmallConcurrentEditedClosedDomainConservesAccountedVolume {
    constexpr std::size_t size = 8;
    constexpr std::size_t workerCount = 2;
    constexpr std::size_t warmUpStepCount = 20;
    constexpr std::size_t measuredStepCount = 400;
    SimulationState state = makeState(size, size, 0.2);
    SolverConfiguration configuration;
    configuration.workerCount = workerCount;
    configuration.minimumWetDepth = 1.0e-8;
    configuration.linearDamping = 0.02;
    WeakNonlinearSolver solver(state, configuration);
    for (std::size_t step = 0; step < warmUpStepCount; ++step) {
        XCTAssertEqual(solver.stepOnce(0.0005), StepStatus::success);
    }

    const double editTime = state.time();
    double accountedVolume = volume(state);
    TerrainEditor editor(state, configuration.minimumWetDepth);
    constexpr Point2D regions[][4] = {
        {{0.25, 0.25}, {3.75, 0.25}, {3.75, 3.75}, {0.25, 3.75}},
        {{4.25, 0.25}, {7.75, 0.25}, {7.75, 3.75}, {4.25, 3.75}},
        {{0.25, 4.25}, {3.75, 4.25}, {3.75, 7.75}, {0.25, 7.75}},
        {{4.25, 4.25}, {7.75, 4.25}, {7.75, 7.75}, {4.25, 7.75}},
    };
    constexpr MaterialOperation operations[]{
        MaterialOperation::addSand,
        MaterialOperation::removeSand,
        MaterialOperation::addWater,
        MaterialOperation::removeWater,
    };
    for (std::size_t index = 0; index < std::size(operations); ++index) {
        const TerrainEditResult result = editor.applyPolygon({
            regions[index],
            {operations[index], 0.05, EditTarget::pausedCurrentState},
        });
        XCTAssertEqual(result.status, TerrainEditStatus::success);
        XCTAssertGreaterThan(result.changedCells, 0UL);
        accountedVolume += result.waterVolumeDelta;
        XCTAssertEqualWithAccuracy(volume(state), accountedVolume,
                                   conservationTolerance(state));
        XCTAssertEqual(state.time(), editTime);
        solver.stateWasEdited();
        XCTAssertTrue(solver.diagnostics().finite);
    }

    const double editedVolume = accountedVolume;
    for (std::size_t step = 0; step < measuredStepCount; ++step) {
        XCTAssertEqual(solver.stepOnce(0.0005), StepStatus::success);
    }
    XCTAssertEqualWithAccuracy(volume(state), editedVolume,
                               conservationTolerance(state));
    XCTAssertEqualWithAccuracy(solver.diagnostics().totalVolume, editedVolume,
                               conservationTolerance(state));
    XCTAssertTrue(solver.diagnostics().finite);
    XCTAssertGreaterThanOrEqual(solver.diagnostics().minimumDepth, 0.0);
    XCTAssertTrue(allFinite(state.bedElevation().values()));
    XCTAssertTrue(allFinite(state.waterDepth().values()));
    XCTAssertTrue(allFinite(state.velX().values()));
    XCTAssertTrue(allFinite(state.velY().values()));
}

- (void)testTenThousandStepEditedClosedDomainConservesAccountedVolume {
    constexpr std::size_t size = 32;
    SimulationState state = makeState(size, size, 0.2);
    SolverConfiguration configuration;
    configuration.workerCount = 4;
    configuration.minimumWetDepth = 1.0e-8;
    configuration.linearDamping = 0.02;
    WeakNonlinearSolver solver(state, configuration);
    for (std::size_t step = 0; step < 100; ++step) {
        XCTAssertEqual(solver.stepOnce(0.0005), StepStatus::success);
    }

    const double editTime = state.time();
    double accountedVolume = volume(state);
    TerrainEditor editor(state, configuration.minimumWetDepth);
    constexpr Point2D regions[][4] = {
        {{3.0, 3.0}, {13.0, 3.0}, {13.0, 13.0}, {3.0, 13.0}},
        {{19.0, 3.0}, {29.0, 3.0}, {29.0, 13.0}, {19.0, 13.0}},
        {{3.0, 19.0}, {13.0, 19.0}, {13.0, 29.0}, {3.0, 29.0}},
        {{19.0, 19.0}, {29.0, 19.0}, {29.0, 29.0}, {19.0, 29.0}},
    };
    constexpr MaterialOperation operations[]{
        MaterialOperation::addSand,
        MaterialOperation::removeSand,
        MaterialOperation::addWater,
        MaterialOperation::removeWater,
    };
    for (std::size_t index = 0; index < std::size(operations); ++index) {
        const TerrainEditResult result = editor.applyPolygon({
            regions[index],
            {operations[index], 0.05, EditTarget::pausedCurrentState},
        });
        XCTAssertEqual(result.status, TerrainEditStatus::success);
        XCTAssertGreaterThan(result.changedCells, 0UL);
        accountedVolume += result.waterVolumeDelta;
        XCTAssertEqualWithAccuracy(volume(state), accountedVolume,
                                   conservationTolerance(state));
        XCTAssertEqual(state.time(), editTime);
        solver.stateWasEdited();
        XCTAssertTrue(solver.diagnostics().finite);
    }

    const double editedVolume = accountedVolume;
    for (std::size_t step = 0; step < 10'000; ++step) {
        XCTAssertEqual(solver.stepOnce(0.0005), StepStatus::success);
    }
    XCTAssertEqualWithAccuracy(volume(state), editedVolume,
                               conservationTolerance(state));
    XCTAssertEqualWithAccuracy(solver.diagnostics().totalVolume, editedVolume,
                               conservationTolerance(state));
    XCTAssertTrue(solver.diagnostics().finite);
    XCTAssertGreaterThanOrEqual(solver.diagnostics().minimumDepth, 0.0);
    XCTAssertTrue(allFinite(state.bedElevation().values()));
    XCTAssertTrue(allFinite(state.waterDepth().values()));
    XCTAssertTrue(allFinite(state.velX().values()));
    XCTAssertTrue(allFinite(state.velY().values()));
}

@end
