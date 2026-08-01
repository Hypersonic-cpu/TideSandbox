# Accelerated SWE Backend and Configurable Boundaries

> Repository baseline: `Hypersonic-cpu/TideSandbox` at `269c7b029ff6d5d80e0187b5448fd46abc1e11b1`  
> Model: existing weakly nonlinear staggered-grid SWE only  
> Default requested backend: `Automatic Accelerated`  
> Reference backend: existing multithreaded double-precision CPU solver
>
> **Status: Complete — 2026-08-01.** Implementation, scientific tests, design
> decisions, and target benchmark evidence are archived in
> `AcceleratedSWE.md`, `DesignDecisions.md`, `ProgressLog.md`,
> `BenchmarkLog.md`, and `AcceleratedBenchmark_2026-08-01.csv`.

## 0. Hard constraints

- [x] Preserve the current equations, hydrostatic connected-depth shoreline reconstruction, MAC layout, donor upwinding, outgoing limiter, editing semantics, 2D/3D shared state, and active-viewport-only rendering.
- [x] Do not migrate to full conservative SWE and do not add nonlinear velocity advection.
- [x] Keep `TideSandbox/Engine` pure C++ (`.cc/.hh`). Put Metal, MPSGraph, Objective-C++, and Apple-framework code outside `Engine`.
- [x] Keep the existing CPU solver as the numerical oracle and selectable fallback.
- [x] Accelerated state may use `Float32`; CPU reference remains `double`.
- [x] `Automatic Accelerated` is the application default. It resolves from grid/workload size, device capabilities, backend readiness, and measured break-even data; it may choose MPSGraph automatic placement, Metal GPU, or CPU fallback, and must expose the resolved backend and reason.
- [x] Do not expose a fake “force ANE” option. MPSGraph optimization level 1 may place supported graph regions across GPU, Neural Engine, and CPU; placement is controlled by Apple.
- [x] Non-reflective boundaries are real mass-flow boundaries. Never emulate them by modifying interior cell depth directly.
- [x] All boundary volume changes must be accounted from signed face flux integrated over time.
- [x] Default verification is non-interactive. Do not start XCUITest or seize mouse/keyboard control unless a requirement cannot be validated by unit tests, offscreen Metal, view-model tests, or accessibility-free launch tests.
- [x] Do not repeat or redesign the completed terrain-editing, 2D decorative rendering, or 3D editing work.
- [x] Treat Sections 1–9 as requirements, not as separate execution stages. Sol must implement adjacent requirements together when they share data structures or hot paths.
- [x] Do not stop, summarize, request confirmation, or create a commit after every subsection. Complete one macro stage, run its focused gate, then continue.
- [x] Prefer end-to-end vertical slices over placeholder APIs: a backend or boundary feature is not complete until its state, runtime integration, diagnostics, persistence/UI where applicable, and focused tests work together.

## 1. Target architecture

### 1.1 Backend selection

Add value enums across Swift, Objective-C, and implementation code:

```text
RequestedSimulationBackend
- automaticAccelerated
- metalGPU
- cpuReference

ResolvedSimulationBackend
- mpsGraphAutomatic
- metalGPU
- cpuReference
```

User-facing selector:

```text
Simulation backend
- Automatic Accelerated (default)
- Metal GPU
- CPU Reference
```

Do not expose `mpsGraphAutomatic` as “ANE”. Show it as `Apple Automatic (GPU / Neural Engine / CPU)` in diagnostics only.

Resolution order:

```text
automaticAccelerated:
    try MPSGraph automatic backend
    else try Metal GPU backend
    else CPU reference

metalGPU:
    try Metal GPU backend
    else fail selection and remain paused; do not silently relabel as GPU

cpuReference:
    existing CPU solver
```

For workloads below the measured acceleration break-even threshold, `automaticAccelerated` may resolve to CPU. Above the threshold, it should resolve to the fastest validated accelerated backend unless an explicit capability or correctness failure is reported. The decision must not contain an exact-grid special case.

