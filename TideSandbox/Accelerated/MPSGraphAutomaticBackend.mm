#import "MPSGraphAutomaticBackend.hh"

#import <Metal/Metal.h>
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>
#import <os/signpost.h>

#include <chrono>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <numbers>
#include <span>
#include <type_traits>
#include <utility>
#include <vector>

namespace tide::accelerated {

namespace {

using Clock = std::chrono::steady_clock;
const os_log_t mpsPerformanceLog = os_log_create(
    "Potassium.TideSandbox", "SWEMPSGraphAutomatic");

[[nodiscard]] double millisecondsSince(const Clock::time_point start) noexcept {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

struct GraphOps final {
    MPSGraph *graph;

    [[nodiscard]] MPSGraphTensor *scalar(const double value) const {
        return [graph constantWithScalar:value dataType:MPSDataTypeFloat32];
    }
    [[nodiscard]] MPSGraphTensor *add(MPSGraphTensor *a, MPSGraphTensor *b) const {
        return [graph additionWithPrimaryTensor:a secondaryTensor:b name:nil];
    }
    [[nodiscard]] MPSGraphTensor *sub(MPSGraphTensor *a, MPSGraphTensor *b) const {
        return [graph subtractionWithPrimaryTensor:a secondaryTensor:b name:nil];
    }
    [[nodiscard]] MPSGraphTensor *mul(MPSGraphTensor *a, MPSGraphTensor *b) const {
        return [graph multiplicationWithPrimaryTensor:a secondaryTensor:b name:nil];
    }
    [[nodiscard]] MPSGraphTensor *div(MPSGraphTensor *a, MPSGraphTensor *b) const {
        return [graph divisionWithPrimaryTensor:a secondaryTensor:b name:nil];
    }
    [[nodiscard]] MPSGraphTensor *maximum(MPSGraphTensor *a, MPSGraphTensor *b) const {
        return [graph maximumWithPrimaryTensor:a secondaryTensor:b name:nil];
    }
    [[nodiscard]] MPSGraphTensor *minimum(MPSGraphTensor *a, MPSGraphTensor *b) const {
        return [graph minimumWithPrimaryTensor:a secondaryTensor:b name:nil];
    }
    [[nodiscard]] MPSGraphTensor *negate(MPSGraphTensor *value) const {
        return [graph negativeWithTensor:value name:nil];
    }
    [[nodiscard]] MPSGraphTensor *absolute(MPSGraphTensor *value) const {
        return [graph absoluteWithTensor:value name:nil];
    }
    [[nodiscard]] MPSGraphTensor *greater(MPSGraphTensor *a, MPSGraphTensor *b) const {
        return [graph greaterThanWithPrimaryTensor:a secondaryTensor:b name:nil];
    }
    [[nodiscard]] MPSGraphTensor *greaterEqual(MPSGraphTensor *a,
                                               MPSGraphTensor *b) const {
        return [graph greaterThanOrEqualToWithPrimaryTensor:a secondaryTensor:b name:nil];
    }
    [[nodiscard]] MPSGraphTensor *logicalAnd(MPSGraphTensor *a,
                                             MPSGraphTensor *b) const {
        return [graph logicalANDWithPrimaryTensor:a secondaryTensor:b name:nil];
    }
    [[nodiscard]] MPSGraphTensor *select(MPSGraphTensor *predicate,
                                         MPSGraphTensor *yes,
                                         MPSGraphTensor *no) const {
        return [graph selectWithPredicateTensor:predicate truePredicateTensor:yes
                           falsePredicateTensor:no name:nil];
    }
    [[nodiscard]] MPSGraphTensor *slice(MPSGraphTensor *value, const NSUInteger dimension,
                                        const NSInteger start, const NSInteger length) const {
        return [graph sliceTensor:value dimension:dimension start:start length:length name:nil];
    }
    [[nodiscard]] MPSGraphTensor *concat(NSArray<MPSGraphTensor *> *values,
                                         const NSInteger dimension) const {
        return [graph concatTensors:values dimension:dimension name:nil];
    }
    [[nodiscard]] MPSGraphTensor *sum(MPSGraphTensor *value) const {
        return [graph reductionSumWithTensor:value axes:nil name:nil];
    }
    [[nodiscard]] MPSGraphTensor *maxAll(MPSGraphTensor *value) const {
        return [graph reductionMaximumWithTensor:value axes:nil name:nil];
    }
    [[nodiscard]] MPSGraphTensor *minAll(MPSGraphTensor *value) const {
        return [graph reductionMinimumWithTensor:value axes:nil name:nil];
    }
    [[nodiscard]] MPSGraphTensor *cast(MPSGraphTensor *value,
                                       const MPSDataType type) const {
        return [graph castTensor:value toType:type name:nil];
    }
    [[nodiscard]] MPSGraphTensor *cleanDepth(MPSGraphTensor *raw,
                                             MPSGraphTensor *minimumWetDepth) const {
        return select(greater(raw, minimumWetDepth), raw, scalar(0.0));
    }
};

struct GraphHydrostaticPair final {
    MPSGraphTensor *firstDepth;
    MPSGraphTensor *secondDepth;
    MPSGraphTensor *firstSurface;
    MPSGraphTensor *secondSurface;
};

[[nodiscard]] GraphHydrostaticPair reconstruct(
    const GraphOps& op,
    MPSGraphTensor *firstBed,
    MPSGraphTensor *firstSurface,
    MPSGraphTensor *secondBed,
    MPSGraphTensor *secondSurface,
    MPSGraphTensor *minimumWetDepth
) {
    MPSGraphTensor * const faceBed = op.maximum(firstBed, secondBed);
    MPSGraphTensor * const firstDepth = op.cleanDepth(
        op.maximum(op.sub(firstSurface, faceBed), op.scalar(0.0)), minimumWetDepth);
    MPSGraphTensor * const secondDepth = op.cleanDepth(
        op.maximum(op.sub(secondSurface, faceBed), op.scalar(0.0)), minimumWetDepth);
    return {firstDepth, secondDepth, op.add(faceBed, firstDepth),
            op.add(faceBed, secondDepth)};
}

struct GraphBoundaryScalars final {
    swe::BoundaryType type = swe::BoundaryType::reflective;
    MPSGraphTensor *meanSurface;
    MPSGraphTensor *amplitude;
    MPSGraphTensor *period;
    MPSGraphTensor *phase;
    MPSGraphTensor *rampSeconds;
};

[[nodiscard]] MPSGraphTensor *drivenSurface(const GraphOps& op,
                                            const GraphBoundaryScalars& boundary,
                                            MPSGraphTensor *time) {
    MPSGraphTensor * const zero = op.scalar(0.0);
    MPSGraphTensor * const one = op.scalar(1.0);
    MPSGraphTensor * const safeRamp = op.maximum(boundary.rampSeconds, op.scalar(1.0e-20));
    MPSGraphTensor * const progress = op.minimum(
        op.maximum(op.div(time, safeRamp), zero), one);
    MPSGraphTensor * const smooth = op.mul(op.mul(progress, progress),
                                           op.sub(op.scalar(3.0), op.mul(op.scalar(2.0),
                                                                        progress)));
    MPSGraphTensor * const ramp = op.select(op.greater(boundary.rampSeconds, zero),
                                            smooth, one);
    MPSGraphTensor * const angle = op.add(
        op.div(op.mul(op.scalar(2.0 * std::numbers::pi), time), boundary.period),
        boundary.phase);
    return op.add(boundary.meanSurface,
                  op.mul(op.mul(ramp, boundary.amplitude),
                         [op.graph sinWithTensor:angle name:nil]));
}

[[nodiscard]] GraphHydrostaticPair reconstructBoundary(
    const GraphOps& op,
    const GraphBoundaryScalars& boundary,
    MPSGraphTensor *interiorBed,
    MPSGraphTensor *interiorSurface,
    MPSGraphTensor *time,
    MPSGraphTensor *minimumWetDepth
) {
    MPSGraphTensor *reservoirSurface = interiorSurface;
    if (boundary.type == swe::BoundaryType::drivenHeight) {
        reservoirSurface = drivenSurface(op, boundary, time);
    }
    return reconstruct(op, interiorBed, interiorSurface, interiorBed, reservoirSurface,
                       minimumWetDepth);
}

[[nodiscard]] MPSGraphTensor *updatedBoundaryVelocity(
    const GraphOps& op,
    const GraphBoundaryScalars& boundary,
    MPSGraphTensor *oldOutwardVelocity,
    MPSGraphTensor *bed,
    MPSGraphTensor *surface,
    MPSGraphTensor *time,
    MPSGraphTensor *factor,
    MPSGraphTensor *minimumWetDepth
) {
    if (boundary.type == swe::BoundaryType::reflective) {
        return op.mul(oldOutwardVelocity, op.scalar(0.0));
    }
    const GraphHydrostaticPair hydro = reconstructBoundary(
        op, boundary, bed, surface, time, minimumWetDepth);
    MPSGraphTensor * const candidate = op.sub(
        oldOutwardVelocity, op.mul(factor, op.sub(hydro.secondSurface,
                                                  hydro.firstSurface)));
    return op.select(op.greater(op.add(hydro.firstDepth, hydro.secondDepth), op.scalar(0.0)),
                     candidate, op.scalar(0.0));
}

[[nodiscard]] MPSGraphTensor *boundaryFlux(
    const GraphOps& op,
    const GraphBoundaryScalars& boundary,
    MPSGraphTensor *outwardVelocity,
    MPSGraphTensor *bed,
    MPSGraphTensor *surface,
    MPSGraphTensor *time,
    MPSGraphTensor *minimumWetDepth
) {
    if (boundary.type == swe::BoundaryType::reflective) {
        return op.mul(outwardVelocity, op.scalar(0.0));
    }
    const GraphHydrostaticPair hydro = reconstructBoundary(
        op, boundary, bed, surface, time, minimumWetDepth);
    return op.mul(outwardVelocity,
                  op.select(op.greaterEqual(outwardVelocity, op.scalar(0.0)),
                            hydro.firstDepth, hydro.secondDepth));
}

struct GraphProgram final {
    MPSGraph *graph;
    MPSGraphExecutable *executable;
    NSArray<MPSGraphTensor *> *inputs;
    NSArray<MPSGraphTensor *> *outputs;
    NSArray<MPSGraphShapedType *> *inputTypes;
    std::vector<std::size_t> inputPermutation;
    std::vector<std::size_t> outputPermutation;
};

[[nodiscard]] std::vector<std::size_t> tensorPermutation(
    NSArray<MPSGraphTensor *> *requested,
    NSArray<MPSGraphTensor *> *actual
) {
    std::vector<std::size_t> result;
    result.reserve(actual.count);
    for (MPSGraphTensor *tensor in actual) {
        const NSUInteger index = [requested indexOfObjectIdenticalTo:tensor];
        if (index == NSNotFound) { return {}; }
        result.push_back(index);
    }
    return result;
}

[[nodiscard]] GraphProgram makeProgram(
    MPSGraph *graph,
    MPSGraphExecutable *executable,
    NSArray<MPSGraphTensor *> *inputs,
    NSArray<MPSGraphTensor *> *outputs,
    NSArray<MPSGraphShapedType *> *inputTypes
) {
    return {graph, executable, inputs, outputs, inputTypes,
            tensorPermutation(inputs, executable.feedTensors),
            tensorPermutation(outputs, executable.targetTensors)};
}

class GraphPlaceholders final {
public:
    explicit GraphPlaceholders(MPSGraph *source) : graph_(source) {}

    [[nodiscard]] MPSGraphTensor *add(MPSShape *shape, NSString *name) {
        MPSGraphTensor * const tensor = [graph_ placeholderWithShape:shape
                                                            dataType:MPSDataTypeFloat32
                                                                name:name];
        [inputs_ addObject:tensor];
        [types_ addObject:[[MPSGraphShapedType alloc] initWithShape:shape
                                                        dataType:MPSDataTypeFloat32]];
        feeds_[tensor] = types_.lastObject;
        return tensor;
    }

    [[nodiscard]] MPSGraphTensor *scalar(NSString *name) { return add(@[@1], name); }
    [[nodiscard]] NSArray<MPSGraphTensor *> *inputs() const { return inputs_; }
    [[nodiscard]] NSArray<MPSGraphShapedType *> *types() const { return types_; }
    [[nodiscard]] NSDictionary<MPSGraphTensor *, MPSGraphShapedType *> *feeds() const {
        return feeds_;
    }

private:
    MPSGraph *graph_;
    NSMutableArray<MPSGraphTensor *> *inputs_ = [NSMutableArray array];
    NSMutableArray<MPSGraphShapedType *> *types_ = [NSMutableArray array];
    NSMutableDictionary<MPSGraphTensor *, MPSGraphShapedType *> *feeds_ =
        [NSMutableDictionary dictionary];
};

struct SubstepTensors final {
    GraphProgram program;
    MPSShape *cellShape;
    MPSShape *xShape;
    MPSShape *yShape;
};

[[nodiscard]] std::array<swe::BoundaryType, swe::boundaryEdgeCount> boundaryTypes(
    const swe::BoundaryConfiguration& boundaries
) noexcept {
    return {boundaries.left.type, boundaries.right.type,
            boundaries.bottom.type, boundaries.top.type};
}

[[nodiscard]] SubstepTensors buildSubstepProgram(
    const BackendState& state,
    MPSGraphDevice *device,
    MPSGraphCompilationDescriptor *descriptor
) {
    const NSInteger width = static_cast<NSInteger>(state.geometry.width);
    const NSInteger height = static_cast<NSInteger>(state.geometry.height);
    MPSShape * const cellShape = @[@(height), @(width)];
    MPSShape * const xShape = @[@(height), @(width + 1)];
    MPSShape * const yShape = @[@(height + 1), @(width)];
    MPSGraph * const graph = [MPSGraph new];
    const GraphOps op{graph};
    GraphPlaceholders feeds(graph);
    MPSGraphTensor * const bed = feeds.add(cellShape, @"bed");
    MPSGraphTensor * const depth = feeds.add(cellShape, @"depth");
    MPSGraphTensor * const velX = feeds.add(xShape, @"velX");
    MPSGraphTensor * const velY = feeds.add(yShape, @"velY");
    MPSGraphTensor * const referenceSurface = feeds.add(cellShape, @"referenceSurface");
    MPSGraphTensor * const dt = feeds.scalar(@"dt");
    MPSGraphTensor * const time = feeds.scalar(@"time");
    MPSGraphTensor * const gravity = feeds.scalar(@"gravity");
    MPSGraphTensor * const damping = feeds.scalar(@"damping");
    MPSGraphTensor * const minimumWetDepth = feeds.scalar(@"minimumWetDepth");
    MPSGraphTensor * const minimumBed = feeds.scalar(@"minimumBed");
    MPSGraphTensor * const maximumSurface = feeds.scalar(@"maximumSurface");
    MPSGraphTensor * const dx = feeds.scalar(@"dx");
    MPSGraphTensor * const dy = feeds.scalar(@"dy");
    MPSGraphTensor * const debugVelocityBound = feeds.scalar(@"debugVelocityBound");
    std::array<GraphBoundaryScalars, swe::boundaryEdgeCount> boundaries;
    const auto types = boundaryTypes(state.boundaries);
    for (std::size_t edge = 0; edge < boundaries.size(); ++edge) {
        NSString * const prefix = [NSString stringWithFormat:@"boundary%zu", edge];
        boundaries[edge] = {
            .type = types[edge],
            .meanSurface = feeds.scalar([prefix stringByAppendingString:@"Mean"]),
            .amplitude = feeds.scalar([prefix stringByAppendingString:@"Amplitude"]),
            .period = feeds.scalar([prefix stringByAppendingString:@"Period"]),
            .phase = feeds.scalar([prefix stringByAppendingString:@"Phase"]),
            .rampSeconds = feeds.scalar([prefix stringByAppendingString:@"Ramp"]),
        };
    }

    MPSGraphTensor * const zero = op.scalar(0.0);
    MPSGraphTensor * const surface = op.add(bed, depth);
    MPSGraphTensor * const factorX = op.div(op.mul(gravity, dt), dx);
    MPSGraphTensor * const factorY = op.div(op.mul(gravity, dt), dy);

    MPSGraphTensor * const bedLeft = op.slice(bed, 1, 0, 1);
    MPSGraphTensor * const bedRight = op.slice(bed, 1, width - 1, 1);
    MPSGraphTensor * const surfaceLeft = op.slice(surface, 1, 0, 1);
    MPSGraphTensor * const surfaceRight = op.slice(surface, 1, width - 1, 1);
    MPSGraphTensor * const leftOutward = updatedBoundaryVelocity(
        op, boundaries[0], op.negate(op.slice(velX, 1, 0, 1)), bedLeft, surfaceLeft,
        time, factorX, minimumWetDepth);
    MPSGraphTensor * const rightOutward = updatedBoundaryVelocity(
        op, boundaries[1], op.slice(velX, 1, width, 1), bedRight, surfaceRight,
        time, factorX, minimumWetDepth);
    const GraphHydrostaticPair xHydro = reconstruct(
        op, op.slice(bed, 1, 0, width - 1), op.slice(surface, 1, 0, width - 1),
        op.slice(bed, 1, 1, width - 1), op.slice(surface, 1, 1, width - 1),
        minimumWetDepth);
    MPSGraphTensor * const xInteriorOld = op.slice(velX, 1, 1, width - 1);
    MPSGraphTensor * const xInteriorCandidate = op.sub(
        xInteriorOld, op.mul(factorX, op.sub(xHydro.secondSurface,
                                             xHydro.firstSurface)));
    MPSGraphTensor * const xInterior = op.select(
        op.greater(op.add(xHydro.firstDepth, xHydro.secondDepth), zero),
        xInteriorCandidate, zero);
    MPSGraphTensor * const updatedX = op.concat(
        @[op.negate(leftOutward), xInterior, rightOutward], 1);

    MPSGraphTensor * const bedBottom = op.slice(bed, 0, 0, 1);
    MPSGraphTensor * const bedTop = op.slice(bed, 0, height - 1, 1);
    MPSGraphTensor * const surfaceBottom = op.slice(surface, 0, 0, 1);
    MPSGraphTensor * const surfaceTop = op.slice(surface, 0, height - 1, 1);
    MPSGraphTensor * const bottomOutward = updatedBoundaryVelocity(
        op, boundaries[2], op.negate(op.slice(velY, 0, 0, 1)), bedBottom,
        surfaceBottom, time, factorY, minimumWetDepth);
    MPSGraphTensor * const topOutward = updatedBoundaryVelocity(
        op, boundaries[3], op.slice(velY, 0, height, 1), bedTop, surfaceTop,
        time, factorY, minimumWetDepth);
    const GraphHydrostaticPair yHydro = reconstruct(
        op, op.slice(bed, 0, 0, height - 1), op.slice(surface, 0, 0, height - 1),
        op.slice(bed, 0, 1, height - 1), op.slice(surface, 0, 1, height - 1),
        minimumWetDepth);
    MPSGraphTensor * const yInteriorOld = op.slice(velY, 0, 1, height - 1);
    MPSGraphTensor * const yInteriorCandidate = op.sub(
        yInteriorOld, op.mul(factorY, op.sub(yHydro.secondSurface,
                                             yHydro.firstSurface)));
    MPSGraphTensor * const yInterior = op.select(
        op.greater(op.add(yHydro.firstDepth, yHydro.secondDepth), zero),
        yInteriorCandidate, zero);
    MPSGraphTensor * const updatedY = op.concat(
        @[op.negate(bottomOutward), yInterior, topOutward], 0);
    MPSGraphTensor * const dampingFactor = [graph exponentWithTensor:
        op.negate(op.mul(damping, dt)) name:nil];
    MPSGraphTensor * const dampedX = op.mul(updatedX, dampingFactor);
    MPSGraphTensor * const dampedY = op.mul(updatedY, dampingFactor);

    MPSGraphTensor * const leftFluxOut = boundaryFlux(
        op, boundaries[0], op.negate(op.slice(dampedX, 1, 0, 1)), bedLeft,
        surfaceLeft, time, minimumWetDepth);
    MPSGraphTensor * const rightFluxOut = boundaryFlux(
        op, boundaries[1], op.slice(dampedX, 1, width, 1), bedRight,
        surfaceRight, time, minimumWetDepth);
    MPSGraphTensor * const xInteriorVelocity = op.slice(dampedX, 1, 1, width - 1);
    MPSGraphTensor * const xInteriorFlux = op.mul(
        xInteriorVelocity,
        op.select(op.greaterEqual(xInteriorVelocity, zero), xHydro.firstDepth,
                  xHydro.secondDepth));
    MPSGraphTensor * const fluxX = op.concat(
        @[op.negate(leftFluxOut), xInteriorFlux, rightFluxOut], 1);

    MPSGraphTensor * const bottomFluxOut = boundaryFlux(
        op, boundaries[2], op.negate(op.slice(dampedY, 0, 0, 1)), bedBottom,
        surfaceBottom, time, minimumWetDepth);
    MPSGraphTensor * const topFluxOut = boundaryFlux(
        op, boundaries[3], op.slice(dampedY, 0, height, 1), bedTop,
        surfaceTop, time, minimumWetDepth);
    MPSGraphTensor * const yInteriorVelocity = op.slice(dampedY, 0, 1, height - 1);
    MPSGraphTensor * const yInteriorFlux = op.mul(
        yInteriorVelocity,
        op.select(op.greaterEqual(yInteriorVelocity, zero), yHydro.firstDepth,
                  yHydro.secondDepth));
    MPSGraphTensor * const fluxY = op.concat(
        @[op.negate(bottomFluxOut), yInteriorFlux, topFluxOut], 0);

    MPSGraphTensor * const fluxXLeft = op.slice(fluxX, 1, 0, width);
    MPSGraphTensor * const fluxXRight = op.slice(fluxX, 1, 1, width);
    MPSGraphTensor * const fluxYBottom = op.slice(fluxY, 0, 0, height);
    MPSGraphTensor * const fluxYTop = op.slice(fluxY, 0, 1, height);
    MPSGraphTensor * const outgoing = op.add(
        op.mul(op.div(dt, dx),
               op.add(op.maximum(fluxXRight, zero),
                      op.maximum(op.negate(fluxXLeft), zero))),
        op.mul(op.div(dt, dy),
               op.add(op.maximum(fluxYTop, zero),
                      op.maximum(op.negate(fluxYBottom), zero))));
    MPSGraphTensor * const outgoingScale = op.select(
        op.greater(outgoing, depth), op.div(depth, outgoing), op.scalar(1.0));

    MPSGraphTensor * const scaleLeftEdge = op.slice(outgoingScale, 1, 0, 1);
    MPSGraphTensor * const scaleRightEdge = op.slice(outgoingScale, 1, width - 1, 1);
    MPSGraphTensor * const limitedLeft = op.select(
        op.greater(zero, op.slice(fluxX, 1, 0, 1)),
        op.mul(op.slice(fluxX, 1, 0, 1), scaleLeftEdge),
        op.slice(fluxX, 1, 0, 1));
    MPSGraphTensor * const limitedRight = op.select(
        op.greater(op.slice(fluxX, 1, width, 1), zero),
        op.mul(op.slice(fluxX, 1, width, 1), scaleRightEdge),
        op.slice(fluxX, 1, width, 1));
    MPSGraphTensor * const interiorFluxX = op.slice(fluxX, 1, 1, width - 1);
    MPSGraphTensor * const limitedInteriorX = op.mul(
        interiorFluxX,
        op.select(op.greaterEqual(interiorFluxX, zero),
                  op.slice(outgoingScale, 1, 0, width - 1),
                  op.slice(outgoingScale, 1, 1, width - 1)));
    MPSGraphTensor * const limitedFluxX = op.concat(
        @[limitedLeft, limitedInteriorX, limitedRight], 1);

    MPSGraphTensor * const scaleBottomEdge = op.slice(outgoingScale, 0, 0, 1);
    MPSGraphTensor * const scaleTopEdge = op.slice(outgoingScale, 0, height - 1, 1);
    MPSGraphTensor * const limitedBottom = op.select(
        op.greater(zero, op.slice(fluxY, 0, 0, 1)),
        op.mul(op.slice(fluxY, 0, 0, 1), scaleBottomEdge),
        op.slice(fluxY, 0, 0, 1));
    MPSGraphTensor * const limitedTop = op.select(
        op.greater(op.slice(fluxY, 0, height, 1), zero),
        op.mul(op.slice(fluxY, 0, height, 1), scaleTopEdge),
        op.slice(fluxY, 0, height, 1));
    MPSGraphTensor * const interiorFluxY = op.slice(fluxY, 0, 1, height - 1);
    MPSGraphTensor * const limitedInteriorY = op.mul(
        interiorFluxY,
        op.select(op.greaterEqual(interiorFluxY, zero),
                  op.slice(outgoingScale, 0, 0, height - 1),
                  op.slice(outgoingScale, 0, 1, height - 1)));
    MPSGraphTensor * const limitedFluxY = op.concat(
        @[limitedBottom, limitedInteriorY, limitedTop], 0);

    MPSGraphTensor * const rawDepthNext = op.sub(
        depth,
        op.add(op.mul(op.div(dt, dx),
                      op.sub(op.slice(limitedFluxX, 1, 1, width),
                             op.slice(limitedFluxX, 1, 0, width))),
               op.mul(op.div(dt, dy),
                      op.sub(op.slice(limitedFluxY, 0, 1, height),
                             op.slice(limitedFluxY, 0, 0, height)))));
    MPSGraphTensor * const depthNext = op.cleanDepth(rawDepthNext, minimumWetDepth);
    MPSGraphTensor * const correction = op.select(
        op.greaterEqual(minimumWetDepth, rawDepthNext), op.absolute(rawDepthNext), zero);
    MPSGraphTensor * const nextSurface = op.add(bed, depthNext);
    MPSGraphTensor * const nextTime = op.add(time, dt);

    const GraphHydrostaticPair nextXHydro = reconstruct(
        op, op.slice(bed, 1, 0, width - 1), op.slice(nextSurface, 1, 0, width - 1),
        op.slice(bed, 1, 1, width - 1), op.slice(nextSurface, 1, 1, width - 1),
        minimumWetDepth);
    MPSGraphTensor * const nextXInterior = op.slice(dampedX, 1, 1, width - 1);
    MPSGraphTensor * const nextXDonor = op.select(
        op.greaterEqual(nextXInterior, zero), nextXHydro.firstDepth,
        nextXHydro.secondDepth);
    MPSGraphTensor * const cleanXInterior = op.select(
        op.greater(nextXDonor, zero), nextXInterior, zero);
    const GraphHydrostaticPair nextLeftHydro = reconstructBoundary(
        op, boundaries[0], bedLeft, op.slice(nextSurface, 1, 0, 1), nextTime,
        minimumWetDepth);
    const GraphHydrostaticPair nextRightHydro = reconstructBoundary(
        op, boundaries[1], bedRight, op.slice(nextSurface, 1, width - 1, 1), nextTime,
        minimumWetDepth);
    MPSGraphTensor * const nextLeftGlobal = op.slice(dampedX, 1, 0, 1);
    MPSGraphTensor * const nextRightGlobal = op.slice(dampedX, 1, width, 1);
    MPSGraphTensor * const nextLeftDonor = op.select(
        op.greaterEqual(op.negate(nextLeftGlobal), zero), nextLeftHydro.firstDepth,
        nextLeftHydro.secondDepth);
    MPSGraphTensor * const nextRightDonor = op.select(
        op.greaterEqual(nextRightGlobal, zero), nextRightHydro.firstDepth,
        nextRightHydro.secondDepth);
    MPSGraphTensor * const cleanX = op.concat(@[
        op.select(op.greater(nextLeftDonor, zero), nextLeftGlobal, zero),
        cleanXInterior,
        op.select(op.greater(nextRightDonor, zero), nextRightGlobal, zero),
    ], 1);

    const GraphHydrostaticPair nextYHydro = reconstruct(
        op, op.slice(bed, 0, 0, height - 1), op.slice(nextSurface, 0, 0, height - 1),
        op.slice(bed, 0, 1, height - 1), op.slice(nextSurface, 0, 1, height - 1),
        minimumWetDepth);
    MPSGraphTensor * const nextYInterior = op.slice(dampedY, 0, 1, height - 1);
    MPSGraphTensor * const nextYDonor = op.select(
        op.greaterEqual(nextYInterior, zero), nextYHydro.firstDepth,
        nextYHydro.secondDepth);
    MPSGraphTensor * const cleanYInterior = op.select(
        op.greater(nextYDonor, zero), nextYInterior, zero);
    const GraphHydrostaticPair nextBottomHydro = reconstructBoundary(
        op, boundaries[2], bedBottom, op.slice(nextSurface, 0, 0, 1), nextTime,
        minimumWetDepth);
    const GraphHydrostaticPair nextTopHydro = reconstructBoundary(
        op, boundaries[3], bedTop, op.slice(nextSurface, 0, height - 1, 1), nextTime,
        minimumWetDepth);
    MPSGraphTensor * const nextBottomGlobal = op.slice(dampedY, 0, 0, 1);
    MPSGraphTensor * const nextTopGlobal = op.slice(dampedY, 0, height, 1);
    MPSGraphTensor * const nextBottomDonor = op.select(
        op.greaterEqual(op.negate(nextBottomGlobal), zero), nextBottomHydro.firstDepth,
        nextBottomHydro.secondDepth);
    MPSGraphTensor * const nextTopDonor = op.select(
        op.greaterEqual(nextTopGlobal, zero), nextTopHydro.firstDepth,
        nextTopHydro.secondDepth);
    MPSGraphTensor * const cleanY = op.concat(@[
        op.select(op.greater(nextBottomDonor, zero), nextBottomGlobal, zero),
        cleanYInterior,
        op.select(op.greater(nextTopDonor, zero), nextTopGlobal, zero),
    ], 0);

    MPSGraphTensor * const leftRate = op.mul(
        op.negate(dy), op.sum(op.slice(limitedFluxX, 1, 0, 1)));
    MPSGraphTensor * const rightRate = op.mul(
        dy, op.sum(op.slice(limitedFluxX, 1, width, 1)));
    MPSGraphTensor * const bottomRate = op.mul(
        op.negate(dx), op.sum(op.slice(limitedFluxY, 0, 0, 1)));
    MPSGraphTensor * const topRate = op.mul(
        dx, op.sum(op.slice(limitedFluxY, 0, height, 1)));
    MPSGraphTensor * const boundaryRates = op.concat(
        @[[graph reshapeTensor:leftRate withShape:@[@1] name:nil],
          [graph reshapeTensor:rightRate withShape:@[@1] name:nil],
          [graph reshapeTensor:bottomRate withShape:@[@1] name:nil],
          [graph reshapeTensor:topRate withShape:@[@1] name:nil]], 0);

    MPSGraphTensor * const minimumDepthResult = op.minAll(depthNext);
    MPSGraphTensor * const maximumDepthResult = op.maxAll(depthNext);
    MPSGraphTensor * const maximumXResult = op.maxAll(op.absolute(cleanX));
    MPSGraphTensor * const maximumYResult = op.maxAll(op.absolute(cleanY));
    MPSGraphTensor * const totalVolume = op.mul(
        op.sum(depthNext), op.mul(dx, dy));
    MPSGraphTensor * const correctionVolume = op.mul(
        op.sum(correction), op.mul(dx, dy));
    MPSGraphTensor * const wetMaskBoolean = op.greater(depthNext, minimumWetDepth);
    MPSGraphTensor * const wetMask = op.cast(wetMaskBoolean, MPSDataTypeUInt8);
    MPSGraphTensor * const wetCount = op.sum(op.cast(wetMaskBoolean, MPSDataTypeFloat32));
    MPSGraphTensor * const correctionCount = op.sum(op.cast(
        op.greater(correction, zero), MPSDataTypeFloat32));
    MPSGraphTensor *finite = op.logicalAnd(
        [graph isFiniteWithTensor:bed name:nil], [graph isFiniteWithTensor:depthNext name:nil]);
    finite = op.logicalAnd(finite, op.greaterEqual(depthNext, zero));
    finite = op.logicalAnd(finite, op.greaterEqual(bed, minimumBed));
    finite = op.logicalAnd(finite, op.greaterEqual(maximumSurface, nextSurface));
    MPSGraphTensor * const finiteCells = op.minAll(op.cast(finite, MPSDataTypeFloat32));
    MPSGraphTensor * const finiteX = op.minAll(op.cast(
        [graph isFiniteWithTensor:cleanX name:nil], MPSDataTypeFloat32));
    MPSGraphTensor * const finiteY = op.minAll(op.cast(
        [graph isFiniteWithTensor:cleanY name:nil], MPSDataTypeFloat32));
    MPSGraphTensor * const withinDebugBound = op.select(
        op.greater(debugVelocityBound, zero),
        op.cast(op.greaterEqual(debugVelocityBound,
                               op.maximum(maximumXResult, maximumYResult)),
                MPSDataTypeFloat32), op.scalar(1.0));
    MPSGraphTensor * const finiteResult = op.minimum(
        op.minimum(finiteCells, finiteX), op.minimum(finiteY, withinDebugBound));
    MPSGraphTensor * const cellX = op.mul(
        op.add(op.slice(cleanX, 1, 0, width), op.slice(cleanX, 1, 1, width)),
        op.scalar(0.5));
    MPSGraphTensor * const cellY = op.mul(
        op.add(op.slice(cleanY, 0, 0, height), op.slice(cleanY, 0, 1, height)),
        op.scalar(0.5));
    MPSGraphTensor * const velocityMagnitude = [graph squareRootWithTensor:
        op.add(op.mul(cellX, cellX), op.mul(cellY, cellY)) name:nil];
    MPSGraphTensor * const surfaceDeviation = op.sub(nextSurface, referenceSurface);

    NSArray<MPSGraphTensor *> * const outputs = @[
        depthNext, cleanX, cleanY, nextSurface, limitedFluxX, limitedFluxY,
        outgoingScale, boundaryRates, totalVolume, minimumDepthResult,
        maximumDepthResult, maximumXResult, maximumYResult, correctionVolume,
        wetCount, correctionCount, finiteResult, surfaceDeviation,
        velocityMagnitude, wetMask,
    ];
    MPSGraphExecutable * const executable = [graph compileWithDevice:device
        feeds:feeds.feeds() targetTensors:outputs targetOperations:nil
        compilationDescriptor:descriptor];
    return {makeProgram(graph, executable, feeds.inputs(), outputs, feeds.types()),
            cellShape, xShape, yShape};
}

[[nodiscard]] GraphProgram buildStableProgram(
    const BackendState& state,
    MPSGraphDevice *device,
    MPSGraphCompilationDescriptor *descriptor
) {
    const NSInteger width = static_cast<NSInteger>(state.geometry.width);
    const NSInteger height = static_cast<NSInteger>(state.geometry.height);
    MPSShape * const cellShape = @[@(height), @(width)];
    MPSGraph * const graph = [MPSGraph new];
    const GraphOps op{graph};
    GraphPlaceholders feeds(graph);
    MPSGraphTensor * const bed = feeds.add(cellShape, @"bed");
    MPSGraphTensor * const depth = feeds.add(cellShape, @"depth");
    MPSGraphTensor * const velX = feeds.add(@[@(height), @(width + 1)], @"velX");
    MPSGraphTensor * const velY = feeds.add(@[@(height + 1), @(width)], @"velY");
    MPSGraphTensor * const time = feeds.scalar(@"time");
    MPSGraphTensor * const gravity = feeds.scalar(@"gravity");
    MPSGraphTensor * const dx = feeds.scalar(@"dx");
    MPSGraphTensor * const dy = feeds.scalar(@"dy");
    MPSGraphTensor * const cfl = feeds.scalar(@"cfl");
    MPSGraphTensor * const debugVelocityBound = feeds.scalar(@"debugVelocityBound");
    std::array<GraphBoundaryScalars, swe::boundaryEdgeCount> boundaries;
    const auto types = boundaryTypes(state.boundaries);
    for (std::size_t edge = 0; edge < boundaries.size(); ++edge) {
        NSString * const prefix = [NSString stringWithFormat:@"boundary%zu", edge];
        boundaries[edge] = {
            .type = types[edge],
            .meanSurface = feeds.scalar([prefix stringByAppendingString:@"Mean"]),
            .amplitude = feeds.scalar([prefix stringByAppendingString:@"Amplitude"]),
            .period = feeds.scalar([prefix stringByAppendingString:@"Period"]),
            .phase = feeds.scalar([prefix stringByAppendingString:@"Phase"]),
            .rampSeconds = feeds.scalar([prefix stringByAppendingString:@"Ramp"]),
        };
    }
    MPSGraphTensor *maximumDepth = op.maxAll(depth);
    for (std::size_t edge = 0; edge < boundaries.size(); ++edge) {
        if (boundaries[edge].type != swe::BoundaryType::drivenHeight) { continue; }
        MPSGraphTensor *edgeBed;
        if (edge == 0) { edgeBed = op.slice(bed, 1, 0, 1); }
        else if (edge == 1) { edgeBed = op.slice(bed, 1, width - 1, 1); }
        else if (edge == 2) { edgeBed = op.slice(bed, 0, 0, 1); }
        else { edgeBed = op.slice(bed, 0, height - 1, 1); }
        MPSGraphTensor * const reservoirDepth = op.maximum(
            op.sub(drivenSurface(op, boundaries[edge], time), edgeBed), op.scalar(0.0));
        maximumDepth = op.maximum(maximumDepth, op.maxAll(reservoirDepth));
    }
    MPSGraphTensor * const maximumX = op.maxAll(op.absolute(velX));
    MPSGraphTensor * const maximumY = op.maxAll(op.absolute(velY));
    MPSGraphTensor * const waveSpeed = [graph squareRootWithTensor:
        op.mul(gravity, maximumDepth) name:nil];
    MPSGraphTensor * const inverseScale = op.add(
        op.div(op.add(maximumX, waveSpeed), dx),
        op.div(op.add(maximumY, waveSpeed), dy));
    MPSGraphTensor * const stableCandidate = op.mul(
        op.scalar(0.95), op.div(cfl, op.maximum(inverseScale, op.scalar(1.0e-30))));
    MPSGraphTensor * const stable = op.select(
        op.greater(inverseScale, op.scalar(0.0)), stableCandidate,
        op.scalar(std::numeric_limits<float>::max()));
    MPSGraphTensor *finite = op.logicalAnd(
        [graph isFiniteWithTensor:depth name:nil], op.greaterEqual(depth, op.scalar(0.0)));
    MPSGraphTensor * const finiteDepth = op.minAll(op.cast(finite, MPSDataTypeFloat32));
    MPSGraphTensor * const finiteX = op.minAll(op.cast(
        [graph isFiniteWithTensor:velX name:nil], MPSDataTypeFloat32));
    MPSGraphTensor * const finiteY = op.minAll(op.cast(
        [graph isFiniteWithTensor:velY name:nil], MPSDataTypeFloat32));
    MPSGraphTensor * const finiteStable = op.cast(op.logicalAnd(
        [graph isFiniteWithTensor:stable name:nil], op.greater(stable, op.scalar(0.0))),
        MPSDataTypeFloat32);
    MPSGraphTensor * const withinDebugBound = op.select(
        op.greater(debugVelocityBound, op.scalar(0.0)),
        op.cast(op.greaterEqual(debugVelocityBound, op.maximum(maximumX, maximumY)),
                MPSDataTypeFloat32), op.scalar(1.0));
    MPSGraphTensor * const finiteResult = op.minimum(
        op.minimum(finiteDepth, finiteX),
        op.minimum(finiteY, op.minimum(finiteStable, withinDebugBound)));
    NSArray<MPSGraphTensor *> * const outputs = @[
        maximumDepth, maximumX, maximumY, stable, finiteResult,
    ];
    MPSGraphExecutable * const executable = [graph compileWithDevice:device
        feeds:feeds.feeds() targetTensors:outputs targetOperations:nil
        compilationDescriptor:descriptor];
    return makeProgram(graph, executable, feeds.inputs(), outputs, feeds.types());
}

struct GraphCacheKey final {
    std::uint64_t deviceRegistryID = 0;
    std::size_t width = 0;
    std::size_t height = 0;
    std::array<swe::BoundaryType, swe::boundaryEdgeCount> boundaries{};

    auto operator<=>(const GraphCacheKey&) const = default;
};

struct CachedGraphPrograms final {
    GraphProgram stable;
    SubstepTensors substep;
};

[[nodiscard]] bool validProgram(const GraphProgram& program) noexcept {
    return program.executable != nil &&
        program.inputPermutation.size() == program.inputs.count &&
        program.outputPermutation.size() == program.outputs.count;
}

[[nodiscard]] bool validPrograms(const CachedGraphPrograms& programs) noexcept {
    return validProgram(programs.stable) && validProgram(programs.substep.program);
}

[[nodiscard]] std::shared_ptr<CachedGraphPrograms> cachedPrograms(
    const BackendState& state,
    id<MTLDevice> metalDevice,
    MPSGraphDevice *graphDevice,
    bool& cacheHit
) {
    static std::mutex cacheMutex;
    static std::map<GraphCacheKey, std::shared_ptr<CachedGraphPrograms>> cache;
    const GraphCacheKey key{metalDevice.registryID, state.geometry.width, state.geometry.height,
                            boundaryTypes(state.boundaries)};
    std::scoped_lock lock(cacheMutex);
    if (const auto found = cache.find(key); found != cache.end()) {
        cacheHit = true;
        return found->second;
    }
    MPSGraphCompilationDescriptor * const descriptor = [MPSGraphCompilationDescriptor new];
    descriptor.optimizationLevel = MPSGraphOptimizationLevel1;
    descriptor.waitForCompilationCompletion = YES;
    auto result = std::make_shared<CachedGraphPrograms>(CachedGraphPrograms{
        buildStableProgram(state, graphDevice, descriptor),
        buildSubstepProgram(state, graphDevice, descriptor),
    });
    cache[key] = result;
    cacheHit = false;
    return result;
}

} // namespace

class MPSGraphAutomaticBackend::Implementation final {
public:
    struct SnapshotStaging final {
        id<MTLBuffer> bed;
        id<MTLBuffer> depth;
        id<MTLBuffer> surface;
        id<MTLBuffer> deviation;
        id<MTLBuffer> velocity;
        id<MTLBuffer> wetMask;
    };

