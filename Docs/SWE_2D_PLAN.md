# WaterSandbox 2D MVP — Implementation Plan

> **Status:** Active  
> **Target:** macOS desktop application (Do not design iOS version so far)
> **Current scope:** CPU-only weakly nonlinear shallow-water Engine, multi-core execution, 2D mosaic rendering, terrain editing, and persistent scenes  
> **Deferred:** iOS, WidgetKit, Metal, 3D rendering, splashing, and full nonlinear/conservative SWE
> **Important**: You ARE RESPONSIBLE for make correct design decisions to make this app accurate, efficient and beautiful. Also make both code and UI tidy, clean and graceful. UI should follow AppleMap-style (mostly plain). 

---

## 0. Mandatory instructions for Codex

1. Before implementing or modifying the solver, read **`Docs/SWE_WeakNonLinear_Math.md`** completely.
2. Treat that document as the mathematical specification.
3. Implement only its **weakly nonlinear SWE**:
   - cell-centered water depth `h`;
   - face-centered velocities `u` and `v`;
   - `eta = h + bedElevation`;
   - conservative mass update through shared face fluxes;
   - velocity update from the free-surface gradient;
   - linear damping;
   - first-order upwind face depth;
   - CFL-controlled substeps;
   - positivity and simple wet/dry handling.
4. Do not add `((u · grad)u)` and do not silently replace the state with the full conservative `[h, hu, hv]` system.
5. Naming convention:
   - pure C++ implementation: `.cc`;
   - pure C++ headers: `.hh`;
   - Apple platform bridge: `.mm` / `.hh`;
   - UI: `.swift`;
   - do not create `.cpp` or `.cxx`.
6. Keep `Engine/` independent of Swift, Objective-C, Foundation, AppKit, and Metal.
7. Finish and verify the current Phase before starting the next one.
8. Keep every progress, benchmark, debugging, and design-decision log in a file under `Docs/`.
9. Make small, frequent Git commits at verified checkpoints.
10. After verifying a numbered task, update its checkbox in this file.

---

## 1. Engine engineering rules

`Engine/` is a numerical/HPC solver library, not a product-layer framework. FOLLOW BEST PRACTICE FOR **MODERN CPP** HPC LIBRARY!

Friendly notes:
- Prefer modern C++17/20/23/26 facilities e.g. STL container / smart pointer when they simplify or strengthen the implementation, while respecting the compiler version configured by the project.
- Prefer explicit contiguous arrays, predictable ownership, simple value types, and short call paths.
- Keep the numerical state and iteration spaces visible in code.
- Prefer `assert`, debug assertions, precondition checks, and fail-fast behavior for programmer errors.
- Prefer non-exception control flow in the Engine.
- Suitable examples include `std::span`, `std::jthread`, `std::barrier`, `std::latch`, concepts, ranges where they do not obscure hot loops, `constexpr`, `[[nodiscard]]`, and standard attributes.
- Properly use inherit class whenever necessary.
- Avoid excessive helper classes and tiny forwarding methods.
- Avoid pervasive mutable elements when they can be const. Make ownership clear. Make constant `const` whenever possible.
- Avoid hiding hot loops behind virtual dispatch, callbacks, or type-erased abstractions.
- Avoid allocating during a solver substep.
- Reuse scratch buffers.
- Keep serial and parallel implementations mathematically identical.
- Use compiler-visible, straightforward loops first; optimize only after measurement.
- Product behavior such as alerts, file pickers, gallery state, and UI lifecycle belongs outside `Engine/`.

---

## 2. MVP requirements

The first usable application shall:

- run the weakly nonlinear solver on multiple CPU cores;
- test using `16×16`, `32×32`, `128×128`, and `512×512` grids, support any `N×N` grids for `N>=8`.
- display one mosaic square per simulation cell;
- use no visual interpolation in the initial debug renderer;
- show bed elevation, water depth, free-surface elevation, velocity magnitude, and wet/dry state;
- support play, pause, single-step, reset, and basic parameter controls;
- support continuous raise-sand and lower-sand brushes;
- support polygon terrain editing;
- save user-created and imported scenes;
- restore scenes after relaunch;
- include Engine, terrain-editor, display-mapping, and persistence tests.

Initial mapping:

```text
1 simulation cell -> 1 logical mosaic tile
```

The complete grid may be scaled to fit the view, but each tile is still derived from exactly one cell.

---

## 3. Architecture

```text
SwiftUI App
    |
    v
Objective-C++ Bridge (.mm/.hh)
    |
    v
Pure C++ Engine (.cc/.hh)
    |
    +-- contiguous fields
    +-- weakly nonlinear solver
    +-- CPU parallel loops
    +-- terrain operations
    +-- diagnostics
```

