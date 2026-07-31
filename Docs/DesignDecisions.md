# WaterSandbox Design Decisions

## DD-001 — Weakly nonlinear reference model

The CPU Engine stores cell-centered water depth and face-centered velocity. It
does not store momentum and does not implement velocity advection. Free-surface
elevation, upwind depths, outgoing limiter scales, and face fluxes are reusable
scratch fields. This keeps the implementation aligned with
`SWE_WeakNonLinear_Math.md` and separate from a future full conservative SWE.

## DD-002 — Concrete fields and shared velocity type

The Engine uses two small concrete row-major field types: `CellField` and
`FaceField`. Both x- and y-velocity fields are `FaceField`; only their extents
differ. This expresses their common physical role without inheritance or virtual
dispatch in hot loops. Inheritance is reserved for genuine substitutable
interfaces; none is needed in the Phase 1 numerical core.

## DD-003 — Coordinate convention

Cell `(column, row)` maps to the physical cell center
`((column + 0.5) * dx, (row + 0.5) * dy)`. Columns increase to the right and rows
increase upward in Engine/world coordinates. Swift display mapping will perform
the single required vertical-axis conversion for a top-left view coordinate
system.

## DD-004 — Wet/dry pressure faces

At a wet/dry face, a dry bed at or above the wet free surface does not create an
unphysical pressure slope. A lower dry bed retains the downhill surface gradient
and can be inundated. Faces between two dry cells are zeroed. The mass update
still uses donor upwinding and the documented conservative outgoing limiter.

## DD-005 — Persistent CPU work scheduling

`ParallelFor` owns long-lived `std::jthread` workers. Each pass publishes a
function pointer and stack-owned context, partitions contiguous row ranges, and
waits at the dependency boundary. Dispatch performs no heap allocation. Worker
count is fixed for a solver lifetime so pool ownership and shutdown remain clear.
