#include <metal_stdlib>
using namespace metal;

constant uint boundaryReflective = 0;
constant uint boundaryDrivenHeight = 2;

struct BoundaryParameters {
    uint type;
    float meanSurfaceElevation;
    float amplitude;
    float periodSeconds;
    float phaseRadians;
    float rampSeconds;
};

struct SolverParameters {
    uint width;
    uint height;
    float dx;
    float dy;
    float gravity;
    float damping;
    float minimumWetDepth;
    float dt;
    float time;
    float minimumBed;
    float maximumSurface;
    float cfl;
    float debugVelocityBound;
    BoundaryParameters boundaries[4];
};

struct StableTimeStepResult {
    float maximumDepth;
    float maximumAbsVelX;
    float maximumAbsVelY;
    float stableDt;
    uint finite;
};

struct StablePartial {
    float maximumDepth;
    float maximumAbsVelX;
    float maximumAbsVelY;
    uint finite;
};

struct DiagnosticResult {
    float totalVolume;
    float minimumDepth;
    float maximumDepth;
    float maximumAbsVelX;
    float maximumAbsVelY;
    float maximumWaveSpeed;
    float correctionVolume;
    uint wetCellCount;
    uint correctionCount;
    uint finite;
};

struct DiagnosticPartial {
    float depthSum;
    float minimumDepth;
    float maximumDepth;
    float maximumAbsVelX;
    float maximumAbsVelY;
    float correctionVolume;
    uint wetCellCount;
    uint correctionCount;
    uint finite;
};

inline float drivenSurface(const BoundaryParameters boundary, const float time) {
    const float progress = boundary.rampSeconds > 0.0f
        ? clamp(time / boundary.rampSeconds, 0.0f, 1.0f) : 1.0f;
    const float ramp = progress * progress * (3.0f - 2.0f * progress);
    constexpr float twoPi = 6.28318530717958647692f;
    return boundary.meanSurfaceElevation + boundary.amplitude * ramp *
        sin(twoPi * time / boundary.periodSeconds + boundary.phaseRadians);
}

inline float4 reconstructFace(const float firstBed, const float firstSurface,
                              const float secondBed, const float secondSurface,
                              const float minimumWetDepth) {
    const float faceBed = max(firstBed, secondBed);
    float firstDepth = max(firstSurface - faceBed, 0.0f);
    float secondDepth = max(secondSurface - faceBed, 0.0f);
    firstDepth = firstDepth <= minimumWetDepth ? 0.0f : firstDepth;
    secondDepth = secondDepth <= minimumWetDepth ? 0.0f : secondDepth;
    return float4(firstDepth, secondDepth, faceBed + firstDepth, faceBed + secondDepth);
}

inline float4 reconstructBoundary(const BoundaryParameters boundary,
                                  const float interiorBed,
                                  const float interiorSurface,
                                  const float time,
                                  const float minimumWetDepth) {
    if (boundary.type == boundaryReflective) {
        return float4(0.0f);
    }
    const float reservoirSurface = boundary.type == boundaryDrivenHeight
        ? drivenSurface(boundary, time) : interiorSurface;
    return reconstructFace(interiorBed, interiorSurface, interiorBed, reservoirSurface,
                           minimumWetDepth);
}

inline float updatedBoundaryVelocity(const BoundaryParameters boundary,
                                     const float oldOutwardVelocity,
                                     const float bed,
                                     const float surface,
                                     const float time,
                                     const float velocityFactor,
                                     const float minimumWetDepth) {
    const float4 hydro = reconstructBoundary(boundary, bed, surface, time,
                                             minimumWetDepth);
    if (boundary.type == boundaryReflective || (hydro.x == 0.0f && hydro.y == 0.0f)) {
        return 0.0f;
    }
    return oldOutwardVelocity - velocityFactor * (hydro.w - hydro.z);
}

inline float boundaryFlux(const BoundaryParameters boundary,
                          const float outwardVelocity,
                          const float bed,
                          const float surface,
                          const float time,
                          const float minimumWetDepth) {
    const float4 hydro = reconstructBoundary(boundary, bed, surface, time,
                                             minimumWetDepth);
    return outwardVelocity * (outwardVelocity >= 0.0f ? hydro.x : hydro.y);
}

