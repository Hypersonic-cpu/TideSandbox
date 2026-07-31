#pragma once

#include "SimulationState.hh"

#include <cstddef>
#include <span>

namespace tide::swe {

struct Point2D final {
    double x = 0.0;
    double y = 0.0;
};

enum class EditTarget {
    initialState,
    pausedCurrentState,
};

enum class MaterialOperation {
    addSand,
    removeSand,
    addWater,
    removeWater,
};

enum class BrushFalloff {
    constant,
    linear,
    smooth,
};

struct MaterialEdit final {
    MaterialOperation operation = MaterialOperation::addSand;
    double amount = 0.1;
    EditTarget target = EditTarget::initialState;
};

struct BrushGeometry final {
    Point2D center;
    double radius = 1.0;
    BrushFalloff falloff = BrushFalloff::smooth;
};

struct BrushCommand final {
    BrushGeometry geometry;
    MaterialEdit material;
};

struct PolygonCommand final {
    std::span<const Point2D> vertices;
    MaterialEdit material;
};

enum class TerrainEditStatus {
    success,
    invalidCommand,
    malformedPolygon,
};

struct TerrainEditResult final {
    TerrainEditStatus status = TerrainEditStatus::success;
    std::size_t changedCells = 0;
    std::size_t changedFaces = 0;
    double sandVolumeDelta = 0.0;
    double waterVolumeDelta = 0.0;
    bool clamped = false;
    std::size_t newlyWetCells = 0;
    std::size_t newlyDryCells = 0;

    [[nodiscard]] bool changed() const noexcept { return changedCells != 0; }
};

class TerrainEditor final {
public:
    explicit TerrainEditor(SimulationState& state, double minimumWetDepth = 1.0e-6);

    [[nodiscard]] TerrainEditResult applyBrush(const BrushCommand& command) noexcept;
    [[nodiscard]] TerrainEditResult applyPolygon(const PolygonCommand& command) noexcept;

private:
    [[nodiscard]] TerrainEditResult applyWeighted(const MaterialEdit& edit) noexcept;
    void resizeScratch();

    SimulationState& state_;
    CellField weights_;
    CellField candidateBed_;
    CellField candidateDepth_;
    CellField retainedDepth_;
    double minimumWetDepth_ = 1.0e-6;
};

} // namespace tide::swe
