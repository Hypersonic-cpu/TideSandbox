#pragma once

#include <algorithm>
#include <condition_variable>
#include <cstddef>
#include <memory>
#include <mutex>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

namespace tide::swe {

class ParallelFor final {
public:
    explicit ParallelFor(std::size_t requestedWorkerCount);
    ~ParallelFor();

    ParallelFor(const ParallelFor&) = delete;
    ParallelFor& operator=(const ParallelFor&) = delete;
    ParallelFor(ParallelFor&&) = delete;
    ParallelFor& operator=(ParallelFor&&) = delete;

    [[nodiscard]] std::size_t workerCount() const noexcept { return workerCount_; }

    template <typename Function>
    void forRows(std::size_t rowCount, Function&& function) noexcept {
        if (rowCount == 0) {
            return;
        }
        if (workerCount_ == 1 || rowCount == 1) {
            function(0, rowCount);
            return;
        }

        using Callable = std::remove_reference_t<Function>;
        dispatch(rowCount, static_cast<void*>(std::addressof(function)),
                 [](void* context, std::size_t begin, std::size_t end) noexcept {
                     (*static_cast<Callable*>(context))(begin, end);
                 });
    }

private:
    using RowFunction = void (*)(void*, std::size_t, std::size_t) noexcept;

    void dispatch(std::size_t rowCount, void* context, RowFunction function) noexcept;
    void workerLoop(std::size_t workerIndex) noexcept;
    void executePartition(std::size_t workerIndex, std::size_t rowCount,
                          void* context, RowFunction function) noexcept;

    std::size_t workerCount_ = 1;
    std::mutex mutex_;
    std::condition_variable workAvailable_;
    std::condition_variable workComplete_;
    std::size_t generation_ = 0;
    std::size_t completedWorkers_ = 0;
    std::size_t rowCount_ = 0;
    void* context_ = nullptr;
    RowFunction function_ = nullptr;
    bool stopping_ = false;
    std::vector<std::jthread> workers_;
};

} // namespace tide::swe
