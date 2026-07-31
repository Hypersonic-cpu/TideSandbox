#include "TerrainEdit.hh"

#include <algorithm>
#include <cmath>

namespace tide::swe {

namespace {

[[nodiscard]] bool finite(Point2D point) noexcept {
    return std::isfinite(point.x) && std::isfinite(point.y);
}

[[nodiscard]] double cross(Point2D a, Point2D b, Point2D c) noexcept {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

[[nodiscard]] bool onSegment(Point2D a, Point2D b, Point2D point) noexcept {
    constexpr double tolerance = 1.0e-12;
    return std::abs(cross(a, b, point)) <= tolerance &&
           point.x >= std::min(a.x, b.x) - tolerance &&
           point.x <= std::max(a.x, b.x) + tolerance &&
           point.y >= std::min(a.y, b.y) - tolerance &&
           point.y <= std::max(a.y, b.y) + tolerance;
}

[[nodiscard]] int orientation(Point2D a, Point2D b, Point2D c) noexcept {
    constexpr double tolerance = 1.0e-12;
    const auto value = cross(a, b, c);
    return value > tolerance ? 1 : (value < -tolerance ? -1 : 0);
}

[[nodiscard]] bool segmentsIntersect(Point2D a, Point2D b, Point2D c, Point2D d) noexcept {
    const auto abc = orientation(a, b, c);
    const auto abd = orientation(a, b, d);
    const auto cda = orientation(c, d, a);
    const auto cdb = orientation(c, d, b);
    if (abc != abd && cda != cdb) {
        return true;
    }
    return (abc == 0 && onSegment(a, b, c)) || (abd == 0 && onSegment(a, b, d)) ||
           (cda == 0 && onSegment(c, d, a)) || (cdb == 0 && onSegment(c, d, b));
}

[[nodiscard]] bool validPolygon(std::span<const Point2D> vertices) noexcept {
    if (vertices.size() < 3) {
        return false;
    }
    for (const auto point : vertices) {
        if (!finite(point)) {
            return false;
        }
    }

    double twiceArea = 0.0;
    for (std::size_t index = 0; index < vertices.size(); ++index) {
        const auto a = vertices[index];
        const auto b = vertices[(index + 1) % vertices.size()];
        if (a.x == b.x && a.y == b.y) {
            return false;
        }
        twiceArea += a.x * b.y - b.x * a.y;
    }
    if (std::abs(twiceArea) <= 1.0e-12) {
        return false;
    }

    for (std::size_t first = 0; first < vertices.size(); ++first) {
        const auto firstNext = (first + 1) % vertices.size();
        for (std::size_t second = first + 1; second < vertices.size(); ++second) {
            const auto secondNext = (second + 1) % vertices.size();
            if (first == second || firstNext == second || secondNext == first) {
                continue;
            }
            if (segmentsIntersect(vertices[first], vertices[firstNext],
                                  vertices[second], vertices[secondNext])) {
                return false;
            }
        }
    }
    return true;
}

[[nodiscard]] bool contains(std::span<const Point2D> vertices, Point2D point) noexcept {
    bool inside = false;
    for (std::size_t current = 0, previous = vertices.size() - 1;
         current < vertices.size(); previous = current++) {
        const auto a = vertices[previous];
        const auto b = vertices[current];
        if (onSegment(a, b, point)) {
            return true;
        }
        const auto crosses = (a.y > point.y) != (b.y > point.y);
        if (crosses) {
            const auto intersectionX = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x;
            if (point.x < intersectionX) {
                inside = !inside;
            }
        }
    }
    return inside;
}

[[nodiscard]] double falloffWeight(BrushFalloff falloff, double normalizedDistance) noexcept {
    switch (falloff) {
    case BrushFalloff::constant:
        return 1.0;
    case BrushFalloff::linear:
        return 1.0 - normalizedDistance;
    case BrushFalloff::smooth: {
        const auto linear = 1.0 - normalizedDistance;
        return linear * linear * (3.0 - 2.0 * linear);
    }
    }
    return 0.0;
}

[[nodiscard]] bool validLimits(double minimum, double maximum) noexcept {
    return std::isfinite(minimum) && std::isfinite(maximum) && minimum <= maximum;
}

} // namespace

TerrainEditStatus TerrainEditor::applyBrush(const BrushCommand& command) noexcept {
    if (!finite(command.center) || !std::isfinite(command.radius) || command.radius <= 0.0 ||
        !std::isfinite(command.strength) || !validLimits(command.minimumBedElevation,
                                                         command.maximumBedElevation)) {
        return TerrainEditStatus::invalidCommand;
    }

    const auto& geometry = state_.geometry_;
    const auto radiusSquared = command.radius * command.radius;
    for (std::size_t row = 0; row < geometry.height; ++row) {
        const auto y = (static_cast<double>(row) + 0.5) * geometry.dy();
        for (std::size_t column = 0; column < geometry.width; ++column) {
            const auto x = (static_cast<double>(column) + 0.5) * geometry.dx();
            const auto deltaX = x - command.center.x;
            const auto deltaY = y - command.center.y;
            const auto distanceSquared = deltaX * deltaX + deltaY * deltaY;
            if (distanceSquared > radiusSquared) {
                continue;
            }
            const auto normalizedDistance = std::sqrt(distanceSquared) / command.radius;
            const auto delta = command.strength *
                               falloffWeight(command.falloff, normalizedDistance);
            auto& bed = state_.bedElevation_(column, row);
            bed = std::clamp(bed + delta, command.minimumBedElevation,
                            command.maximumBedElevation);
        }
    }
    return TerrainEditStatus::success;
}

TerrainEditStatus TerrainEditor::applyPolygon(const PolygonCommand& command) noexcept {
    if (!std::isfinite(command.elevation) ||
        !validLimits(command.minimumBedElevation, command.maximumBedElevation)) {
        return TerrainEditStatus::invalidCommand;
    }
    if (!validPolygon(command.vertices)) {
        return TerrainEditStatus::malformedPolygon;
    }

    const auto& geometry = state_.geometry_;
    for (std::size_t row = 0; row < geometry.height; ++row) {
        const auto y = (static_cast<double>(row) + 0.5) * geometry.dy();
        for (std::size_t column = 0; column < geometry.width; ++column) {
            const auto point = Point2D{(static_cast<double>(column) + 0.5) * geometry.dx(), y};
            if (!contains(command.vertices, point)) {
                continue;
            }
            auto& bed = state_.bedElevation_(column, row);
            const auto edited = command.mode == PolygonMode::add
                ? bed + command.elevation : command.elevation;
            bed = std::clamp(edited, command.minimumBedElevation,
                            command.maximumBedElevation);
        }
    }
    return TerrainEditStatus::success;
}

} // namespace tide::swe
