#include "WeakNonlinearSolver.hh"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <limits>
#include <utility>

namespace tide::swe {

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

double WeakNonlinearSolver::stableTimeStep() noexcept {
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
}

StepStatus WeakNonlinearSolver::substep(double timeStep) noexcept {
    assert(timeStep > 0.0 && std::isfinite(timeStep));
    const auto width = state_.geometry_.width;
    const auto height = state_.geometry_.height;
    const auto inverseDx = 1.0 / state_.geometry_.dx();
    const auto inverseDy = 1.0 / state_.geometry_.dy();

    forRows(height, width * height, [this, width](std::size_t begin, std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            for (std::size_t column = 0; column < width; ++column) {
                surfaceElevation_(column, row) = state_.waterDepth_(column, row) +
                                                 state_.bedElevation_(column, row);
            }
        }
    });

    const auto velocityFactor = configuration_.gravity * timeStep * inverseDx;
    forRows(height, (width - 1) * height,
            [this, width, velocityFactor](std::size_t begin, std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            for (std::size_t face = 1; face < width; ++face) {
                const auto leftDepth = state_.waterDepth_(face - 1, row);
                const auto rightDepth = state_.waterDepth_(face, row);
                auto leftSurface = surfaceElevation_(face - 1, row);
                auto rightSurface = surfaceElevation_(face, row);
                if (leftDepth == 0.0 && rightDepth == 0.0) {
                    state_.velX_(face, row) = 0.0;
                    continue;
                }
                if (leftDepth == 0.0) {
                    leftSurface = std::min(leftSurface, rightSurface);
                } else if (rightDepth == 0.0) {
                    rightSurface = std::min(rightSurface, leftSurface);
                }
                state_.velX_(face, row) -= velocityFactor * (rightSurface - leftSurface);
            }
        }
    });

    const auto verticalVelocityFactor = configuration_.gravity * timeStep * inverseDy;
    forRows(height - 1, width * (height - 1),
            [this, width, verticalVelocityFactor](std::size_t begin, std::size_t end) noexcept {
        for (auto row = begin + 1; row < end + 1; ++row) {
            for (std::size_t column = 0; column < width; ++column) {
                const auto lowerDepth = state_.waterDepth_(column, row - 1);
                const auto upperDepth = state_.waterDepth_(column, row);
                auto lowerSurface = surfaceElevation_(column, row - 1);
                auto upperSurface = surfaceElevation_(column, row);
                if (lowerDepth == 0.0 && upperDepth == 0.0) {
                    state_.velY_(column, row) = 0.0;
                    continue;
                }
                if (lowerDepth == 0.0) {
                    lowerSurface = std::min(lowerSurface, upperSurface);
                } else if (upperDepth == 0.0) {
                    upperSurface = std::min(upperSurface, lowerSurface);
                }
                state_.velY_(column, row) -= verticalVelocityFactor *
                    (upperSurface - lowerSurface);
            }
        }
    });

    const auto damping = std::exp(-configuration_.linearDamping * timeStep);
    forRows(height, state_.velX_.size(), [this, width, damping](std::size_t begin,
                                                               std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            state_.velX_(0, row) = 0.0;
            for (std::size_t face = 1; face < width; ++face) {
                state_.velX_(face, row) *= damping;
            }
            state_.velX_(width, row) = 0.0;
        }
    });
    forRows(height + 1, state_.velY_.size(), [this, width, height, damping](std::size_t begin,
                                                                          std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            for (std::size_t column = 0; column < width; ++column) {
                state_.velY_(column, row) = row == 0 || row == height
                    ? 0.0 : state_.velY_(column, row) * damping;
            }
        }
    });

    forRows(height, fluxX_.size(), [this, width](std::size_t begin,
                                                        std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            upwindDepthX_(0, row) = 0.0;
            fluxX_(0, row) = 0.0;
            for (std::size_t face = 1; face < width; ++face) {
                const auto velocity = state_.velX_(face, row);
                const auto depth = velocity >= 0.0 ? state_.waterDepth_(face - 1, row)
                                                   : state_.waterDepth_(face, row);
                upwindDepthX_(face, row) = depth;
                fluxX_(face, row) = depth * velocity;
            }
            upwindDepthX_(width, row) = 0.0;
            fluxX_(width, row) = 0.0;
        }
    });
    forRows(height + 1, fluxY_.size(), [this, width, height](std::size_t begin,
                                                                  std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            for (std::size_t column = 0; column < width; ++column) {
                if (row == 0 || row == height) {
                    upwindDepthY_(column, row) = 0.0;
                    fluxY_(column, row) = 0.0;
                    continue;
                }
                const auto velocity = state_.velY_(column, row);
                const auto depth = velocity >= 0.0 ? state_.waterDepth_(column, row - 1)
                                                   : state_.waterDepth_(column, row);
                upwindDepthY_(column, row) = depth;
                fluxY_(column, row) = depth * velocity;
            }
        }
    });

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

    forRows(height, (width - 1) * height,
            [this, width](std::size_t begin, std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            for (std::size_t face = 1; face < width; ++face) {
                auto& flux = fluxX_(face, row);
                flux *= flux >= 0.0 ? outgoingScale_(face - 1, row)
                                    : outgoingScale_(face, row);
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

    // Cleanup is deliberately serial: corrections are rare and the aggregate remains exact.
    const auto cellArea = state_.geometry_.dx() * state_.geometry_.dy();
    for (auto& depth : nextWaterDepth_.values()) {
        if (depth < configuration_.minimumWetDepth) {
            if (depth != 0.0) {
                diagnostics_.correctionVolume += std::abs(depth) * cellArea;
                ++diagnostics_.correctionCount;
            }
            depth = 0.0;
        }
    }
    state_.waterDepth_.swapValues(nextWaterDepth_);

    forRows(height, (width - 1) * height,
            [this, width](std::size_t begin, std::size_t end) noexcept {
        for (auto row = begin; row < end; ++row) {
            for (std::size_t face = 1; face < width; ++face) {
                const auto velocity = state_.velX_(face, row);
                const auto donorDepth = velocity >= 0.0 ? state_.waterDepth_(face - 1, row)
                                                        : state_.waterDepth_(face, row);
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
                const auto velocity = state_.velY_(column, row);
                const auto donorDepth = velocity >= 0.0 ? state_.waterDepth_(column, row - 1)
                                                        : state_.waterDepth_(column, row);
                if (donorDepth == 0.0) {
                    state_.velY_(column, row) = 0.0;
                }
            }
        }
    });

    state_.time_ += timeStep;
    const auto status = inspectFiniteState();
    diagnostics_.status = status;
    diagnostics_.finite = status != StepStatus::nonFiniteState;
    assert(status == StepStatus::success && "invalid numerical state after solver substep");
    return status;
}

StepStatus WeakNonlinearSolver::inspectFiniteState() noexcept {
    for (const auto depth : state_.waterDepth_.values()) {
        if (!std::isfinite(depth) || depth < 0.0) {
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
    return StepStatus::success;
}

void WeakNonlinearSolver::updateDiagnostics(StepStatus status) noexcept {
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
}

void WeakNonlinearSolver::resizeScratch() {
    const auto width = state_.geometry_.width;
    const auto height = state_.geometry_.height;
    surfaceElevation_.resize(width, height);
    nextWaterDepth_.resize(width, height);
    outgoingScale_.resize(width, height, 1.0);
    upwindDepthX_.resize(width + 1, height);
    upwindDepthY_.resize(width, height + 1);
    fluxX_.resize(width + 1, height);
    fluxY_.resize(width, height + 1);
}

} // namespace tide::swe