    [[nodiscard]] bool load(const BackendState& state,
                            const swe::SolverConfiguration configuration,
                            std::string& failureReason) {
        if (!state.isValid() || !configuration.isValid()) {
            failureReason = "Invalid MPSGraph state or solver configuration";
            return false;
        }
        const std::size_t width = state.geometry.width;
        const std::size_t height = state.geometry.height;
        const std::size_t cells = width * height;
        const std::size_t xFaces = (width + 1) * height;
        const std::size_t yFaces = width * (height + 1);
        const std::size_t maximumDimension = static_cast<std::size_t>(
            std::numeric_limits<NSInteger>::max());
        const std::size_t maximumFloatElements =
            std::numeric_limits<NSUInteger>::max() / sizeof(float);
        if (width > maximumDimension || height > maximumDimension ||
            cells > maximumFloatElements || xFaces > maximumFloatElements ||
            yFaces > maximumFloatElements) {
            failureReason = "Grid exceeds the MPSGraph shape or buffer range";
            return false;
        }
        const auto start = Clock::now();
        metalDevice = MTLCreateSystemDefaultDevice();
        if (metalDevice == nil) {
            failureReason = "No device is available for MPSGraph";
            return false;
        }
        queue = [metalDevice newCommandQueue];
        if (queue == nil) {
            failureReason = "Could not create the MPSGraph command queue";
            return false;
        }
        graphDevice = [MPSGraphDevice deviceWithMTLDevice:metalDevice];
        os_signpost_interval_begin(mpsPerformanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                   "GraphPreparation", "width=%zu height=%zu",
                                   state.geometry.width, state.geometry.height);
        metadata = state;
        solverConfiguration = configuration;
        bool cacheHit = false;
        @try {
            cachedGraphPrograms = cachedPrograms(state, metalDevice, graphDevice, cacheHit);
            stableProgram = cachedGraphPrograms->stable;
            substep = cachedGraphPrograms->substep;
        } @catch (NSException *exception) {
            os_signpost_interval_end(mpsPerformanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                     "GraphPreparation", "failed=1");
            failureReason = std::string("MPSGraph compilation exception: ") +
                exception.reason.UTF8String;
            return false;
        }
        status.graphCompileMilliseconds = cacheHit ? 0.0 : millisecondsSince(start);
        os_signpost_interval_end(mpsPerformanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                 "GraphPreparation", "cache_hit=%d", cacheHit);
        if (!validPrograms(*cachedGraphPrograms)) {
            failureReason = "MPSGraph level-1 executable compilation failed";
            return false;
        }
        if (!allocateBuffers(failureReason)) { return false; }
        uploadState(state);
        initializeDerivedFields();
        initializeDiagnostics();
        status.requested = RequestedSimulationBackend::automaticAccelerated;
        status.resolved = ResolvedSimulationBackend::mpsGraphAutomatic;
        status.ready = true;
        status.statePrecision = "Float32";
        return true;
    }

