#include "../TideSandbox/Engine/SimulationState.hh"
#include "../TideSandbox/Engine/WeakNonlinearSolver.hh"

#include <bit>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <span>
#include <vector>

using namespace tide::swe;

namespace {

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

[[nodiscard]] SimulationState makeState(const std::size_t width, const std::size_t height) {
    const GridGeometry geometry{width, height, static_cast<double>(width),
                                static_cast<double>(height)};
    std::vector<double> bed(width * height);
    std::vector<double> depth(width * height);
    for (std::size_t row = 0; row < height; ++row) {
        for (std::size_t column = 0; column < width; ++column) {
            const std::size_t index = row * width + column;
            const auto signedPattern = static_cast<std::int64_t>((17 * column + 13 * row) % 11) - 5;
            bed[index] = static_cast<double>(signedPattern) * 0.01;
            depth[index] = 2.0 - bed[index];
        }
    }
    depth[(height / 2) * width + width / 2] += 0.125;
    SimulationState state;
    if (!state.initializeDepth(geometry, bed, depth)) { std::abort(); }
    return state;
}

void printGolden(const std::size_t width, const std::size_t height,
                 const std::size_t steps) {
    SimulationState state = makeState(width, height);
    SolverConfiguration configuration;
    configuration.workerCount = 1;
    configuration.linearDamping = 0.0;
    configuration.minimumWetDepth = 0.0;
    WeakNonlinearSolver solver(state, configuration);
    for (std::size_t step = 0; step < steps; ++step) {
        if (solver.stepOnce(0.001) != StepStatus::success) { std::abort(); }
    }
    std::printf("GOLDEN,%zu,%zu,%zu,%016llx,%016llx,%016llx,%.17g\n",
                width, height, steps,
                static_cast<unsigned long long>(fingerprint(state.waterDepth().values())),
                static_cast<unsigned long long>(fingerprint(state.velX().values())),
                static_cast<unsigned long long>(fingerprint(state.velY().values())),
                solver.diagnostics().totalVolume);
}

} // namespace

int main() {
    printGolden(16, 9, 25);
    printGolden(128, 128, 25);
    printGolden(512, 512, 5);
    return 0;
}
