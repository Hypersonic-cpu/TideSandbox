#pragma once

#include <cstddef>

namespace tide::swe {

enum class StepStatus {
    success,
    invalidConfiguration,
    invalidTimeStep,
    nonFiniteState,
    velocityBoundExceeded,
    substepLimitReached,
};

struct Diagnostics final {
    double totalVolume = 0.0;
    double minimumDepth = 0.0;
    double maximumDepth = 0.0;
    double maximumAbsVelX = 0.0;
    double maximumAbsVelY = 0.0;
    double maximumWaveSpeed = 0.0;
    double selectedTimeStep = 0.0;
    double simulatedTime = 0.0;
    double correctionVolume = 0.0;
    std::size_t substepCount = 0;
    std::size_t wetCellCount = 0;
    std::size_t correctionCount = 0;
    bool finite = true;
    StepStatus status = StepStatus::success;
};

} // namespace tide::swe
