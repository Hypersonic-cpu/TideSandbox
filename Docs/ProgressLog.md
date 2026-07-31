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
