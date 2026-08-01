# Terrain Editing and Shoreline Contract

This document defines TideSandbox's authoritative material-editing semantics,
shoreline reconstruction, display scope, and 2D/3D interaction contract. The
Engine owns every committed edit. Renderers consume immutable snapshots and
never maintain an alternate terrain or water state.

## Coordinates and edit geometry

Engine/world coordinates cover the closed physical rectangle
`[0, domainWidth] × [0, domainHeight]`. Cell `(column, row)` is centered at:

```text
x = (column + 0.5) * dx
y = (row + 0.5) * dy
```

Columns increase rightward and rows increase upward. The 2D view performs the
single top-left display-axis conversion. The 3D view maps Engine `x` to world
`x`, Engine `y` to world `z`, and elevation to world `y`.

Brush centers must be finite and inside the closed world rectangle. Radius must
be finite and positive. Constant, linear, and smooth falloffs produce a weight
in `[0, 1]` at each cell center. Polygon vertices use the same world bounds;
polygons require at least three vertices, nonzero area, distinct adjacent
vertices, and no self-intersections. Convex and concave winding orders are both
valid. Invalid commands are rejected atomically.

Every candidate cell is constrained by:

```text
worldMinimumElevation <= b
0 <= h
b + h <= worldMaximumElevation
```

Clamping is reported in `TerrainEditResult`. All candidate fields are built in
scratch storage and committed only after the complete command validates.

## Edit contexts

`EditTarget.initialState` edits the stored initial bed/depth fields. A
successful command then calls the ordinary reset path: current bed and depth
become the edited initial fields, both same-typed `FaceField` velocity arrays
become zero, and simulation time becomes zero. No solver step is run.

`EditTarget.pausedCurrentState` edits the current bed/depth fields in place. The
UI pauses before submitting the command. Simulation time is preserved exactly,
and face velocity is mixed according to retained connected water described
below. The stored initial state is unchanged.

Selecting any edit tool pauses immediately in either viewport. Pointer-down
publishes the first brush command immediately; a held brush repeats on the
runtime's 60 Hz editing cadence. Polygon Apply publishes immediately. An
unfinished polygon and the selected tool survive 2D/3D switches in physical
world coordinates. Preset/scene load and explicit Cancel clear it.

## Four material operations

For requested weighted amount `a`, old bed `b`, old depth `h`, and maximum
surface elevation `etaMax`:

| Operation | New bed/depth | Material meaning |
|---|---|---|
| Add sand | `b' = min(b+a, etaMax)`, `h' = max(0, h-(b'-b))` | Raises terrain, preserves `eta=b+h` while submerged, then displaces/deletes water as the cell emerges. |
| Remove sand | `b' = max(b-a, bMin)`, `h' = min(h+(b-b'), etaMax-b')` | Lowers terrain and fills the excavation with newly introduced zero-velocity water, preserving surface elevation where unclamped. |
| Add water | `b'=b`, `h'=min(h+a, etaMax-b)` | Adds zero-momentum water and mixes existing face velocity down. |
| Remove water | `b'=b`, `h'=max(0, h-a)` | Removes water without creating negative depth; retained water keeps its velocity unless a connected face becomes dry. |

`changedCells`, `changedFaces`, `sandVolumeDelta`, `waterVolumeDelta`, `clamped`,
`newlyWetCells`, and `newlyDryCells` describe the committed result. An amount
of zero or a fully clamped command is a successful no-op and publishes no false
edit generation.

## Volume accounting

Cell area is `dx * dy`. The edit result sums exact per-cell bed and depth
changes:

```text
sandVolumeDelta  = sum((b' - b) * cellArea)
waterVolumeDelta = sum((h' - h) * cellArea)
```

Equivalently, the post-edit water volume is:

```text
VAfter = VBefore
       + directlyAddedWater
       - directlyRemovedWater
       + zeroVelocityWaterFromSandRemoval
       - waterDeletedBySandAddition
```

