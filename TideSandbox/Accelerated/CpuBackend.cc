#include "CpuBackend.hh"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <thread>

namespace tide::accelerated {

namespace {

using Clock = std::chrono::steady_clock;

[[nodiscard]] double millisecondsSince(const Clock::time_point start) noexcept {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

} // namespace

class CpuBackend::Implementation final {
public:
    [[nodiscard]] bool load(const BackendState& source,
                            const swe::SolverConfiguration newConfiguration,
                            std::string& failureReason) {
        swe::SimulationState candidate;
        if (!newConfiguration.isValid() || !importState(source, candidate)) {
            failureReason = "Invalid CPU backend state or configuration";
            return false;
        }
        state = std::move(candidate);
        configuration = newConfiguration;
        rebuildSolver();
        referenceSurface.resize(source.initialBedElevation.size());
        for (std::size_t index = 0; index < referenceSurface.size(); ++index) {
            referenceSurface[index] = source.initialBedElevation[index] +
                                      source.initialWaterDepth[index];
        }
        status = {
            .requested = RequestedSimulationBackend::cpuReference,
            .resolved = ResolvedSimulationBackend::cpuReference,
            .ready = true,
            .fallbackReason = {},
            .statePrecision = "Float64",
        };
        return true;
    }

    void rebuildSolver() {
        solver = std::make_unique<swe::WeakNonlinearSolver>(state, configuration);
        editor = std::make_unique<swe::TerrainEditor>(state, configuration.minimumWetDepth);
    }

