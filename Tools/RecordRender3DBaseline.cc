#include "../TideSandbox/Engine/SimulationState.hh"
#include "../TideSandbox/Engine/WeakNonlinearSolver.hh"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <vector>

using namespace tide::swe;

namespace {

constexpr std::size_t gridSize = 32;
constexpr std::size_t frameCount = 120;
constexpr double frameDuration = 1.0 / 60.0;

[[nodiscard]] SimulationState makeDefaultState() {
    const GridGeometry geometry{gridSize, gridSize,
                                static_cast<double>(gridSize),
                                static_cast<double>(gridSize)};
    std::vector<double> bed(gridSize * gridSize);
    std::vector<double> depth(gridSize * gridSize);
    for (std::size_t row = 0; row < gridSize; ++row) {
        const double y = (static_cast<double>(row) + 0.5) /
                         static_cast<double>(gridSize);
        for (std::size_t column = 0; column < gridSize; ++column) {
            const double x = (static_cast<double>(column) + 0.5) /
                             static_cast<double>(gridSize);
            const double offsetX = x - 0.5;
            const double offsetY = y - 0.5;
            const double elevation = 0.45 * std::exp(
                -(offsetX * offsetX + offsetY * offsetY) / 0.018);
            const std::size_t index = row * gridSize + column;

            // Match BuiltInScenes.swift and the bridge exactly: each scalar is
            // rounded to Float32 before entering the Double-precision Engine.
            const float bedValue = static_cast<float>(elevation);
            const float depthValue = static_cast<float>(std::max(1.0 - elevation, 0.0));
            bed[index] = static_cast<double>(bedValue);
            depth[index] = static_cast<double>(depthValue);
        }
    }

    SimulationState state;
    if (!state.initializeDepth(geometry, bed, depth)) {
        std::abort();
    }
    return state;
}

} // namespace

int main() {
    SimulationState state = makeDefaultState();
    SolverConfiguration configuration;
    configuration.workerCount = 1;
    WeakNonlinearSolver solver(state, configuration);
    for (std::size_t frame = 0; frame < frameCount; ++frame) {
        if (solver.advance(frameDuration) != StepStatus::success) {
            return 1;
        }
    }

    const Diagnostics& diagnostics = solver.diagnostics();
    const double maximumSpeed = std::hypot(diagnostics.maximumAbsVelX,
                                           diagnostics.maximumAbsVelY);
    std::printf("frames=%zu\n", frameCount);
    std::printf("frame_duration=%.17g\n", frameDuration);
    std::printf("simulated_time=%.17g\n", diagnostics.simulatedTime);
    std::printf("total_volume=%.17g\n", diagnostics.totalVolume);
    std::printf("maximum_depth=%.17g\n", diagnostics.maximumDepth);
    std::printf("maximum_speed=%.17g\n", maximumSpeed);
    std::printf("wet_cell_count=%zu\n", diagnostics.wetCellCount);
    return diagnostics.finite ? 0 : 2;
}
