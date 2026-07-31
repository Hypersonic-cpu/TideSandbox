#pragma once

#include "Grid.hh"

#include <span>

namespace tide::swe {

class WeakNonlinearSolver;
class TerrainEditor;

class SimulationState final {
public:
    SimulationState() = default;
    explicit SimulationState(GridGeometry geometry);

    [[nodiscard]] bool initializeLevelLake(GridGeometry geometry,
                                           std::span<const double> bedElevation,
                                           double initialSurfaceLevel) noexcept;
    [[nodiscard]] bool initializeDepth(GridGeometry geometry,
                                       std::span<const double> bedElevation,
                                       std::span<const double> waterDepth) noexcept;
    void reset() noexcept;

    [[nodiscard]] const GridGeometry& geometry() const noexcept { return geometry_; }
    [[nodiscard]] const CellField& bedElevation() const noexcept { return bedElevation_; }
    [[nodiscard]] const CellField& waterDepth() const noexcept { return waterDepth_; }
    [[nodiscard]] const FaceField& velX() const noexcept { return velX_; }
    [[nodiscard]] const FaceField& velY() const noexcept { return velY_; }
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
    double time_ = 0.0;

    friend class WeakNonlinearSolver;
    friend class TerrainEditor;
};

} // namespace tide::swe