### 1.2 Size-generic acceleration policy

Backend selection and kernels must support every valid grid dimension accepted by the product.

Use a measured workload classifier rather than a dimension literal:

```text
cellCount = width * height
faceCount = (width + 1) * height + width * (height + 1)
estimatedSubstepWork = weighted sum of cell and face passes
```

Maintain benchmark-derived break-even data by device/backend family. Selection may use buckets such as:

```text
small
medium
large
```

but the bucket boundaries must be based on estimated work and benchmark results, not names such as `512Mode`.

Requirements:

```text
same kernels and buffer lifecycle for all supported dimensions
threadgroup sizing derived from pipeline/device limits
dispatch dimensions derived from actual field extents
reduction hierarchy derived from element count
buffer allocation derived from validated counts
no 512-specific constants, tiling, branches, or storage
```

Benchmark at multiple shapes and sizes, including at least one non-square case, so a square-only optimization cannot pass accidentally.

### 1.2 Concrete ownership; no virtual hierarchy

Use a tagged concrete holder in Objective-C++:

```cpp
using BackendStorage = std::variant<
    CpuBackend,
    MPSGraphAutomaticBackend,
    MetalGPUBackend
>;
```

Do not add `ISolverBackend` virtual dispatch.

Suggested files:

```text
TideSandbox/Accelerated/AcceleratedSolverTypes.hh
TideSandbox/Accelerated/MPSGraphAutomaticBackend.hh
TideSandbox/Accelerated/MPSGraphAutomaticBackend.mm
TideSandbox/Accelerated/MetalGPUBackend.hh
TideSandbox/Accelerated/MetalGPUBackend.mm
TideSandbox/Accelerated/SWEComputeKernels.metal
TideSandbox/Bridge/WaterEngineBridge.hh
TideSandbox/Bridge/WaterEngineBridge.mm
```

`WSWaterEngineBridge` remains the facade used by `SimulationRuntime`.

### 1.3 Backend status

Expose:

```text
requestedBackend
resolvedBackend
backendReady
fallbackReason
statePrecision
graphCompileMilliseconds
lastFramePhysicsMilliseconds
lastSubstepMilliseconds
lastReadbackMilliseconds
substepCount
```

Never claim ANE usage unless a reliable Apple API reports it. Add signposts so Instruments can inspect placement separately.

## 2. Shared simulation contract

### 2.1 Required state

Every backend owns equivalent logical fields:

```text
bedElevation: cell centered
waterDepth: cell centered
velX: x faces
velY: y faces
time
initial bed/depth
world limits
boundary configuration
boundary cumulative volume accounting
reference surface
```

The CPU reference stores `double`. Accelerated backends store `Float32`.

### 2.2 Required operations

Every concrete backend must implement equivalent non-virtual methods:

```text
load(scene)
reset()
advance(frameDeltaTime)
stepOnce(timeStep)
setConfiguration(...)
setBoundaryConfiguration(...)
applyMaterialBrush(...)
applyMaterialPolygon(...)
makeSnapshot(request)
synchronizeToHost()
resolvedDiagnostics()
```

Backend switching:

1. pause;
2. wait for the last submitted accelerated command;
3. export current state, time, initial state, boundary configuration, and cumulative boundary volumes;
4. initialize the selected backend;
5. publish one snapshot;
6. resume only after successful conversion.

Do not reset time, velocities, boundary forcing phase, or cumulative boundary accounting when switching.

### 2.3 Precision and safety

Accelerated backend:

```text
state: Float32
reductions: Float32 or wider supported accumulator
CPU-side boundary-volume accumulation: Float64
```

Use a small accelerated CFL safety multiplier:

```text
effectiveStableDt = computedStableDt * 0.95
```

Do not clamp velocity as a normal stabilization method.

## 3. Boundary model

### 3.1 Public types