The solver is closed-domain and conserves `VAfter` to the documented
floating-point tolerance. Tests accumulate `waterVolumeDelta` over mixed edit
sequences and use that accounted value as the 10,000-step conservation oracle.

## Momentum mixing on MAC faces

TideSandbox stores velocity, not momentum. Both directions use the same
concrete `FaceField` type with different MAC extents. For a face shared by two
cells, the edit path reconstructs water connected above the higher adjacent
bed:

```text
faceBed = max(bFirst, bSecond)
connectedDepth(b, h) = max(0, b + h - faceBed)
```

Let `dNew` be the mean connected depth after the edit and `dRetained` the mean
connected depth belonging to water that existed before the edit. Then:

```text
uNew = 0                                      when dNew <= minimumWetDepth
uNew = uOld * clamp(dRetained / dNew, 0, 1) otherwise
```

The same function is used for X and Y faces. Add water and sand removal dilute
velocity with zero-momentum water. Add sand and water removal retain velocity
for remaining connected water, but close newly disconnected/dry faces. Domain
normal velocities remain zero. This is a deterministic velocity-form mixing
rule, not a full nonlinear momentum solver.

## Movable shoreline reconstruction

Each solver face uses hydrostatic reconstruction with the higher adjacent bed:

```text
faceBed = max(bLeft, bRight)
hLeft*  = max(0, etaLeft  - faceBed)
hRight* = max(0, etaRight - faceBed)
```

Connected depths at or below `minimumWetDepth` become exactly zero. A face with
two zero connected depths closes and its velocity becomes zero. A dry neighbor
whose bed is below the wet free surface retains a downhill surface gradient and
can be inundated; high dry terrain at or above that surface blocks flow.

Flux uses the reconstructed upwind connected depth selected by face-velocity
sign. The per-cell outgoing donor limiter scales each shared face flux once,
the continuity pass remains conservative, and the post-step cleanup enforces
nonnegative depth and zeros velocities with dry updated donors. This supports
advancing and retreating shorelines without a separate dry-neighbor heuristic.

After a paused-state edit, `stateWasEdited()` refreshes diagnostics before
resume. Required invariants after edits and steps are finite fields, bounded bed
and surface, nonnegative depth, zero closed/disconnected face velocity,
unchanged time during editing, and closed-domain conservation from the
explicitly accounted post-edit volume.

## Reset, load, and save behavior

Reset always restores the stored initial bed/depth pair, zeros both velocity
fields, and returns time to zero. Initial-state edits therefore become the new
reset state. Paused-current edits do not change reset data unless the user saves
the paused current state explicitly as a scene's new initial state.

`.waterscene` packages persist bed elevation and initial water depth, along with
world limits and solver configuration. Velocity and UI session state are never
persisted. Loading a preset or scene pauses, clears transient brush/polygon
feedback, resets camera framing, rebuilds stable decorative ranges, and loads
one authoritative Engine state.

## 2D decorative composite and annotations

Decorative composite is a 2D-only display mode. It does not change simulation
values and is semantically separate from quantitative scalar modes.

The composite has three ordered layers:

1. land elevation from pale yellow through a light middle to pale green;
2. a configured linear-light submerged-bed cooling contribution plus an
   optical water overlay whose opacity is `1 - exp(-h / hClear)` and whose hue
   progresses from pale cyan to deep blue;
3. independent four-neighbor shoreline treatment: pale cyan on the wet side
   and wet-sand color on the dry side.

Diagonal-only contact is not a shoreline. The shoreline pass is independent of
water opacity, so very shallow wet cells remain legible without a dark outline.
Configuration stores stable scene ranges for land and depth, optical thresholds,
`submergedBedCoolingStrength`, shore highlight strength, and wet-sand strength.
Edits do not continuously rerange the map.

