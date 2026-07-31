#import "WaterEngineBridge.hh"

#include "../Engine/SimulationState.hh"
#include "../Engine/TerrainEdit.hh"
#include "../Engine/WeakNonlinearSolver.hh"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <limits>
#include <memory>
#include <span>
#include <vector>

using namespace tide::swe;

namespace {

struct BridgeImplementation final {
    SimulationState state;
    SolverConfiguration configuration;
    std::unique_ptr<WeakNonlinearSolver> solver;
    std::vector<double> referenceSurface;
    bool running = false;
};

[[nodiscard]] BridgeImplementation& implementation(void *pointer) noexcept {
    return *static_cast<BridgeImplementation *>(pointer);
}

[[nodiscard]] WSEngineStepStatus bridgeStatus(const StepStatus status) noexcept {
    switch (status) {
    case StepStatus::success: return WSEngineStepStatusSuccess;
    case StepStatus::invalidConfiguration: return WSEngineStepStatusInvalidConfiguration;
    case StepStatus::invalidTimeStep: return WSEngineStepStatusInvalidTimeStep;
    case StepStatus::nonFiniteState: return WSEngineStepStatusNonFiniteState;
    case StepStatus::velocityBoundExceeded: return WSEngineStepStatusVelocityBoundExceeded;
    case StepStatus::substepLimitReached: return WSEngineStepStatusSubstepLimitReached;
    }
}

[[nodiscard]] BrushFalloff engineFalloff(const WSBrushFalloff falloff) noexcept {
    switch (falloff) {
    case WSBrushFalloffConstant: return BrushFalloff::constant;
    case WSBrushFalloffLinear: return BrushFalloff::linear;
    case WSBrushFalloffSmooth: return BrushFalloff::smooth;
    }
}

[[nodiscard]] PolygonMode enginePolygonMode(const WSPolygonMode mode) noexcept {
    return mode == WSPolygonModeSet ? PolygonMode::set : PolygonMode::add;
}

struct FreeDeleter final {
    void operator()(void *pointer) const noexcept { std::free(pointer); }
};

template <typename Value>
class OwnedSnapshotBuffer final {
public:
    explicit OwnedSnapshotBuffer(const std::size_t count)
        : bytes_(static_cast<Value *>(std::malloc(count * sizeof(Value)))), count_(count) {
        if (bytes_ == nullptr && count_ != 0) {
            std::abort();
        }
    }

    OwnedSnapshotBuffer(const OwnedSnapshotBuffer&) = delete;
    OwnedSnapshotBuffer& operator=(const OwnedSnapshotBuffer&) = delete;

    [[nodiscard]] std::span<Value> values() noexcept { return {bytes_.get(), count_}; }

    [[nodiscard]] NSData *consumeAsData() noexcept {
        void * const storage = bytes_.release();
        return [NSData dataWithBytesNoCopy:storage
                                    length:count_ * sizeof(Value)
                              freeWhenDone:YES];
    }

private:
    std::unique_ptr<Value, FreeDeleter> bytes_;
    const std::size_t count_;
};

[[nodiscard]] std::vector<double> doubleValues(NSData *data, const std::size_t count) {
    if (data.length != count * sizeof(float)) {
        return {};
    }
    const auto values = std::span(static_cast<const float *>(data.bytes), count);
    std::vector<double> result(count);
    std::transform(values.begin(), values.end(), result.begin(),
                   [](const float value) { return static_cast<double>(value); });
    return result;
}

} // namespace

@interface WSEngineDiagnostics ()

@property(nonatomic, readwrite) double totalVolume;
@property(nonatomic, readwrite) double minimumDepth;
@property(nonatomic, readwrite) double maximumDepth;
@property(nonatomic, readwrite) double maximumAbsVelocityX;
@property(nonatomic, readwrite) double maximumAbsVelocityY;
@property(nonatomic, readwrite) double maximumWaveSpeed;
@property(nonatomic, readwrite) double selectedTimeStep;
@property(nonatomic, readwrite) double simulatedTime;
@property(nonatomic, readwrite) double correctionVolume;
@property(nonatomic, readwrite) NSUInteger substepCount;
@property(nonatomic, readwrite) NSUInteger wetCellCount;
@property(nonatomic, readwrite) NSUInteger correctionCount;
@property(nonatomic, readwrite, getter=isFinite) BOOL finite;
@property(nonatomic, readwrite) WSEngineStepStatus status;

@end

@implementation WSEngineDiagnostics
@end

@interface WSEngineSnapshot ()

@property(nonatomic, readwrite) NSUInteger width;
@property(nonatomic, readwrite) NSUInteger height;
@property(nonatomic, readwrite) double domainWidth;
@property(nonatomic, readwrite) double domainHeight;
@property(nonatomic, readwrite) NSData *bedElevation;
@property(nonatomic, readwrite) NSData *waterDepth;
@property(nonatomic, readwrite) NSData *surfaceElevation;
@property(nonatomic, readwrite) NSData *surfaceDeviation;
@property(nonatomic, readwrite) NSData *velocityMagnitude;
@property(nonatomic, readwrite) NSData *wetMask;
@property(nonatomic, readwrite) WSEngineDiagnostics *diagnostics;

