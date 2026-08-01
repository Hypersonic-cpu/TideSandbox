#include "WeakNonlinearSolver.hh"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cmath>
#include <limits>
#include <utility>

namespace tide::swe {

namespace {

using ProfileClock = std::chrono::steady_clock;

class ScopedProfileTimer final {
public:
    ScopedProfileTimer(const bool enabled, double& destination) noexcept
        : enabled_(enabled), destination_(destination), start_(enabled ? ProfileClock::now()
                                                                    : ProfileClock::time_point{}) {}

    ~ScopedProfileTimer() {
        if (enabled_) {
            destination_ += std::chrono::duration<double>(ProfileClock::now() - start_).count();
        }
    }

private:
    const bool enabled_;
    double& destination_;
    const ProfileClock::time_point start_;
};

[[nodiscard]] ProfileClock::time_point profileStart(const bool enabled) noexcept {
    return enabled ? ProfileClock::now() : ProfileClock::time_point{};
}

void profileFinish(const bool enabled, double& destination,
                   const ProfileClock::time_point start) noexcept {
    if (enabled) {
        destination += std::chrono::duration<double>(ProfileClock::now() - start).count();
    }
}

struct HydrostaticFace final {
    double firstDepth = 0.0;
    double secondDepth = 0.0;
    double firstSurface = 0.0;
    double secondSurface = 0.0;
};

[[nodiscard]] HydrostaticFace reconstructFace(const double firstBed,
                                              const double firstDepth,
                                              const double secondBed,
                                              const double secondDepth,
                                              const double minimumWetDepth) noexcept {
    const double faceBed = std::max(firstBed, secondBed);
    double connectedFirst = std::max(0.0, firstBed + firstDepth - faceBed);
    double connectedSecond = std::max(0.0, secondBed + secondDepth - faceBed);
    connectedFirst = connectedFirst <= minimumWetDepth ? 0.0 : connectedFirst;
    connectedSecond = connectedSecond <= minimumWetDepth ? 0.0 : connectedSecond;
    return {
        .firstDepth = connectedFirst,
        .secondDepth = connectedSecond,
        .firstSurface = faceBed + connectedFirst,
        .secondSurface = faceBed + connectedSecond,
    };
}

[[nodiscard]] HydrostaticFace reconstructBoundaryFace(
    const BoundarySide& boundary,
    const double interiorBed,
    const double interiorDepth,
    const double time,
    const double minimumWetDepth) noexcept {
    switch (boundary.type) {
    case BoundaryType::reflective:
        return {};
    case BoundaryType::freeOpen:
        return reconstructFace(interiorBed, interiorDepth, interiorBed, interiorDepth,
                               minimumWetDepth);
    case BoundaryType::drivenHeight: {
        const double reservoirSurface = boundary.driven.surfaceElevation(time);
        const double reservoirDepth = std::max(reservoirSurface - interiorBed, 0.0);
        return reconstructFace(interiorBed, interiorDepth, interiorBed, reservoirDepth,
                               minimumWetDepth);
    }
    }
    return {};
}

[[nodiscard]] double updateBoundaryOutwardVelocity(
    const BoundarySide& boundary,
    const double oldOutwardVelocity,
    const double interiorBed,
    const double interiorDepth,
    const double time,
    const double velocityFactor,
    const double minimumWetDepth) noexcept {
    const HydrostaticFace hydro = reconstructBoundaryFace(
        boundary, interiorBed, interiorDepth, time, minimumWetDepth);
    if (boundary.type == BoundaryType::reflective ||
        (hydro.firstDepth == 0.0 && hydro.secondDepth == 0.0)) {
        return 0.0;
    }
    return oldOutwardVelocity - velocityFactor *
        (hydro.secondSurface - hydro.firstSurface);
}

[[nodiscard]] double boundaryOutwardFlux(
    const BoundarySide& boundary,
    const double outwardVelocity,
    const double interiorBed,
    const double interiorDepth,
    const double time,
    const double minimumWetDepth) noexcept {
    const HydrostaticFace hydro = reconstructBoundaryFace(
        boundary, interiorBed, interiorDepth, time, minimumWetDepth);
    const double donorDepth = outwardVelocity >= 0.0 ? hydro.firstDepth : hydro.secondDepth;
    return donorDepth * outwardVelocity;
}

} // namespace

bool SolverConfiguration::isValid() const noexcept {
    return std::isfinite(gravity) && gravity > 0.0 &&
           std::isfinite(linearDamping) && linearDamping >= 0.0 &&
           std::isfinite(cflNumber) && cflNumber > 0.0 && cflNumber <= 1.0 &&
           std::isfinite(minimumWetDepth) && minimumWetDepth >= 0.0 &&
           maximumSubsteps > 0 && serialThreshold > 0 &&
           std::isfinite(debugVelocityBound);
}

WeakNonlinearSolver::WeakNonlinearSolver(SimulationState& state,
                                         SolverConfiguration configuration)
    : state_(state), configuration_(configuration), parallelFor_(configuration.workerCount) {
    assert(state.isInitialized());
    assert(configuration.isValid());
    resizeScratch();
    updateDiagnostics(StepStatus::success);
}

bool WeakNonlinearSolver::setConfiguration(SolverConfiguration configuration) noexcept {
    if (!configuration.isValid()) {
        return false;
    }
    const auto requestedWorkers = configuration.workerCount == 0
        ? std::max<std::size_t>(std::thread::hardware_concurrency(), 1)
        : configuration.workerCount;
    if (requestedWorkers != parallelFor_.workerCount()) {
        return false;
    }
    configuration_ = configuration;
    return true;
}

bool WeakNonlinearSolver::setBoundaryConfiguration(
    BoundaryConfiguration configuration) noexcept {
    if (!state_.setBoundaryConfiguration(configuration)) {
        return false;
    }
    instantaneousBoundaryOutflowRate_.fill(0.0);
    stateWasEdited();
    return true;
}

double WeakNonlinearSolver::stableTimeStep() noexcept {
    const ScopedProfileTimer profileTimer(configuration_.collectPerformanceCounters,
                                          performanceCounters_.stableTimeStepSeconds);
    if (!configuration_.isValid() || !state_.isInitialized()) {
        diagnostics_.status = StepStatus::invalidConfiguration;
        return 0.0;
    }

    double maximumDepth = 0.0;
    for (const auto depth : state_.waterDepth_.values()) {
        if (!std::isfinite(depth) || depth < 0.0) {
            diagnostics_.status = StepStatus::nonFiniteState;
            diagnostics_.finite = false;
            return 0.0;
        }
        maximumDepth = std::max(maximumDepth, depth);
    }

    const BoundaryConfiguration& boundaries = state_.boundaryConfiguration_;
    const double time = state_.time_;
    const auto includeDrivenReservoirDepth = [&](const BoundarySide& side,
                                                  const BoundaryEdge edge) noexcept -> bool {
        if (side.type != BoundaryType::drivenHeight) {
            return true;
        }
        const double surface = side.driven.surfaceElevation(time);
        if (!std::isfinite(surface)) {
            return false;
        }
        const std::size_t count = edge == BoundaryEdge::left || edge == BoundaryEdge::right
            ? state_.geometry_.height : state_.geometry_.width;
        for (std::size_t index = 0; index < count; ++index) {
            const std::size_t column = edge == BoundaryEdge::left ? 0 :
                (edge == BoundaryEdge::right ? state_.geometry_.width - 1 : index);
            const std::size_t row = edge == BoundaryEdge::bottom ? 0 :
                (edge == BoundaryEdge::top ? state_.geometry_.height - 1 : index);
            maximumDepth = std::max(maximumDepth,
                                    std::max(surface - state_.bedElevation_(column, row), 0.0));
        }
        return true;
    };
    if (!includeDrivenReservoirDepth(boundaries.left, BoundaryEdge::left) ||
        !includeDrivenReservoirDepth(boundaries.right, BoundaryEdge::right) ||
        !includeDrivenReservoirDepth(boundaries.bottom, BoundaryEdge::bottom) ||
        !includeDrivenReservoirDepth(boundaries.top, BoundaryEdge::top)) {
        diagnostics_.status = StepStatus::nonFiniteState;
        diagnostics_.finite = false;
        return 0.0;
    }

    double maximumVelX = 0.0;
    for (const auto velocity : state_.velX_.values()) {
        if (!std::isfinite(velocity)) {
            diagnostics_.status = StepStatus::nonFiniteState;
            diagnostics_.finite = false;
            return 0.0;
        }
        maximumVelX = std::max(maximumVelX, std::abs(velocity));
    }
    double maximumVelY = 0.0;
    for (const auto velocity : state_.velY_.values()) {
        if (!std::isfinite(velocity)) {
            diagnostics_.status = StepStatus::nonFiniteState;
            diagnostics_.finite = false;
            return 0.0;
        }
        maximumVelY = std::max(maximumVelY, std::abs(velocity));
    }

    if (configuration_.debugVelocityBound > 0.0 &&
        std::max(maximumVelX, maximumVelY) > configuration_.debugVelocityBound) {
        diagnostics_.status = StepStatus::velocityBoundExceeded;
        return 0.0;
    }

    const auto waveSpeed = std::sqrt(configuration_.gravity * maximumDepth);
    const auto inverseTimeScale = (maximumVelX + waveSpeed) / state_.geometry_.dx() +
                                  (maximumVelY + waveSpeed) / state_.geometry_.dy();
    diagnostics_.maximumWaveSpeed = waveSpeed;
    if (inverseTimeScale == 0.0) {
        return std::numeric_limits<double>::max();
    }
    const auto result = configuration_.cflNumber / inverseTimeScale;
    if (!std::isfinite(result) || result <= 0.0) {
        diagnostics_.status = StepStatus::invalidTimeStep;
        return 0.0;
    }
    return result;
}

StepStatus WeakNonlinearSolver::stepOnce(double timeStep) noexcept {
    resetDiagnostics();
    if (!std::isfinite(timeStep) || timeStep <= 0.0) {
        updateDiagnostics(StepStatus::invalidTimeStep);
        return diagnostics_.status;
    }
    const auto stable = stableTimeStep();
    if (stable <= 0.0 || diagnostics_.status != StepStatus::success) {
        updateDiagnostics(diagnostics_.status);
        return diagnostics_.status;
    }
    if (timeStep > stable * (1.0 + 1.0e-12)) {
        updateDiagnostics(StepStatus::invalidTimeStep);
        return diagnostics_.status;
    }

    diagnostics_.selectedTimeStep = timeStep;
    const auto status = substep(timeStep);
    diagnostics_.substepCount = status == StepStatus::success ? 1 : 0;
    updateDiagnostics(status);
    return status;
}

StepStatus WeakNonlinearSolver::advance(double frameDeltaTime) noexcept {
    resetDiagnostics();
    if (!std::isfinite(frameDeltaTime) || frameDeltaTime <= 0.0) {
        updateDiagnostics(StepStatus::invalidTimeStep);
        return diagnostics_.status;
    }

    auto remaining = frameDeltaTime;
    while (remaining > std::numeric_limits<double>::epsilon() * frameDeltaTime) {
        if (diagnostics_.substepCount == configuration_.maximumSubsteps) {
            updateDiagnostics(StepStatus::substepLimitReached);
            return diagnostics_.status;
        }
        const auto stable = stableTimeStep();
        if (stable <= 0.0 || diagnostics_.status != StepStatus::success) {
            updateDiagnostics(diagnostics_.status);
            return diagnostics_.status;
        }
        const auto timeStep = std::min(remaining, stable);
        diagnostics_.selectedTimeStep = diagnostics_.substepCount == 0
            ? timeStep : std::min(diagnostics_.selectedTimeStep, timeStep);
        const auto status = substep(timeStep);
        if (status != StepStatus::success) {
            updateDiagnostics(status);
            return status;
        }
        remaining -= timeStep;
        ++diagnostics_.substepCount;
    }

    updateDiagnostics(StepStatus::success);
    return StepStatus::success;
}

void WeakNonlinearSolver::resetDiagnostics() noexcept {
    diagnostics_ = {};
    instantaneousBoundaryOutflowRate_.fill(0.0);
}

void WeakNonlinearSolver::stateWasEdited() noexcept {
    resetDiagnostics();
    updateDiagnostics(StepStatus::success);
}

std::size_t WeakNonlinearSolver::estimatedFieldStorageBytes() const noexcept {
    const auto width = state_.geometry_.width;
    const auto height = state_.geometry_.height;
    const auto cellValues = width * height;
    const auto xFaceValues = (width + 1) * height;
    const auto yFaceValues = width * (height + 1);
    return (7 * cellValues + 2 * xFaceValues + 2 * yFaceValues) * sizeof(double);
}

StepStatus WeakNonlinearSolver::substep(double timeStep) noexcept {
    const ScopedProfileTimer totalTimer(configuration_.collectPerformanceCounters,
                                        performanceCounters_.totalSubstepSeconds);
    performanceCounters_.profiledSubsteps += configuration_.collectPerformanceCounters ? 1 : 0;
    assert(timeStep > 0.0 && std::isfinite(timeStep));
    const auto width = state_.geometry_.width;
    const auto height = state_.geometry_.height;
    const auto inverseDx = 1.0 / state_.geometry_.dx();
    const auto inverseDy = 1.0 / state_.geometry_.dy();
    const BoundaryConfiguration& boundaries = state_.boundaryConfiguration_;
    const double boundaryTime = state_.time_;

    const auto surfaceStart = profileStart(configuration_.collectPerformanceCounters);
    forRows(height, width * height, [this, width](std::size_t begin, std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            for (std::size_t column = 0; column < width; ++column) {
                surfaceElevation_(column, row) = state_.waterDepth_(column, row) +
                                                 state_.bedElevation_(column, row);
            }
        }
    });
    profileFinish(configuration_.collectPerformanceCounters,
                  performanceCounters_.surfaceSeconds, surfaceStart);

