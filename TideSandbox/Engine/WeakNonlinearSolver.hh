#pragma once

#include "Diagnostics.hh"
#include "Grid.hh"
#include "ParallelFor.hh"
#include "SimulationState.hh"

#include <cstddef>

namespace tide::swe {

struct SolverConfiguration final {
    double gravity = 9.81;
    double linearDamping = 0.08;
    double cflNumber = 0.3;
    double minimumWetDepth = 1.0e-6;
    std::size_t maximumSubsteps = 256;
    std::size_t workerCount = 0; // Zero selects the hardware concurrency.
    std::size_t serialThreshold = 4'096;
    double debugVelocityBound = 0.0; // Non-positive disables the debug bound.

    [[nodiscard]] bool isValid() const noexcept;
};

class WeakNonlinearSolver final {
public:
    WeakNonlinearSolver(SimulationState& state, SolverConfiguration configuration = {});

    WeakNonlinearSolver(const WeakNonlinearSolver&) = delete;
    WeakNonlinearSolver& operator=(const WeakNonlinearSolver&) = delete;

    [[nodiscard]] const SolverConfiguration& configuration() const noexcept {
        return configuration_;
    }
    [[nodiscard]] const Diagnostics& diagnostics() const noexcept { return diagnostics_; }
    [[nodiscard]] std::size_t workerCount() const noexcept { return parallelFor_.workerCount(); }

    // A worker-count change requires constructing a new solver so its persistent pool is explicit.
    [[nodiscard]] bool setConfiguration(SolverConfiguration configuration) noexcept;
    [[nodiscard]] double stableTimeStep() noexcept;
    [[nodiscard]] StepStatus stepOnce(double timeStep) noexcept;
    [[nodiscard]] StepStatus advance(double frameDeltaTime) noexcept;
    void resetDiagnostics() noexcept;

private:
    template <typename Function>
    void forRows(std::size_t rows, std::size_t workItems, Function&& function) noexcept {
        if (parallelFor_.workerCount() == 1 || workItems < configuration_.serialThreshold) {
            function(0, rows);
        } else {
            parallelFor_.forRows(rows, std::forward<Function>(function));
        }
    }

    [[nodiscard]] StepStatus substep(double timeStep) noexcept;
    [[nodiscard]] StepStatus inspectFiniteState() noexcept;
    void updateDiagnostics(StepStatus status) noexcept;
    void resizeScratch();

    SimulationState& state_;
    SolverConfiguration configuration_;
    ParallelFor parallelFor_;
    CellField surfaceElevation_;
    CellField nextWaterDepth_;
    CellField outgoingScale_;
    FaceField upwindDepthX_;
    FaceField upwindDepthY_;
    FaceField fluxX_;
    FaceField fluxY_;
    Diagnostics diagnostics_;
};

} // namespace tide::swe