@end

@implementation WSEngineSnapshot
@end

@implementation WSWaterEngineBridge

- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  domainWidth:(double)domainWidth
                 domainHeight:(double)domainHeight {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _implementation = new BridgeImplementation();
    const std::vector<float> bed(width * height, 0.0F);
    const std::vector<float> depth(width * height, 1.0F);
    NSData * const bedData = [NSData dataWithBytes:bed.data() length:bed.size() * sizeof(float)];
    NSData * const depthData = [NSData dataWithBytes:depth.data() length:depth.size() * sizeof(float)];
    if (![self loadWidth:width height:height domainWidth:domainWidth domainHeight:domainHeight
             bedElevation:bedData waterDepth:depthData]) {
        delete static_cast<BridgeImplementation *>(_implementation);
        _implementation = nullptr;
        return nil;
    }
    return self;
}

- (void)dealloc {
    delete static_cast<BridgeImplementation *>(_implementation);
}

- (BOOL)isRunning {
    return implementation(_implementation).running;
}

- (void)setRunning:(BOOL)running {
    implementation(_implementation).running = running;
}

- (BOOL)loadWidth:(NSUInteger)width
            height:(NSUInteger)height
       domainWidth:(double)domainWidth
      domainHeight:(double)domainHeight
      bedElevation:(NSData *)bedElevation
         waterDepth:(NSData *)waterDepth {
    if (width < 8 || height < 8 || width > std::numeric_limits<std::size_t>::max() / height) {
        return NO;
    }
    const auto count = static_cast<std::size_t>(width * height);
    const auto bed = doubleValues(bedElevation, count);
    const auto depth = doubleValues(waterDepth, count);
    if (bed.size() != count || depth.size() != count) {
        return NO;
    }

    auto& impl = implementation(_implementation);
    const GridGeometry geometry{static_cast<std::size_t>(width), static_cast<std::size_t>(height),
                                domainWidth, domainHeight};
    if (!impl.state.initializeDepth(geometry, bed, depth)) {
        return NO;
    }
    impl.solver = std::make_unique<WeakNonlinearSolver>(impl.state, impl.configuration);
    impl.referenceSurface.resize(count);
    for (std::size_t index = 0; index < count; ++index) {
        impl.referenceSurface[index] = bed[index] + depth[index];
    }
    impl.running = false;
    return YES;
}

- (void)reset {
    auto& impl = implementation(_implementation);
    impl.state.reset();
    impl.running = false;
}

- (WSEngineStepStatus)advance:(double)frameDeltaTime {
    auto& impl = implementation(_implementation);
    return bridgeStatus(impl.solver->advance(frameDeltaTime));
}

- (WSEngineStepStatus)stepOnce:(double)timeStep {
    auto& impl = implementation(_implementation);
    return bridgeStatus(impl.solver->stepOnce(timeStep));
}