kernel void sweComputeSurface(const device float *bed [[buffer(0)]],
                              const device float *depth [[buffer(1)]],
                              device float *surface [[buffer(2)]],
                              constant SolverParameters& parameters [[buffer(3)]],
                              uint gid [[thread_position_in_grid]]) {
    const uint count = parameters.width * parameters.height;
    if (gid < count) {
        surface[gid] = bed[gid] + depth[gid];
    }
}

kernel void sweStableTimeStepPartials(const device float *bed [[buffer(0)]],
                                      const device float *depth [[buffer(1)]],
                                      const device float *velX [[buffer(2)]],
                                      const device float *velY [[buffer(3)]],
                                      device StablePartial *partials [[buffer(4)]],
                                      constant SolverParameters& p [[buffer(5)]],
                                      uint gid [[thread_position_in_grid]],
                                      uint tid [[thread_index_in_threadgroup]],
                                      uint group [[threadgroup_position_in_grid]],
                                      uint threadgroupWidth [[threads_per_threadgroup]]) {
    const uint cells = p.width * p.height;
    const uint xFaces = (p.width + 1) * p.height;
    const uint yFaces = p.width * (p.height + 1);
    float maximumDepth = 0.0f;
    float maximumX = 0.0f;
    float maximumY = 0.0f;
    bool finite = true;
    if (gid < cells) {
        const float value = depth[gid];
        finite = finite && isfinite(value) && value >= 0.0f;
        maximumDepth = max(maximumDepth, value);
    }
    if (gid < xFaces) {
        const float value = abs(velX[gid]);
        finite = finite && isfinite(value);
        maximumX = max(maximumX, value);
    }
    if (gid < yFaces) {
        const float value = abs(velY[gid]);
        finite = finite && isfinite(value);
        maximumY = max(maximumY, value);
    }
    for (uint edge = 0; edge < 4; ++edge) {
        const BoundaryParameters boundary = p.boundaries[edge];
        if (boundary.type != boundaryDrivenHeight) { continue; }
        const float reservoirSurface = drivenSurface(boundary, p.time);
        finite = finite && isfinite(reservoirSurface);
        const uint count = edge < 2 ? p.height : p.width;
        if (gid < count) {
            const uint column = edge == 0 ? 0 : (edge == 1 ? p.width - 1 : gid);
            const uint row = edge == 2 ? 0 : (edge == 3 ? p.height - 1 : gid);
            maximumDepth = max(maximumDepth,
                               max(reservoirSurface - bed[row * p.width + column], 0.0f));
        }
    }

    threadgroup StablePartial shared[256];
    shared[tid] = {maximumDepth, maximumX, maximumY, finite ? 1u : 0u};
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint offset = threadgroupWidth >> 1; offset > 0; offset >>= 1) {
        if (tid < offset) {
            shared[tid].maximumDepth = max(shared[tid].maximumDepth,
                                           shared[tid + offset].maximumDepth);
            shared[tid].maximumAbsVelX = max(shared[tid].maximumAbsVelX,
                                             shared[tid + offset].maximumAbsVelX);
            shared[tid].maximumAbsVelY = max(shared[tid].maximumAbsVelY,
                                             shared[tid + offset].maximumAbsVelY);
            shared[tid].finite &= shared[tid + offset].finite;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0) { partials[group] = shared[0]; }
}

