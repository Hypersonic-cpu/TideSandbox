#pragma once

#include "Boundary.hh"
#include "Grid.hh"

#include <cmath>
#include <span>

namespace tide::swe {

class WeakNonlinearSolver;
class TerrainEditor;

struct WorldLimits final {
    double minimumBedElevation = -1'000.0;
    double maximumSurfaceElevation = 1'000.0;

    [[nodiscard]] bool isValid() const noexcept {
        return std::isfinite(minimumBedElevation) &&
               std::isfinite(maximumSurfaceElevation) &&
               minimumBedElevation <= maximumSurfaceElevation;
    }
};

class SimulationState final {
public:
    SimulationState() = default;
    explicit SimulationState(GridGeometry geometry);

    [[nodiscard]] bool initializeLevelLake(GridGeometry geometry,
                                           std::span<const double> bedElevation,
                                           double initialSurfaceLevel,
                                           WorldLimits limits = {}) noexcept;
    [[nodiscard]] bool initializeDepth(GridGeometry geometry,
                                       std::span<const double> bedElevation,
                                       std::span<const double> waterDepth,
                                       WorldLimits limits = {},
                                       BoundaryConfiguration boundaries = {}) noexcept;
    void reset() noexcept;
    [[nodiscard]] bool setBoundaryConfiguration(BoundaryConfiguration boundaries) noexcept;
    [[nodiscard]] bool restoreCurrentState(
        std::span<const double> bedElevation,
        std::span<const double> waterDepth,
        std::span<const double> velX,
        std::span<const double> velY,
        double time,
        BoundaryValues cumulativeBoundaryVolume,
        double accumulatedEditWaterVolume) noexcept;

    [[nodiscard]] const GridGeometry& geometry() const noexcept { return geometry_; }
    [[nodiscard]] const CellField& bedElevation() const noexcept { return bedElevation_; }
    [[nodiscard]] const CellField& waterDepth() const noexcept { return waterDepth_; }
    [[nodiscard]] const FaceField& velX() const noexcept { return velX_; }
    [[nodiscard]] const FaceField& velY() const noexcept { return velY_; }
    [[nodiscard]] const CellField& initialBedElevation() const noexcept {
        return initialBedElevation_;
    }
    [[nodiscard]] const CellField& initialWaterDepth() const noexcept {
        return initialWaterDepth_;
    }
    [[nodiscard]] const WorldLimits& worldLimits() const noexcept { return worldLimits_; }
    [[nodiscard]] const BoundaryConfiguration& boundaryConfiguration() const noexcept {
        return boundaryConfiguration_;
    }
    [[nodiscard]] const BoundaryValues& cumulativeBoundaryVolume() const noexcept {
        return cumulativeBoundaryVolume_;
    }
    [[nodiscard]] double initialWaterVolume() const noexcept { return initialWaterVolume_; }
    [[nodiscard]] double accumulatedEditWaterVolume() const noexcept {
        return accumulatedEditWaterVolume_;
    }
    [[nodiscard]] double time() const noexcept { return time_; }
    [[nodiscard]] bool isInitialized() const noexcept { return geometry_.isValid(); }

private:
    void resize(GridGeometry geometry);

    GridGeometry geometry_;
    CellField bedElevation_;
    CellField waterDepth_;
    FaceField velX_;
    FaceField velY_;
    CellField initialBedElevation_;
    CellField initialWaterDepth_;
    WorldLimits worldLimits_;
    BoundaryConfiguration boundaryConfiguration_;
    BoundaryValues cumulativeBoundaryVolume_{};
    double initialWaterVolume_ = 0.0;
    double accumulatedEditWaterVolume_ = 0.0;
    double time_ = 0.0;

    friend class WeakNonlinearSolver;
    friend class TerrainEditor;
};

} // namespace tide::swe