The optional annotation overlay contains the decorative land/water scales,
actual configured shoreline colors, and a physical horizontal scale bar. In a
quantitative depth view the legend uses the exact configured depth mapping.
Scale length is a `1/2/5 × 10^n` value no larger than the target map-width
fraction. One `Map annotations` toggle hides or restores legends, shoreline key,
and scale bar together.

No decorative composite color, legend, or scale-bar code is used by the 3D
renderer. The existing 3D terrain/water palette, lighting, opacity, wet mask,
wireframes, and debug materials remain unchanged.

## 3D picking and interaction routing

The Metal view uses the current orbit-camera view-projection matrix and latest
immutable snapshot. A pointer is unprojected to a camera ray. A regular-grid 2D
DDA visits only crossed height-field cells in deterministic order, intersects
the two terrain triangles and visible wet portions of the two water triangles,
and returns the nearest valid hit. Mixed wet/dry water triangles validate
interpolated depth against the wet threshold before accepting a water hit.

No full-frame readback occurs, and drag events do not brute-force all triangles.
Misses outside the rendered domain are rejected; clamping occurs only after a
valid triangle hit. The picker converts world `(x,z)` back to Engine physical
`(x,y)` and sends only that horizontal coordinate to the same view-model/runtime
material command used by 2D.

Interaction is unambiguous:

- Inspect: primary drag orbits, Shift-primary drag pans, scroll zooms, and
  double-click fits.
- Edit tools: primary press/drag edits through the shared Engine path.
- Polygon: primary click adds a picked world-space point.
- While editing: Option-primary retains orbit/Shift-pan; the middle button pans.
- Camera keys `1`–`4` select presets and `F` fits.

Brush radius is drawn as a neutral dashed horizontal world-space outline at the
picked visible elevation. Polygon points and edges use the same separate
`CAShapeLayer`. Preview colors are never baked into terrain/water shaders.
Committed geometry changes only when a new Engine snapshot arrives.

## 3D snapshot and active-viewport contract

For unchanged dimensions, `HeightFieldRenderer.update(snapshot:)` rotates among
preallocated scalar buffer pairs and copies only bed and water-depth values.
It reuses mesh topology, index buffer, pipelines, scalar allocation, and camera.
Dimension changes alone rebuild topology and refit. Wet-to-dry cells disappear
from the water fragment pass through the existing wet threshold.

`SimulationViewport` is a Swift `switch`, not a stack of hidden renderers:

- in 2D, no `HeightFieldRenderer` exists, so no Metal update/upload/draw or
  hidden display loop can occur;
- in 3D, no `MosaicGridView` exists, so no mosaic raster, scalar resample, or 2D
  pixel-buffer construction can occur;
- switching constructs the newly active view from the latest shared snapshot;
  camera session state and unfinished world-space polygon state survive.

DEBUG-only counters cover 2D rasterization/resampling and 3D snapshot/draw
calls; Release methods are no-ops. Tests prove zero cross-renderer activity,
topology reuse, scalar-buffer changes, camera preservation, and exact shared
state parity across rapid mode changes.

## Verification contract

The scientific suite covers all four material operations, brush and polygon,
initial and paused-current targets, all brush falloffs, clamping, malformed
geometry, momentum mixing, volume accounting, newly wet/dry counts, reset,
resume stability, lake at rest, high-ground blocking, inundation, recession,
16²/32²/128²/512² grids, serial/parallel equality, and a 10,000-step edited
closed-domain smoke test.

2D/3D parity tests compare bed, depth, surface, velocity magnitude, wet mask,
diagnostics, and time at the Swift boundary, plus exact `b`, `h`, `velX`,
`velY`, result accounting, wet/dry counts, and reset state in the C++ Engine.
Metal tests read the actual active scalar buffers and verify that value-only
edits do not rebuild topology or mutate camera state. Retained XCUITest
attachments cover water-surface removal to dryness, brush footprint, polygon
preview, committed terrain relief, shared 2D composite state, and camera state
after returning to 3D.
