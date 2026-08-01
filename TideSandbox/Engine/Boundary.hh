#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <numbers>

namespace tide::swe {

enum class BoundaryType : std::uint8_t {
    reflective,
    freeOpen,
    drivenHeight,
};

enum class BoundaryEdge : std::uint8_t {
    left,
    right,
    bottom,
    top,
};

inline constexpr std::size_t boundaryEdgeCount = 4;
using BoundaryValues = std::array<double, boundaryEdgeCount>;

[[nodiscard]] constexpr std::size_t boundaryIndex(const BoundaryEdge edge) noexcept {
    return static_cast<std::size_t>(edge);
}

struct DrivenHeightBoundary final {
    double meanSurfaceElevation = 0.0;
    double amplitude = 0.0;
    double periodSeconds = 1.0;
    double phaseRadians = 0.0;
    double rampSeconds = 0.0;

    [[nodiscard]] bool isValid() const noexcept {
        return std::isfinite(meanSurfaceElevation) && std::isfinite(amplitude) &&
               amplitude >= 0.0 && std::isfinite(periodSeconds) && periodSeconds > 0.0 &&
               std::isfinite(phaseRadians) && std::isfinite(rampSeconds) &&
               rampSeconds >= 0.0;
    }

    [[nodiscard]] double surfaceElevation(const double time) const noexcept {
        if (!isValid() || !std::isfinite(time) || time < 0.0) {
            return std::numeric_limits<double>::quiet_NaN();
        }
        double ramp = 1.0;
        if (rampSeconds > 0.0) {
            const double normalized = std::clamp(time / rampSeconds, 0.0, 1.0);
            ramp = normalized * normalized * (3.0 - 2.0 * normalized);
        }
        const double angle = 2.0 * std::numbers::pi * time / periodSeconds + phaseRadians;
        return meanSurfaceElevation + ramp * amplitude * std::sin(angle);
    }
};

struct BoundarySide final {
    BoundaryType type = BoundaryType::reflective;
    DrivenHeightBoundary driven;

    [[nodiscard]] bool isValid(const double minimumElevation,
                               const double maximumElevation) const noexcept {
        switch (type) {
        case BoundaryType::reflective:
        case BoundaryType::freeOpen:
            return true;
        case BoundaryType::drivenHeight:
            return driven.isValid() &&
                   driven.meanSurfaceElevation - driven.amplitude >= minimumElevation &&
                   driven.meanSurfaceElevation + driven.amplitude <= maximumElevation;
        }
        return false;
    }
};

struct BoundaryConfiguration final {
    BoundarySide left;
    BoundarySide right;
    BoundarySide bottom;
    BoundarySide top;

    [[nodiscard]] bool isValid(const double minimumElevation,
                               const double maximumElevation) const noexcept {
        return std::isfinite(minimumElevation) && std::isfinite(maximumElevation) &&
               minimumElevation <= maximumElevation &&
               left.isValid(minimumElevation, maximumElevation) &&
               right.isValid(minimumElevation, maximumElevation) &&
               bottom.isValid(minimumElevation, maximumElevation) &&
               top.isValid(minimumElevation, maximumElevation);
    }

    [[nodiscard]] const BoundarySide& side(const BoundaryEdge edge) const noexcept {
        switch (edge) {
        case BoundaryEdge::left: return left;
        case BoundaryEdge::right: return right;
        case BoundaryEdge::bottom: return bottom;
        case BoundaryEdge::top: return top;
        }
        return left;
    }
};

} // namespace tide::swe
