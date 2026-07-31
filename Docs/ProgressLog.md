# WaterSandbox Progress Log

## 2026-07-31 — Phase 1 complete

- Added contiguous row-major cell and face fields. Both velocity components use the
  same `FaceField` value type with their MAC-grid extents (`(width + 1) × height`
  and `width × (height + 1)`).
- Added initialization from a level surface or explicit nonnegative depth, plus
  allocation-free same-grid reset.
- Implemented the weakly nonlinear kick-drift solver described by
  `SWE_WeakNonLinear_Math.md`: free-surface pressure gradient, exponential linear
  damping, reflective walls, first-order donor upwinding, shared face fluxes,
  donor outflow limiting, conservative depth update, and wet/dry cleanup.
- Added 2D CFL frame substepping, explicit-step validation, diagnostics, and a
  persistent standard-C++ worker pool. The serial and parallel paths execute the
  same row kernels.
- Added pure C++ brush and polygon terrain operations. Edits preserve water depth.
- Verified strict C++20 compilation and Phase 1 acceptance smoke coverage at
  non-square, 32², 128², and 512² sizes. The smoke run checked lake-at-rest,
  conservation, positivity, serial/parallel equality, terrain edits, malformed
  polygon rejection, and zero heap allocations during a warmed substep.

Verification commands:

```sh
clang++ -std=c++20 -Wall -Wextra -Wpedantic -Wconversion -Wshadow -Werror \
  -I TideSandbox/Engine -c TideSandbox/Engine/*.cc

clang++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Wconversion -Wshadow -Werror \
  -I TideSandbox/Engine /private/tmp/tide_phase1_smoke.cc \
  TideSandbox/Engine/*.cc -o /private/tmp/tide_phase1_smoke
/private/tmp/tide_phase1_smoke
```

Result: `phase1 smoke: passed`.

## 2026-08-01 — Phase 2 complete

- Replaced the template unit test with a formal Objective-C++ XCTest suite in
  `TideSandboxTests/EngineTests.mm`. Tests use only public Engine headers and
  public read-only state access.
- Tests are driven by numerical invariants rather than example-only values:
  machine-epsilon-scaled closed-domain conservation, exact lake-at-rest balance,
  the analytical initial CFL time step, exact exponential damping after one
  pressure kick, nonnegativity, finite-state checks, reflective zero-normal-flow
  boundaries, and bit-identical serial/parallel row kernels.
- Covered 16², 32², 128², 512², and non-square fields; flat and uneven terrain;
  wet/dry islands; worker counts 1, 2, and 4; all brush falloffs; clamping and
  accumulation; convex/concave polygons in both orientations; add/set modes; and
  malformed polygon rejection.
- Removed the template SwiftUI preview declaration because sandboxed macro
  expansion prevented command-line builds; previews will use ordinary fixtures
  when the real UI is present.

Verification:

```text
XCTest (Debug):          9/9 passed, 8.789 s
Address Sanitizer:      9/9 passed, 14.625 s
Thread Sanitizer:       9/9 passed, 86.930 s
512² consistency case: passed with worker counts 2 and 4
```

The sanitizer runs reported no invalid memory accesses and no Engine data races.

## 2026-08-01 — Phase 3 complete

- Added a narrow Objective-C++ bridge that keeps STL and mutable Engine storage
  out of Swift. It owns load/reset, play state, stepping, configuration, copied
  immutable snapshots, diagnostics, and terrain commands.
- Added a single serial runtime queue around the bridge. The Engine retains its
  own persistent worker pool, snapshots publish at a controlled rate, continuous
  brushing ticks at 60 Hz, and shutdown cancels the timer before releasing the
  solver. Snapshot callback installation and invocation both occur on the
  runtime queue.
- Added exact fit-to-view grid mapping and a one-source-pixel-per-cell RGBA
  raster with nearest-neighbor display. The only axis conversion is the
  documented Engine-bottom-left to SwiftUI-top-left row flip.
- Added six scalar modes, four palettes, an explicit invalid-value color,
  optional grid lines, play/pause/step/reset, speed and solver parameters,
  diagnostics, continuous raise/lower painting, and polygon add/set tools.
- Added finite level-water presets at 16², 32², 128², and 512². Scientific
  XCTest coverage verifies roundoff-bounded level surfaces, finite nonnegative
  depth, bridge round trips, coordinate inverses, raster byte placement, color
  endpoints, invalid values, and brush/polygon mapping at every required scale.
- Added signed macOS UI tests for launch, controls, and loading all four presets.
  UI attachments are window-scoped so they never capture the primary display.
- Added `.gitignore` coverage for Xcode, SwiftPM, coverage, and standalone C++
  build artifacts, and removed unused iOS/visionOS target settings.

Verification:

```text
Debug app build:          passed
Release app build:        passed
Engine/bridge/display:    16/16 passed, 10.895 s
Signed macOS UI suite:     4/4 passed, 34.905 s
No Metal/3D source scan:  passed
git diff --check:          passed
```

Visual verification was performed on display 2 only. The 32² view showed crisp,
aligned cell tiles and grid lines. A retained window-only 512² coast/channel
capture confirmed the selected preset, 512 × 512 diagnostic, uninterpolated
mosaic, legible floating controls, and non-overlapping inspector layout.

## 2026-08-01 — Phase 4 complete

- Defined and documented schema-1 `.waterscene` packages in
  `Docs/WaterSceneFormat.md`: explicit little-endian IEEE-754 `Float32` fields,
  bottom-to-top row-major orientation, versioned JSON metadata, PNG preview, and
  no transient velocity persistence.