    [[nodiscard]] bool allocateBuffers(std::string& failureReason) {
        stateSizedAllocationCount = 0;
        const std::size_t cells = metadata.geometry.width * metadata.geometry.height;
        const std::size_t xFaces = (metadata.geometry.width + 1) * metadata.geometry.height;
        const std::size_t yFaces = metadata.geometry.width * (metadata.geometry.height + 1);
        const auto make = [&](const std::size_t bytes, NSString *label) {
            id<MTLBuffer> const result = [metalDevice newBufferWithLength:bytes
                options:MTLResourceStorageModeShared];
            result.label = label;
            return result;
        };
        bedBuffer = make(cells * sizeof(float), @"MPSGraph bed");
        referenceSurfaceBuffer = make(cells * sizeof(float), @"MPSGraph reference surface");
        for (std::size_t index = 0; index < 2; ++index) {
            depthBuffers[index] = make(cells * sizeof(float),
                [NSString stringWithFormat:@"MPSGraph depth %zu", index]);
            velXBuffers[index] = make(xFaces * sizeof(float),
                [NSString stringWithFormat:@"MPSGraph velX %zu", index]);
            velYBuffers[index] = make(yFaces * sizeof(float),
                [NSString stringWithFormat:@"MPSGraph velY %zu", index]);
        }
        surfaceBuffer = make(cells * sizeof(float), @"MPSGraph surface");
        fluxXBuffer = make(xFaces * sizeof(float), @"MPSGraph fluxX");
        fluxYBuffer = make(yFaces * sizeof(float), @"MPSGraph fluxY");
        outgoingScaleBuffer = make(cells * sizeof(float), @"MPSGraph outgoing scale");
        boundaryRatesBuffer = make(swe::boundaryEdgeCount * sizeof(float),
                                   @"MPSGraph boundary rates");
        surfaceDeviationBuffer = make(cells * sizeof(float), @"MPSGraph surface deviation");
        velocityMagnitudeBuffer = make(cells * sizeof(float), @"MPSGraph velocity magnitude");
        wetMaskBuffer = make(cells, @"MPSGraph wet mask");
        for (std::size_t index = 0; index < snapshotStaging.size(); ++index) {
            SnapshotStaging& staging = snapshotStaging[index];
            staging.bed = make(cells * sizeof(float),
                [NSString stringWithFormat:@"MPSGraph snapshot bed %zu", index]);
            staging.depth = make(cells * sizeof(float),
                [NSString stringWithFormat:@"MPSGraph snapshot depth %zu", index]);
            staging.surface = make(cells * sizeof(float),
                [NSString stringWithFormat:@"MPSGraph snapshot surface %zu", index]);
            staging.deviation = make(cells * sizeof(float),
                [NSString stringWithFormat:@"MPSGraph snapshot deviation %zu", index]);
            staging.velocity = make(cells * sizeof(float),
                [NSString stringWithFormat:@"MPSGraph snapshot velocity %zu", index]);
            staging.wetMask = make(cells,
                [NSString stringWithFormat:@"MPSGraph snapshot wet mask %zu", index]);
        }
        for (std::size_t index = 0; index < stableScalarBuffers.size(); ++index) {
            stableScalarBuffers[index] = make(sizeof(float),
                [NSString stringWithFormat:@"MPSGraph stable scalar %zu", index]);
        }
        for (std::size_t index = 0; index < diagnosticScalarBuffers.size(); ++index) {
            diagnosticScalarBuffers[index] = make(sizeof(float),
                [NSString stringWithFormat:@"MPSGraph diagnostic scalar %zu", index]);
        }
        if (bedBuffer == nil || referenceSurfaceBuffer == nil || depthBuffers[0] == nil ||
            depthBuffers[1] == nil || velXBuffers[0] == nil || velXBuffers[1] == nil ||
            velYBuffers[0] == nil || velYBuffers[1] == nil || surfaceBuffer == nil ||
            fluxXBuffer == nil || fluxYBuffer == nil || outgoingScaleBuffer == nil ||
            boundaryRatesBuffer == nil || surfaceDeviationBuffer == nil ||
            velocityMagnitudeBuffer == nil || wetMaskBuffer == nil) {
            failureReason = "Could not allocate persistent MPSGraph state buffers";
            return false;
        }
        for (const SnapshotStaging& staging : snapshotStaging) {
            if (staging.bed == nil || staging.depth == nil || staging.surface == nil ||
                staging.deviation == nil || staging.velocity == nil || staging.wetMask == nil) {
                failureReason = "Could not allocate the MPSGraph snapshot staging ring";
                return false;
            }
        }
        stateSizedAllocationCount = 33;
        return std::ranges::all_of(stableScalarBuffers, [](id<MTLBuffer> value) {
            return value != nil;
        }) && std::ranges::all_of(diagnosticScalarBuffers, [](id<MTLBuffer> value) {
            return value != nil;
        });
    }

