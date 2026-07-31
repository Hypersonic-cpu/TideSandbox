#pragma once

#include "SimulationState.hh"

#include <span>

namespace tide::swe {

struct Point2D final {
    double x = 0.0;
    double y = 0.0;
};

enum class BrushFalloff {
    constant,
    linear,
    smooth,
};

struct BrushCommand final {
    Point2D center;
    double radius = 1.0;
    double strength = 0.1;
    BrushFalloff falloff = BrushFalloff::smooth;
    double minimumBedElevation = -1'000.0;
    double maximumBedElevation = 1'000.0;
};

enum class PolygonMode {
    add,
    set,
};

struct PolygonCommand final {
    std::span<const Point2D> vertices;
    PolygonMode mode = PolygonMode::add;
    double elevation = 0.0;
    double minimumBedElevation = -1'000.0;
    double maximumBedElevation = 1'000.0;
};

enum class TerrainEditStatus {
    success,
    invalidCommand,
    malformedPolygon,
};

class TerrainEditor final {
public:
    explicit TerrainEditor(SimulationState& state) noexcept : state_(state) {}

    [[nodiscard]] TerrainEditStatus applyBrush(const BrushCommand& command) noexcept;
    [[nodiscard]] TerrainEditStatus applyPolygon(const PolygonCommand& command) noexcept;

private:
    SimulationState& state_;
};

} // namespace tide::swe
