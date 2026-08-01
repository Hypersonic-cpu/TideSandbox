#include "SimulationState.hh"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <numeric>

namespace tide::swe {

SimulationState::SimulationState(GridGeometry geometry) {
    assert(geometry.isValid());
    resize(geometry);
    initialBedElevation_.fill(0.0);
    initialWaterDepth_.fill(0.0);
}

bool SimulationState::initializeLevelLake(GridGeometry geometry,
                                          std::span<const double> bedElevation,
                                          double initialSurfaceLevel,
                                          WorldLimits limits) noexcept {
    if (!geometry.isValid() || bedElevation.size() != geometry.width * geometry.height ||
        !std::isfinite(initialSurfaceLevel) || !limits.isValid() ||
        initialSurfaceLevel > limits.maximumSurfaceElevation) {
        return false;
    }
    for (const auto value : bedElevation) {
        if (!std::isfinite(value) || value < limits.minimumBedElevation ||
            value > limits.maximumSurfaceElevation) {
            return false;
        }
    }

    resize(geometry);
    worldLimits_ = limits;
    boundaryConfiguration_ = {};
    std::copy(bedElevation.begin(), bedElevation.end(), bedElevation_.values().begin());
    std::copy(bedElevation.begin(), bedElevation.end(), initialBedElevation_.values().begin());
    for (std::size_t index = 0; index < bedElevation.size(); ++index) {
        const auto depth = std::max(initialSurfaceLevel - bedElevation[index], 0.0);
        waterDepth_.values()[index] = depth;
        initialWaterDepth_.values()[index] = depth;
    }
    velX_.fill(0.0);
    velY_.fill(0.0);
    const double cellArea = geometry_.dx() * geometry_.dy();
    initialWaterVolume_ = std::accumulate(initialWaterDepth_.values().begin(),
                                          initialWaterDepth_.values().end(), 0.0) * cellArea;
    accumulatedEditWaterVolume_ = 0.0;
    cumulativeBoundaryVolume_.fill(0.0);
    time_ = 0.0;
    return true;
}

bool SimulationState::initializeDepth(GridGeometry geometry,
                                      std::span<const double> bedElevation,
                                      std::span<const double> waterDepth,
                                      WorldLimits limits,
                                      BoundaryConfiguration boundaries) noexcept {
    if (!geometry.isValid() || bedElevation.size() != geometry.width * geometry.height ||
        waterDepth.size() != bedElevation.size() || !limits.isValid() ||
        !boundaries.isValid(limits.minimumBedElevation, limits.maximumSurfaceElevation)) {
        return false;
    }
    for (std::size_t index = 0; index < bedElevation.size(); ++index) {
        if (!std::isfinite(bedElevation[index]) || !std::isfinite(waterDepth[index]) ||
            bedElevation[index] < limits.minimumBedElevation ||
            bedElevation[index] > limits.maximumSurfaceElevation || waterDepth[index] < 0.0 ||
            bedElevation[index] + waterDepth[index] > limits.maximumSurfaceElevation) {
            return false;
        }
    }

    resize(geometry);
    worldLimits_ = limits;
    boundaryConfiguration_ = boundaries;
    std::copy(bedElevation.begin(), bedElevation.end(), bedElevation_.values().begin());
    std::copy(bedElevation.begin(), bedElevation.end(), initialBedElevation_.values().begin());
    std::copy(waterDepth.begin(), waterDepth.end(), waterDepth_.values().begin());
    std::copy(waterDepth.begin(), waterDepth.end(), initialWaterDepth_.values().begin());
    velX_.fill(0.0);
    velY_.fill(0.0);
    const double cellArea = geometry_.dx() * geometry_.dy();
    initialWaterVolume_ = std::accumulate(initialWaterDepth_.values().begin(),
                                          initialWaterDepth_.values().end(), 0.0) * cellArea;
    accumulatedEditWaterVolume_ = 0.0;
    cumulativeBoundaryVolume_.fill(0.0);
    time_ = 0.0;
    return true;
}

void SimulationState::reset() noexcept {
    assert(isInitialized());
    std::copy(initialBedElevation_.values().begin(), initialBedElevation_.values().end(),
              bedElevation_.values().begin());
    std::copy(initialWaterDepth_.values().begin(), initialWaterDepth_.values().end(),
              waterDepth_.values().begin());
    velX_.fill(0.0);
    velY_.fill(0.0);
    const double cellArea = geometry_.dx() * geometry_.dy();
    initialWaterVolume_ = std::accumulate(initialWaterDepth_.values().begin(),
                                          initialWaterDepth_.values().end(), 0.0) * cellArea;
    accumulatedEditWaterVolume_ = 0.0;
    cumulativeBoundaryVolume_.fill(0.0);
    time_ = 0.0;
}

bool SimulationState::setBoundaryConfiguration(BoundaryConfiguration boundaries) noexcept {
    if (!boundaries.isValid(worldLimits_.minimumBedElevation,
                            worldLimits_.maximumSurfaceElevation)) {
        return false;
    }
    boundaryConfiguration_ = boundaries;
    return true;
}

bool SimulationState::restoreCurrentState(
    const std::span<const double> bedElevation,
    const std::span<const double> waterDepth,
    const std::span<const double> velX,
    const std::span<const double> velY,
    const double time,
    const BoundaryValues cumulativeBoundaryVolume,
    const double accumulatedEditWaterVolume) noexcept {
    if (!isInitialized() || bedElevation.size() != bedElevation_.size() ||
        waterDepth.size() != waterDepth_.size() || velX.size() != velX_.size() ||
        velY.size() != velY_.size() || !std::isfinite(time) || time < 0.0 ||
        !std::isfinite(accumulatedEditWaterVolume)) {
        return false;
    }
    for (std::size_t index = 0; index < bedElevation.size(); ++index) {
        if (!std::isfinite(bedElevation[index]) || !std::isfinite(waterDepth[index]) ||
            bedElevation[index] < worldLimits_.minimumBedElevation || waterDepth[index] < 0.0 ||
            bedElevation[index] + waterDepth[index] > worldLimits_.maximumSurfaceElevation) {
            return false;
        }
    }
    if (!std::all_of(velX.begin(), velX.end(), [](const double value) {
            return std::isfinite(value);
        }) ||
        !std::all_of(velY.begin(), velY.end(), [](const double value) {
            return std::isfinite(value);
        }) ||
        !std::all_of(cumulativeBoundaryVolume.begin(), cumulativeBoundaryVolume.end(),
                     [](const double value) { return std::isfinite(value); })) {
        return false;
    }
    std::copy(bedElevation.begin(), bedElevation.end(), bedElevation_.values().begin());
    std::copy(waterDepth.begin(), waterDepth.end(), waterDepth_.values().begin());
    std::copy(velX.begin(), velX.end(), velX_.values().begin());
    std::copy(velY.begin(), velY.end(), velY_.values().begin());
    cumulativeBoundaryVolume_ = cumulativeBoundaryVolume;
    accumulatedEditWaterVolume_ = accumulatedEditWaterVolume;
    time_ = time;
    return true;
}

void SimulationState::resize(GridGeometry geometry) {
    assert(geometry.isValid());
    geometry_ = geometry;
    bedElevation_.resize(geometry.width, geometry.height);
    waterDepth_.resize(geometry.width, geometry.height);
    velX_.resize(geometry.width + 1, geometry.height);
    velY_.resize(geometry.width, geometry.height + 1);
    initialBedElevation_.resize(geometry.width, geometry.height);
    initialWaterDepth_.resize(geometry.width, geometry.height);
}

} // namespace tide::swe