Persistence:

```text
Swift/App persistence layer
    |
    +-- Application Support path
    +-- gallery catalog
    +-- package import/export
    |
    v
Versioned scene files and matrix files
```

Rendering:

```text
Engine snapshot -> Bridge -> Swift 2D mosaic renderer
```

Dependency rules:

- `Engine/` depends only on the C++ standard library.
- `Bridge/` translates between Engine values and Apple-facing types.
- Swift does not receive mutable Engine storage.
- The renderer does not write directly to solver arrays.
- Terrain edits are explicit Engine operations.
- The CPU Engine remains the reference implementation after later GPU work.

---

## 4. Suggested source layout

```text
WaterSandbox/
├── App/
│   ├── WaterSandboxApp.swift
│   ├── MainWindowView.swift
│   ├── SimulationViewModel.swift
│   ├── MosaicGridView.swift
│   ├── GridDisplayMapping.swift
│   ├── ColorMap.swift
│   ├── SceneLibrary.swift
│   └── ScenePackageIO.swift
│
├── Bridge/
│   ├── WaterEngineBridge.hh
│   └── WaterEngineBridge.mm
│
├── Engine/
│   ├── Grid.hh
│   ├── SimulationState.hh
│   ├── SimulationState.cc
│   ├── WeakNonlinearSolver.hh
│   ├── WeakNonlinearSolver.cc
│   ├── ParallelFor.hh
│   ├── ParallelFor.cc
│   ├── TerrainEdit.hh
│   ├── TerrainEdit.cc
│   ├── Diagnostics.hh
│   └── Diagnostics.cc
│
├── Tests/
│   ├── Engine/
│   ├── Rendering/
│   └── Persistence/
│
├── Docs/
│   ├── SWE_WeakNonLinear_math.md
│   ├── plan.md
│   ├── ProgressLog.md
│   ├── BenchmarkLog.md
│   ├── DebugLog.md
│   └── DesignDecisions.md
│
└── Resources/
    └── BuiltInScenes/
```

Do not split files merely to match this tree. A smaller set of cohesive files is preferable until file size or compilation dependencies justify separation.

---

# Phase 1 — Pure C++ Engine

- [x] **Phase 1 complete**

## Goal

Build a deterministic pure C++ weakly nonlinear solver with a serial reference path and a multi-core path.

### 1.1 Mathematical scope and field layout

- [x] Lock the weakly nonlinear equations and MAC-style field layout.

Requirements:

- Read `Docs/SWE_WeakNonLinear_math.md`.
- Store `waterDepth` and `bedElevation` at cell centers.
- Store `velX` on `(width + 1) × height` faces.
- Store `velY` on `width × (height + 1)` faces.
- Keep `surfaceElevation`, upwind depths, and face fluxes as scratch/derived fields.
- Document that full nonlinear momentum advection and `[h, hu, hv]` storage are deferred.

### 1.2 Contiguous grid storage

- [x] Implement the minimum contiguous row-major field types needed by the solver.

Requirements:

- Support cell fields and both face-field shapes.
- Provide predictable row-major indexing.
- Use assertions for invalid programmer access in debug builds.
- Keep hot access simple and inlineable.
- Support non-square grids.
- Avoid a generic multidimensional container framework.
- Avoid public mutable ownership aliases.

### 1.3 Simulation state and initialization

- [x] Implement state, physical dimensions, initialization, and reset.

Requirements:

- Store domain width, domain height, `dx`, and `dy`.
- Initialize `h = max(initialSurfaceLevel - bedElevation, 0)`.
- Reset without reallocating when dimensions are unchanged.
- Expose const views or snapshots for consumers.
- Keep initial state separately only when required for reset.

### 1.4 Solver configuration

- [x] Implement a compact validated solver configuration.

Include:

- gravity;
- linear damping;
- CFL number;
- minimum wet depth;
- maximum substeps;
- worker count;
- serial threshold;
- optional debug velocity bound.

Use SI-like units and conservative defaults.

### 1.5 Solver substep

- [x] Implement one complete weakly nonlinear substep.

Order:

1. derive `eta`;
2. update x-face velocity;
3. update y-face velocity;
4. apply exponential damping;
5. enforce reflective walls;
6. compute upwind face depths;
7. compute shared face fluxes;
8. apply donor-cell outgoing-flux limiting;
9. conservatively update water depth;
10. clean dry cells and record corrections.

Requirements:

- no allocation inside the substep;
- no exception-based control flow;
- invalid numerical state triggers debug assertions and diagnostic reporting;
- hot loops remain direct and readable.

