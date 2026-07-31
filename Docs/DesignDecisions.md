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

## DD-006 — Narrow copied-snapshot bridge

Swift receives Objective-C objects and immutable copied `NSData` fields, never
STL containers or mutable Engine arrays. One serial runtime queue is the sole
owner of bridge operations and callback state; the SwiftUI main actor receives
only completed `SimulationSnapshot` values. This makes queue ownership explicit
and keeps the numerical core independent of AppKit and SwiftUI.

The bridge and Engine use constant values and `const` references by default;
mutable references are limited to operations that actually update solver state.
Both velocity directions remain the same concrete `FaceField` type. Inheritance
is used only where there is a genuine substitutable interface, rather than as a
mechanism for sharing incidental storage behavior.

## DD-007 — Exact CPU mosaic

The renderer creates an RGBA image whose width and height exactly equal the grid
dimensions, so each source pixel is one simulation cell. SwiftUI scales that
image uniformly with interpolation disabled. Engine rows increase upward;
display rows increase downward, so raster construction performs exactly one
vertical row reversal. Pointer mapping applies the inverse transform.

Grid lines are drawn only when a displayed tile is at least four points wide.
They remain an optional inspection aid at small scales without obscuring the
512² scalar field.