- (WSEngineSnapshot *)snapshot {
    const auto& impl = implementation(_implementation);
    const auto& state = impl.state;
    const auto& geometry = state.geometry();
    const auto count = geometry.width * geometry.height;
    OwnedSnapshotBuffer<float> bedElevation(count);
    OwnedSnapshotBuffer<float> waterDepth(count);
    OwnedSnapshotBuffer<float> surfaceElevation(count);
    OwnedSnapshotBuffer<float> surfaceDeviation(count);
    OwnedSnapshotBuffer<float> velocityMagnitude(count);
    OwnedSnapshotBuffer<std::uint8_t> wetMask(count);
    const auto bedValues = bedElevation.values();
    const auto depthValues = waterDepth.values();
    const auto surfaceValues = surfaceElevation.values();
    const auto deviationValues = surfaceDeviation.values();
    const auto velocityValues = velocityMagnitude.values();
    const auto wetValues = wetMask.values();
    for (std::size_t row = 0; row < geometry.height; ++row) {
        for (std::size_t column = 0; column < geometry.width; ++column) {
            const auto index = row * geometry.width + column;
            const auto bedValue = state.bedElevation()(column, row);
            const auto depthValue = state.waterDepth()(column, row);
            const auto surfaceValue = bedValue + depthValue;
            const auto velocityX = 0.5 * (state.velX()(column, row) +
                                          state.velX()(column + 1, row));
            const auto velocityY = 0.5 * (state.velY()(column, row) +
                                          state.velY()(column, row + 1));
            bedValues[index] = static_cast<float>(bedValue);
            depthValues[index] = static_cast<float>(depthValue);
            surfaceValues[index] = static_cast<float>(surfaceValue);
            deviationValues[index] = static_cast<float>(
                surfaceValue - impl.referenceSurface[index]);
            velocityValues[index] = static_cast<float>(std::hypot(velocityX, velocityY));
            wetValues[index] = depthValue > impl.configuration.minimumWetDepth ? 1 : 0;
        }
    }

    const auto& sourceDiagnostics = impl.solver->diagnostics();
    WSEngineDiagnostics *diagnostics = [[WSEngineDiagnostics alloc] init];
    diagnostics.totalVolume = sourceDiagnostics.totalVolume;
    diagnostics.minimumDepth = sourceDiagnostics.minimumDepth;
    diagnostics.maximumDepth = sourceDiagnostics.maximumDepth;
    diagnostics.maximumAbsVelocityX = sourceDiagnostics.maximumAbsVelX;
    diagnostics.maximumAbsVelocityY = sourceDiagnostics.maximumAbsVelY;
    diagnostics.maximumWaveSpeed = sourceDiagnostics.maximumWaveSpeed;
    diagnostics.selectedTimeStep = sourceDiagnostics.selectedTimeStep;
    diagnostics.simulatedTime = sourceDiagnostics.simulatedTime;
    diagnostics.correctionVolume = sourceDiagnostics.correctionVolume;
    diagnostics.substepCount = sourceDiagnostics.substepCount;
    diagnostics.wetCellCount = sourceDiagnostics.wetCellCount;
    diagnostics.correctionCount = sourceDiagnostics.correctionCount;
    diagnostics.finite = sourceDiagnostics.finite;
    diagnostics.status = bridgeStatus(sourceDiagnostics.status);

    WSEngineSnapshot *snapshot = [[WSEngineSnapshot alloc] init];
    snapshot.width = geometry.width;
    snapshot.height = geometry.height;
    snapshot.domainWidth = geometry.domainWidth;
    snapshot.domainHeight = geometry.domainHeight;
    snapshot.bedElevation = bedElevation.consumeAsData();
    snapshot.waterDepth = waterDepth.consumeAsData();
    snapshot.surfaceElevation = surfaceElevation.consumeAsData();
    snapshot.surfaceDeviation = surfaceDeviation.consumeAsData();
    snapshot.velocityMagnitude = velocityMagnitude.consumeAsData();
    snapshot.wetMask = wetMask.consumeAsData();
    snapshot.diagnostics = diagnostics;
    return snapshot;
}

- (BOOL)updateGravity:(double)gravity
        linearDamping:(double)linearDamping
             cflNumber:(double)cflNumber
       minimumWetDepth:(double)minimumWetDepth
           workerCount:(NSUInteger)workerCount {
    auto& impl = implementation(_implementation);
    auto configuration = impl.configuration;
    configuration.gravity = gravity;
    configuration.linearDamping = linearDamping;
    configuration.cflNumber = cflNumber;
    configuration.minimumWetDepth = minimumWetDepth;
    configuration.workerCount = workerCount;
    if (!configuration.isValid()) {
        return NO;
    }
    const auto priorWorkerCount = impl.solver->workerCount();
    const auto resolvedWorkerCount = workerCount == 0
        ? std::max<std::size_t>(std::thread::hardware_concurrency(), 1)
        : static_cast<std::size_t>(workerCount);
    impl.configuration = configuration;
    if (priorWorkerCount != resolvedWorkerCount) {
        impl.solver = std::make_unique<WeakNonlinearSolver>(impl.state, configuration);
        return YES;
    }
    return impl.solver->setConfiguration(configuration);
}

- (BOOL)applyBrushAtX:(double)x
                    y:(double)y
               radius:(double)radius
             strength:(double)strength
              falloff:(WSBrushFalloff)falloff
           minimumBed:(double)minimumBed
           maximumBed:(double)maximumBed {
    auto& impl = implementation(_implementation);
    TerrainEditor editor(impl.state);
    const BrushCommand command{{x, y}, radius, strength, engineFalloff(falloff),
                               minimumBed, maximumBed};
    return editor.applyBrush(command) == TerrainEditStatus::success;
}

- (BOOL)applyPolygonWithXYCoordinates:(NSData *)xyCoordinates
                                  mode:(WSPolygonMode)mode
                             elevation:(double)elevation
                            minimumBed:(double)minimumBed
                            maximumBed:(double)maximumBed {
    if (xyCoordinates.length % (2 * sizeof(double)) != 0) {
        return NO;
    }
    const auto coordinateCount = xyCoordinates.length / sizeof(double);
    const auto coordinates = std::span(static_cast<const double *>(xyCoordinates.bytes),
                                       coordinateCount);
    std::vector<Point2D> points(coordinateCount / 2);
    for (std::size_t index = 0; index < points.size(); ++index) {
        points[index] = {coordinates[index * 2], coordinates[index * 2 + 1]};
    }
    auto& impl = implementation(_implementation);
    TerrainEditor editor(impl.state);
    const PolygonCommand command{points, enginePolygonMode(mode), elevation,
                                 minimumBed, maximumBed};
    return editor.applyPolygon(command) == TerrainEditStatus::success;
}

@end