### 1.6 CFL stepping

- [x] Implement characteristic-speed reduction and frame substepping.

Requirements:

- derive stable `dt` from the documented 2D CFL condition;
- implement deterministic `stepOnce(dt)`;
- implement `advance(frameDeltaTime)`;
- cap and report excessive substeps;
- keep play/pause outside the solver.

### 1.7 Multi-core execution

- [x] Implement persistent CPU parallel execution.

Requirements:

- use standard C++ threading;
- prefer persistent workers rather than thread creation per pass;
- partition contiguous row ranges;
- synchronize only between dependent passes;
- avoid concurrent writes to one cell or face;
- support 1, 2, 4, and automatic worker counts;
- preserve a straightforward serial reference path;
- avoid virtual dispatch in hot loops.

### 1.8 Diagnostics

- [x] Implement low-overhead diagnostics and reductions.

Include:

- total volume;
- min/max depth;
- max absolute velocities;
- selected `dt`;
- substep count;
- wet-cell count;
- correction count/volume;
- finite-value status.

Diagnostics must not require per-step heap allocation.

### 1.9 Terrain editing kernel

- [x] Implement brush and polygon terrain edits in pure C++.

Brush:

- positive/negative strength;
- radius;
- constant, linear, and smooth radial falloff;
- repeated application for continuous painting;
- min/max bed limits.

Polygon:

- add elevation;
- set elevation;
- rasterize by cell center;
- accept either vertex orientation;
- reject malformed polygons with simple explicit status or assertion as appropriate.

Initial water policy during terrain edits:

```text
Preserve water depth h; surface elevation moves with the edited bed.
```

## Phase 1 acceptance criteria

- Engine builds without Apple frameworks.
- Engine contains only `.cc/.hh`.
- `16×16`, `32×32`, `128×128`, and `512×512` cases remain finite under valid settings.
- Closed-boundary volume drift stays near floating-point roundoff when limiting/correction is inactive.
- Serial and parallel outputs remain within documented tolerance.
- No allocation occurs inside the steady-state solver substep.
- No full nonlinear/conservative SWE has been introduced.

---

# Phase 2 — Engine and terrain tests

- [x] **Phase 2 complete**

## Goal

Verify the numerical Engine before building the live UI. XCTest `.mm` files may call the public C++ headers.

### 2.1 Test target and helpers

- [x] Configure the Engine test target and minimal numerical comparison helpers.

Include:

- approximate comparisons;
- field comparison;
- finite checks;
- volume calculation;
- deterministic initial-state builders;
- explicit worker-count selection.

### 2.2 Field layout tests

- [x] Verify dimensions, indexing, row/column orientation, non-square grids, and invalid preconditions.

Primary sizes:

- `16×16`;
- `32×32`;
- non-square grids near those scales.

### 2.3 Lake-at-rest tests

- [x] Verify flat-bed and uneven-bed lake-at-rest states.

Run at:

- `16×16`;
- `32×32`;
- `128×128`.

### 2.4 Conservation tests

- [x] Verify closed-boundary mass conservation and shared-face flux consistency.

Run perturbation and terrain cases at:

- `32×32`;
- `128×128`.

### 2.5 Boundary tests

- [x] Verify reflective wall behavior, corners, and absence of leakage.

### 2.6 Wave, damping, and CFL tests

- [x] Verify bounded wave propagation, monotonic damping behavior, and invalid-step detection.

Use `32×32` for fast tests and `128×128` for longer propagation.

### 2.7 Wet/dry and positivity tests

- [x] Verify donor limiting, nonnegative water depth, and dry-cell cleanup.

Use `32×32` and `128×128` dry-island scenes.

### 2.8 Serial/parallel consistency tests

- [x] Compare serial and parallel execution over short and long runs.

Cover:

- one substep;
- 100 substeps;
- worker counts 2 and 4;
- `32×32`;
- `128×128`;
- `512×512` as a longer-running case.

### 2.9 Terrain brush tests

- [x] Verify brush coverage, falloff, accumulation, clamping, and boundary safety.

Use `32×32` and `128×128`.

### 2.10 Polygon tests

- [x] Verify triangle, rectangle, supported concave shape, vertex-order reversal, invalid input, add mode, and set mode.

Use `32×32` and `128×128`.

## Phase 2 acceptance criteria

- All tests pass from Xcode.
- Thread Sanitizer reports no Engine data race.
- Address Sanitizer reports no invalid memory access.
- `512×512` parallel stability/consistency coverage exists.
- Tests access only public Engine interfaces.
- Test code does not force product-style abstractions into the Engine.