    const auto pressureStart = profileStart(configuration_.collectPerformanceCounters);
    const auto velocityFactor = configuration_.gravity * timeStep * inverseDx;
    forRows(height, (width - 1) * height,
            [this, width, velocityFactor](std::size_t begin, std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            for (std::size_t face = 1; face < width; ++face) {
                const HydrostaticFace hydro = reconstructFace(
                    state_.bedElevation_(face - 1, row), state_.waterDepth_(face - 1, row),
                    state_.bedElevation_(face, row), state_.waterDepth_(face, row),
                    configuration_.minimumWetDepth);
                if (hydro.firstDepth == 0.0 && hydro.secondDepth == 0.0) {
                    state_.velX_(face, row) = 0.0;
                    continue;
                }
                state_.velX_(face, row) -= velocityFactor *
                    (hydro.secondSurface - hydro.firstSurface);
            }
        }
    });

    const auto verticalVelocityFactor = configuration_.gravity * timeStep * inverseDy;
    forRows(height - 1, width * (height - 1),
            [this, width, verticalVelocityFactor](std::size_t begin, std::size_t end) noexcept {
        for (auto row = begin + 1; row < end + 1; ++row) {
            for (std::size_t column = 0; column < width; ++column) {
                const HydrostaticFace hydro = reconstructFace(
                    state_.bedElevation_(column, row - 1), state_.waterDepth_(column, row - 1),
                    state_.bedElevation_(column, row), state_.waterDepth_(column, row),
                    configuration_.minimumWetDepth);
                if (hydro.firstDepth == 0.0 && hydro.secondDepth == 0.0) {
                    state_.velY_(column, row) = 0.0;
                    continue;
                }
                state_.velY_(column, row) -= verticalVelocityFactor *
                    (hydro.secondSurface - hydro.firstSurface);
            }
        }
    });
    forRows(height, 2 * height,
            [this, width, velocityFactor, boundaryTime, &boundaries](
                std::size_t begin, std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            const double leftOutward = updateBoundaryOutwardVelocity(
                boundaries.left, -state_.velX_(0, row),
                state_.bedElevation_(0, row), state_.waterDepth_(0, row), boundaryTime,
                velocityFactor, configuration_.minimumWetDepth);
            state_.velX_(0, row) = -leftOutward;
            const double rightOutward = updateBoundaryOutwardVelocity(
                boundaries.right, state_.velX_(width, row),
                state_.bedElevation_(width - 1, row), state_.waterDepth_(width - 1, row),
                boundaryTime, velocityFactor, configuration_.minimumWetDepth);
            state_.velX_(width, row) = rightOutward;
        }
    });
    forRows(width, 2 * width,
            [this, height, verticalVelocityFactor, boundaryTime, &boundaries](
                std::size_t begin, std::size_t end) noexcept {
        for (auto column = begin; column < end; ++column) {
            const double bottomOutward = updateBoundaryOutwardVelocity(
                boundaries.bottom, -state_.velY_(column, 0),
                state_.bedElevation_(column, 0), state_.waterDepth_(column, 0), boundaryTime,
                verticalVelocityFactor, configuration_.minimumWetDepth);
            state_.velY_(column, 0) = -bottomOutward;
            const double topOutward = updateBoundaryOutwardVelocity(
                boundaries.top, state_.velY_(column, height),
                state_.bedElevation_(column, height - 1),
                state_.waterDepth_(column, height - 1), boundaryTime,
                verticalVelocityFactor, configuration_.minimumWetDepth);
            state_.velY_(column, height) = topOutward;
        }
    });
    profileFinish(configuration_.collectPerformanceCounters,
                  performanceCounters_.pressureSeconds, pressureStart);

    const auto dampingStart = profileStart(configuration_.collectPerformanceCounters);
    const auto damping = std::exp(-configuration_.linearDamping * timeStep);
    forRows(height, state_.velX_.size(), [this, width, damping, &boundaries](std::size_t begin,
                                                                            std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            state_.velX_(0, row) = boundaries.left.type == BoundaryType::reflective
                ? 0.0 : state_.velX_(0, row) * damping;
            for (std::size_t face = 1; face < width; ++face) {
                state_.velX_(face, row) *= damping;
            }
            state_.velX_(width, row) = boundaries.right.type == BoundaryType::reflective
                ? 0.0 : state_.velX_(width, row) * damping;
        }
    });
    forRows(height + 1, state_.velY_.size(),
            [this, width, height, damping, &boundaries](std::size_t begin,
                                                        std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            for (std::size_t column = 0; column < width; ++column) {
                if (row == 0) {
                    state_.velY_(column, row) = boundaries.bottom.type == BoundaryType::reflective
                        ? 0.0 : state_.velY_(column, row) * damping;
                } else if (row == height) {
                    state_.velY_(column, row) = boundaries.top.type == BoundaryType::reflective
                        ? 0.0 : state_.velY_(column, row) * damping;
                } else {
                    state_.velY_(column, row) *= damping;
                }
            }
        }
    });
    profileFinish(configuration_.collectPerformanceCounters,
                  performanceCounters_.dampingSeconds, dampingStart);

    const auto fluxStart = profileStart(configuration_.collectPerformanceCounters);
    forRows(height, fluxX_.size(),
            [this, width, boundaryTime, &boundaries](std::size_t begin,
                                                     std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            const double leftOutwardFlux = boundaryOutwardFlux(
                boundaries.left, -state_.velX_(0, row),
                state_.bedElevation_(0, row), state_.waterDepth_(0, row), boundaryTime,
                configuration_.minimumWetDepth);
            fluxX_(0, row) = -leftOutwardFlux;
            for (std::size_t face = 1; face < width; ++face) {
                const double velocity = state_.velX_(face, row);
                const HydrostaticFace hydro = reconstructFace(
                    state_.bedElevation_(face - 1, row), state_.waterDepth_(face - 1, row),
                    state_.bedElevation_(face, row), state_.waterDepth_(face, row),
                    configuration_.minimumWetDepth);
                const double depth = velocity >= 0.0 ? hydro.firstDepth : hydro.secondDepth;
                fluxX_(face, row) = depth * velocity;
            }
            fluxX_(width, row) = boundaryOutwardFlux(
                boundaries.right, state_.velX_(width, row),
                state_.bedElevation_(width - 1, row), state_.waterDepth_(width - 1, row),
                boundaryTime, configuration_.minimumWetDepth);
        }
    });
    forRows(height + 1, fluxY_.size(),
            [this, width, height, boundaryTime, &boundaries](std::size_t begin,
                                                             std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            for (std::size_t column = 0; column < width; ++column) {
                if (row == 0) {
                    fluxY_(column, row) = -boundaryOutwardFlux(
                        boundaries.bottom, -state_.velY_(column, row),
                        state_.bedElevation_(column, 0), state_.waterDepth_(column, 0),
                        boundaryTime, configuration_.minimumWetDepth);
                    continue;
                }
                if (row == height) {
                    fluxY_(column, row) = boundaryOutwardFlux(
                        boundaries.top, state_.velY_(column, row),
                        state_.bedElevation_(column, height - 1),
                        state_.waterDepth_(column, height - 1), boundaryTime,
                        configuration_.minimumWetDepth);
                    continue;
                }
                const double velocity = state_.velY_(column, row);
                const HydrostaticFace hydro = reconstructFace(
                    state_.bedElevation_(column, row - 1), state_.waterDepth_(column, row - 1),
                    state_.bedElevation_(column, row), state_.waterDepth_(column, row),
                    configuration_.minimumWetDepth);
                const double depth = velocity >= 0.0 ? hydro.firstDepth : hydro.secondDepth;
                fluxY_(column, row) = depth * velocity;
            }
        }
    });
    profileFinish(configuration_.collectPerformanceCounters,
                  performanceCounters_.fluxSeconds, fluxStart);

    const auto limiterScaleStart = profileStart(configuration_.collectPerformanceCounters);
    forRows(height, width * height,
            [this, width, timeStep, inverseDx, inverseDy](std::size_t begin,
                                                          std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            for (std::size_t column = 0; column < width; ++column) {
                const auto outgoingDepth = timeStep * inverseDx *
                    (std::max(fluxX_(column + 1, row), 0.0) +
                     std::max(-fluxX_(column, row), 0.0)) +
                    timeStep * inverseDy *
                    (std::max(fluxY_(column, row + 1), 0.0) +
                     std::max(-fluxY_(column, row), 0.0));
                const auto depth = state_.waterDepth_(column, row);
                outgoingScale_(column, row) = outgoingDepth > depth && outgoingDepth > 0.0
                    ? depth / outgoingDepth : 1.0;
            }
        }
    });
    profileFinish(configuration_.collectPerformanceCounters,
                  performanceCounters_.limiterScaleSeconds, limiterScaleStart);

    const auto fluxLimitStart = profileStart(configuration_.collectPerformanceCounters);
    forRows(height, (width - 1) * height,
            [this, width](std::size_t begin, std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            if (fluxX_(0, row) < 0.0) {
                fluxX_(0, row) *= outgoingScale_(0, row);
            }
            for (std::size_t face = 1; face < width; ++face) {
                auto& flux = fluxX_(face, row);
                flux *= flux >= 0.0 ? outgoingScale_(face - 1, row)
                                    : outgoingScale_(face, row);
            }
            if (fluxX_(width, row) > 0.0) {
                fluxX_(width, row) *= outgoingScale_(width - 1, row);
            }
        }
    });
    forRows(height - 1, width * (height - 1),
            [this, width](std::size_t begin, std::size_t end) noexcept {
        for (auto row = begin + 1; row < end + 1; ++row) {
            for (std::size_t column = 0; column < width; ++column) {
                auto& flux = fluxY_(column, row);
                flux *= flux >= 0.0 ? outgoingScale_(column, row - 1)
                                    : outgoingScale_(column, row);
            }
        }
    });
    for (std::size_t column = 0; column < width; ++column) {
        if (fluxY_(column, 0) < 0.0) {
            fluxY_(column, 0) *= outgoingScale_(column, 0);
        }
        if (fluxY_(column, height) > 0.0) {
            fluxY_(column, height) *= outgoingScale_(column, height - 1);
        }
    }
    profileFinish(configuration_.collectPerformanceCounters,
                  performanceCounters_.fluxLimitSeconds, fluxLimitStart);

    BoundaryValues substepOutflowRates{};
    for (std::size_t row = 0; row < height; ++row) {
        substepOutflowRates[boundaryIndex(BoundaryEdge::left)] -=
            state_.geometry_.dy() * fluxX_(0, row);
        substepOutflowRates[boundaryIndex(BoundaryEdge::right)] +=
            state_.geometry_.dy() * fluxX_(width, row);
    }
    for (std::size_t column = 0; column < width; ++column) {
        substepOutflowRates[boundaryIndex(BoundaryEdge::bottom)] -=
            state_.geometry_.dx() * fluxY_(column, 0);
        substepOutflowRates[boundaryIndex(BoundaryEdge::top)] +=
            state_.geometry_.dx() * fluxY_(column, height);
    }
    instantaneousBoundaryOutflowRate_ = substepOutflowRates;
    for (std::size_t edge = 0; edge < boundaryEdgeCount; ++edge) {
        state_.cumulativeBoundaryVolume_[edge] += timeStep * substepOutflowRates[edge];
    }

    const auto continuityStart = profileStart(configuration_.collectPerformanceCounters);
    forRows(height, width * height,
            [this, width, timeStep, inverseDx, inverseDy](std::size_t begin,
                                                          std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            for (std::size_t column = 0; column < width; ++column) {
                nextWaterDepth_(column, row) = state_.waterDepth_(column, row) -
                    timeStep * inverseDx *
                        (fluxX_(column + 1, row) - fluxX_(column, row)) -
                    timeStep * inverseDy *
                        (fluxY_(column, row + 1) - fluxY_(column, row));
            }
        }
    });
    profileFinish(configuration_.collectPerformanceCounters,
                  performanceCounters_.continuitySeconds, continuityStart);

    const auto cleanupStart = profileStart(configuration_.collectPerformanceCounters);
    // Cleanup is deliberately serial: corrections are rare and the aggregate remains exact.
    const auto cellArea = state_.geometry_.dx() * state_.geometry_.dy();
    for (auto& depth : nextWaterDepth_.values()) {
        if (depth <= configuration_.minimumWetDepth) {
            if (depth != 0.0) {
                diagnostics_.correctionVolume += std::abs(depth) * cellArea;
                ++diagnostics_.correctionCount;
            }
            depth = 0.0;
        }
    }
    state_.waterDepth_.swapValues(nextWaterDepth_);
    profileFinish(configuration_.collectPerformanceCounters,
                  performanceCounters_.cleanupSeconds, cleanupStart);

    const auto dryVelocityStart = profileStart(configuration_.collectPerformanceCounters);
    forRows(height, (width - 1) * height,
            [this, width](std::size_t begin, std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            for (std::size_t face = 1; face < width; ++face) {
                const double velocity = state_.velX_(face, row);
                const HydrostaticFace hydro = reconstructFace(
                    state_.bedElevation_(face - 1, row), state_.waterDepth_(face - 1, row),
                    state_.bedElevation_(face, row), state_.waterDepth_(face, row),
                    configuration_.minimumWetDepth);
                const double donorDepth = velocity >= 0.0 ? hydro.firstDepth : hydro.secondDepth;
                if (donorDepth == 0.0) {
                    state_.velX_(face, row) = 0.0;
                }
            }
        }
    });
    forRows(height - 1, width * (height - 1),
            [this, width](std::size_t begin, std::size_t end) noexcept {
        for (auto row = begin + 1; row < end + 1; ++row) {
            for (std::size_t column = 0; column < width; ++column) {
                const double velocity = state_.velY_(column, row);
                const HydrostaticFace hydro = reconstructFace(
                    state_.bedElevation_(column, row - 1), state_.waterDepth_(column, row - 1),
                    state_.bedElevation_(column, row), state_.waterDepth_(column, row),
                    configuration_.minimumWetDepth);
                const double donorDepth = velocity >= 0.0 ? hydro.firstDepth : hydro.secondDepth;
                if (donorDepth == 0.0) {
                    state_.velY_(column, row) = 0.0;
                }
            }
        }
    });
    const double cleanupBoundaryTime = boundaryTime + timeStep;
    for (std::size_t row = 0; row < height; ++row) {
        const double leftOutwardVelocity = -state_.velX_(0, row);
        if (boundaryOutwardFlux(boundaries.left, leftOutwardVelocity,
                                state_.bedElevation_(0, row), state_.waterDepth_(0, row),
                                cleanupBoundaryTime, configuration_.minimumWetDepth) == 0.0) {
            state_.velX_(0, row) = 0.0;
        }
        const double rightOutwardVelocity = state_.velX_(width, row);
        if (boundaryOutwardFlux(boundaries.right, rightOutwardVelocity,
                                state_.bedElevation_(width - 1, row),
                                state_.waterDepth_(width - 1, row), cleanupBoundaryTime,
                                configuration_.minimumWetDepth) == 0.0) {
            state_.velX_(width, row) = 0.0;
        }
    }
    for (std::size_t column = 0; column < width; ++column) {
        const double bottomOutwardVelocity = -state_.velY_(column, 0);
        if (boundaryOutwardFlux(boundaries.bottom, bottomOutwardVelocity,
                                state_.bedElevation_(column, 0), state_.waterDepth_(column, 0),
                                cleanupBoundaryTime, configuration_.minimumWetDepth) == 0.0) {
            state_.velY_(column, 0) = 0.0;
        }
        const double topOutwardVelocity = state_.velY_(column, height);
        if (boundaryOutwardFlux(boundaries.top, topOutwardVelocity,
                                state_.bedElevation_(column, height - 1),
                                state_.waterDepth_(column, height - 1), cleanupBoundaryTime,
                                configuration_.minimumWetDepth) == 0.0) {
            state_.velY_(column, height) = 0.0;
        }
    }
    profileFinish(configuration_.collectPerformanceCounters,
                  performanceCounters_.dryVelocitySeconds, dryVelocityStart);

    state_.time_ += timeStep;
    const auto validationStart = profileStart(configuration_.collectPerformanceCounters);
    const auto status = inspectFiniteState();
    diagnostics_.status = status;
    diagnostics_.finite = status != StepStatus::nonFiniteState;
    profileFinish(configuration_.collectPerformanceCounters,
                  performanceCounters_.validationSeconds, validationStart);
    assert(status == StepStatus::success && "invalid numerical state after solver substep");
    return status;
}

