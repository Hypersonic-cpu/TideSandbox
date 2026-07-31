#include "SimulationState.hh"

#include <algorithm>
#include <cassert>
#include <cmath>

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
    std::copy(bedElevation.begin(), bedElevation.end(), bedElevation_.values().begin());
    std::copy(bedElevation.begin(), bedElevation.end(), initialBedElevation_.values().begin());
    for (std::size_t index = 0; index < bedElevation.size(); ++index) {
        const auto depth = std::max(initialSurfaceLevel - bedElevation[index], 0.0);
        waterDepth_.values()[index] = depth;
        initialWaterDepth_.values()[index] = depth;
    }
    velX_.fill(0.0);
    velY_.fill(0.0);
    time_ = 0.0;
    return true;
}

bool SimulationState::initializeDepth(GridGeometry geometry,
                                      std::span<const double> bedElevation,
                                      std::span<const double> waterDepth,
                                      WorldLimits limits) noexcept {
    if (!geometry.isValid() || bedElevation.size() != geometry.width * geometry.height ||
        waterDepth.size() != bedElevation.size() || !limits.isValid()) {
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
    std::copy(bedElevation.begin(), bedElevation.end(), bedElevation_.values().begin());
    std::copy(bedElevation.begin(), bedElevation.end(), initialBedElevation_.values().begin());
    std::copy(waterDepth.begin(), waterDepth.end(), waterDepth_.values().begin());
    std::copy(waterDepth.begin(), waterDepth.end(), initialWaterDepth_.values().begin());
    velX_.fill(0.0);
    velY_.fill(0.0);
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
    time_ = 0.0;
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