    template <typename Source>
    static void copyToBuffer(const std::vector<Source>& source, id<MTLBuffer> destination) {
        auto target = std::span(static_cast<float *>(destination.contents), source.size());
        std::transform(source.begin(), source.end(), target.begin(),
                       [](const Source value) { return static_cast<float>(value); });
    }

    static void copyFromBuffer(id<MTLBuffer> source, std::vector<double>& destination,
                               const std::size_t count) {
        destination.resize(count);
        const auto values = std::span(static_cast<const float *>(source.contents), count);
        std::transform(values.begin(), values.end(), destination.begin(),
                       [](const float value) { return static_cast<double>(value); });
    }

    void uploadState(const BackendState& state) {
        copyToBuffer(state.bedElevation, bedBuffer);
        copyToBuffer(state.waterDepth, depthBuffers[0]);
        copyToBuffer(state.waterDepth, depthBuffers[1]);
        copyToBuffer(state.velX, velXBuffers[0]);
        copyToBuffer(state.velX, velXBuffers[1]);
        copyToBuffer(state.velY, velYBuffers[0]);
        copyToBuffer(state.velY, velYBuffers[1]);
        auto reference = std::span(static_cast<float *>(referenceSurfaceBuffer.contents),
                                   state.initialBedElevation.size());
        for (std::size_t index = 0; index < reference.size(); ++index) {
            reference[index] = static_cast<float>(state.initialBedElevation[index] +
                                                   state.initialWaterDepth[index]);
        }
        currentIndex = 0;
        ++bufferGeneration;
    }