kernel void sweFinalizeStableTimeStep(const device StablePartial *partials [[buffer(0)]],
                                      device StableTimeStepResult *result [[buffer(1)]],
                                      constant SolverParameters& p [[buffer(2)]],
                                      constant uint& partialCount [[buffer(3)]],
                                      uint gid [[thread_position_in_grid]]) {
    if (gid != 0) { return; }
    StablePartial combined{0.0f, 0.0f, 0.0f, 1u};
    for (uint index = 0; index < partialCount; ++index) {
        const StablePartial value = partials[index];
        combined.maximumDepth = max(combined.maximumDepth, value.maximumDepth);
        combined.maximumAbsVelX = max(combined.maximumAbsVelX, value.maximumAbsVelX);
        combined.maximumAbsVelY = max(combined.maximumAbsVelY, value.maximumAbsVelY);
        combined.finite &= value.finite;
    }
    if (p.debugVelocityBound > 0.0f &&
        max(combined.maximumAbsVelX, combined.maximumAbsVelY) > p.debugVelocityBound) {
        combined.finite = 0;
    }
    const float waveSpeed = sqrt(p.gravity * combined.maximumDepth);
    const float inverseScale = (combined.maximumAbsVelX + waveSpeed) / p.dx +
                               (combined.maximumAbsVelY + waveSpeed) / p.dy;
    const float stable = inverseScale == 0.0f
        ? numeric_limits<float>::max() : 0.95f * p.cfl / inverseScale;
    result[0] = {combined.maximumDepth, combined.maximumAbsVelX,
                 combined.maximumAbsVelY, stable,
                 combined.finite != 0 && isfinite(stable) && stable > 0.0f ? 1u : 0u};
}

kernel void sweUpdateVelocityX(const device float *bed [[buffer(0)]],
                               const device float *depth [[buffer(1)]],
                               const device float *currentVelocity [[buffer(2)]],
                               device float *nextVelocity [[buffer(3)]],
                               constant SolverParameters& p [[buffer(4)]],
                               uint gid [[thread_position_in_grid]]) {
    const uint stride = p.width + 1;
    const uint count = stride * p.height;
    if (gid >= count) { return; }
    const uint row = gid / stride;
    const uint face = gid - row * stride;
    const float factor = p.gravity * p.dt / p.dx;
    float updatedVelocity = 0.0f;
    if (face == 0) {
        const uint cell = row * p.width;
        const float outward = updatedBoundaryVelocity(p.boundaries[0], -currentVelocity[gid],
            bed[cell], bed[cell] + depth[cell], p.time, factor, p.minimumWetDepth);
        updatedVelocity = -outward;
    } else if (face == p.width) {
        const uint cell = row * p.width + p.width - 1;
        updatedVelocity = updatedBoundaryVelocity(p.boundaries[1], currentVelocity[gid],
            bed[cell], bed[cell] + depth[cell], p.time, factor, p.minimumWetDepth);
    } else {
        const uint first = row * p.width + face - 1;
        const uint second = first + 1;
        const float4 hydro = reconstructFace(bed[first], bed[first] + depth[first], bed[second],
                                             bed[second] + depth[second], p.minimumWetDepth);
        updatedVelocity = hydro.x == 0.0f && hydro.y == 0.0f ? 0.0f :
            currentVelocity[gid] - factor * (hydro.w - hydro.z);
    }
    // Damping immediately follows the pressure/boundary update in the CPU oracle. Fusing the
    // element-wise multiply here preserves that dependency and removes a full face dispatch.
    nextVelocity[gid] = updatedVelocity * exp(-p.damping * p.dt);
}

kernel void sweUpdateVelocityY(const device float *bed [[buffer(0)]],
                               const device float *depth [[buffer(1)]],
                               const device float *currentVelocity [[buffer(2)]],
                               device float *nextVelocity [[buffer(3)]],
                               constant SolverParameters& p [[buffer(4)]],
                               uint gid [[thread_position_in_grid]]) {
    const uint count = p.width * (p.height + 1);
    if (gid >= count) { return; }
    const uint row = gid / p.width;
    const uint column = gid - row * p.width;
    const float factor = p.gravity * p.dt / p.dy;
    float updatedVelocity = 0.0f;
    if (row == 0) {
        const uint cell = column;
        const float outward = updatedBoundaryVelocity(p.boundaries[2], -currentVelocity[gid],
            bed[cell], bed[cell] + depth[cell], p.time, factor, p.minimumWetDepth);
        updatedVelocity = -outward;
    } else if (row == p.height) {
        const uint cell = (p.height - 1) * p.width + column;
        updatedVelocity = updatedBoundaryVelocity(p.boundaries[3], currentVelocity[gid],
            bed[cell], bed[cell] + depth[cell], p.time, factor, p.minimumWetDepth);
    } else {
        const uint first = (row - 1) * p.width + column;
        const uint second = row * p.width + column;
        const float4 hydro = reconstructFace(bed[first], bed[first] + depth[first], bed[second],
                                             bed[second] + depth[second], p.minimumWetDepth);
        updatedVelocity = hydro.x == 0.0f && hydro.y == 0.0f ? 0.0f :
            currentVelocity[gid] - factor * (hydro.w - hydro.z);
    }
    nextVelocity[gid] = updatedVelocity * exp(-p.damping * p.dt);
}