```cpp
enum class BoundaryType : std::uint8_t {
    reflective,
    freeOpen,
    drivenHeight,
};

struct DrivenHeightBoundary {
    double meanSurfaceElevation;
    double amplitude;
    double periodSeconds;
    double phaseRadians;
    double rampSeconds;
};

struct BoundarySide {
    BoundaryType type;
    DrivenHeightBoundary driven;
};

struct BoundaryConfiguration {
    BoundarySide left;
    BoundarySide right;
    BoundarySide bottom;
    BoundarySide top;
};
```

Validation:

```text
all values finite
periodSeconds > 0 when driven
amplitude >= 0
rampSeconds >= 0
driven eta must remain within world limits after evaluation
```

Missing persisted configuration defaults all four sides to `reflective`.

### 3.2 Coordinate and flux convention

Existing face conventions:

```text
fluxX > 0: left to right
fluxY > 0: bottom to top
```

Signed outward discharge rate per side:

```text
QleftOut   = -dy * sum_j fluxX(0, j)
QrightOut  = +dy * sum_j fluxX(width, j)
QbottomOut = -dx * sum_i fluxY(i, 0)
QtopOut    = +dx * sum_i fluxY(i, height)
```

Positive means water leaves the domain. Negative means water enters.

Per substep:

```text
boundaryVolumeSide += dt * QsideOut
expectedVolume =
    initialVolume
  + accumulatedEditWaterVolume
  - sum(boundaryVolumeSide)
```

For no interior sources:

```text
actualVolume ~= expectedVolume
```

Add diagnostics:

```text
instantaneousOutflowRate[4]
cumulativeOutwardVolume[4]
netBoundaryOutflowRate
accountedExpectedVolume
accountingError
```

Reset clears cumulative boundary volumes. Paused editing does not advance them.

### 3.3 Ghost/reservoir state

Implement boundary faces through one conceptual interior/reservoir pair. Do not write a source into the first interior cell.

For boundary-adjacent interior state:

```text
bi, hi, etai = bi + hi
```

#### Reflective

```text
normal face velocity = 0
boundary flux = 0
```

No ghost donor is used.

#### Free / open

First-order transmissive reservoir:

```text
bg = bi
hg = hi
etag = etai
normal reservoir velocity = nearest interior normal face velocity
```

The boundary face remains a true velocity state and receives damping/cleanup. Zero surface gradient adds no pressure impulse. Existing outward velocity permits outflow; inward velocity permits inflow from the copied reservoir state.

#### Driven height

At simulation time `t`:

```text
ramp(t) =
    1                                  when rampSeconds == 0
    smoothstep(0, rampSeconds, t)      otherwise

etaDrive(t) =
    meanSurfaceElevation
  + ramp(t) * amplitude * sin(2*pi*t/periodSeconds + phaseRadians)

bg = bi
hg = max(etaDrive - bg, 0)
etag = bg + hg
```

Update the boundary normal face velocity from the same hydrostatic connected-depth pressure rule used internally, using the interior and reservoir states. Apply damping afterward.

The driven reservoir is external:

- inflow donor depth comes from the reservoir and is not limited by an interior-cell water budget;
- outflow donor depth comes from the interior cell and uses that cell's outgoing limiter;
- a boundary row/column whose bed is above `etaDrive` has zero reservoir depth;
- driven height may produce either inflow or outflow.

### 3.4 Generic oriented boundary flux

Implement a shared local-normal helper to avoid four divergent formulas:

```text
outwardNormalSpeed > 0: interior -> reservoir
outwardNormalSpeed < 0: reservoir -> interior
```

Then map back to global `fluxX/fluxY`.

Limiter rule:

```text
outflow:
    scale by adjacent interior donor theta

inflow:
    no interior donor scaling
```

Continuity consumes boundary face flux exactly like an interior face.

### 3.5 CFL and validation

Include in stability reduction:

```text
all cell depths
all interior and boundary face speeds
driven reservoir depths at current time
```

Reject non-finite driven values before dispatch.

## 4. CPU reference boundary implementation