    void initializeDerivedFields() {
        const std::size_t cells = metadata.geometry.width * metadata.geometry.height;
        const auto bed = std::span(static_cast<const float *>(bedBuffer.contents), cells);
        const auto depth = std::span(static_cast<const float *>(depthBuffers[currentIndex].contents),
                                     cells);
        const std::size_t width = metadata.geometry.width;
        const std::size_t height = metadata.geometry.height;
        const auto velX = std::span(
            static_cast<const float *>(velXBuffers[currentIndex].contents),
            (width + 1) * height);
        const auto velY = std::span(
            static_cast<const float *>(velYBuffers[currentIndex].contents),
            width * (height + 1));
        const auto reference = std::span(
            static_cast<const float *>(referenceSurfaceBuffer.contents), cells);
        auto surface = std::span(static_cast<float *>(surfaceBuffer.contents), cells);
        auto deviation = std::span(static_cast<float *>(surfaceDeviationBuffer.contents), cells);
        auto magnitude = std::span(static_cast<float *>(velocityMagnitudeBuffer.contents), cells);
        auto wet = std::span(static_cast<std::uint8_t *>(wetMaskBuffer.contents), cells);
        for (std::size_t index = 0; index < cells; ++index) {
            surface[index] = bed[index] + depth[index];
            deviation[index] = surface[index] - reference[index];
            const std::size_t row = index / width;
            const std::size_t column = index - row * width;
            const float x = 0.5F * (velX[row * (width + 1) + column] +
                                    velX[row * (width + 1) + column + 1]);
            const float y = 0.5F * (velY[row * width + column] +
                                    velY[(row + 1) * width + column]);
            magnitude[index] = std::sqrt(x * x + y * y);
            wet[index] = depth[index] > solverConfiguration.minimumWetDepth ? 1 : 0;
        }
    }

