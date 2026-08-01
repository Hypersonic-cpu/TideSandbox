#import <XCTest/XCTest.h>

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
#include <numbers>
#include <span>
#include <vector>

using namespace tide::swe;

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

[[nodiscard]] double volume(const SimulationState& state) noexcept {
    double depthSum = 0.0;
    for (const double depth : state.waterDepth().values()) {
        depthSum += depth;
    }
    return depthSum * state.geometry().dx() * state.geometry().dy();
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
