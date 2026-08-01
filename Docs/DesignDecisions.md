# TideSandbox Design Decisions

## DD-001 — Weakly nonlinear reference model

The CPU Engine stores cell-centered water depth and face-centered velocity. It
does not store momentum and does not implement velocity advection. Free-surface
elevation, outgoing limiter scales, and face fluxes are reusable scratch fields;
upwind donor depth is consumed directly while constructing each flux. This keeps the implementation aligned with
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

## DD-008 — Versioned package with ordinary field files

`.waterscene` is a directory package, not a monolithic archive or database.
Metadata is human-readable JSON, while bed and initial depth are portable,
little-endian `Float32` files. This preserves exact row-major orientation,
supports memory-mapped reads, keeps 512² data independently inspectable, and
leaves room for future optional resources without changing the numerical core.

Schema markers explicitly state byte order, scalar type, and row order. Readers
fail closed on unsupported encodings and reject paths or symbolic links that
could escape a package. Velocity is deliberately absent because it is transient
solver state rather than scene initialization data.

## DD-009 — Packages authoritative, catalog disposable

An actor serializes repository mutations. A save writes and validates a hidden
sibling package, then atomically installs it on the same volume. `catalog.json`
contains only gallery metadata and relative user-package locations; it is
rebuilt whenever it is absent, corrupt, stale, or inconsistent with a manifest.
No user field data exists only in the catalog.

Built-in packages live in the signed app bundle and are represented as read-only
documents. Saving one always creates a new UUID under Application Support.
Imported packages are validated and rewritten into app-owned storage; an ID
collision also receives a new UUID. These rules make ownership explicit without
subclassing scene types: source and mutability are data properties shared by the
same `SceneDocument` value type.

## DD-010 — Opt-in profiling and measured buffer removal

Performance counters are disabled by default and use direct steady-clock timing
around the existing pass boundaries when enabled. Baselines showed that unused
upwind-depth face writes and multi-copy snapshot conversion were material at
512². Removing those arrays does not change any arithmetic consumed by a later
pass. Snapshot buffers are still wholly detached from Engine state, but ownership
is transferred to immutable `NSData` instead of copied a second time.

## DD-011 — Renderer-owned sampling policies

Exact mosaic mode remains one raster pixel per simulation cell. Nearest-cell and
bilinear-scalar policies sample at destination pixel centers; area-average uses
exact source/destination overlap weights and only downsamples. Every policy
starts from a copied scalar snapshot, performs the sole bottom-up to top-down row
conversion, and produces a non-interpolated `CGImage`. These value policies use
one enum rather than a class hierarchy because they are closed, stateless
algorithms with no substitutable object lifecycle.

## DD-012 — Dual display renderers over one immutable snapshot

The 2D and 3D views are separate renderers selected by one closed
`ViewportMode`. The 2D branch keeps `MosaicGridView` and its exact CPU raster,
sampling, row-flip, grid, overlay, and pointer-mapping behavior. The 3D branch
uses SwiftUI → `NSViewRepresentable` → `MTKView` → `HeightFieldRenderer`. Only
the selected branch exists, so an inactive renderer performs no rasterization,
buffer upload, or draw work.

Both branches consume the same completed, immutable `SimulationSnapshot`.
Metal owns reusable topology and three rotating bed/depth buffer pairs; a
snapshot generation is uploaded at most once and camera-only redraws do not
re-upload scalar fields. While the simulation is paused, Metal renders on
demand. While it is playing, the view presents the most recent immutable
buffers at the display cadence, independently of the lower snapshot-publication
cadence. This keeps camera motion smooth without increasing solver or snapshot
work.

The Engine and Objective-C bridge have no Metal, MetalKit, AppKit, or SwiftUI
dependency, and the renderer never writes simulation state. Camera and display
settings are session UI state and do not enter `.waterscene` persistence or
dirty-state accounting.

Inheritance remains limited to required framework substitution:
`HeightFieldRenderer` conforms through `NSObject`/`MTKViewDelegate`, and
`InteractiveMTKView` subclasses `MTKView` to receive AppKit pointer and keyboard
events. Meshes, camera state, settings, and policies remain value structs or
enums; no domain hierarchy or virtual abstraction is introduced.