---

# Phase 3 — macOS 2D mosaic app

- [x] **Phase 3 complete**

## Goal

Run the CPU Engine from a macOS app and display an exact one-tile-per-cell mosaic with interactive terrain tools.

### 3.1 Objective-C++ bridge

- [x] Implement a narrow bridge for state control, snapshots, diagnostics, and terrain commands.

Support:

- load/reset;
- play/pause;
- advance;
- single-step;
- immutable snapshot retrieval;
- diagnostics;
- brush command;
- polygon command.

Do not expose STL or mutable Engine arrays to Swift.

### 3.2 Runtime scheduling

- [x] Run simulation outside the SwiftUI main thread.

Requirements:

- one runtime queue/thread controlling the Engine;
- Engine-owned worker pool for parallel loops;
- controlled snapshot publication;
- safe shutdown;
- copied or double-buffered snapshots initially.

### 3.3 Snapshot data

- [x] Expose the fields required by the renderer.

Include:

- grid dimensions;
- bed elevation;
- water depth;
- free-surface elevation;
- derived cell velocity magnitude;
- wet/dry state;
- time and diagnostics.

### 3.4 Exact mosaic mapping

- [x] Implement exact cell-to-tile and pointer-to-cell mapping.

Requirements:

- no interpolation;
- crisp tiles;
- documented origin and axis directions;
- optional grid lines;
- uniform fit-to-view scaling;
- correct handling of `16×16`, `32×32`, `128×128`, and `512×512`.

### 3.5 Display modes

- [x] Implement selectable scalar visualization.

Modes:

- bed elevation;
- water depth;
- free-surface elevation;
- surface deviation;
- velocity magnitude;
- wet/dry mask.

Color maps:

- grayscale;
- blue-white;
- sand/brown;
- signed diverging debug map;
- explicit invalid-value color.

### 3.6 Simulation controls

- [x] Implement play, pause, step, reset, speed, parameters, grid preset, and diagnostics.

### 3.7 Brush editing

- [x] Implement continuous raise/lower painting.

Requirements:

- press begins;
- drag continues;
- holding still continues at a controlled rate;
- release stops;
- radius, strength, and falloff controls;
- visible brush preview;
- exact display-to-grid mapping;
- paused editing by default.

### 3.8 Polygon editing

- [x] Implement polygon entry, preview, completion, cancellation, add mode, and set mode.

Commit each completed polygon as one Engine operation.

### 3.9 Built-in scale presets

- [x] Add `16×16`, `32×32`, `128×128`, and `512×512` debug scenes.

Suggested scenes:

- `16×16 Flat`;
- `32×32 Center Bump`;
- `128×128 Uneven Bed`;
- `512×512 Coast or Channel`.

### 3.10 Display tests

- [x] Test coordinate mapping, resizing, color maps, invalid values, brush mapping, and polygon mapping at all four scales.

## Phase 3 acceptance criteria

- App launches and loads all four grid sizes.
- One tile corresponds to one cell.
- Play, pause, step, and reset work.
- UI remains responsive.
- Brush and polygon editing work.
- Diagnostics are safely displayed.
- No Metal or 3D code exists.

---

# Phase 4 — Scene persistence and gallery

- [x] **Phase 4 complete**

## Goal

Save built-in, imported, and edited scenes in a lightweight versioned format that survives relaunch.

### 4.1 Scene package

- [x] Define and document `.waterscene`.

Proposed structure:

```text
SceneName.waterscene/
├── manifest.json
├── bed_elevation.bin
├── initial_water_depth.bin
├── preview.png
└── optional/
    └── notes.md
```

Specify:

- schema version;
- byte order;
- `Float32` field storage;
- row-major orientation;
- dimensions;
- physical dimensions;
- validation;
- no transient velocity persistence by default.

### 4.2 Manifest schema

- [x] Define UUID, name, timestamps, grid/physical dimensions, initialization mode, solver parameters, resource filenames, source type, and optional description/tags.

### 4.3 Built-in scenes

- [x] Package built-in scenes as read-only resources and copy before user editing.

Include all four grid scales and at least one coast/bay scene.

### 4.4 User storage

- [x] Store scenes atomically under Application Support.

Target:

```text
~/Library/Application Support/WaterSandbox/Scenes/
```

Use UUID directories and handle missing/corrupt files cleanly.

### 4.5 Gallery catalog

- [x] Implement a rebuildable `catalog.json` index.

Store only gallery metadata and package locations. Scene packages remain authoritative.

### 4.6 Import

- [x] Implement validated `.waterscene` import, copying, collision handling, gallery insertion, and readable errors.