kernel void sweApplyDampingX(device float *velocity [[buffer(0)]],
                             constant SolverParameters& p [[buffer(1)]],
                             uint gid [[thread_position_in_grid]]) {
    const uint stride = p.width + 1;
    if (gid >= stride * p.height) { return; }
    const uint face = gid % stride;
    if ((face == 0 && p.boundaries[0].type == boundaryReflective) ||
        (face == p.width && p.boundaries[1].type == boundaryReflective)) {
        velocity[gid] = 0.0f;
    } else {
        velocity[gid] *= exp(-p.damping * p.dt);
    }
}

kernel void sweApplyDampingY(device float *velocity [[buffer(0)]],
                             constant SolverParameters& p [[buffer(1)]],
                             uint gid [[thread_position_in_grid]]) {
    const uint count = p.width * (p.height + 1);
    if (gid >= count) { return; }
    const uint row = gid / p.width;
    if ((row == 0 && p.boundaries[2].type == boundaryReflective) ||
        (row == p.height && p.boundaries[3].type == boundaryReflective)) {
        velocity[gid] = 0.0f;
    } else {
        velocity[gid] *= exp(-p.damping * p.dt);
    }
}

kernel void sweComputeFluxX(const device float *bed [[buffer(0)]],
                            const device float *depth [[buffer(1)]],
                            const device float *velocity [[buffer(2)]],
                            device float *flux [[buffer(3)]],
                            constant SolverParameters& p [[buffer(4)]],
                            uint gid [[thread_position_in_grid]]) {
    const uint stride = p.width + 1;
    if (gid >= stride * p.height) { return; }
    const uint row = gid / stride;
    const uint face = gid - row * stride;
    if (face == 0) {
        const uint cell = row * p.width;
        flux[gid] = -boundaryFlux(p.boundaries[0], -velocity[gid], bed[cell],
                                  bed[cell] + depth[cell], p.time, p.minimumWetDepth);
    } else if (face == p.width) {
        const uint cell = row * p.width + p.width - 1;
        flux[gid] = boundaryFlux(p.boundaries[1], velocity[gid], bed[cell],
                                 bed[cell] + depth[cell], p.time, p.minimumWetDepth);
    } else {
        const uint first = row * p.width + face - 1;
        const uint second = first + 1;
        const float4 hydro = reconstructFace(bed[first], bed[first] + depth[first], bed[second],
                                             bed[second] + depth[second], p.minimumWetDepth);
        flux[gid] = velocity[gid] * (velocity[gid] >= 0.0f ? hydro.x : hydro.y);
    }
}

kernel void sweComputeFluxY(const device float *bed [[buffer(0)]],
                            const device float *depth [[buffer(1)]],
                            const device float *velocity [[buffer(2)]],
                            device float *flux [[buffer(3)]],
                            constant SolverParameters& p [[buffer(4)]],
                            uint gid [[thread_position_in_grid]]) {
    const uint count = p.width * (p.height + 1);
    if (gid >= count) { return; }
    const uint row = gid / p.width;
    const uint column = gid - row * p.width;
    if (row == 0) {
        const uint cell = column;
        flux[gid] = -boundaryFlux(p.boundaries[2], -velocity[gid], bed[cell],
                                  bed[cell] + depth[cell], p.time, p.minimumWetDepth);
    } else if (row == p.height) {
        const uint cell = (p.height - 1) * p.width + column;
        flux[gid] = boundaryFlux(p.boundaries[3], velocity[gid], bed[cell],
                                 bed[cell] + depth[cell], p.time, p.minimumWetDepth);
    } else {
        const uint first = (row - 1) * p.width + column;
        const uint second = row * p.width + column;
        const float4 hydro = reconstructFace(bed[first], bed[first] + depth[first], bed[second],
                                             bed[second] + depth[second], p.minimumWetDepth);
        flux[gid] = velocity[gid] * (velocity[gid] >= 0.0f ? hydro.x : hydro.y);
    }
}

