#include "ParallelFor.hh"

#include <cassert>

namespace tide::swe {

namespace {

[[nodiscard]] std::size_t resolvedWorkerCount(std::size_t requested) noexcept {
    if (requested != 0) {
        return requested;
    }
    const auto hardwareCount = static_cast<std::size_t>(std::thread::hardware_concurrency());
    return std::max<std::size_t>(hardwareCount, 1);
}

} // namespace

ParallelFor::ParallelFor(std::size_t requestedWorkerCount)
    : workerCount_(resolvedWorkerCount(requestedWorkerCount)) {
    workers_.reserve(workerCount_ - 1);
    for (std::size_t worker = 1; worker < workerCount_; ++worker) {
        workers_.emplace_back([this, worker] { workerLoop(worker); });
    }
    completedWorkers_ = workers_.size();
}

ParallelFor::~ParallelFor() {
    {
        const std::scoped_lock lock(mutex_);
        stopping_ = true;
    }
    workAvailable_.notify_all();
    workers_.clear();
}

void ParallelFor::dispatch(std::size_t rowCount, void* context, RowFunction function) noexcept {
    assert(rowCount > 0 && context != nullptr && function != nullptr);
    {
        const std::scoped_lock lock(mutex_);
        assert(completedWorkers_ == workers_.size());
        rowCount_ = rowCount;
        context_ = context;
        function_ = function;
        completedWorkers_ = 0;
        ++generation_;
    }
    workAvailable_.notify_all();

    executePartition(0, rowCount, context, function);

    std::unique_lock lock(mutex_);
    workComplete_.wait(lock, [this] { return completedWorkers_ == workers_.size(); });
}

void ParallelFor::workerLoop(std::size_t workerIndex) noexcept {
    std::size_t observedGeneration = 0;
    for (;;) {
        std::unique_lock lock(mutex_);
        workAvailable_.wait(lock, [this, observedGeneration] {
            return stopping_ || generation_ != observedGeneration;
        });
        if (stopping_) {
            return;
        }

        observedGeneration = generation_;
        const auto rowCount = rowCount_;
        auto* const context = context_;
        const auto function = function_;
        lock.unlock();

        executePartition(workerIndex, rowCount, context, function);

        lock.lock();
        ++completedWorkers_;
        if (completedWorkers_ == workers_.size()) {
            workComplete_.notify_one();
        }
    }
}

void ParallelFor::executePartition(std::size_t workerIndex, std::size_t rowCount,
                                   void* context, RowFunction function) noexcept {
    const auto begin = rowCount * workerIndex / workerCount_;
    const auto end = rowCount * (workerIndex + 1) / workerCount_;
    if (begin != end) {
        function(context, begin, end);
    }
}

} // namespace tide::swe
