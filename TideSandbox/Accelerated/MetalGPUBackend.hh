#pragma once

#include "AcceleratedSolverTypes.hh"
#include "../Engine/TerrainEdit.hh"

#include <cstddef>
#include <memory>
#include <string>

namespace tide::accelerated {

class MetalGPUBackend final {
public:
    MetalGPUBackend();
    ~MetalGPUBackend();
    MetalGPUBackend(MetalGPUBackend&&) noexcept;
    MetalGPUBackend& operator=(MetalGPUBackend&&) noexcept;

    MetalGPUBackend(const MetalGPUBackend&) = delete;
    MetalGPUBackend& operator=(const MetalGPUBackend&) = delete;

    [[nodiscard]] bool load(const BackendState& state,
                            swe::SolverConfiguration configuration,
                            std::string& failureReason);
    [[nodiscard]] bool reset(std::string& failureReason);
    [[nodiscard]] swe::StepStatus advance(double frameDeltaTime,
                                          std::string& failureReason);
    [[nodiscard]] swe::StepStatus stepOnce(double timeStep,
                                           std::string& failureReason);
    [[nodiscard]] bool setConfiguration(swe::SolverConfiguration configuration) noexcept;
    [[nodiscard]] bool setBoundaryConfiguration(swe::BoundaryConfiguration boundaries,
                                                std::string& failureReason) noexcept;
    [[nodiscard]] swe::TerrainEditResult applyMaterialBrush(
        const swe::BrushCommand& command, std::string& failureReason);
    [[nodiscard]] swe::TerrainEditResult applyMaterialPolygon(
        const swe::PolygonCommand& command, std::string& failureReason);
    [[nodiscard]] BackendState synchronizeToHost(std::string& failureReason);
    [[nodiscard]] BackendSnapshot makeSnapshot(std::string& failureReason);

    [[nodiscard]] const swe::Diagnostics& diagnostics() const noexcept;
    [[nodiscard]] const BackendStatus& status() const noexcept;
    [[nodiscard]] std::size_t stateSizedAllocationCount() const noexcept;
    [[nodiscard]] AcceleratedFieldBufferSnapshot fieldBufferSnapshot() const noexcept;

private:
    class Implementation;
    std::unique_ptr<Implementation> implementation_;
};

} // namespace tide::accelerated