    void initializeDiagnostics() {
        diagnostics = {};
        diagnostics.finite = true;
        diagnostics.minimumDepth = std::numeric_limits<double>::max();
        double sum = 0.0;
        for (const double value : metadata.waterDepth) {
            sum += value;
            diagnostics.minimumDepth = std::min(diagnostics.minimumDepth, value);
            diagnostics.maximumDepth = std::max(diagnostics.maximumDepth, value);
            diagnostics.wetCellCount += value > solverConfiguration.minimumWetDepth ? 1 : 0;
        }
        diagnostics.totalVolume = sum * metadata.geometry.dx() * metadata.geometry.dy();
        diagnostics.maximumWaveSpeed = std::sqrt(
            solverConfiguration.gravity * diagnostics.maximumDepth);
        diagnostics.simulatedTime = metadata.time;
        diagnostics.cumulativeBoundaryOutwardVolume = metadata.cumulativeBoundaryVolume;
        updateAccounting();
    }

    void updateAccounting() noexcept {
        double cumulative = 0.0;
        for (const double value : metadata.cumulativeBoundaryVolume) { cumulative += value; }
        diagnostics.accountedExpectedVolume = metadata.initialWaterVolume +
            metadata.accumulatedEditWaterVolume - cumulative;
        diagnostics.accountingError = diagnostics.totalVolume -
                                      diagnostics.accountedExpectedVolume;
    }

    [[nodiscard]] MPSGraphTensorData *tensorData(id<MTLBuffer> buffer,
                                                  MPSShape *shape,
                                                  const MPSDataType type =
                                                      MPSDataTypeFloat32) const {
        return [[MPSGraphTensorData alloc] initWithMTLBuffer:buffer shape:shape dataType:type];
    }

    [[nodiscard]] MPSGraphTensorData *scalarData(const float value) const {
        NSData * const data = [NSData dataWithBytes:&value length:sizeof(value)];
        return [[MPSGraphTensorData alloc] initWithDevice:graphDevice data:data
                                                    shape:@[@1] dataType:MPSDataTypeFloat32];
    }

    void appendBoundaryScalars(NSMutableArray<MPSGraphTensorData *> *inputs) const {
        const std::array sides{metadata.boundaries.left, metadata.boundaries.right,
                               metadata.boundaries.bottom, metadata.boundaries.top};
        for (const swe::BoundarySide& side : sides) {
            [inputs addObject:scalarData(static_cast<float>(
                side.driven.meanSurfaceElevation))];
            [inputs addObject:scalarData(static_cast<float>(side.driven.amplitude))];
            [inputs addObject:scalarData(static_cast<float>(side.driven.periodSeconds))];
            [inputs addObject:scalarData(static_cast<float>(side.driven.phaseRadians))];
            [inputs addObject:scalarData(static_cast<float>(side.driven.rampSeconds))];
        }
    }

    [[nodiscard]] static NSArray<MPSGraphTensorData *> *orderedData(
        NSArray<MPSGraphTensorData *> *source,
        const std::vector<std::size_t>& permutation
    ) {
        NSMutableArray<MPSGraphTensorData *> * const result =
            [NSMutableArray arrayWithCapacity:permutation.size()];
        for (const std::size_t index : permutation) {
            [result addObject:source[index]];
        }
        return result;
    }

    [[nodiscard]] double stableTimeStep(std::string& failureReason) {
        const auto start = Clock::now();
        os_signpost_interval_begin(mpsPerformanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                   "StableDtReduction");
        NSMutableArray<MPSGraphTensorData *> * const inputs = [NSMutableArray array];
        [inputs addObject:tensorData(bedBuffer, substep.cellShape)];
        [inputs addObject:tensorData(depthBuffers[currentIndex], substep.cellShape)];
        [inputs addObject:tensorData(velXBuffers[currentIndex], substep.xShape)];
        [inputs addObject:tensorData(velYBuffers[currentIndex], substep.yShape)];
        [inputs addObject:scalarData(static_cast<float>(metadata.time))];
        [inputs addObject:scalarData(static_cast<float>(solverConfiguration.gravity))];
        [inputs addObject:scalarData(static_cast<float>(metadata.geometry.dx()))];
        [inputs addObject:scalarData(static_cast<float>(metadata.geometry.dy()))];
        [inputs addObject:scalarData(static_cast<float>(solverConfiguration.cflNumber))];
        [inputs addObject:scalarData(static_cast<float>(solverConfiguration.debugVelocityBound))];
        appendBoundaryScalars(inputs);
        NSMutableArray<MPSGraphTensorData *> * const results = [NSMutableArray array];
        for (id<MTLBuffer> buffer : stableScalarBuffers) {
            [results addObject:tensorData(buffer, @[@1])];
        }
        @try {
            NSArray<MPSGraphTensorData *> * const actual = [stableProgram.executable
                runWithMTLCommandQueue:queue
                inputsArray:orderedData(inputs, stableProgram.inputPermutation)
                resultsArray:orderedData(results, stableProgram.outputPermutation)
                executionDescriptor:nil];
            if (actual == nil) {
                os_signpost_interval_end(mpsPerformanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                         "StableDtReduction");
                failureReason = "MPSGraph stable-dt executable returned no results";
                return 0.0;
            }
        } @catch (NSException *exception) {
            os_signpost_interval_end(mpsPerformanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                     "StableDtReduction");
            failureReason = std::string("MPSGraph stable-dt exception: ") +
                exception.reason.UTF8String;
            return 0.0;
        }
        status.lastStableDtMilliseconds = millisecondsSince(start);
        os_signpost_interval_end(mpsPerformanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                 "StableDtReduction");
        const auto value = [&](const std::size_t index) {
            return *static_cast<const float *>(stableScalarBuffers[index].contents);
        };
        diagnostics.maximumWaveSpeed = std::sqrt(solverConfiguration.gravity * value(0));
        diagnostics.maximumAbsVelX = value(1);
        diagnostics.maximumAbsVelY = value(2);
        if (value(4) < 0.5F || !std::isfinite(value(3)) || value(3) <= 0.0F) {
            failureReason = "MPSGraph stable-dt reduction rejected the state";
            return 0.0;
        }
        return value(3);
    }