- [x] Replace hard-coded zero values at `velX(0,*)`, `velX(width,*)`, `velY(*,0)`, and `velY(*,height)` with boundary-type handling.
- [x] Compute boundary pressure update before damping.
- [x] Compute boundary fluxes before outgoing-scale calculation.
- [x] Include boundary outflow in the adjacent cell's outgoing-depth estimate.
- [x] Apply interior donor limiter only to outward boundary flux.
- [x] Keep reflective behavior bit-compatible where practical.
- [x] Update dry-face cleanup for boundary reservoir connectivity.
- [x] Accumulate signed boundary volume after final limited boundary flux is known.
- [x] Update diagnostics and volume oracle.
- [x] Add CPU tests before implementing accelerated boundaries.

Do not proceed to accelerated boundary kernels until CPU tests pass.

## 5. Accelerated backend

### 5.1 MPSGraph automatic backend

Use `MPSGraphExecutable` with an explicit compilation descriptor:

```text
optimizationLevel = level1
```

This is the automatic-placement path. Compile fixed-shape graphs per cache key:

```text
(width, height, leftType, rightType, bottomType, topType)
```

This cache supports arbitrary valid dimensions. Do not precompile, tune, tile, or branch specifically for `512×512`.

Driven numerical parameters and simulation time are scalar feeds; changing amplitude, period, phase, mean height, or ramp does not require graph recompilation.

Compile two executables:

```text
StableDtGraph
SubstepGraph
```

#### StableDtGraph

Inputs:

```text
h, velX, velY
gravity, dx, dy, cfl
time
driven boundary parameters
```

Outputs:

```text
maxDepthIncludingReservoir
maxAbsVelX
maxAbsVelY
stableDt
finiteFlag
```

Read back only the scalar result.

#### SubstepGraph

Inputs:

```text
bed
hCurrent
velXCurrent
velYCurrent
dt
time
gravity
damping
minimumWetDepth
world limits
boundary parameters
```

Outputs:

```text
hNext
velXNext
velYNext
surface
fluxX
fluxY
outgoingScale
boundary outflow rates
finite/min/max diagnostic scalars
```

Graph order:

```text
surface
hydrostatic interior face reconstruction
boundary reservoir construction
interior and boundary velocity pressure update
damping
interior and boundary flux
outgoing donor scale including boundary outflow
limited flux
continuity
minimum-depth cleanup
dry donor velocity cleanup
boundary volume-rate reduction
finite/diagnostic reduction
```

Use ping-pong state tensors. Do not allocate state-sized tensors on every substep after compilation/warm-up.

### 5.2 Metal GPU fallback/backend

Implement equivalent fixed compute kernels:

```text
computeSurface
computeStableDtReduction
updateVelocityX
updateVelocityY
updateBoundaryFaces
applyDamping
computeFluxX
computeFluxY
computeBoundaryFlux
computeOutgoingScale
limitFluxX
limitFluxY
updateDepth
cleanupDepth
cleanupDryVelocityX
cleanupDryVelocityY
reduceDiagnostics
```

Requirements:

- persistent `MTLBuffer` allocations;
- ping-pong depth buffers;
- shared face flux consumed by both adjacent cells;
- one command queue owned by the simulation backend;
- no CPU loop over grid-sized fields during an accelerated substep;
- group reductions with small scalar readback;
- label command buffers and encoders;
- no work submitted while paused except edits, explicit snapshots, or backend preparation.

### 5.3 Runtime failure policy

On graph compilation failure:

```text
automatic -> Metal GPU
```

On Metal creation failure:

```text
automatic -> CPU reference
```

On accelerated execution failure or non-finite result:

1. stop playback;
2. preserve the last fully completed valid state;
3. publish an error/fallback diagnostic;
4. in `automatic`, switch to CPU reference from that valid state;
5. in forced `metalGPU`, remain paused and require user action.

Never continue from partially written buffers.

## 6. State transfer, snapshots, and rendering

### 6.1 Accelerated authoritative buffers

During playback, accelerated buffers are authoritative. Do not round-trip full state through CPU per substep.