    swe::SimulationState state;
    swe::SolverConfiguration configuration;
    std::unique_ptr<swe::WeakNonlinearSolver> solver;
    std::unique_ptr<swe::TerrainEditor> editor;
    std::vector<double> referenceSurface;
    BackendStatus status;
};

CpuBackend::CpuBackend() : implementation_(std::make_unique<Implementation>()) {}
CpuBackend::~CpuBackend() = default;
CpuBackend::CpuBackend(CpuBackend&&) noexcept = default;
CpuBackend& CpuBackend::operator=(CpuBackend&&) noexcept = default;

bool CpuBackend::load(const BackendState& state,
                      const swe::SolverConfiguration configuration,
                      std::string& failureReason) {
    return implementation_->load(state, configuration, failureReason);
}

bool CpuBackend::reset(std::string& failureReason) noexcept {
    if (!implementation_->solver) {
        failureReason = "CPU backend is not ready";
        return false;
    }
    implementation_->state.reset();
    implementation_->solver->stateWasEdited();
    return true;
}

swe::StepStatus CpuBackend::advance(const double frameDeltaTime,
                                    std::string&) noexcept {
    const auto start = Clock::now();
    const swe::StepStatus result = implementation_->solver->advance(frameDeltaTime);
    implementation_->status.lastFramePhysicsMilliseconds = millisecondsSince(start);
    implementation_->status.substepCount = implementation_->solver->diagnostics().substepCount;
    return result;
}

swe::StepStatus CpuBackend::stepOnce(const double timeStep,
                                     std::string&) noexcept {
    const auto start = Clock::now();
    const swe::StepStatus result = implementation_->solver->stepOnce(timeStep);
    implementation_->status.lastSubstepMilliseconds = millisecondsSince(start);
    implementation_->status.substepCount = implementation_->solver->diagnostics().substepCount;
    return result;
}

bool CpuBackend::setConfiguration(const swe::SolverConfiguration configuration) noexcept {
    if (!configuration.isValid()) {
        return false;
    }
    const std::size_t workers = configuration.workerCount == 0
        ? std::max<std::size_t>(std::thread::hardware_concurrency(), 1)
        : configuration.workerCount;
    implementation_->configuration = configuration;
    if (implementation_->solver->workerCount() != workers) {
        implementation_->rebuildSolver();
        return true;
    }
    const bool changed = implementation_->solver->setConfiguration(configuration);
    if (changed) {
        implementation_->editor = std::make_unique<swe::TerrainEditor>(
            implementation_->state, configuration.minimumWetDepth);
    }
    return changed;
}

bool CpuBackend::setBoundaryConfiguration(const swe::BoundaryConfiguration boundaries,
                                          std::string& failureReason) noexcept {
    const bool result = implementation_->solver->setBoundaryConfiguration(boundaries);
    if (!result) {
        failureReason = "Invalid boundary configuration";
    }
    return result;
}

BackendState CpuBackend::synchronizeToHost(std::string&) const {
    return exportState(implementation_->state);
}

BackendSnapshot CpuBackend::makeSnapshot(std::string&) const {
    const auto start = Clock::now();
    const swe::SimulationState& state = implementation_->state;
    const swe::GridGeometry& geometry = state.geometry();
    BackendSnapshot result{
        .width = geometry.width,
        .height = geometry.height,
        .domainWidth = geometry.domainWidth,
        .domainHeight = geometry.domainHeight,
        .bedElevation = std::vector<float>(geometry.width * geometry.height),
        .waterDepth = std::vector<float>(geometry.width * geometry.height),
        .surfaceElevation = std::vector<float>(geometry.width * geometry.height),
        .surfaceDeviation = std::vector<float>(geometry.width * geometry.height),
        .velocityMagnitude = std::vector<float>(geometry.width * geometry.height),
        .wetMask = std::vector<std::uint8_t>(geometry.width * geometry.height),
        .diagnostics = implementation_->solver->diagnostics(),
    };
    for (std::size_t row = 0; row < geometry.height; ++row) {
        for (std::size_t column = 0; column < geometry.width; ++column) {
            const std::size_t index = row * geometry.width + column;
            const double bed = state.bedElevation()(column, row);
            const double depth = state.waterDepth()(column, row);
            const double surface = bed + depth;
            const double velocityX = 0.5 * (state.velX()(column, row) +
                                            state.velX()(column + 1, row));
            const double velocityY = 0.5 * (state.velY()(column, row) +
                                            state.velY()(column, row + 1));
            result.bedElevation[index] = static_cast<float>(bed);
            result.waterDepth[index] = static_cast<float>(depth);
            result.surfaceElevation[index] = static_cast<float>(surface);
            result.surfaceDeviation[index] = static_cast<float>(
                surface - implementation_->referenceSurface[index]);
            result.velocityMagnitude[index] = static_cast<float>(
                std::sqrt(velocityX * velocityX + velocityY * velocityY));
            result.wetMask[index] = depth > implementation_->configuration.minimumWetDepth ? 1 : 0;
        }
    }
    implementation_->status.lastReadbackMilliseconds = millisecondsSince(start);
    return result;
}

swe::TerrainEditResult CpuBackend::applyMaterialBrush(
    const swe::BrushCommand& command) noexcept {
    const swe::TerrainEditResult result = implementation_->editor->applyBrush(command);
    implementation_->solver->stateWasEdited();
    if (result.changed() && command.material.target == swe::EditTarget::initialState) {
        const auto bed = implementation_->state.initialBedElevation().values();
        const auto depth = implementation_->state.initialWaterDepth().values();
        for (std::size_t index = 0; index < bed.size(); ++index) {
            implementation_->referenceSurface[index] = bed[index] + depth[index];
        }
    }
    return result;
}

swe::TerrainEditResult CpuBackend::applyMaterialPolygon(
    const swe::PolygonCommand& command) noexcept {
    const swe::TerrainEditResult result = implementation_->editor->applyPolygon(command);
    implementation_->solver->stateWasEdited();
    if (result.changed() && command.material.target == swe::EditTarget::initialState) {
        const auto bed = implementation_->state.initialBedElevation().values();
        const auto depth = implementation_->state.initialWaterDepth().values();
        for (std::size_t index = 0; index < bed.size(); ++index) {
            implementation_->referenceSurface[index] = bed[index] + depth[index];
        }
    }
    return result;
}

const swe::Diagnostics& CpuBackend::diagnostics() const noexcept {
    return implementation_->solver->diagnostics();
}

const BackendStatus& CpuBackend::status() const noexcept {
    return implementation_->status;
}

} // namespace tide::accelerated