    [[nodiscard]] swe::StepStatus executeSubstep(const double timeStep,
                                                  std::string& failureReason) {
        const auto start = Clock::now();
        os_signpost_interval_begin(mpsPerformanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                   "SWESubstep", "cells=%zu",
                                   metadata.geometry.width * metadata.geometry.height);
        const std::size_t nextIndex = 1 - currentIndex;
        NSMutableArray<MPSGraphTensorData *> * const inputs = [NSMutableArray array];
        [inputs addObject:tensorData(bedBuffer, substep.cellShape)];
        [inputs addObject:tensorData(depthBuffers[currentIndex], substep.cellShape)];
        [inputs addObject:tensorData(velXBuffers[currentIndex], substep.xShape)];
        [inputs addObject:tensorData(velYBuffers[currentIndex], substep.yShape)];
        [inputs addObject:tensorData(referenceSurfaceBuffer, substep.cellShape)];
        [inputs addObject:scalarData(static_cast<float>(timeStep))];
        [inputs addObject:scalarData(static_cast<float>(metadata.time))];
        [inputs addObject:scalarData(static_cast<float>(solverConfiguration.gravity))];
        [inputs addObject:scalarData(static_cast<float>(solverConfiguration.linearDamping))];
        [inputs addObject:scalarData(static_cast<float>(solverConfiguration.minimumWetDepth))];
        [inputs addObject:scalarData(static_cast<float>(metadata.worldLimits.minimumBedElevation))];
        [inputs addObject:scalarData(static_cast<float>(metadata.worldLimits.maximumSurfaceElevation))];
        [inputs addObject:scalarData(static_cast<float>(metadata.geometry.dx()))];
        [inputs addObject:scalarData(static_cast<float>(metadata.geometry.dy()))];
        [inputs addObject:scalarData(static_cast<float>(solverConfiguration.debugVelocityBound))];
        appendBoundaryScalars(inputs);
        NSMutableArray<MPSGraphTensorData *> * const results = [NSMutableArray array];
        [results addObject:tensorData(depthBuffers[nextIndex], substep.cellShape)];
        [results addObject:tensorData(velXBuffers[nextIndex], substep.xShape)];
        [results addObject:tensorData(velYBuffers[nextIndex], substep.yShape)];
        [results addObject:tensorData(surfaceBuffer, substep.cellShape)];
        [results addObject:tensorData(fluxXBuffer, substep.xShape)];
        [results addObject:tensorData(fluxYBuffer, substep.yShape)];
        [results addObject:tensorData(outgoingScaleBuffer, substep.cellShape)];
        [results addObject:tensorData(boundaryRatesBuffer, @[@4])];
        for (id<MTLBuffer> buffer : diagnosticScalarBuffers) {
            [results addObject:tensorData(buffer, @[@1])];
        }
        [results addObject:tensorData(surfaceDeviationBuffer, substep.cellShape)];
        [results addObject:tensorData(velocityMagnitudeBuffer, substep.cellShape)];
        [results addObject:tensorData(wetMaskBuffer, substep.cellShape, MPSDataTypeUInt8)];
        @try {
            NSArray<MPSGraphTensorData *> * const actual = [substep.program.executable
                runWithMTLCommandQueue:queue
                inputsArray:orderedData(inputs, substep.program.inputPermutation)
                resultsArray:orderedData(results, substep.program.outputPermutation)
                executionDescriptor:nil];
            if (actual == nil) {
                os_signpost_interval_end(mpsPerformanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                         "SWESubstep");
                failureReason = "MPSGraph substep executable returned no results";
                return swe::StepStatus::nonFiniteState;
            }
        } @catch (NSException *exception) {
            os_signpost_interval_end(mpsPerformanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                     "SWESubstep");
            failureReason = std::string("MPSGraph substep exception: ") +
                exception.reason.UTF8String;
            return swe::StepStatus::nonFiniteState;
        }
        status.lastSubstepMilliseconds = millisecondsSince(start);
        os_signpost_interval_end(mpsPerformanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                 "SWESubstep");
        const auto scalar = [&](const std::size_t index) {
            return *static_cast<const float *>(diagnosticScalarBuffers[index].contents);
        };
        if (scalar(8) < 0.5F) {
            failureReason = "MPSGraph SWE diagnostics rejected the candidate state";
            return swe::StepStatus::nonFiniteState;
        }
        currentIndex = nextIndex;
        ++bufferGeneration;
        metadata.time += timeStep;
        const auto rates = std::span(static_cast<const float *>(boundaryRatesBuffer.contents),
                                     swe::boundaryEdgeCount);
        diagnostics.netBoundaryOutflowRate = 0.0;
        for (std::size_t edge = 0; edge < rates.size(); ++edge) {
            diagnostics.instantaneousBoundaryOutflowRate[edge] = rates[edge];
            metadata.cumulativeBoundaryVolume[edge] += timeStep * rates[edge];
            diagnostics.netBoundaryOutflowRate += rates[edge];
        }
        diagnostics.totalVolume = scalar(0);
        diagnostics.minimumDepth = scalar(1);
        diagnostics.maximumDepth = scalar(2);
        diagnostics.maximumAbsVelX = scalar(3);
        diagnostics.maximumAbsVelY = scalar(4);
        diagnostics.maximumWaveSpeed = std::sqrt(
            solverConfiguration.gravity * diagnostics.maximumDepth);
        diagnostics.correctionVolume += scalar(5);
        diagnostics.wetCellCount = static_cast<std::size_t>(scalar(6));
        diagnostics.correctionCount += static_cast<std::size_t>(scalar(7));
        diagnostics.finite = true;
        diagnostics.simulatedTime = metadata.time;
        diagnostics.cumulativeBoundaryOutwardVolume = metadata.cumulativeBoundaryVolume;
        updateAccounting();
        return swe::StepStatus::success;
    }

    [[nodiscard]] bool reset(std::string& failureReason) {
        if (!status.ready) { failureReason = "MPSGraph backend is not ready"; return false; }
        metadata.bedElevation = metadata.initialBedElevation;
        metadata.waterDepth = metadata.initialWaterDepth;
        metadata.velX.assign(metadata.velX.size(), 0.0);
        metadata.velY.assign(metadata.velY.size(), 0.0);
        metadata.time = 0.0;
        metadata.cumulativeBoundaryVolume.fill(0.0);
        metadata.accumulatedEditWaterVolume = 0.0;
        uploadState(metadata);
        initializeDerivedFields();
        initializeDiagnostics();
        return true;
    }

    [[nodiscard]] swe::StepStatus advance(const double frameDeltaTime,
                                           std::string& failureReason) {
        const auto frameStart = Clock::now();
        diagnostics.substepCount = 0;
        diagnostics.selectedTimeStep = 0.0;
        if (!std::isfinite(frameDeltaTime) || frameDeltaTime <= 0.0) {
            return diagnostics.status = swe::StepStatus::invalidTimeStep;
        }
        double remaining = frameDeltaTime;
        while (remaining > std::numeric_limits<double>::epsilon() * frameDeltaTime) {
            if (diagnostics.substepCount == solverConfiguration.maximumSubsteps) {
                return diagnostics.status = swe::StepStatus::substepLimitReached;
            }
            const double stable = stableTimeStep(failureReason);
            if (!(stable > 0.0)) {
                diagnostics.finite = false;
                return diagnostics.status = swe::StepStatus::nonFiniteState;
            }
            const double dt = std::min(remaining, stable);
            diagnostics.selectedTimeStep = diagnostics.substepCount == 0
                ? dt : std::min(diagnostics.selectedTimeStep, dt);
            const swe::StepStatus result = executeSubstep(dt, failureReason);
            if (result != swe::StepStatus::success) {
                return diagnostics.status = result;
            }
            remaining -= dt;
            ++diagnostics.substepCount;
        }
        status.substepCount = diagnostics.substepCount;
        status.lastFramePhysicsMilliseconds = millisecondsSince(frameStart);
        return diagnostics.status = swe::StepStatus::success;
    }

    [[nodiscard]] swe::StepStatus stepOnce(const double timeStep,
                                            std::string& failureReason) {
        diagnostics.substepCount = 0;
        if (!std::isfinite(timeStep) || timeStep <= 0.0) {
            return diagnostics.status = swe::StepStatus::invalidTimeStep;
        }
        const double stable = stableTimeStep(failureReason);
        if (!(stable > 0.0) || timeStep > stable * (1.0 + 1.0e-6)) {
            return diagnostics.status = swe::StepStatus::invalidTimeStep;
        }
        diagnostics.selectedTimeStep = timeStep;
        diagnostics.status = executeSubstep(timeStep, failureReason);
        diagnostics.substepCount = diagnostics.status == swe::StepStatus::success ? 1 : 0;
        status.substepCount = diagnostics.substepCount;
        return diagnostics.status;
    }

    [[nodiscard]] bool setConfiguration(
        const swe::SolverConfiguration configuration) noexcept {
        if (!configuration.isValid()) { return false; }
        solverConfiguration = configuration;
        initializeDerivedFields();
        return true;
    }

    [[nodiscard]] bool setBoundaries(const swe::BoundaryConfiguration boundaries,
                                     std::string& failureReason) {
        if (!boundaries.isValid(metadata.worldLimits.minimumBedElevation,
                                metadata.worldLimits.maximumSurfaceElevation)) {
            failureReason = "Invalid MPSGraph boundary configuration";
            return false;
        }
        const swe::BoundaryConfiguration oldBoundaries = metadata.boundaries;
        const auto oldTypes = boundaryTypes(oldBoundaries);
        const auto newTypes = boundaryTypes(boundaries);
        metadata.boundaries = boundaries;
        const auto clearRates = [this] {
            diagnostics.instantaneousBoundaryOutflowRate.fill(0.0);
            diagnostics.netBoundaryOutflowRate = 0.0;
        };
        if (oldTypes == newTypes) {
            clearRates();
            return true;
        }
        const auto compileStart = Clock::now();
        bool cacheHit = false;
        std::shared_ptr<CachedGraphPrograms> candidate;
        @try {
            candidate = cachedPrograms(metadata, metalDevice, graphDevice, cacheHit);
        } @catch (NSException *exception) {
            metadata.boundaries = oldBoundaries;
            failureReason = std::string("MPSGraph boundary graph compilation exception: ") +
                exception.reason.UTF8String;
            return false;
        }
        if (candidate == nullptr || !validPrograms(*candidate)) {
            metadata.boundaries = oldBoundaries;
            failureReason = "MPSGraph boundary graph compilation failed";
            return false;
        }
        cachedGraphPrograms = std::move(candidate);
        stableProgram = cachedGraphPrograms->stable;
        substep = cachedGraphPrograms->substep;
        status.graphCompileMilliseconds = cacheHit ? 0.0 : millisecondsSince(compileStart);
        clearRates();
        return true;
    }