kernel void sweComputeOutgoingScale(const device float *depth [[buffer(0)]],
                                    const device float *fluxX [[buffer(1)]],
                                    const device float *fluxY [[buffer(2)]],
                                    device float *scale [[buffer(3)]],
                                    constant SolverParameters& p [[buffer(4)]],
                                    uint gid [[thread_position_in_grid]]) {
    const uint cells = p.width * p.height;
    if (gid >= cells) { return; }
    const uint row = gid / p.width;
    const uint column = gid - row * p.width;
    const uint xStride = p.width + 1;
    const float outgoing = p.dt / p.dx *
        (max(fluxX[row * xStride + column + 1], 0.0f) +
         max(-fluxX[row * xStride + column], 0.0f)) + p.dt / p.dy *
        (max(fluxY[(row + 1) * p.width + column], 0.0f) +
         max(-fluxY[row * p.width + column], 0.0f));
    scale[gid] = outgoing > depth[gid] && outgoing > 0.0f ? depth[gid] / outgoing : 1.0f;
}

kernel void sweLimitFluxX(device float *flux [[buffer(0)]],
                          const device float *scale [[buffer(1)]],
                          constant SolverParameters& p [[buffer(2)]],
                          uint gid [[thread_position_in_grid]]) {
    const uint stride = p.width + 1;
    if (gid >= stride * p.height) { return; }
    const uint row = gid / stride;
    const uint face = gid - row * stride;
    const float value = flux[gid];
    if (face == 0) {
        flux[gid] = value < 0.0f ? value * scale[row * p.width] : value;
    } else if (face == p.width) {
        flux[gid] = value > 0.0f ? value * scale[row * p.width + p.width - 1] : value;
    } else {
        flux[gid] = value * (value >= 0.0f ? scale[row * p.width + face - 1]
                                          : scale[row * p.width + face]);
    }
}

kernel void sweLimitFluxY(device float *flux [[buffer(0)]],
                          const device float *scale [[buffer(1)]],
                          constant SolverParameters& p [[buffer(2)]],
                          uint gid [[thread_position_in_grid]]) {
    const uint count = p.width * (p.height + 1);
    if (gid >= count) { return; }
    const uint row = gid / p.width;
    const uint column = gid - row * p.width;
    const float value = flux[gid];
    if (row == 0) {
        flux[gid] = value < 0.0f ? value * scale[column] : value;
    } else if (row == p.height) {
        flux[gid] = value > 0.0f ? value * scale[(p.height - 1) * p.width + column] : value;
    } else {
        flux[gid] = value * (value >= 0.0f ? scale[(row - 1) * p.width + column]
                                          : scale[row * p.width + column]);
    }
}

kernel void sweUpdateDepth(const device float *currentDepth [[buffer(0)]],
                           const device float *fluxX [[buffer(1)]],
                           const device float *fluxY [[buffer(2)]],
                           device float *nextDepth [[buffer(3)]],
                           device float *correction [[buffer(4)]],
                           constant SolverParameters& p [[buffer(5)]],
                           uint gid [[thread_position_in_grid]]) {
    if (gid >= p.width * p.height) { return; }
    const uint row = gid / p.width;
    const uint column = gid - row * p.width;
    const uint xStride = p.width + 1;
    const float evolvedDepth = currentDepth[gid] - p.dt / p.dx *
        (fluxX[row * xStride + column + 1] - fluxX[row * xStride + column]) - p.dt / p.dy *
        (fluxY[(row + 1) * p.width + column] - fluxY[row * p.width + column]);
    if (evolvedDepth <= p.minimumWetDepth) {
        correction[gid] = abs(evolvedDepth) * p.dx * p.dy;
        nextDepth[gid] = 0.0f;
    } else {
        correction[gid] = 0.0f;
        nextDepth[gid] = evolvedDepth;
    }
}

