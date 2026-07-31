#pragma once

#include <algorithm>
#include <cassert>
#include <cstddef>
#include <span>
#include <vector>

namespace tide::swe {

struct GridGeometry final {
    std::size_t width = 0;
    std::size_t height = 0;
    double domainWidth = 0.0;
    double domainHeight = 0.0;

    [[nodiscard]] constexpr bool isValid() const noexcept {
        return width > 0 && height > 0 && domainWidth > 0.0 && domainHeight > 0.0;
    }

    [[nodiscard]] constexpr double dx() const noexcept {
        assert(isValid());
        return domainWidth / static_cast<double>(width);
    }

    [[nodiscard]] constexpr double dy() const noexcept {
        assert(isValid());
        return domainHeight / static_cast<double>(height);
    }
};

class CellField final {
public:
    CellField() = default;
    CellField(std::size_t width, std::size_t height, double value = 0.0)
        : width_(width), height_(height), values_(width * height, value) {}

    void resize(std::size_t width, std::size_t height, double value = 0.0) {
        width_ = width;
        height_ = height;
        values_.resize(width * height);
        std::fill(values_.begin(), values_.end(), value);
    }

    [[nodiscard]] std::size_t width() const noexcept { return width_; }
    [[nodiscard]] std::size_t height() const noexcept { return height_; }
    [[nodiscard]] std::size_t size() const noexcept { return values_.size(); }

    [[nodiscard]] double& operator()(std::size_t column, std::size_t row) noexcept {
        assert(column < width_ && row < height_);
        return values_[row * width_ + column];
    }

    [[nodiscard]] const double& operator()(std::size_t column, std::size_t row) const noexcept {
        assert(column < width_ && row < height_);
        return values_[row * width_ + column];
    }

    [[nodiscard]] std::span<double> values() noexcept { return values_; }
    [[nodiscard]] std::span<const double> values() const noexcept { return values_; }

    void fill(double value) noexcept { std::fill(values_.begin(), values_.end(), value); }
    void swapValues(CellField& other) noexcept {
        assert(width_ == other.width_ && height_ == other.height_);
        values_.swap(other.values_);
    }

private:
    std::size_t width_ = 0;
    std::size_t height_ = 0;
    std::vector<double> values_;
};

class FaceField final {
public:
    FaceField() = default;
    FaceField(std::size_t width, std::size_t height, double value = 0.0)
        : width_(width), height_(height), values_(width * height, value) {}

    void resize(std::size_t width, std::size_t height, double value = 0.0) {
        width_ = width;
        height_ = height;
        values_.resize(width * height);
        std::fill(values_.begin(), values_.end(), value);
    }

    [[nodiscard]] std::size_t width() const noexcept { return width_; }
    [[nodiscard]] std::size_t height() const noexcept { return height_; }
    [[nodiscard]] std::size_t size() const noexcept { return values_.size(); }

    [[nodiscard]] double& operator()(std::size_t column, std::size_t row) noexcept {
        assert(column < width() && row < height());
        return values_[row * width() + column];
    }

    [[nodiscard]] const double& operator()(std::size_t column, std::size_t row) const noexcept {
        assert(column < width() && row < height());
        return values_[row * width() + column];
    }

    [[nodiscard]] std::span<double> values() noexcept { return values_; }
    [[nodiscard]] std::span<const double> values() const noexcept { return values_; }
    void fill(double value) noexcept { std::fill(values_.begin(), values_.end(), value); }

private:
    std::size_t width_ = 0;
    std::size_t height_ = 0;
    std::vector<double> values_;
};

} // namespace tide::swe