    template <typename Command>
    [[nodiscard]] swe::TerrainEditResult applyMaterial(
        const Command& command, std::string& failureReason) {
        const BackendState synchronized = synchronize(failureReason);
        swe::SimulationState hostState;
        if (!synchronized.isValid() || !importState(synchronized, hostState)) {
            failureReason = "Could not synchronize MPSGraph state for editing";
            return {.status = swe::TerrainEditStatus::invalidCommand};
        }
        swe::TerrainEditor editor(hostState, solverConfiguration.minimumWetDepth);
        swe::TerrainEditResult result;
        if constexpr (std::is_same_v<Command, swe::BrushCommand>) {
            result = editor.applyBrush(command);
        } else {
            result = editor.applyPolygon(command);
        }
        if (!result.changed()) { return result; }
        metadata = exportState(hostState);
        uploadState(metadata);
        initializeDerivedFields();
        initializeDiagnostics();
        status.fallbackReason.clear();
        return result;
    }

    [[nodiscard]] BackendState synchronize(std::string& failureReason) const {
        if (!status.ready) { failureReason = "MPSGraph backend is not ready"; return {}; }
        BackendState result = metadata;
        const std::size_t cells = metadata.geometry.width * metadata.geometry.height;
        copyFromBuffer(bedBuffer, result.bedElevation, cells);
        copyFromBuffer(depthBuffers[currentIndex], result.waterDepth, cells);
        copyFromBuffer(velXBuffers[currentIndex], result.velX,
                       (metadata.geometry.width + 1) * metadata.geometry.height);
        copyFromBuffer(velYBuffers[currentIndex], result.velY,
                       metadata.geometry.width * (metadata.geometry.height + 1));
        return result;
    }

    [[nodiscard]] BackendSnapshot snapshot(std::string& failureReason) const {
        const auto start = Clock::now();
        if (!status.ready) { failureReason = "MPSGraph backend is not ready"; return {}; }
        os_signpost_interval_begin(mpsPerformanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                   "SnapshotReadback");
        snapshotStagingIndex = (snapshotStagingIndex + 1) % snapshotStaging.size();
        SnapshotStaging& staging = snapshotStaging[snapshotStagingIndex];
        const std::size_t cells = metadata.geometry.width * metadata.geometry.height;
        id<MTLCommandBuffer> const commandBuffer = [queue commandBuffer];
        commandBuffer.label = @"MPSGraph snapshot staging";
        id<MTLBlitCommandEncoder> const blit = [commandBuffer blitCommandEncoder];
        const NSUInteger floatBytes = cells * sizeof(float);
        const auto copy = [&](id<MTLBuffer> source, id<MTLBuffer> destination,
                              const NSUInteger bytes) {
            [blit copyFromBuffer:source sourceOffset:0 toBuffer:destination
               destinationOffset:0 size:bytes];
        };
        copy(bedBuffer, staging.bed, floatBytes);
        copy(depthBuffers[currentIndex], staging.depth, floatBytes);
        copy(surfaceBuffer, staging.surface, floatBytes);
        copy(surfaceDeviationBuffer, staging.deviation, floatBytes);
        copy(velocityMagnitudeBuffer, staging.velocity, floatBytes);
        copy(wetMaskBuffer, staging.wetMask, cells);
        [blit endEncoding];
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
            os_signpost_interval_end(mpsPerformanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                     "SnapshotReadback");
            failureReason = "MPSGraph snapshot staging command failed";
            return {};
        }
        BackendSnapshot result;
        result.width = metadata.geometry.width;
        result.height = metadata.geometry.height;
        result.domainWidth = metadata.geometry.domainWidth;
        result.domainHeight = metadata.geometry.domainHeight;
        const auto copyFloat = [cells](id<MTLBuffer> buffer, std::vector<float>& target) {
            target.resize(cells);
            std::memcpy(target.data(), buffer.contents, cells * sizeof(float));
        };
        copyFloat(staging.bed, result.bedElevation);
        copyFloat(staging.depth, result.waterDepth);
        copyFloat(staging.surface, result.surfaceElevation);
        copyFloat(staging.deviation, result.surfaceDeviation);
        copyFloat(staging.velocity, result.velocityMagnitude);
        result.wetMask.resize(cells);
        std::memcpy(result.wetMask.data(), staging.wetMask.contents, cells);
        result.diagnostics = diagnostics;
        status.lastReadbackMilliseconds = millisecondsSince(start);
        os_signpost_interval_end(mpsPerformanceLog, OS_SIGNPOST_ID_EXCLUSIVE,
                                 "SnapshotReadback");
        return result;
    }

    [[nodiscard]] AcceleratedFieldBufferSnapshot fieldBuffers() const noexcept {
        if (!status.ready) { return {}; }
        return {
            .device = (__bridge void *)metalDevice,
            .bedElevation = (__bridge void *)bedBuffer,
            .waterDepth = (__bridge void *)depthBuffers[currentIndex],
            .width = metadata.geometry.width,
            .height = metadata.geometry.height,
            .generation = bufferGeneration,
        };
    }
    id<MTLDevice> metalDevice;
    id<MTLCommandQueue> queue;
    MPSGraphDevice *graphDevice;
    GraphProgram stableProgram;
    SubstepTensors substep;
    std::shared_ptr<CachedGraphPrograms> cachedGraphPrograms;
    id<MTLBuffer> bedBuffer;
    id<MTLBuffer> referenceSurfaceBuffer;
    std::array<id<MTLBuffer>, 2> depthBuffers{};
    std::array<id<MTLBuffer>, 2> velXBuffers{};
    std::array<id<MTLBuffer>, 2> velYBuffers{};
    id<MTLBuffer> surfaceBuffer;
    id<MTLBuffer> fluxXBuffer;
    id<MTLBuffer> fluxYBuffer;
    id<MTLBuffer> outgoingScaleBuffer;
    id<MTLBuffer> boundaryRatesBuffer;
    id<MTLBuffer> surfaceDeviationBuffer;
    id<MTLBuffer> velocityMagnitudeBuffer;
    id<MTLBuffer> wetMaskBuffer;
    mutable std::array<SnapshotStaging, 3> snapshotStaging{};
    std::array<id<MTLBuffer>, 5> stableScalarBuffers{};
    std::array<id<MTLBuffer>, 9> diagnosticScalarBuffers{};
    BackendState metadata;
    swe::SolverConfiguration solverConfiguration;
    std::size_t currentIndex = 0;
    mutable std::size_t snapshotStagingIndex = 0;
    std::uint64_t bufferGeneration = 0;
    std::size_t stateSizedAllocationCount = 0;
    swe::Diagnostics diagnostics;
    mutable BackendStatus status{
        .requested = RequestedSimulationBackend::automaticAccelerated,
        .resolved = ResolvedSimulationBackend::mpsGraphAutomatic,
        .ready = false,
        .statePrecision = "Float32",
    };
};

MPSGraphAutomaticBackend::MPSGraphAutomaticBackend()
    : implementation_(std::make_unique<Implementation>()) {}
MPSGraphAutomaticBackend::~MPSGraphAutomaticBackend() = default;
MPSGraphAutomaticBackend::MPSGraphAutomaticBackend(MPSGraphAutomaticBackend&&) noexcept = default;
MPSGraphAutomaticBackend& MPSGraphAutomaticBackend::operator=(
    MPSGraphAutomaticBackend&&) noexcept = default;

bool MPSGraphAutomaticBackend::load(const BackendState& state,
                                    const swe::SolverConfiguration configuration,
                                    std::string& failureReason) {
    return implementation_->load(state, configuration, failureReason);
}

bool MPSGraphAutomaticBackend::reset(std::string& failureReason) noexcept {
    return implementation_->reset(failureReason);
}

swe::StepStatus MPSGraphAutomaticBackend::advance(const double frameDeltaTime,
                                                   std::string& failureReason) noexcept {
    return implementation_->advance(frameDeltaTime, failureReason);
}

swe::StepStatus MPSGraphAutomaticBackend::stepOnce(const double timeStep,
                                                    std::string& failureReason) noexcept {
    return implementation_->stepOnce(timeStep, failureReason);
}

bool MPSGraphAutomaticBackend::setConfiguration(
    const swe::SolverConfiguration configuration) noexcept {
    return implementation_->setConfiguration(configuration);
}

bool MPSGraphAutomaticBackend::setBoundaryConfiguration(
                                                        const swe::BoundaryConfiguration boundaries,
                                                        std::string& failureReason) noexcept {
    return implementation_->setBoundaries(boundaries, failureReason);
}

swe::TerrainEditResult MPSGraphAutomaticBackend::applyMaterialBrush(
    const swe::BrushCommand& command, std::string& failureReason) {
    return implementation_->applyMaterial(command, failureReason);
}

swe::TerrainEditResult MPSGraphAutomaticBackend::applyMaterialPolygon(
    const swe::PolygonCommand& command, std::string& failureReason) {
    return implementation_->applyMaterial(command, failureReason);
}

BackendState MPSGraphAutomaticBackend::synchronizeToHost(std::string& failureReason) const {
    return implementation_->synchronize(failureReason);
}

BackendSnapshot MPSGraphAutomaticBackend::makeSnapshot(std::string& failureReason) const {
    return implementation_->snapshot(failureReason);
}

const swe::Diagnostics& MPSGraphAutomaticBackend::diagnostics() const noexcept {
    return implementation_->diagnostics;
}

const BackendStatus& MPSGraphAutomaticBackend::status() const noexcept {
    return implementation_->status;
}

std::size_t MPSGraphAutomaticBackend::stateSizedAllocationCount() const noexcept {
    return implementation_->stateSizedAllocationCount;
}

AcceleratedFieldBufferSnapshot MPSGraphAutomaticBackend::fieldBufferSnapshot() const noexcept {
    return implementation_->fieldBuffers();
}

} // namespace tide::accelerated