StepStatus WeakNonlinearSolver::inspectFiniteState() noexcept {
    if (!state_.boundaryConfiguration_.isValid(
            state_.worldLimits_.minimumBedElevation,
            state_.worldLimits_.maximumSurfaceElevation)) {
        return StepStatus::nonFiniteState;
    }
    for (std::size_t index = 0; index < state_.waterDepth_.size(); ++index) {
        const double bed = state_.bedElevation_.values()[index];
        const double depth = state_.waterDepth_.values()[index];
        if (!std::isfinite(bed) || !std::isfinite(depth) ||
            bed < state_.worldLimits_.minimumBedElevation || depth < 0.0 ||
            bed + depth > state_.worldLimits_.maximumSurfaceElevation) {
            return StepStatus::nonFiniteState;
        }
    }
    for (const auto velocity : state_.velX_.values()) {
        if (!std::isfinite(velocity)) {
            return StepStatus::nonFiniteState;
        }
        if (configuration_.debugVelocityBound > 0.0 &&
            std::abs(velocity) > configuration_.debugVelocityBound) {
            return StepStatus::velocityBoundExceeded;
        }
    }
    for (const auto velocity : state_.velY_.values()) {
        if (!std::isfinite(velocity)) {
            return StepStatus::nonFiniteState;
        }
        if (configuration_.debugVelocityBound > 0.0 &&
            std::abs(velocity) > configuration_.debugVelocityBound) {
            return StepStatus::velocityBoundExceeded;
        }
    }
    for (const double volume : state_.cumulativeBoundaryVolume_) {
        if (!std::isfinite(volume)) {
            return StepStatus::nonFiniteState;
        }
    }
    return StepStatus::success;
}