kernel void sweCleanupDepth(device float *depth [[buffer(0)]],
                            device float *correction [[buffer(1)]],
                            constant SolverParameters& p [[buffer(2)]],
                            uint gid [[thread_position_in_grid]]) {
    if (gid >= p.width * p.height) { return; }
    if (depth[gid] <= p.minimumWetDepth) {
        correction[gid] = abs(depth[gid]) * p.dx * p.dy;
        depth[gid] = 0.0f;
    } else {
        correction[gid] = 0.0f;
    }
}

inline float cleanedDryVelocityX(const device float *bed,
                                 const device float *depth,
                                 const float velocity,
                                 constant SolverParameters& p,
                                 const uint gid) {
    const uint stride = p.width + 1;
    const uint row = gid / stride;
    const uint face = gid - row * stride;
    const float time = p.time + p.dt;
    float donorDepth = 0.0f;
    if (face == 0 || face == p.width) {
        const uint edge = face == 0 ? 0 : 1;
        const uint cell = row * p.width + (face == 0 ? 0 : p.width - 1);
        const float outward = face == 0 ? -velocity : velocity;
        const float surface = bed[cell] + depth[cell];
        const float4 hydro = reconstructBoundary(p.boundaries[edge], bed[cell], surface,
                                                 time, p.minimumWetDepth);
        donorDepth = outward >= 0.0f ? hydro.x : hydro.y;
    } else {
        const uint first = row * p.width + face - 1;
        const uint second = first + 1;
        const float4 hydro = reconstructFace(bed[first], bed[first] + depth[first],
                                             bed[second], bed[second] + depth[second],
                                             p.minimumWetDepth);
        donorDepth = velocity >= 0.0f ? hydro.x : hydro.y;
    }
    return donorDepth == 0.0f ? 0.0f : velocity;
}

inline float cleanedDryVelocityY(const device float *bed,
                                 const device float *depth,
                                 const float velocity,
                                 constant SolverParameters& p,
                                 const uint gid) {
    const uint row = gid / p.width;
    const uint column = gid - row * p.width;
    const float time = p.time + p.dt;
    float donorDepth = 0.0f;
    if (row == 0 || row == p.height) {
        const uint edge = row == 0 ? 2 : 3;
        const uint cell = (row == 0 ? 0 : p.height - 1) * p.width + column;
        const float outward = row == 0 ? -velocity : velocity;
        const float surface = bed[cell] + depth[cell];
        const float4 hydro = reconstructBoundary(p.boundaries[edge], bed[cell], surface,
                                                 time, p.minimumWetDepth);
        donorDepth = outward >= 0.0f ? hydro.x : hydro.y;
    } else {
        const uint first = (row - 1) * p.width + column;
        const uint second = row * p.width + column;
        const float4 hydro = reconstructFace(bed[first], bed[first] + depth[first],
                                             bed[second], bed[second] + depth[second],
                                             p.minimumWetDepth);
        donorDepth = velocity >= 0.0f ? hydro.x : hydro.y;
    }
    return donorDepth == 0.0f ? 0.0f : velocity;
}

kernel void sweCleanupDryVelocityX(const device float *bed [[buffer(0)]],
                                   const device float *depth [[buffer(1)]],
                                   device float *velocity [[buffer(2)]],
                                   constant SolverParameters& p [[buffer(3)]],
                                   uint gid [[thread_position_in_grid]]) {
    if (gid >= (p.width + 1) * p.height) { return; }
    velocity[gid] = cleanedDryVelocityX(bed, depth, velocity[gid], p, gid);
}

kernel void sweCleanupDryVelocityY(const device float *bed [[buffer(0)]],
                                   const device float *depth [[buffer(1)]],
                                   device float *velocity [[buffer(2)]],
                                   constant SolverParameters& p [[buffer(3)]],
                                   uint gid [[thread_position_in_grid]]) {
    if (gid >= p.width * (p.height + 1)) { return; }
    velocity[gid] = cleanedDryVelocityY(bed, depth, velocity[gid], p, gid);
}

