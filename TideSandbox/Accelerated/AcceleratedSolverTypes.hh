#pragma once

#include "../Engine/Diagnostics.hh"
#include "../Engine/SimulationState.hh"
#include "../Engine/WeakNonlinearSolver.hh"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace tide::accelerated {

enum class RequestedSimulationBackend : std::uint8_t {
    automaticAccelerated,
    metalGPU,
    cpuReference,
};

enum class ResolvedSimulationBackend : std::uint8_t {
    mpsGraphAutomatic,
    metalGPU,
    cpuReference,
};

struct BackendStatus final {
    RequestedSimulationBackend requested = RequestedSimulationBackend::automaticAccelerated;
    ResolvedSimulationBackend resolved = ResolvedSimulationBackend::cpuReference;
    bool ready = false;
    std::string resolutionReason;
    std::string fallbackReason;
    std::string statePrecision = "Float64";
    double graphCompileMilliseconds = 0.0;
    double lastStableDtMilliseconds = 0.0;
    double lastFramePhysicsMilliseconds = 0.0;
    double lastSubstepMilliseconds = 0.0;
    double lastReadbackMilliseconds = 0.0;
    std::size_t substepCount = 0;
};

struct AcceleratedFieldBufferSnapshot final {
    void *device = nullptr;
    void *bedElevation = nullptr;
    void *waterDepth = nullptr;
    std::size_t width = 0;
    std::size_t height = 0;
    std::uint64_t generation = 0;
};

struct BackendState final {
    swe::GridGeometry geometry;
    swe::WorldLimits worldLimits;
    swe::BoundaryConfiguration boundaries;
    std::vector<double> initialBedElevation;
    std::vector<double> initialWaterDepth;
    std::vector<double> bedElevation;
    std::vector<double> waterDepth;
    std::vector<double> velX;
    std::vector<double> velY;
    swe::BoundaryValues cumulativeBoundaryVolume{};
    double initialWaterVolume = 0.0;
    double accumulatedEditWaterVolume = 0.0;
    double time = 0.0;

    [[nodiscard]] bool isValid() const noexcept;
};

struct BackendSnapshot final {
    std::size_t width = 0;
    std::size_t height = 0;
    double domainWidth = 0.0;
    double domainHeight = 0.0;
    std::vector<float> bedElevation;
    std::vector<float> waterDepth;
    std::vector<float> surfaceElevation;
    std::vector<float> surfaceDeviation;
    std::vector<float> velocityMagnitude;
    std::vector<std::uint8_t> wetMask;
    swe::Diagnostics diagnostics;
};

[[nodiscard]] BackendState exportState(const swe::SimulationState& state);
[[nodiscard]] bool importState(const BackendState& source, swe::SimulationState& destination);

} // namespace tide::accelerated