Plain matrix/CSV import is deferred until package import works.

### 4.7 Save and duplicate

- [x] Implement save, duplicate/Save As, restore, dirty-state warning, and preview generation.

Built-in resources are never modified in place.

### 4.8 Persistence tests

- [x] Test field/manifest round trips, non-square orientation, corruption, unsupported schema, atomic save, catalog rebuild, and copy-on-edit.

## Phase 4 acceptance criteria

- A user-created scene survives relaunch.
- Imported scenes survive relaunch.
- Built-in scenes remain read-only.
- Matrix orientation is preserved exactly.
- Invalid packages return clear errors.
- Large matrices remain ordinary files.
- All persistence and design logs remain under `Docs/`.

---

# Phase 5 — Profiling and future optimization

- [ ] **Phase 5 complete**

## Goal

Measure the CPU implementation, improve verified bottlenecks, generalize display sampling, and prepare for later Metal and 3D work without changing the weakly nonlinear model.

### 5.1 Baseline profiling

- [ ] Benchmark the CPU solver and renderer at `16×16`, `32×32`, `128×128`, and `512×512`.

Record results in `Docs/BenchmarkLog.md`:

- total substep time;
- individual pass time;
- serial/parallel speedup;
- snapshot cost;
- rendering cost;
- memory footprint;
- worker count and hardware;
- release/debug build settings.

### 5.2 CPU optimization

- [ ] Optimize only measured bottlenecks while preserving numerical tests.

Possible work:

- scratch-buffer reuse;
- alignment;
- row chunk tuning;
- reduced synchronization;
- parallel reductions;
- improved snapshot scheduling.

Keep direct loops and avoid abstraction that hides memory access.

### 5.3 Renderer scaling

- [ ] Add display-resolution policies while preserving exact mosaic mode.

Future policies:

- `IdenticalCells`;
- nearest cell;
- bilinear scalar interpolation;
- area-average downsampling.

Interpolation is visualization-only and never feeds back into the Engine.

### 5.4 Snapshot optimization

- [ ] Reduce snapshot overhead without exposing mutable Engine state.

Possible steps:

- reusable buffers;
- lower publication rate;
- batched bitmap/Canvas rendering;
- avoid one Swift object per cell.

### 5.5 Metal preparation

- [ ] Document the CPU pass graph, layouts, and golden outputs for a future Metal backend.

Requirements:

- retain CPU reference implementation;
- compare each future GPU pass against CPU golden states;
- keep the weakly nonlinear solver separate from any future full SWE solver;
- avoid creating speculative GPU abstractions before Metal work begins.

### 5.6 Future 3D preparation

- [ ] Preserve the data required by a later 3D renderer.

Required data:

- free-surface elevation;
- bed elevation;
- physical dimensions;
- wet/dry mask;
- optional velocity;
- renderer-owned interpolation policy.

## Phase 5 acceptance criteria

- Performance decisions are supported by measurements.
- Small and large grid behavior remains correct.
- CPU optimization preserves numerical tolerance.
- Exact mosaic mode remains available.
- Renderer interpolation does not affect simulation.
- CPU golden results are ready for future Metal comparison.
- The weakly nonlinear solver remains a distinct implementation.

---

## 5-Phase completion order

```text
Phase 1: Engine
    ->
Phase 2: Engine and editor tests
    ->
Phase 3: 2D macOS renderer and interaction
    ->
Phase 4: scene persistence and gallery
    ->
Phase 5: profiling, GPU preparation, and rendering optimization
```

Do not implement Metal, 3D rendering, or full nonlinear SWE during Phases 1–4.

---

## Definition of done for the 2D MVP

Phases 1–4 are complete when this workflow succeeds:

1. Launch the macOS app.
2. Open any of the four grid-size presets.
3. See one mosaic tile per simulation cell.
4. Play, pause, single-step, and reset.
5. Switch display quantities.
6. Continuously raise terrain with the sand brush.
7. Continuously lower terrain with the erase/lower brush.
8. Add or assign terrain with a polygon.
9. Save the scene under a new name.
10. Quit and relaunch.
11. Reopen it from the gallery.
12. Run the full Engine, terrain, display, and persistence test suites successfully.

Phase 5 is subsequent optimization work and is not required for the first correct 2D MVP.

---

## Deferred features

- iOS;
- WidgetKit;
- Metal compute;
- Metal rendering;
- 3D water;
- ray tracing;
- splashing and breaking waves;
- rigid-body coupling;
- GIS/GeoTIFF import;
- real-world tide calibration;
- full nonlinear/conservative SWE;
- cloud synchronization;
- SwiftData unless the gallery later needs database-style querying.
