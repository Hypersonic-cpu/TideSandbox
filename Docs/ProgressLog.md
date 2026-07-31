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
