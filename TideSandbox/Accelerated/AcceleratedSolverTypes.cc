#include "AcceleratedSolverTypes.hh"

#include <algorithm>
#include <cmath>
#include <limits>

namespace tide::accelerated {

namespace {

[[nodiscard]] bool finiteValues(const std::vector<double>& values) noexcept {
    return std::ranges::all_of(values, [](const double value) {
        return std::isfinite(value);
    });
}

} // namespace

bool BackendState::isValid() const noexcept {
    if (!geometry.isValid() || !worldLimits.isValid() ||
        !boundaries.isValid(worldLimits.minimumBedElevation,
                            worldLimits.maximumSurfaceElevation) ||
        !std::isfinite(time) || time < 0.0 ||
        !std::isfinite(initialWaterVolume) || initialWaterVolume < 0.0 ||
        !std::isfinite(accumulatedEditWaterVolume)) {
        return false;
    }
    const std::size_t maximum = std::numeric_limits<std::size_t>::max();
    if (geometry.width == maximum || geometry.height == maximum ||
        geometry.width > maximum / geometry.height ||
        geometry.width + 1 > maximum / geometry.height ||
        geometry.height + 1 > maximum / geometry.width) {
        return false;
    }
    const std::size_t cellCount = geometry.width * geometry.height;
    const std::size_t xFaceCount = (geometry.width + 1) * geometry.height;
    const std::size_t yFaceCount = geometry.width * (geometry.height + 1);
    if (initialBedElevation.size() != cellCount || initialWaterDepth.size() != cellCount ||
        bedElevation.size() != cellCount || waterDepth.size() != cellCount ||
        velX.size() != xFaceCount || velY.size() != yFaceCount ||
        !finiteValues(initialBedElevation) || !finiteValues(initialWaterDepth) ||
        !finiteValues(bedElevation) || !finiteValues(waterDepth) ||
        !finiteValues(velX) || !finiteValues(velY)) {
        return false;
    }
    for (const double volume : cumulativeBoundaryVolume) {
        if (!std::isfinite(volume)) {
            return false;
        }
    }
    for (std::size_t index = 0; index < cellCount; ++index) {
        const double bed = bedElevation[index];
        const double depth = waterDepth[index];
        if (bed < worldLimits.minimumBedElevation || depth < 0.0 ||
            bed + depth > worldLimits.maximumSurfaceElevation) {
            return false;
        }
    }
    return true;
}

BackendState exportState(const swe::SimulationState& state) {
    return {
        .geometry = state.geometry(),
        .worldLimits = state.worldLimits(),
        .boundaries = state.boundaryConfiguration(),
        .initialBedElevation = {state.initialBedElevation().values().begin(),
                                state.initialBedElevation().values().end()},
        .initialWaterDepth = {state.initialWaterDepth().values().begin(),
                              state.initialWaterDepth().values().end()},
        .bedElevation = {state.bedElevation().values().begin(),
                         state.bedElevation().values().end()},
        .waterDepth = {state.waterDepth().values().begin(),
                       state.waterDepth().values().end()},
        .velX = {state.velX().values().begin(), state.velX().values().end()},
        .velY = {state.velY().values().begin(), state.velY().values().end()},
        .cumulativeBoundaryVolume = state.cumulativeBoundaryVolume(),
        .initialWaterVolume = state.initialWaterVolume(),
        .accumulatedEditWaterVolume = state.accumulatedEditWaterVolume(),
        .time = state.time(),
    };
}

bool importState(const BackendState& source, swe::SimulationState& destination) {
    if (!source.isValid() ||
        !destination.initializeDepth(source.geometry, source.initialBedElevation,
                                     source.initialWaterDepth, source.worldLimits,
                                     source.boundaries)) {
        return false;
    }
    return destination.restoreCurrentState(source.bedElevation, source.waterDepth,
                                           source.velX, source.velY, source.time,
                                           source.cumulativeBoundaryVolume,
                                           source.accumulatedEditWaterVolume);
}

} // namespace tide::accelerated