void WeakNonlinearSolver::updateDiagnostics(StepStatus status) noexcept {
    const ScopedProfileTimer profileTimer(configuration_.collectPerformanceCounters,
                                          performanceCounters_.diagnosticsSeconds);
    diagnostics_.status = status;
    diagnostics_.finite = status != StepStatus::nonFiniteState;
    diagnostics_.simulatedTime = state_.time_;
    diagnostics_.minimumDepth = std::numeric_limits<double>::max();
    diagnostics_.maximumDepth = 0.0;
    diagnostics_.wetCellCount = 0;
    double depthSum = 0.0;
    for (const auto depth : state_.waterDepth_.values()) {
        diagnostics_.finite = diagnostics_.finite && std::isfinite(depth);
        diagnostics_.minimumDepth = std::min(diagnostics_.minimumDepth, depth);
        diagnostics_.maximumDepth = std::max(diagnostics_.maximumDepth, depth);
        depthSum += depth;
        diagnostics_.wetCellCount += depth > configuration_.minimumWetDepth ? 1 : 0;
    }
    diagnostics_.totalVolume = depthSum * state_.geometry_.dx() * state_.geometry_.dy();
    diagnostics_.maximumWaveSpeed = std::sqrt(configuration_.gravity * diagnostics_.maximumDepth);
    diagnostics_.maximumAbsVelX = 0.0;
    for (const auto velocity : state_.velX_.values()) {
        diagnostics_.finite = diagnostics_.finite && std::isfinite(velocity);
        diagnostics_.maximumAbsVelX = std::max(diagnostics_.maximumAbsVelX, std::abs(velocity));
    }
    diagnostics_.maximumAbsVelY = 0.0;
    for (const auto velocity : state_.velY_.values()) {
        diagnostics_.finite = diagnostics_.finite && std::isfinite(velocity);
        diagnostics_.maximumAbsVelY = std::max(diagnostics_.maximumAbsVelY, std::abs(velocity));
    }
    diagnostics_.instantaneousBoundaryOutflowRate = instantaneousBoundaryOutflowRate_;
    diagnostics_.cumulativeBoundaryOutwardVolume = state_.cumulativeBoundaryVolume_;
    diagnostics_.netBoundaryOutflowRate = 0.0;
    double cumulativeOutflow = 0.0;
    for (std::size_t edge = 0; edge < boundaryEdgeCount; ++edge) {
        diagnostics_.netBoundaryOutflowRate += instantaneousBoundaryOutflowRate_[edge];
        cumulativeOutflow += state_.cumulativeBoundaryVolume_[edge];
    }
    diagnostics_.accountedExpectedVolume = state_.initialWaterVolume_ +
        state_.accumulatedEditWaterVolume_ - cumulativeOutflow;
    diagnostics_.accountingError = diagnostics_.totalVolume -
        diagnostics_.accountedExpectedVolume;
}

void WeakNonlinearSolver::resizeScratch() {
    const auto width = state_.geometry_.width;
    const auto height = state_.geometry_.height;
    surfaceElevation_.resize(width, height);
    nextWaterDepth_.resize(width, height);
    outgoingScale_.resize(width, height, 1.0);
    fluxX_.resize(width + 1, height);
    fluxY_.resize(width, height + 1);
}

} // namespace tide::swe
