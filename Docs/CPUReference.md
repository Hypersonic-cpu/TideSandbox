# CPU Reference Contract

This document fixes the CPU weakly nonlinear solver as the numerical reference
for a later Metal implementation. It describes current storage and pass
boundaries; it does not introduce a GPU abstraction.

## Model identity

`WeakNonlinearSolver` implements the weakly nonlinear system in
`SWE_WeakNonLinear_Math.md`: cell depth plus face velocity, free-surface pressure
gradient, linear damping, donor upwinding, conservative continuity, and wet/dry
cleanup. It has no momentum fields and no velocity-advection term. A future full
conservative SWE solver must use a distinct type and state layout rather than
changing the meaning of this reference class.

## Layout and coordinates

All fields are contiguous `double`, row-major arrays. Engine row zero is the
physical bottom row; columns increase rightward and rows increase upward.

| Quantity | Type | Extent | Linear index |
|---|---|---|---|
| Bed `b`, depth `h`, surface `eta` | `CellField` | `width × height` | `row * width + column` |
| X velocity `u`, X flux | `FaceField` | `(width + 1) × height` | `row * (width + 1) + face` |
| Y velocity `v`, Y flux | `FaceField` | `width × (height + 1)` | `row * width + column` |

Both velocity directions deliberately use the same concrete `FaceField` type;
only their extents differ. There is no inheritance because these are value
buffers, not polymorphic services. The state exposes only `const` field access.

Persistent cell storage is bed, depth, initial bed, initial depth, surface,
next depth, and donor scale. Persistent face storage is velocity and flux for
each direction. Upwind donor depths are evaluated directly and are not stored.

## CPU pass graph

One public `stepOnce` has this dependency order:

```text
CFL / finite input scan
    -> eta = h + b
    -> x/y pressure-gradient velocity kick
    -> damping and reflective boundary enforcement
    -> x/y donor-upwind face flux
    -> per-cell outgoing donor scale
    -> scale shared face flux once
    -> conservative continuity into next depth
    -> positivity cleanup and depth-buffer swap
    -> zero velocities whose updated donor is dry
    -> finite-state / velocity-bound validation
    -> public diagnostics
```

X and Y kernels within a stage are independent. Every arrow is a dependency
barrier. Row partitions execute the same kernel for one or many workers; the
serial positivity correction remains ordered so its aggregate is deterministic.
No solver substep allocates after construction.

## Material edits and movable-shoreline review

The terrain-modification work was reviewed against the same CPU reference in
August 2026. A material command builds finite, bounded candidate bed/depth
fields atomically. Initial-state edits replace reset data and restore zero time
and velocity. Paused-current edits preserve time and mix each existing face
velocity by retained connected depth divided by new connected depth. Both X and
Y paths call the same mixing function on the same `FaceField` type.

Solver faces now use hydrostatic connected-depth reconstruction over the higher
adjacent bed. A high dry neighbor blocks flow, while low dry ground retains the
downhill free-surface gradient and can be inundated. Donor upwinding consumes
the reconstructed connected depth; the shared outgoing limiter and conservative
continuity pass are unchanged. Details and edit-volume equations are fixed in
`TerrainEditingAndShoreline.md`.

The complete mathematical suite passed before the golden review: lake at rest,
closed-domain conservation with explicit edit-volume accounting, nonnegativity,
inundation, recession to exactly dry, high-ground blocking, paused momentum
mixing, 512² resume, serial/parallel equality, and 10,000 edited-domain steps.
The checked hashes below match the reviewed implementation, so no golden value
changed at this final documentation checkpoint.

## Checked CPU golden states

`Tools/GenerateCPUGolden.cc` constructs an algebraic uneven bed, a level lake
with one `0.125 m` center perturbation, zero damping, zero wet threshold, one
worker, and fixed `0.001 s` steps. FNV-1a hashes consume the little-endian bytes
of each row-major IEEE-754 `double`. `EngineTests` checks these values in both
Debug and Release builds.

| Grid | Steps | Depth hash | X-velocity hash | Y-velocity hash | Volume |
|---|---:|---|---|---|---:|
| 16 × 9 | 25 | `e53d405add0eb75c` | `eea22af86fbc9f4c` | `6b4c01398899b87a` | 288.19500000000005 |
| 128 × 128 | 25 | `911c89d32db6e6e9` | `ce31bca6c26caf5c` | `e08f64226e564d90` | 32768.165000000015 |
| 512 × 512 | 5 | `a9cd1b27cfc8bc8c` | `642e24b4a604f6d6` | `dd8244fff5566ce2` | 524288.11499999999 |

The hashes detect accidental CPU reference drift. A future GPU test should also
capture CPU output at every pass boundary listed above and compare the GPU pass
before allowing the next pass to run. Use exact comparison for indexing,
boundaries, masks, and donor choices; use documented scale-aware floating-point
tolerances for arithmetic. End-to-end GPU tests must still check conservation,
lake at rest, nonnegativity, wet/dry behavior, and these CPU checkpoints. The CPU
path remains available as a fallback and oracle.

## Rendering and future 3D data

Every `WSEngineSnapshot` is detached from mutable Engine arrays and preserves:

- bed elevation, water depth, and free-surface elevation;
- surface deviation and velocity magnitude;
- wet/dry mask;
- grid and physical domain dimensions;
- diagnostics and coordinate orientation.

This is sufficient for a height-field 3D surface and terrain mesh. A later 3D
renderer may add copied face-velocity components if vector visualization needs
them; it must not borrow Engine storage. Exact, nearest, bilinear-scalar, and
area-average policies belong to the renderer. No interpolated value is ever fed
back into the solver.