- Added strict package validation for schema/encoding, dimensions and overflow,
  physical sizes, solver parameters, safe unique resource names, symbolic links,
  exact field byte counts, finite bed values, nonnegative finite depth, UTF-8
  notes, and decodable single-image PNG previews.
- Added same-volume temporary-package validation and atomic directory
  replacement. User/imported scenes live in UUID-named packages under
  Application Support; large matrices remain ordinary binary files.
- Added an actor-owned repository with a package-authoritative, rebuildable
  `catalog.json`. Missing, corrupt, stale, or mismatched catalog metadata causes
  a deterministic rebuild from valid scene packages.
- Added validated package import with security-scoped access, UUID collision
  handling, source tagging, durable catalog insertion, and readable errors.
- Generated four reproducible application-bundle packages at 16², 32², 128²,
  and 512², including a coast/channel scene. Fixed IDs and a committed generator
  make their manifests, fields, and previews reproducible. Built-ins open
  read-only and Save creates a user copy.
- Added a preview gallery, exported macOS document type, Save, Save As,
  overwrite-save, restore, import, and dirty-state confirmation. Gallery and
  file operations run outside the simulation runtime and do not expose Engine
  state.
- Added isolated signed UI persistence storage for tests, so relaunch coverage
  never changes ordinary user scenes.

Verification:

```text
Persistence XCTest:       7/7 passed, 1.769 s
Complete product XCTest: 23/23 passed, 10.828 s
Signed macOS UI suite:     6/6 passed, 69.141 s
Focused Save/Save As:      passed, 1.032 s
Debug app build:           passed
Release app build:         passed
Info.plist validation:     passed
git diff --check:          passed
```

After the secondary display was disconnected, visual verification continued on
the remaining main display as directed. The window-only gallery capture showed
five durable scenes after relaunch, correctly oriented previews, lock badges on
all four built-ins, an unlocked user copy, and an unclipped responsive layout.

## 2026-08-01 — Phase 5 complete

- Added opt-in Engine pass counters and reproducible Debug/Release benchmark
  tools for solver, snapshot, and renderer work at 16², 32², 128², and 512².
  Measurements use repeated batches, medians, and median absolute deviations;
  hardware, compiler flags, worker count, memory, and every pass are recorded in
  `BenchmarkLog.md`.
- Optimized only measured costs. Removing write-only upwind-depth arrays reduced
  512² Engine field storage by 15.4% and the Release four-worker end-to-end step
  by 12.1%. One-pass ownership-transferred snapshot buffers reduced publication
  cost by 58.5% while remaining detached from mutable Engine state.
- Added exact, nearest-cell, bilinear-scalar, and exact-overlap area-average
  display policies. Exact mode remains one raster pixel per Engine cell;
  area-average only downsamples. Analytical tests verify planar bilinear values,
  global-mean preservation, invalid propagation, row orientation, dimensions,
  and that rendering never mutates simulation values.
- Documented the CPU reference layout and dependency graph in `CPUReference.md`.
  A reproducible generator and XCTest lock depth and both same-typed `FaceField`
  velocity components at non-square, 128², and 512² golden checkpoints.
- Preserved copied bed, depth, surface, deviation, velocity magnitude, wet mask,
  grid dimensions, and physical dimensions for a future renderer. Metal, 3D,
  momentum storage, and full nonlinear SWE remain deliberately absent.

Verification:

```text
Strict standalone C++20:      passed with warnings as errors
Complete product XCTest:     28/28 passed
AddressSanitizer XCTest:     28/28 passed
Normally signed UI suite:     7/7 passed, 98.605 s
Signed Debug app build:       passed as part of both XCTest runs
Signed Release app build:     passed
CPU goldens Debug/Release:    identical
Benchmark reproduction:       Debug and Release passed
git diff --check:              passed
```

Visual verification used the remaining main display as directed. The retained
window-only bilinear capture showed a smooth scalar field beneath cell-aligned
grid lines, a readable Sampling picker, and no overlap or clipping in the
floating toolbar or inspector. Signed UI automation exercised all four policies
without changing the 32 × 32 Engine diagnostic.

## 2026-08-01 — 3D Phase 0 baseline locked

- Locked the unchanged 2D product at commit `2c8341e` before introducing a
  switchable viewport or any Metal source.
- Added a reproducible fixed-step default-scene checkpoint. After 120 frames at
  1/60 second, simulated time is 1.9999999999999978 s, volume is
  997.94238066673302 m³, maximum depth is 1.0000000096825417 m, maximum speed is
  9.1571385829100175e-08 m/s, and all 1024 cells remain wet.
- Captured and inspected a 1960 × 1424 window-only default 2D screenshot after
  play, pause, step, and reset. Its SHA-256 and result-bundle provenance are in
  `Render3DBaseline.md`.

Verification:

```text
Complete product XCTest: 28/28 passed
Normally signed UI suite: 7/7 passed, 99.313 s
Strict baseline recorder: passed with warnings as errors
```

## 2026-08-01 — 3D Phase 1 viewport abstraction complete

- Added the closed `ViewportMode` enum to the existing view model and a small
  `SimulationViewport` switch. The 2D branch still instantiates the original
  `MosaicGridView` without sharing or replacing its raster implementation.
- Added a compact 2D/3D segmented picker. The launch default remains 2D, and
  changing modes does not invoke load, reset, pause, stepping, persistence, or
  dirty-state paths.
- Added explicit semantic accessibility elements for both viewport branches and
  a UI test that verifies 2D → 3D placeholder → 2D switching while the 32 × 32
  grid diagnostic remains unchanged.

Verification:

```text
Complete product XCTest: 28/28 passed
Normally signed UI suite: 8/8 passed, 112.577 s
Existing 2D implementation: retained in MosaicGridView.swift
```
