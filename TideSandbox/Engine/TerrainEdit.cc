#include "TerrainEdit.hh"

#include <algorithm>
#include <cassert>
#include <cmath>

namespace tide::swe {

namespace {

[[nodiscard]] bool finite(const Point2D point) noexcept {
    return std::isfinite(point.x) && std::isfinite(point.y);
}

[[nodiscard]] double cross(const Point2D a, const Point2D b, const Point2D c) noexcept {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

[[nodiscard]] bool onSegment(const Point2D a, const Point2D b, const Point2D point) noexcept {
    constexpr double tolerance = 1.0e-12;
    return std::abs(cross(a, b, point)) <= tolerance &&
           point.x >= std::min(a.x, b.x) - tolerance &&
           point.x <= std::max(a.x, b.x) + tolerance &&
           point.y >= std::min(a.y, b.y) - tolerance &&
           point.y <= std::max(a.y, b.y) + tolerance;
}

[[nodiscard]] int orientation(const Point2D a, const Point2D b, const Point2D c) noexcept {
    constexpr double tolerance = 1.0e-12;
    const double value = cross(a, b, c);
    return value > tolerance ? 1 : (value < -tolerance ? -1 : 0);
}

[[nodiscard]] bool segmentsIntersect(const Point2D a, const Point2D b,
                                     const Point2D c, const Point2D d) noexcept {
    const int abc = orientation(a, b, c);
    const int abd = orientation(a, b, d);
    const int cda = orientation(c, d, a);
    const int cdb = orientation(c, d, b);
    if (abc != abd && cda != cdb) {
        return true;
    }
    return (abc == 0 && onSegment(a, b, c)) || (abd == 0 && onSegment(a, b, d)) ||
           (cda == 0 && onSegment(c, d, a)) || (cdb == 0 && onSegment(c, d, b));
}

[[nodiscard]] bool validPoint(const Point2D point, const GridGeometry& geometry) noexcept {
    return finite(point) && point.x >= 0.0 && point.x <= geometry.domainWidth &&
           point.y >= 0.0 && point.y <= geometry.domainHeight;
}

[[nodiscard]] bool validPolygon(const std::span<const Point2D> vertices,
                                const GridGeometry& geometry) noexcept {
    if (vertices.size() < 3) {
        return false;
    }
    for (const Point2D point : vertices) {
        if (!validPoint(point, geometry)) {
            return false;
        }
    }

    double twiceArea = 0.0;
    for (std::size_t index = 0; index < vertices.size(); ++index) {
        const Point2D a = vertices[index];
        const Point2D b = vertices[(index + 1) % vertices.size()];
        if (a.x == b.x && a.y == b.y) {
            return false;
        }
        twiceArea += a.x * b.y - b.x * a.y;
    }
    if (std::abs(twiceArea) <= 1.0e-12) {
        return false;
    }

    for (std::size_t first = 0; first < vertices.size(); ++first) {
        const std::size_t firstNext = (first + 1) % vertices.size();
        for (std::size_t second = first + 1; second < vertices.size(); ++second) {
            const std::size_t secondNext = (second + 1) % vertices.size();
            if (firstNext == second || secondNext == first) {
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

[[nodiscard]] bool contains(const std::span<const Point2D> vertices,
                            const Point2D point) noexcept {
    bool inside = false;
    for (std::size_t current = 0, previous = vertices.size() - 1;
         current < vertices.size(); previous = current++) {
        const Point2D a = vertices[previous];
        const Point2D b = vertices[current];
        if (onSegment(a, b, point)) {
            return true;
        }
        const bool crosses = (a.y > point.y) != (b.y > point.y);
        if (crosses) {
            const double intersectionX =
                (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x;
            if (point.x < intersectionX) {
                inside = !inside;
            }
        }
    }
    return inside;
}

[[nodiscard]] double falloffWeight(const BrushFalloff falloff,
                                   const double normalizedDistance) noexcept {
    switch (falloff) {
    case BrushFalloff::constant:
        return 1.0;
    case BrushFalloff::linear:
        return 1.0 - normalizedDistance;
    case BrushFalloff::smooth: {
        const double linear = 1.0 - normalizedDistance;
        return linear * linear * (3.0 - 2.0 * linear);
    }
    }
    return 0.0;
}

[[nodiscard]] bool validEdit(const MaterialEdit& edit) noexcept {
    return std::isfinite(edit.amount) && edit.amount >= 0.0;
}

[[nodiscard]] double connectedDepth(const double bed, const double depth,
                                    const double faceBed) noexcept {
    return std::max(0.0, bed + depth - faceBed);
}

[[nodiscard]] double mixedFaceVelocity(const double oldVelocity,
                                       const double firstBed, const double firstNewDepth,
                                       const double firstRetainedDepth,
                                       const double secondBed, const double secondNewDepth,
                                       const double secondRetainedDepth,
                                       const double minimumWetDepth) noexcept {
    const double faceBed = std::max(firstBed, secondBed);
    const double newConnectedDepth = 0.5 *
        (connectedDepth(firstBed, firstNewDepth, faceBed) +
         connectedDepth(secondBed, secondNewDepth, faceBed));
    if (newConnectedDepth <= minimumWetDepth) {
        return 0.0;
    }
    const double retainedConnectedDepth = 0.5 *
        (connectedDepth(firstBed, firstRetainedDepth, faceBed) +
         connectedDepth(secondBed, secondRetainedDepth, faceBed));
    return oldVelocity * std::clamp(retainedConnectedDepth / newConnectedDepth, 0.0, 1.0);
}

} // namespace

TerrainEditor::TerrainEditor(SimulationState& state, const double minimumWetDepth)
    : state_(state), minimumWetDepth_(minimumWetDepth) {
    assert(state.isInitialized());
    assert(std::isfinite(minimumWetDepth) && minimumWetDepth >= 0.0);
    resizeScratch();
}

TerrainEditResult TerrainEditor::applyBrush(const BrushCommand& command) noexcept {
    const GridGeometry& geometry = state_.geometry_;
    const BrushGeometry& brush = command.geometry;
    if (!validEdit(command.material) || !validPoint(brush.center, geometry) ||
        !std::isfinite(brush.radius) || brush.radius <= 0.0) {
        return {.status = TerrainEditStatus::invalidCommand};
    }

    weights_.fill(0.0);
    const double radiusSquared = brush.radius * brush.radius;
    for (std::size_t row = 0; row < geometry.height; ++row) {
        const double y = (static_cast<double>(row) + 0.5) * geometry.dy();
        for (std::size_t column = 0; column < geometry.width; ++column) {
            const double x = (static_cast<double>(column) + 0.5) * geometry.dx();
            const double deltaX = x - brush.center.x;
            const double deltaY = y - brush.center.y;
            const double distanceSquared = deltaX * deltaX + deltaY * deltaY;
            if (distanceSquared <= radiusSquared) {
                const double normalizedDistance = std::sqrt(distanceSquared) / brush.radius;
                weights_(column, row) = falloffWeight(brush.falloff, normalizedDistance);
            }
        }
    }
    return applyWeighted(command.material);
}

TerrainEditResult TerrainEditor::applyPolygon(const PolygonCommand& command) noexcept {
    const GridGeometry& geometry = state_.geometry_;
    if (!validEdit(command.material)) {
        return {.status = TerrainEditStatus::invalidCommand};
    }
    if (!validPolygon(command.vertices, geometry)) {
        return {.status = TerrainEditStatus::malformedPolygon};
    }

    weights_.fill(0.0);
    for (std::size_t row = 0; row < geometry.height; ++row) {
        const double y = (static_cast<double>(row) + 0.5) * geometry.dy();
        for (std::size_t column = 0; column < geometry.width; ++column) {
            const Point2D point{(static_cast<double>(column) + 0.5) * geometry.dx(), y};
            weights_(column, row) = contains(command.vertices, point) ? 1.0 : 0.0;
        }
    }
    return applyWeighted(command.material);
}

TerrainEditResult TerrainEditor::applyWeighted(const MaterialEdit& edit) noexcept {
    const CellField& sourceBed = edit.target == EditTarget::initialState
        ? state_.initialBedElevation_ : state_.bedElevation_;
    const CellField& sourceDepth = edit.target == EditTarget::initialState
        ? state_.initialWaterDepth_ : state_.waterDepth_;
    std::copy(sourceBed.values().begin(), sourceBed.values().end(),
              candidateBed_.values().begin());
    std::copy(sourceDepth.values().begin(), sourceDepth.values().end(),
              candidateDepth_.values().begin());
    std::copy(sourceDepth.values().begin(), sourceDepth.values().end(),
              retainedDepth_.values().begin());

    TerrainEditResult result;
    const WorldLimits& limits = state_.worldLimits_;
    const double cellArea = state_.geometry_.dx() * state_.geometry_.dy();
    for (std::size_t index = 0; index < weights_.size(); ++index) {
        const double requested = edit.amount * weights_.values()[index];
        if (requested == 0.0) {
            continue;
        }
        const double oldBed = sourceBed.values()[index];
        const double oldDepth = sourceDepth.values()[index];
        double newBed = oldBed;
        double newDepth = oldDepth;
        double retainedDepth = oldDepth;
        switch (edit.operation) {
        case MaterialOperation::addSand: {
            newBed = std::min(oldBed + requested, limits.maximumSurfaceElevation);
            const double addedBed = newBed - oldBed;
            newDepth = std::max(0.0, oldDepth - addedBed);
            retainedDepth = newDepth;
            result.clamped = result.clamped || addedBed < requested;
            break;
        }
        case MaterialOperation::removeSand: {
            newBed = std::max(oldBed - requested, limits.minimumBedElevation);
            const double removedBed = oldBed - newBed;
            newDepth = std::min(oldDepth + removedBed,
                                limits.maximumSurfaceElevation - newBed);
            retainedDepth = std::min(oldDepth, newDepth);
            result.clamped = result.clamped || removedBed < requested;
            break;
        }
        case MaterialOperation::addWater:
            newDepth = std::min(oldDepth + requested,
                                limits.maximumSurfaceElevation - oldBed);
            result.clamped = result.clamped || newDepth - oldDepth < requested;
            break;
        case MaterialOperation::removeWater:
            newDepth = std::max(0.0, oldDepth - requested);
            retainedDepth = newDepth;
            result.clamped = result.clamped || oldDepth - newDepth < requested;
            break;
        }

        if (newBed == oldBed && newDepth == oldDepth) {
            weights_.values()[index] = 0.0;
            continue;
        }
        weights_.values()[index] = 1.0;
        candidateBed_.values()[index] = newBed;
        candidateDepth_.values()[index] = newDepth;
        retainedDepth_.values()[index] = retainedDepth;
        ++result.changedCells;
        result.sandVolumeDelta += (newBed - oldBed) * cellArea;
        result.waterVolumeDelta += (newDepth - oldDepth) * cellArea;
        result.newlyWetCells += oldDepth <= minimumWetDepth_ && newDepth > minimumWetDepth_ ? 1 : 0;
        result.newlyDryCells += oldDepth > minimumWetDepth_ && newDepth <= minimumWetDepth_ ? 1 : 0;
    }

    if (!result.changed()) {
        return result;
    }

    const std::size_t width = state_.geometry_.width;
    const std::size_t height = state_.geometry_.height;
    for (std::size_t row = 0; row < height; ++row) {
        for (std::size_t face = 0; face <= width; ++face) {
            const bool leftChanged = face > 0 && weights_(face - 1, row) != 0.0;
            const bool rightChanged = face < width && weights_(face, row) != 0.0;
            result.changedFaces += leftChanged || rightChanged ? 1 : 0;
        }
    }
    for (std::size_t face = 0; face <= height; ++face) {
        for (std::size_t column = 0; column < width; ++column) {
            const bool lowerChanged = face > 0 && weights_(column, face - 1) != 0.0;
            const bool upperChanged = face < height && weights_(column, face) != 0.0;
            result.changedFaces += lowerChanged || upperChanged ? 1 : 0;
        }
    }

    if (edit.target == EditTarget::initialState) {
        std::copy(candidateBed_.values().begin(), candidateBed_.values().end(),
                  state_.initialBedElevation_.values().begin());
        std::copy(candidateDepth_.values().begin(), candidateDepth_.values().end(),
                  state_.initialWaterDepth_.values().begin());
        state_.reset();
        return result;
    }

    for (std::size_t row = 0; row < height; ++row) {
        for (std::size_t face = 1; face < width; ++face) {
            const double oldVelocity = state_.velX_(face, row);
            const double newVelocity = mixedFaceVelocity(
                oldVelocity,
                candidateBed_(face - 1, row), candidateDepth_(face - 1, row),
                retainedDepth_(face - 1, row),
                candidateBed_(face, row), candidateDepth_(face, row),
                retainedDepth_(face, row), minimumWetDepth_);
            state_.velX_(face, row) = newVelocity;
        }
    }
    for (std::size_t face = 1; face < height; ++face) {
        for (std::size_t column = 0; column < width; ++column) {
            const double oldVelocity = state_.velY_(column, face);
            const double newVelocity = mixedFaceVelocity(
                oldVelocity,
                candidateBed_(column, face - 1), candidateDepth_(column, face - 1),
                retainedDepth_(column, face - 1),
                candidateBed_(column, face), candidateDepth_(column, face),
                retainedDepth_(column, face), minimumWetDepth_);
            state_.velY_(column, face) = newVelocity;
        }
    }
    state_.bedElevation_.swapValues(candidateBed_);
    state_.waterDepth_.swapValues(candidateDepth_);
    state_.accumulatedEditWaterVolume_ += result.waterVolumeDelta;
    return result;
}

void TerrainEditor::resizeScratch() {
    const GridGeometry& geometry = state_.geometry_;
    weights_.resize(geometry.width, geometry.height);
    candidateBed_.resize(geometry.width, geometry.height);
    candidateDepth_.resize(geometry.width, geometry.height);
    retainedDepth_.resize(geometry.width, geometry.height);
}

} // namespace tide::swe