### 6.2 Snapshot compatibility stage

Initial implementation may preserve `SimulationSnapshot`, but:

- perform readback only at the existing publish cadence;
- use a ring of staging buffers;
- synchronize on `SimulationRuntime`'s engine queue, never the main thread;
- generate surface, deviation, velocity magnitude, and wet mask on the accelerated backend;
- measure and report readback time separately from physics time.

### 6.3 3D direct-buffer path

After correctness:

- allow `HeightFieldRenderer` to consume the accelerated bed/depth `MTLBuffer` pair plus generation token;
- avoid CPU snapshot -> Metal re-upload for active 3D playback;
- preserve the current inactive-viewport-zero-work rule;
- dimensions unchanged must not rebuild topology.

The CPU backend continues using the existing snapshot upload path.

### 6.4 Editing and saving

Editing remains paused and uses the existing authoritative CPU edit semantics:

1. synchronize accelerated state to host once at edit entry;
2. apply `TerrainEditor`;
3. upload changed bed/depth/velocity fields once;
4. clear/rebuild accelerated scratch state;
5. publish snapshot;
6. resume with fresh CFL.

Saving synchronizes the requested state to host. This infrequent synchronization is acceptable.

## 7. Runtime, bridge, and UI

### 7.1 Bridge API

Extend `WSWaterEngineBridge` with:

```text
requestedBackend
resolvedBackend
backendStatus
setRequestedBackend(...)
boundaryConfiguration
setBoundaryConfiguration(...)
boundaryDiagnostics
```

`updateConfiguration(...)` must update all concrete backends consistently.

### 7.2 Runtime behavior

On initialization:

```text
requested backend = automaticAccelerated
prepare backend
publish backend status
```

On scene load or boundary-type change:

```text
pause
rebuild/resolve backend if graph cache key changes
publish one snapshot
```

Do not compile on the main thread.

### 7.3 UI

Add a compact `Simulation` inspector subsection:

```text
Backend: [Automatic Accelerated]
Resolved: Apple Automatic / Metal GPU / CPU Reference
```

Add a `Boundaries` subsection with four rows:

```text
Left    [Reflective | Free/Open | Driven Height]
Right   [Reflective | Free/Open | Driven Height]
Bottom  [Reflective | Free/Open | Driven Height]
Top     [Reflective | Free/Open | Driven Height]
```

For each driven side show:

```text
Mean surface
Amplitude
Period
Phase
Ramp
```

Changing any boundary setting pauses simulation and applies atomically.

Display optional compact diagnostics:

```text
Net boundary flow
Left/right/bottom/top signed flow
Accounted volume error
```

### 7.4 Persistence

Add optional scene manifest fields:

```json
{
  "boundaries": {
    "left":   {"type": "reflective"},
    "right":  {
      "type": "drivenHeight",
      "meanSurfaceElevation": 1.2,
      "amplitude": 0.25,
      "periodSeconds": 8.0,
      "phaseRadians": 0.0,
      "rampSeconds": 2.0
    },
    "bottom": {"type": "reflective"},
    "top":    {"type": "reflective"}
  }
}
```

Migration:

```text
field absent -> all reflective
unknown type -> reject package
invalid driven parameters -> reject package
```

Backend preference is application preference, not scene content.

## 8. 512×512 scenarios

### 8.1 Update `coastChannel512`

Replace the nearly fully submerged level-lake terrain with deterministic stronger bathymetry and exposed land.

For normalized cell centers `x,y in (0,1)`:

```text
baseEta = 1.20

coastalSlope =
    -1.25 + 3.10*x

channel =
    0.95 * exp(-((y - 0.52)/0.065)^2)

sandbar =
    0.45
  * exp(-((x - 0.64)/0.055)^2)
  * (0.65 + 0.35*cos(6*pi*y))

shoals =
    0.12
  * sin(14*pi*y)
  * (0.25 + 0.75*x)

bed =
    coastalSlope
  - channel
  + sandbar
  + shoals
```

Initial tsunami-like surface step:

```text
rightStep =
    0.55 * smoothstep(0.79, 0.81, x)

etaInitial =
    baseEta + rightStep

waterDepth =
    max(etaInitial - bed, 0)

velX = 0
velY = 0
```

Default boundaries for this initial-condition stress scene:

```text
left: reflective
right: reflective
bottom: reflective
top: reflective
```

This isolates the initial free-surface imbalance from ongoing external forcing.

Scene assertions:

```text
all fields finite
waterDepth >= 0
dry cell fraction in [0.02, 0.35]
at least one wet channel connects the raised right band to the interior
mean eta in x >= 0.82 exceeds mean eta in x <= 0.75 by >= 0.45 m
initial face velocities are zero
surface range >= 0.50 m
```

Do not describe this weakly nonlinear scene as a quantitatively accurate tsunami model. It is a tidal-bore/tsunami-like stress visualization.

### 8.2 Add `drivenOceanWave512`

Use the same bathymetry with a flat initial free surface:

```text
etaInitial = 1.20
waterDepth = max(etaInitial - bed, 0)
velX = velY = 0
```

Boundary configuration:

```text
left: reflective
right:
    type = drivenHeight
    meanSurfaceElevation = 1.20
    amplitude = 0.25
    periodSeconds = 8.0
    phaseRadians = 0
    rampSeconds = 2.0
bottom: reflective
top: reflective
```

This scene tests continuous right-boundary wave injection separately from the initial step.

### 8.3 Built-in generation

Update both:

```text
TideSandbox/App/BuiltInScenes.swift
Tools/GenerateBuiltInScenes.swift
```

Regenerate packaged scene data/manifests through the existing tool. Do not hand-edit binary payloads.

## 9. Tests

### 9.1 Non-interactive policy

Use by default:

```text
C++ XCTest
Swift unit tests
offscreen Metal/MPSGraph tests
command-line benchmarks
view-model tests
scene generation tests
```

Do not run interactive XCUITest for:

```text
solver correctness
boundary correctness
GPU/CPU parity
backend selection logic
scene initialization
volume accounting
wave propagation
performance
persistence migration
```

An interactive test is permitted only when actual window focus, real pointer capture, or `MTKView` drawable lifecycle cannot be validated otherwise. Before running it, record why non-interactive coverage is insufficient. Run one focused scenario only; do not run the full interactive suite.

### 9.2 CPU boundary tests

Reflective:

```text
all four boundary fluxes exactly zero
closed-domain volume conserved
existing reflective golden behavior unchanged within tolerance
```

Free/open:

```text
preset outward velocity produces positive outward volume
actual volume loss matches integrated boundary outflow
inward velocity produces negative outward volume and matching volume gain
no negative depth or non-finite values
```

Driven height:

```text
etaDrive follows mean/amplitude/period/phase/ramp
flat etaDrive equal to interior equilibrium produces no flow
higher right reservoir produces net inflow
lower right reservoir produces net outflow
boundary flux changes sign when forcing crosses equilibrium
actual volume matches integrated boundary flux
dry boundary segments above etaDrive contribute zero reservoir depth
```

Mixed sides:

```text
left free, right driven, top reflective, bottom free
sign conventions verified independently
```

### 9.3 CPU/accelerated parity

Run the same initial state, boundary configuration, exact explicit `dt` sequence, and step count.

Compare:

```text
water depth L1/Linf
velX L1/Linf
velY L1/Linf
total volume
per-side cumulative boundary volume
wet/dry mask
finite status
```

Required cases:

```text
32² reflective lake
128² movable shoreline
128×64 right-driven wave
512² initial-step coast (scenario/regression case only)
512² driven ocean wave (scenario/regression case only)
```

Do not require bit equality. Establish tolerances from measured Float32 error, then lock them.

### 9.4 Boundary wave tests

Small deterministic test:

```text
grid: 128×64
right driven
other sides reflective
period: 4 s
amplitude: 0.10 m
ramp: 1 s
```

Assertions:

```text
probe near right responds before probe near left
dominant probe period matches forcing within tolerance
wave energy remains finite
wet/dry remains valid
boundary-accounted volume error remains bounded
```

### 9.5 512² scenario tests

Initial-step scene:

```text
dry fraction target met
initial eta step target met
after short evolution, disturbance centroid moves left
no NaN/Inf
h >= 0
substep limit not reached under default settings
```

Driven scene:

```text
right boundary injects and removes water periodically
signed cumulative volume matches domain change
wave reaches interior probes
```

### 9.6 Backend selection tests

```text
Automatic + supported MPSGraph -> mpsGraphAutomatic
MPSGraph compile failure -> Metal GPU
Metal unavailable -> CPU reference
forced Metal failure -> paused error, no silent CPU relabel
backend switch preserves state/time/boundary accounting
default requested backend is Automatic Accelerated
```

### 9.7 Performance tests

Measure separately:

```text
stable-dt reduction
substep compute
snapshot/readback
3D direct-buffer handoff
total frame physics
```

Warm up before timing. Use Release. Benchmark a geometric size sweep rather than one grid:

```text
64²
128²
256²
384²
512²
256×512
```

Use the sweep to determine backend break-even thresholds. Record physics compute, scalar reduction/readback, snapshot staging, and total runtime separately.

Acceptance on target Apple Silicon:

```text
Automatic resolves accelerated for representative workloads above the measured break-even threshold
accelerated result passes parity across multiple medium/large dimensions
median physics time <= CPU reference above the threshold
target speedup >= 2x on at least one representative large case, excluding snapshot/readback
no state-sized allocation per substep after warm-up
no dimension-specific fast path for 512²
```

If MPSGraph automatic is slower than Metal GPU, `Automatic` may resolve to Metal GPU and retain MPSGraph as an experimental backend path.

## 10. Macro implementation stages

The following are the only execution stages. Sections 1–9 are implementation requirements inside these stages, not individual tasks. Sol should continue autonomously within a stage until its focused gate passes.

### Stage A — Boundary system and 512² scenarios

`512²` here identifies the requested built-in scenes only. It does not define a solver optimization target or backend-selection rule.

Implement as one end-to-end change:

```text
boundary value types and validation
CPU reflective/free/driven face handling
real boundary mass flux and per-side accounting
diagnostics and persistence migration
right-driven deterministic fixture
updated coastChannel512
new drivenOceanWave512
built-in package regeneration
compact four-side UI controls
```

Focused gate:

```text
CPU reflective/open/driven tests
boundary volume-accounting tests
scene-generation assertions
persistence migration tests
one small right-driven wave propagation test
```

Do not split boundary enums, flux accounting, driven forcing, scene generation, and UI into separate stages or placeholder commits.

### Stage B — Automatic accelerated solver

Implement the accelerated solver as one coherent backend feature:

```text
requested/resolved backend types
concrete variant-based ownership
Metal compute SWE kernels
MPSGraph level-1 automatic-placement path
persistent ping-pong state and scratch buffers
CFL/diagnostic reductions
boundary kernels for all three boundary types
runtime failure recovery and fallback
backend switching with state/time/boundary-account preservation
bridge/runtime status
```

Metal is the required controllable accelerated implementation. MPSGraph automatic placement is included in the same stage and may fall back to Metal. Do not implement one backend as a disconnected prototype that cannot execute the complete solver.

Focused gate:

```text
32² reflective CPU/accelerated parity
128×64 driven-boundary CPU/accelerated parity
backend resolution and failure-injection tests
no state-sized allocation per warmed-up substep
forced Metal failure does not silently relabel CPU as GPU
```

### Stage C — Device-resident data path and rendering integration

Combine feature and performance work:

```text
accelerated buffers remain authoritative during playback
asynchronous ring-buffer snapshot staging
accelerated generation of derived snapshot fields
readback only at publish cadence
editing/save synchronization
3D direct bed/depth buffer handoff
inactive viewport performs zero work
performance/signpost diagnostics
```