kernel void sweReduceBoundaryRatePartials(const device float *fluxX [[buffer(0)]],
                                          const device float *fluxY [[buffer(1)]],
                                          device float4 *partials [[buffer(2)]],
                                          constant SolverParameters& p [[buffer(3)]],
                                          uint gid [[thread_position_in_grid]],
                                          uint tid [[thread_index_in_threadgroup]],
                                          uint group [[threadgroup_position_in_grid]],
                                          uint threadgroupWidth [[threads_per_threadgroup]]) {
    float4 value = float4(0.0f);
    const uint xStride = p.width + 1;
    if (gid < p.height) {
        value.x = -p.dy * fluxX[gid * xStride];
        value.y = p.dy * fluxX[gid * xStride + p.width];
    }
    if (gid < p.width) {
        value.z = -p.dx * fluxY[gid];
        value.w = p.dx * fluxY[p.height * p.width + gid];
    }
    threadgroup float4 shared[256];
    shared[tid] = value;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint offset = threadgroupWidth >> 1; offset > 0; offset >>= 1) {
        if (tid < offset) { shared[tid] += shared[tid + offset]; }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0) { partials[group] = shared[0]; }
}

kernel void sweFinalizeBoundaryRates(const device float4 *partials [[buffer(0)]],
                                     device float *rates [[buffer(1)]],
                                     constant uint& partialCount [[buffer(2)]],
                                     uint gid [[thread_position_in_grid]]) {
    if (gid != 0) { return; }
    float4 result = float4(0.0f);
    for (uint index = 0; index < partialCount; ++index) { result += partials[index]; }
    rates[0] = result.x;
    rates[1] = result.y;
    rates[2] = result.z;
    rates[3] = result.w;
}

kernel void sweReduceDiagnosticPartials(const device float *bed [[buffer(0)]],
                                        const device float *depth [[buffer(1)]],
                                        device float *velX [[buffer(2)]],
                                        device float *velY [[buffer(3)]],
                                        const device float *correction [[buffer(4)]],
                                        device DiagnosticPartial *partials [[buffer(5)]],
                                        constant SolverParameters& p [[buffer(6)]],
                                        uint gid [[thread_position_in_grid]],
                                        uint tid [[thread_index_in_threadgroup]],
                                        uint group [[threadgroup_position_in_grid]],
                                        uint threadgroupWidth [[threads_per_threadgroup]]) {
    const uint cells = p.width * p.height;
    const uint xFaces = (p.width + 1) * p.height;
    const uint yFaces = p.width * (p.height + 1);
    DiagnosticPartial value{0.0f, numeric_limits<float>::max(), 0.0f,
                            0.0f, 0.0f, 0.0f, 0u, 0u, 1u};
    if (gid < cells) {
        const float b = bed[gid];
        const float h = depth[gid];
        value.finite = isfinite(b) && isfinite(h) && b >= p.minimumBed && h >= 0.0f &&
                       b + h <= p.maximumSurface ? 1u : 0u;
        value.depthSum = h;
        value.minimumDepth = h;
        value.maximumDepth = h;
        value.wetCellCount = h > p.minimumWetDepth ? 1u : 0u;
        value.correctionVolume = correction[gid];
        value.correctionCount = correction[gid] > 0.0f ? 1u : 0u;
    }
    if (gid < xFaces) {
        const float velocity = cleanedDryVelocityX(bed, depth, velX[gid], p, gid);
        velX[gid] = velocity;
        value.finite &= isfinite(velocity) ? 1u : 0u;
        value.maximumAbsVelX = abs(velocity);
    }
    if (gid < yFaces) {
        const float velocity = cleanedDryVelocityY(bed, depth, velY[gid], p, gid);
        velY[gid] = velocity;
        value.finite &= isfinite(velocity) ? 1u : 0u;
        value.maximumAbsVelY = abs(velocity);
    }

    threadgroup DiagnosticPartial shared[256];
    shared[tid] = value;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint offset = threadgroupWidth >> 1; offset > 0; offset >>= 1) {
        if (tid < offset) {
            shared[tid].depthSum += shared[tid + offset].depthSum;
            shared[tid].minimumDepth = min(shared[tid].minimumDepth,
                                           shared[tid + offset].minimumDepth);
            shared[tid].maximumDepth = max(shared[tid].maximumDepth,
                                           shared[tid + offset].maximumDepth);
            shared[tid].maximumAbsVelX = max(shared[tid].maximumAbsVelX,
                                             shared[tid + offset].maximumAbsVelX);
            shared[tid].maximumAbsVelY = max(shared[tid].maximumAbsVelY,
                                             shared[tid + offset].maximumAbsVelY);
            shared[tid].correctionVolume += shared[tid + offset].correctionVolume;
            shared[tid].wetCellCount += shared[tid + offset].wetCellCount;
            shared[tid].correctionCount += shared[tid + offset].correctionCount;
            shared[tid].finite &= shared[tid + offset].finite;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0) { partials[group] = shared[0]; }
}

