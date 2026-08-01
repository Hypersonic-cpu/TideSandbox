#pragma once

#include "AcceleratedSolverTypes.hh"
#include "../Engine/TerrainEdit.hh"

#include <memory>
#include <string>

namespace tide::accelerated {

class CpuBackend final {
public:
    CpuBackend();
    ~CpuBackend();
    CpuBackend(CpuBackend&&) noexcept;
    CpuBackend& operator=(CpuBackend&&) noexcept;

    CpuBackend(const CpuBackend&) = delete;
    CpuBackend& operator=(const CpuBackend&) = delete;

    [[nodiscard]] bool load(const BackendState& state,
                            swe::SolverConfiguration configuration,
                            std::string& failureReason);
    [[nodiscard]] bool reset(std::string& failureReason) noexcept;
    [[nodiscard]] swe::StepStatus advance(double frameDeltaTime,
                                          std::string& failureReason) noexcept;
    [[nodiscard]] swe::StepStatus stepOnce(double timeStep,
                                           std::string& failureReason) noexcept;
    [[nodiscard]] bool setConfiguration(swe::SolverConfiguration configuration) noexcept;
    [[nodiscard]] bool setBoundaryConfiguration(swe::BoundaryConfiguration boundaries,
                                                std::string& failureReason) noexcept;
    [[nodiscard]] BackendState synchronizeToHost(std::string& failureReason) const;
    [[nodiscard]] BackendSnapshot makeSnapshot(std::string& failureReason) const;
    [[nodiscard]] swe::TerrainEditResult applyMaterialBrush(
        const swe::BrushCommand& command) noexcept;
    [[nodiscard]] swe::TerrainEditResult applyMaterialPolygon(
        const swe::PolygonCommand& command) noexcept;

    [[nodiscard]] const swe::Diagnostics& diagnostics() const noexcept;
    [[nodiscard]] const BackendStatus& status() const noexcept;

private:
    class Implementation;
    std::unique_ptr<Implementation> implementation_;
};

} // namespace tide::accelerated