Do not first build a copy-heavy compatibility design and then schedule many separate optimization tasks when the ownership model can avoid those copies immediately.

Focused gate:

```text
snapshot compatibility tests
edit -> synchronize -> upload -> resume stability
2D snapshot correctness
3D direct-buffer generation/update tests
inactive-renderer counters
warmed-up profiling across representative medium and large dimensions, with compute and readback reported separately
```

### Stage D — Product integration and default enablement

Complete together:

```text
backend selector and resolved-backend status
boundary controls and compact flow diagnostics
application preference persistence
scene boundary persistence
atomic pause/reconfigure behavior
Automatic Accelerated as the requested default
```

Set the default only after Stages B and C pass their gates. `Automatic` chooses from measured backend performance by workload class; it may choose CPU below the break-even threshold and the fastest validated accelerated implementation above it. Do not encode an exact-grid exception.

Focused gate:

```text
view-model tests without pointer automation
default/fallback preference tests
scene load and boundary reconfiguration tests
backend switch preserves visible state and time
```

### Stage E — Consolidated validation and delivery

Run grouped suites rather than one test command per assertion:

```text
BoundarySuite
AcceleratedParitySuite
WaveScenarioSuite
BackendFallbackSuite
DataPathAndPerformanceSuite
ExistingRegressionSuite
```

Representative cases:

```text
32² reflective
128² movable shoreline
128×64 driven wave
512² initial-step coast (scenario/regression case only)
512² driven ocean wave (scenario/regression case only)
```

Run:

```text
focused Debug tests during implementation
one Release parity/performance run
one final full non-interactive regression suite
sanitizers only for touched CPU/bridge concurrency and memory paths
```

Interactive XCUITest remains zero by default. Permit one focused interactive scenario only if actual window focus, pointer capture, or `MTKView` drawable lifecycle cannot be validated otherwise; record the reason before running it.

Finish documentation and `Docs/ProgressLog.md` here. Record actual hardware resolution and timings; never report ANE execution without reliable evidence.

## 11. Commit strategy

Target **four to six substantial commits**, not one commit per subsection:

```text
feat: add configurable flow boundaries and 512 wave scenarios
feat: add automatic accelerated SWE solver with persistent device state
feat: integrate accelerated snapshots editing and 3D rendering
feat: expose backend and boundary product controls
test: validate accelerated parity boundaries and performance
docs: document accelerated solver and boundary contract
```

A stage may use fewer commits when changes are inseparable. Do not create commits containing only placeholder interfaces, isolated diagnostics, or a single small optimization. Each feature commit must compile and pass that stage's focused gate.

## 12. Definition of Done

- [x] `Automatic Accelerated` is the saved/default requested backend.
- [x] CPU reference remains selectable and mathematically authoritative.
- [x] Representative medium/large workloads above the measured break-even threshold resolve to an accelerated backend on the target supported Apple Silicon machine; no exact `512×512` check controls backend selection.
- [x] No public UI or diagnostic falsely asserts ANE usage.
- [x] Four boundaries are independently configurable as reflective, free/open, or driven height.
- [x] Free and driven boundaries carry real signed mass flux.
- [x] Domain volume change matches integrated boundary flux plus explicit edit volume.
- [x] Driven right-boundary waves enter the domain through the boundary face, not an interior source.
- [x] Updated `coastChannel512` contains exposed terrain and a rightmost-one-fifth elevated initial surface.
- [x] `drivenOceanWave512` produces continuous right-boundary wave forcing.
- [x] Accelerated and CPU states remain within locked Float32 parity tolerances.
- [x] No negative depth, non-finite state, stale-CFL resume, or substep-limit regression.
- [x] Accelerated substeps allocate no state-sized buffers after warm-up.
- [x] Accelerated kernels, dispatch, reductions, buffer ownership, and backend selection contain no exact-size specialization for `512×512`; 512² is only a scenario and benchmark point.
- [x] Interactive automation was not used unless explicitly justified as unavoidable.
