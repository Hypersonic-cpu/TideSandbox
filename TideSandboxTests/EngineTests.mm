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
        {16, 9, 25, 0xe53d405add0eb75cULL, 0xeea22af86fbc9f4cULL,
         0x6b4c01398899b87aULL},
        {128, 128, 25, 0x911c89d32db6e6e9ULL, 0xce31bca6c26caf5cULL,
         0xe08f64226e564d90ULL},
        {512, 512, 5, 0xa9cd1b27cfc8bc8cULL, 0x642e24b4a604f6d6ULL,
         0xdd8244fff5566ce2ULL},
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

- (void)testBrushFalloffAccumulationClampingAndBoundaries {
    for (const std::size_t size : {32UL, 128UL}) {
        SimulationState state = makeState(size, size);
        TerrainEditor editor(state);
        const double center = static_cast<double>(size / 2) + 0.5;
        const BrushCommand centerBrush{{center, center}, 3.0, 0.5, BrushFalloff::linear,
                                       -1.0, 0.75};
        XCTAssertEqual(editor.applyBrush(centerBrush), TerrainEditStatus::success);
        XCTAssertEqual(editor.applyBrush(centerBrush), TerrainEditStatus::success);
        XCTAssertEqual(state.bedElevation()(size / 2, size / 2), 0.75);
        XCTAssertGreaterThan(state.bedElevation()(size / 2 + 1, size / 2), 0.0);
        XCTAssertEqual(state.bedElevation()(0, size - 1), 0.0);

        SimulationState smoothState = makeState(size, size);
        TerrainEditor smoothEditor(smoothState);
        const BrushCommand smoothBrush{{center, center}, 3.0, 0.5, BrushFalloff::smooth,
                                       -1.0, 1.0};
        XCTAssertEqual(smoothEditor.applyBrush(smoothBrush), TerrainEditStatus::success);
        const double normalizedWeight = (2.0 / 3.0) * (2.0 / 3.0) *
                                        (3.0 - 2.0 * (2.0 / 3.0));
        XCTAssertEqualWithAccuracy(smoothState.bedElevation()(size / 2 + 1, size / 2),
                                   0.5 * normalizedWeight,
                                   4.0 * std::numeric_limits<double>::epsilon());

        const BrushCommand boundaryBrush{{0.0, 0.0}, 4.0, -2.0, BrushFalloff::constant,
                                         -0.5, 0.75};
        XCTAssertEqual(editor.applyBrush(boundaryBrush), TerrainEditStatus::success);
        XCTAssertEqual(state.bedElevation()(0, 0), -0.5);
        XCTAssertEqual(editor.applyBrush({{0.0, 0.0}, 0.0, 1.0}),
                       TerrainEditStatus::invalidCommand);
    }
}

- (void)testPolygonModesConcavityOrientationAndValidation {
    const Point2D concave[]{{4.0, 4.0}, {12.0, 4.0}, {12.0, 8.0},
                            {8.0, 8.0}, {8.0, 12.0}, {4.0, 12.0}};
    const Point2D reversed[]{{4.0, 12.0}, {8.0, 12.0}, {8.0, 8.0},
                             {12.0, 8.0}, {12.0, 4.0}, {4.0, 4.0}};
    for (const std::size_t size : {32UL, 128UL}) {
        SimulationState first = makeState(size, size);
        SimulationState second = makeState(size, size);
        TerrainEditor firstEditor(first);
        TerrainEditor secondEditor(second);
        XCTAssertEqual(firstEditor.applyPolygon({concave, PolygonMode::add, 0.5, -1.0, 1.0}),
                       TerrainEditStatus::success);
        XCTAssertEqual(secondEditor.applyPolygon({reversed, PolygonMode::add, 0.5, -1.0, 1.0}),
                       TerrainEditStatus::success);
        XCTAssertEqual(maximumDifference(first.bedElevation().values(),
                                         second.bedElevation().values()), 0.0);
        XCTAssertEqual(first.bedElevation()(5, 5), 0.5);
        XCTAssertEqual(first.bedElevation()(10, 10), 0.0);
        XCTAssertEqual(firstEditor.applyPolygon({concave, PolygonMode::set, -0.25, -1.0, 1.0}),
                       TerrainEditStatus::success);
        XCTAssertEqual(first.bedElevation()(5, 5), -0.25);

        const Point2D triangle[]{{1.0, 1.0}, {5.0, 1.0}, {1.0, 5.0}};
        XCTAssertEqual(firstEditor.applyPolygon({triangle, PolygonMode::add, 0.2, -1.0, 1.0}),
                       TerrainEditStatus::success);
        const Point2D rectangle[]{{16.0, 16.0}, {20.0, 16.0}, {20.0, 20.0}, {16.0, 20.0}};
        XCTAssertEqual(firstEditor.applyPolygon({rectangle, PolygonMode::set, 0.8, -1.0, 1.0}),
                       TerrainEditStatus::success);
        XCTAssertEqual(first.bedElevation()(17, 17), 0.8);
        const Point2D bowTie[]{{0.0, 0.0}, {4.0, 4.0}, {0.0, 4.0}, {4.0, 0.0}};
        XCTAssertEqual(firstEditor.applyPolygon({bowTie, PolygonMode::set, 1.0, -1.0, 1.0}),
                       TerrainEditStatus::malformedPolygon);
        const Point2D line[]{{0.0, 0.0}, {1.0, 1.0}, {2.0, 2.0}};
        XCTAssertEqual(firstEditor.applyPolygon({line, PolygonMode::set, 1.0, -1.0, 1.0}),
                       TerrainEditStatus::malformedPolygon);
    }
}

@end