kernel void sweFinalizeDiagnostics(const device DiagnosticPartial *partials [[buffer(0)]],
                                   device DiagnosticResult *result [[buffer(1)]],
                                   constant SolverParameters& p [[buffer(2)]],
                                   constant uint& partialCount [[buffer(3)]],
                                   uint gid [[thread_position_in_grid]]) {
    if (gid != 0) { return; }
    DiagnosticPartial combined{0.0f, numeric_limits<float>::max(), 0.0f,
                               0.0f, 0.0f, 0.0f, 0u, 0u, 1u};
    for (uint index = 0; index < partialCount; ++index) {
        const DiagnosticPartial value = partials[index];
        combined.depthSum += value.depthSum;
        combined.minimumDepth = min(combined.minimumDepth, value.minimumDepth);
        combined.maximumDepth = max(combined.maximumDepth, value.maximumDepth);
        combined.maximumAbsVelX = max(combined.maximumAbsVelX, value.maximumAbsVelX);
        combined.maximumAbsVelY = max(combined.maximumAbsVelY, value.maximumAbsVelY);
        combined.correctionVolume += value.correctionVolume;
        combined.wetCellCount += value.wetCellCount;
        combined.correctionCount += value.correctionCount;
        combined.finite &= value.finite;
    }
    if (p.debugVelocityBound > 0.0f &&
        max(combined.maximumAbsVelX, combined.maximumAbsVelY) > p.debugVelocityBound) {
        combined.finite = 0;
    }
    result[0] = {combined.depthSum * p.dx * p.dy, combined.minimumDepth,
                 combined.maximumDepth, combined.maximumAbsVelX,
                 combined.maximumAbsVelY, sqrt(p.gravity * combined.maximumDepth),
                 combined.correctionVolume, combined.wetCellCount,
                 combined.correctionCount, combined.finite};
}

kernel void sweMakeDerivedSnapshot(const device float *bed [[buffer(0)]],
                                   const device float *depth [[buffer(1)]],
                                   const device float *velX [[buffer(2)]],
                                   const device float *velY [[buffer(3)]],
                                   const device float *referenceSurface [[buffer(4)]],
                                   device float *surface [[buffer(5)]],
                                   device float *deviation [[buffer(6)]],
                                   device float *velocityMagnitude [[buffer(7)]],
                                   device uchar *wetMask [[buffer(8)]],
                                   constant SolverParameters& p [[buffer(9)]],
                                   uint gid [[thread_position_in_grid]]) {
    if (gid >= p.width * p.height) { return; }
    const uint row = gid / p.width;
    const uint column = gid - row * p.width;
    const uint xStride = p.width + 1;
    const float eta = bed[gid] + depth[gid];
    const float x = 0.5f * (velX[row * xStride + column] +
                            velX[row * xStride + column + 1]);
    const float y = 0.5f * (velY[row * p.width + column] +
                            velY[(row + 1) * p.width + column]);
    surface[gid] = eta;
    deviation[gid] = eta - referenceSurface[gid];
    velocityMagnitude[gid] = sqrt(x * x + y * y);
    wetMask[gid] = depth[gid] > p.minimumWetDepth ? 1 : 0;
}
