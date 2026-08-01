# Accelerated SWE and Flow-Boundary Contract

This document records the delivered architecture for `SWE_GPU_ACCEL_PLAN.md`.
The numerical model remains the weakly nonlinear, donor-upwind, staggered-grid
solver described in `SWE_WeakNonLinear_Math.md`. The existing `double` CPU
solver is selectable and remains the numerical oracle; accelerated state uses
`Float32` with a 0.95 CFL safety factor.

## Concrete backend ownership

`WSWaterEngineBridge` owns exactly one concrete backend through:

```cpp
std::variant<CpuBackend, MPSGraphAutomaticBackend, MetalGPUBackend>
```

There is no virtual solver hierarchy. The three final concrete types expose the
same state-transition operations, and the bridge visits the active value. The
logical state includes bed and depth cell fields, the shared X/Y face-velocity
type, time, initial fields, limits, four boundary sides, edit-water accounting,
and cumulative per-side boundary volumes.

Switching pauses first, waits for completed device work, exports that complete
logical state, prepares the requested backend, and publishes once. Time,
velocities, forcing phase, initial state, edit accounting, and boundary
accounting survive a successful switch. A failed forced-Metal selection stays
paused and is never presented as GPU execution.

## Automatic policy

`Automatic Accelerated` is the persisted and initial requested backend. The
classifier is dimension-generic:

```text
estimatedSubstepWork = 8 * cellCount + 6 * faceCount
```

The 2026-08-01 M4 Release sweep placed CPU/Metal break-even between 128² and
256². For Apple9, the conservative threshold is 1,000,000 work units; below it
Automatic selects CPU, and at or above it selects Metal because Metal beat the
complete MPSGraph path at every accelerated sample. Unknown families use the
first measured accelerated workload, 1,313,792 work units, and try MPSGraph
before Metal until family-specific measurements exist. Neither policy tests an
exact dimension.

The resolved backend and reason are public diagnostics. MPSGraph is reported as
`MPSGraph GPU`; TideSandbox does not expose a force-ANE control or claim Neural
Engine execution. Signposts and timings permit external Instruments inspection.

## Device-resident execution

Metal owns one command queue and persistent, extent-derived buffers for state,
scratch, reductions, three snapshot staging slots, and ping-pong depth. Its
threadgroups, dispatch extents, and reduction levels come from the current
geometry and pipeline/device limits. The warmed backend reports 30 state-sized
allocations and performs no state-sized allocation per substep. Damping and
cleanup are fused into adjacent numerical passes without changing solver order.

MPSGraph compiles level-1 fixed-shape stable-dt and complete-substep executables.
Its cache key is device registry ID, width, height, and the four boundary types;
forcing parameters and time remain scalar feeds. Both accelerated paths reduce
CFL and diagnostics on device and read back only small results during stepping.

Accelerated buffers are authoritative during playback. Snapshots use a staging
ring at the existing publication cadence. Active 3D rendering consumes the
accelerated bed/depth `MTLBuffer` pair and generation token directly, while the
CPU backend retains the copied-snapshot upload path. Unchanged dimensions do
not rebuild topology, and the inactive viewport submits no work.

Editing and saving are deliberate synchronization points. An edit downloads
once, uses the one authoritative `TerrainEditor` command, uploads the resulting
bed/depth/face-velocity state once, invalidates derived scratch, publishes, and
resumes only with a fresh CFL result.

## Boundary and volume contract

Each side independently stores `reflective`, `freeOpen`, or `drivenHeight`.
Driven parameters are finite, have positive period, nonnegative amplitude and
ramp, and remain inside world elevation limits. Missing persisted boundary data
migrates to four reflective sides; unknown or invalid values reject the scene.

The global face convention is positive X left-to-right and positive Y
bottom-to-top. Signed outward rates are:

```text
left   = -dy * sum(fluxX at x=0)
right  = +dy * sum(fluxX at x=width)
bottom = -dx * sum(fluxY at y=0)
top    = +dx * sum(fluxY at y=height)
```

Positive values leave the domain. Free/open sides use a transmissive reservoir.
Driven sides evaluate a ramped sinusoidal reservoir surface and use the same
hydrostatic connected-depth pressure rule as interior faces. Inflow uses the
external reservoir donor depth; outflow uses and is limited by the adjacent
interior donor. Continuity consumes these real boundary-face fluxes—no interior
depth source is used.

After every completed substep:

```text
expected volume = initial volume
                + accumulated explicit edit-water volume
                - sum(cumulative outward boundary volumes)
```

Diagnostics expose instantaneous and cumulative values per side, net flow,
expected volume, and accounting error. Reset clears cumulative flow; paused
editing does not advance it.

## Failure boundary

Accelerated work commits only after the complete command/graph succeeds and the
result is finite. Automatic preparation tries the measured preferred backend,
then the other accelerated backend, then CPU. An execution or finite-state
failure stops playback and restores CPU from the last fully completed valid
state. Forced Metal stays paused and not ready. Partially written device buffers
are never adopted as authoritative state.

## Verification contract

Scientific XCTest cases lock reflective, signed free/open and driven flow,
hydrostatic dry segments, per-side volume accounting, causal driven-wave period,
32²/128²/128×64/512² CPU-accelerated parity, movable shorelines, fallback,
switching, edit synchronization, direct rendering, and allocation stability.
Release measurements and tolerances are archived in `BenchmarkLog.md` and
`AcceleratedBenchmark_2026-08-01.csv`.

