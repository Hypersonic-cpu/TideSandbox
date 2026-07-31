# TideSandbox Terrain Editing & Movable Shoreline Fix Plan

> Repository: `Hypersonic-cpu/TideSandbox`  
> Scope: CPU weakly nonlinear solver, editing shared by 2D/3D, movable shoreline, 2D composite map and legends  
> Existing 3D status: preserve the current Metal height-field renderer, dynamic terrain/water surfaces, orbit camera, and debug controls  
> Deferred: full conservative SWE, nonlinear momentum advection, new 3D material/color design, 3D optical redesign, splashing

## 0. Mandatory constraints

1. Read `Docs/SWE_WeakNonLinear_Math.md`, `Docs/CPUReference.md`, `Docs/DesignDecisions.md`, and `Docs/SWE_2D_PLAN.md` before modifying solver mathematics.
2. Keep `WeakNonlinearSolver` weakly nonlinear: cell-centered `h`, face-centered `u/v`, no `((u·grad)u)`, no `[h,hu,hv]` state conversion.
3. Keep `Engine/` a compact C++ HPC library: `.cc/.hh`, contiguous arrays, direct loops, no substep allocation, assertions/fail-fast for programmer errors, non-exception control flow, no unnecessary virtual/interface layers.
4. While an edit view is active, the PDE solver never advances. Only direct state mutation and snapshot/render refresh occur.
5. All decorative palette, shoreline color, colorscale, and map-scale work in this plan is **2D-only**. Do not modify the existing 3D terrain/water material colors, lighting, opacity model, Fresnel/specular behavior, or camera behavior.
6. Terrain and water editing semantics are shared by 2D and 3D because both views consume the same Engine state. Edits made in either view must produce the same numerical result.
7. Keep exactly one active viewport renderer:
   - in 2D mode, do not create, update, draw, or upload buffers for the 3D Metal renderer;
   - in 3D mode, do not rasterize or resample the 2D mosaic;
   - switching modes presents the latest shared snapshot to the newly active renderer once.
8. Store every implementation, benchmark, debugging, and design log under `Docs/`.
9. Make small Git commits after coherent changes pass their relevant tests.
10. Use one checkbox per numbered task and update it after verification.


## 0.1 Selective test policy for Codex

Do not rerun the entire existing test suite after every task or commit. Use an impact-based test selection policy.

### Always run

Run these whenever Engine editing or shoreline mathematics changes:

- newly added edit-operation tests;
- lake-at-rest tests relevant to the changed wet/dry behavior;
- nonnegative-depth and outgoing-flux-limiter tests;
- edit-volume accounting;
- finite-state checks;
- serial/parallel consistency for the changed kernel;
- one resume-after-edit stability case.

Run these whenever rendering or interaction changes:

- the directly affected 2D or 3D unit tests;
- one focused UI scenario covering the modified interaction;
- snapshot-generation and solver-time-not-advanced assertions.

### Usually skip when untouched

Do not rerun these after unrelated small changes:

- gallery browsing and unrelated scene-library UI tests;
- camera algebra/preset/fit tests when camera code is unchanged;
- existing 3D lighting, shader-material, wireframe, normal, and domain-bound tests when 3D materials/debug code is unchanged;
- unrelated scalar display modes when only the decorative composite changes;
- renderer sampling-policy tests when resampling code is unchanged;
- persistence corruption/import tests when the scene schema and package I/O are unchanged;
- CPU performance benchmarks after documentation-only, color-only, or UI-label changes;
- `512×512` long-running tests after every small commit.

### Escalation rules

Run broader tests only when one of these conditions applies:

- a shared Engine data layout or public bridge API changes;
- wet/dry or flux mathematics changes;
- snapshot contents or generation semantics change;
- scene manifest/schema changes;
- viewport lifecycle or active-renderer routing changes;
- a focused test fails;
- sanitizers report an issue;
- the implementation changes behavior outside the task's intended module.

### Full-suite checkpoints

Run the complete product XCTest suite only at these checkpoints:

1. after Phase 4 movable-shoreline mathematics is complete;
2. after Phase 6 shared 3D editing and active-viewport routing is complete;
3. once at final Definition of Done.

Run the normally signed UI suite only once near final completion, plus focused UI scenarios during development.

Run Thread Sanitizer and Address Sanitizer once after Engine edit/shoreline work is stable, not after every phase.

Run the full `16×16`, `32×32`, `128×128`, `512×512` matrix only for the final numerical implementation. During development:

- `16×16` or `32×32`: fast correctness/debugging;
- `128×128`: representative numerical and parallel coverage;
- `512×512`: only after relevant performance, allocation, large-grid, or final-regression changes.

Every commit still requires its relevant focused tests to pass. “Skip” means intentionally omit tests outside the changed dependency surface, not ignore failures or remove coverage.

## 1. Required edit contexts

### Initial-state editing

- Entering edit mode restores/selects the editable initial state.
- Simulation time is zero.
- `velX = velY = 0`.
- Brush/polygon edits immediately refresh the snapshot.
- Play starts from the edited state with zero velocity.
- Reset returns to the latest committed edited initial state.

### Paused-current-state editing

- Pause a running simulation and retain current `b`, `h`, `velX`, `velY`, and time.
- Solver remains stopped throughout editing.
- Edits modify the paused current state.
- Resume starts from the edited state after wet/dry and face-velocity sanitation.
- Reset still returns to the stored initial state.

The UI behavior and brush/polygon semantics are identical in both contexts; only the target state differs.


## 1.1 Current 3D integration facts to preserve

The current project already has:

- `SimulationViewport` switching between `MosaicGridView` and `HeightField3DView`;
- a Metal `HeightFieldRenderer` that receives `bedElevation` and `waterDepth` from `SimulationSnapshot`;
- terrain and water vertex positions derived from the same shared snapshot;
- snapshot-generation checks that avoid duplicate 3D buffer uploads;
- orbit/pan/zoom camera state and existing 3D debug rendering;
- terrain tools currently disabled while the 3D viewport is active.

This plan must remove only the 3D editing restriction. It must not redesign the 3D renderer or its colors.

The shared-state rule is:

```text
Engine edit
-> publish one new snapshot generation
-> active viewport only consumes that snapshot
-> inactive viewport performs no render work
```

When the user later switches viewport, the newly active renderer consumes the latest snapshot and shows the same edited terrain/water state.

## 2. World limits and invariants

For each cell:

```text
eta = b + h
worldMinimumElevation <= b <= worldMaximumElevation
0 <= h
eta <= worldMaximumElevation
```

Rules:

- lowering sand stops at `worldMinimumElevation`;
- raising sand stops at `worldMaximumElevation`;
- removing water stops at `h = 0`;
- adding water stops when `eta = worldMaximumElevation`.

Persist these scene parameters with backward-compatible defaults.

## 3. Cell edit semantics

Let old state be `(b,h)` and final state `(b',h')`.

### Add sand

```text
b' = clamp(b + requestedSand, worldMinimumElevation, worldMaximumElevation)
db = b' - b
h' = max(0, h - db)
```

- Added sand deletes equal water depth.
- While `db <= h`, `eta' = eta`.
- Removed water carries existing local velocity.
- If the cell emerges, `h'=0` and disconnected face velocities become zero.

### Remove sand

```text
b' = clamp(b - requestedExcavation, worldMinimumElevation, worldMaximumElevation)
db = b - b'
h' = min(h + db, worldMaximumElevation - b')
```

- Excavated volume is immediately filled with zero-horizontal-velocity water.
- Before upper clamping, `eta' = eta`.
- Existing water momentum is retained and diluted by the new zero-velocity water.

### Add water

```text
h' = min(h + requestedWater, worldMaximumElevation - b)
```

- Added water has zero horizontal velocity.
- It forms a local free-surface bump.
- Existing face velocity is diluted by momentum mixing.

### Remove water

```text
h' = max(0, h - requestedRemoval)
```

- Removed water carries local velocity.
- Surviving water keeps its velocity until the face becomes dry/disconnected.
- The free surface forms a depression.

## 4. Face velocity mixing

Edits affect MAC face velocities. Compute all new cell states first, then update every incident face exactly once.

For adjacent cells `L,R`:

```text
etaL = bL + hL
etaR = bR + hR
zFace = max(bL,bR)
dL = max(0, etaL-zFace)
dR = max(0, etaR-zFace)
HFace = 0.5*(dL+dR)
```

For each face reconstruct:

- `HRetainedFace`: connected depth made from retained old water;
- `HAddedFace`: connected depth made from newly added zero-velocity water;
- `HNewFace = HRetainedFace + HAddedFace`.

Then:

```text
if HNewFace <= minimumWetDepth:
    velocityNew = 0
else:
    velocityNew = velocityOld * HRetainedFace / HNewFace
```

Consequences:

- add water / remove sand: velocity is diluted;
- remove water / add sand: velocity remains unchanged while connected water survives;
- newly dry or closed face: velocity becomes zero.

Implementation order:

1. capture old state over footprint plus one-cell halo;
2. compute final clamped cell states;
3. compute retained/added water;
4. update each affected x/y face once;
5. atomically expose the result and publish a snapshot.

---

# Phase 1 — Edit state model and Engine API

- [x] **1.1 Define edit target, material operation, world limits, and result accounting.**

Use plain enums/value structs:

```text
EditTarget:
- initialState
- pausedCurrentState

EditOperation:
- addSand
- removeSand
- addWater
- removeWater
```

Commands contain brush/polygon geometry, amount/rate, falloff, target, and world limits.

Return a compact result:

- status;
- changed cells/faces;
- sand-volume delta;
- water-volume delta;
- clamped cells;
- newly wet/dry cells.

Avoid a polymorphic command hierarchy.

- [x] **1.2 Separate initial-state and paused-current-state mutation.**

Requirements:

- initial edits update stored initial bed/depth and synchronize current state;
- initial edits set time and velocities to zero;
- paused edits update only current state;
- reset restores initial state;
- saving must explicitly choose initial or current paused state;
- default Save must not silently replace initial data with a transient evolved state.

- [x] **1.3 Implement finite, clamped, atomic edit execution.**

Requirements:

- validate before mutation;
- reuse scratch storage after capacity is established;
- no partial state on failure;
- no exceptions for normal invalid input;
- preserve `h>=0`, finite values, and world bounds;
- brush and polygon call the same cell/face semantic kernel.

### Phase 1 acceptance

- All four operations work for both edit targets.
- Initial edits always leave time zero and velocities zero.
- Paused edits preserve unaffected state exactly.
- No edit API calls a solver step.

---

# Phase 2 — Basic initial-state editing

- [x] **2.1 Implement immediate brush/polygon feedback while the solver is stopped, with one shared edit path for 2D and 3D.**

Requirements:

- pointer-down applies the first edit immediately;
- holding still continues applying at a controlled rate;
- dragging updates the footprint;
- pointer-up stops immediately;
- polygon Apply publishes immediately;
- every changed edit publishes exactly one new snapshot generation;
- the currently active viewport redraws from that generation;
- the inactive viewport performs no rasterization, Metal upload, or draw;
- time and diagnostics do not advance;
- initial Play starts with zero velocities.

- [x] **2.2 Implement the three mandatory base tests.**

### Test 1: submerged sand under static water

Initial: constant `eta`, zero velocity.

Edit: add sand below the waterline.

Before Play:

- `hAfter=max(0,hBefore-actualBedIncrease)`;
- still-wet cells preserve `eta`;
- no negative depth;
- all velocities remain zero;
- emerged cells have `h=0`.

After Play for 100–1,000 stable substeps:

- if all edited sand stayed below the old surface, lake-at-rest velocity remains within tolerance;
- no spike, NaN, or velocity-bound failure;
- water-volume loss equals displaced/deleted water exactly.

### Test 2: add/remove water

Before Play:

- intended bump/depression appears;
- velocities remain zero;
- `h>=0`.

After Play:

- waves develop;
- state remains finite;
- limiter prevents negative depth;
- volume equals initial volume plus exact edit delta.

### Test 3: visual transitions

Sequence:

1. deep water;
2. add submerged sand;
3. continue until dry;
4. add water on dry sand.

Assertions:

- deep water is deep blue;
- shallower water moves toward pale blue;
- emerged terrain becomes yellow/green;
- newly wetted terrain immediately becomes pale blue;
- polygon Apply behaves identically.

- [x] **2.3 Run impact-sized basic edit coverage.**

During implementation:

- use `16×16` or `32×32` for detailed brush/polygon assertions;
- use `128×128` for representative parallel and numerical behavior;
- defer `512×512` until the edit kernel is stable or a change affects allocation/performance/large-grid behavior.

The final numerical checkpoint still covers all four required sizes.

### Phase 2 acceptance

- All mandatory tests pass.
- Solver time never advances in edit mode.
- Visual changes appear immediately.
- 512×512 continuous editing remains usable.

---

# Phase 3 — Paused-current-state editing

- [x] **3.1 Implement dynamic-state editing with face momentum mixing, independent of whether the active viewport is 2D or 3D.**

Requirements:

- pause an evolved nonzero-velocity state;
- no solver steps while editing;
- add water and remove sand as zero-velocity additions;
- remove water and add sand as removal of moving old water;
- update each incident face once;
- preserve unaffected face values exactly;
- retain simulation time.

- [x] **3.2 Add operation-specific momentum tests.**

Add water:

```text
velocityNew = velocityOld * HRetainedFace/HNewFace
```

Verify no velocity increase and retained momentum.

Remove sand: verify constant `eta`, zero-velocity fill, expected dilution, and volume increase.

Remove water: verify surviving velocity unchanged; dry faces become zero; no negative depth.

Add sand: verify deleted water, unchanged surviving velocity, closed-face zeroing, and constant `eta` while submerged.

- [x] **3.3 Add resume-after-edit stability tests.**

For each operation:

1. evolve `32×32` and `128×128` to nonzero velocity;
2. pause;
3. edit;
4. verify unchanged solver time;
5. resume for at least 500 substeps.

Assert finite fields, no negative depth, fresh CFL, exact edit-volume accounting, and no stale-state spike. Add one combined `512×512` case.

### Phase 3 acceptance

- All four dynamic edit operations satisfy momentum rules.
- Resume does not use pre-edit flux or pre-edit CFL.
- Reset restores the original stored initial state.

---

# Phase 4 — Movable shoreline

- [x] **4.1 Replace the dry-neighbor heuristic with hydrostatic face reconstruction.**

For each internal face:

```text
etaL = bL+hL
etaR = bR+hR
zFace = max(bL,bR)
dL = max(0,etaL-zFace)
dR = max(0,etaR-zFace)
etaLStar = zFace+dL
etaRStar = zFace+dR
```

Velocity update:

```text
uFace -= g*dt*(etaRStar-etaLStar)/dx
```

and analogously for `v`.

Rules:

- `dL=dR=0`: face velocity and flux are zero;
- high dry ground above neighboring water acts closed;
- low dry ground below neighboring surface can be inundated;
- constant-`eta` lake at rest remains stationary.

- [x] **4.2 Use connected upwind depth for flux and retain donor limiting.**

```text
connectedDonorDepth = velocity>=0 ? dL : dR
flux = connectedDonorDepth*velocity
```

Requirements:

- dry donor cannot export water;
- only water above the face sill crosses;
- shared face is limited once using donor scale;
- `h<=minimumWetDepth` is dry for activation/cleanup;
- large/frequent post-clamp correction fails tests.

- [x] **4.3 Sanitize edited shoreline state before resume.**

After editing:

- verify finite state and bounds;
- recompute affected connected faces;
- zero disconnected velocities;
- invalidate stale diagnostics;
- next solver call recomputes `eta`, CFL, fluxes, and limiter;
- do not run a hidden solver step.

- [x] **4.4 Add shoreline tests.**

Required:

1. dry island lake-at-rest, 1,000 steps at 32/128;
2. inundation of low dry ground;
3. blocked high ground;
4. shoreline recession to exactly dry without negative depth;
5. edited shoreline resume after add/remove sand/water;
6. one 512 stability case.

### Phase 4 acceptance

- No explicit shoreline geometry or moving mesh exists.
- Low ground inundates, high ground blocks, shoreline recedes safely.
- Conservation and closed-wall tests still pass.
- No negative depth or spurious lake-at-rest motion.

---

# Phase 5 — 2D-only natural composite rendering, legends, and scale bar

- [ ] **5.1 Add two distinct 2D display modes: decorative composite and quantitative scalar views.**

This entire Phase applies only to `MosaicGridView`, `MosaicRaster`, `ScalarRasterizer`, 2D color mapping, and 2D annotation overlays.

Explicitly do not modify:

- `HeightFieldShaders.metal` terrain/water material colors;
- 3D lighting;
- 3D water opacity/Fresnel/specular behavior;
- 3D camera or mesh topology;
- 3D debug colors.

Required modes:

```text
Decorative Composite
Quantitative Water Depth
Bed Elevation
Free-Surface Elevation
Surface Deviation
Velocity Magnitude
Wet/Dry Mask
```

Rules:

- `Decorative Composite` is the default user-facing map.
- `Quantitative Water Depth` remains a strict one-variable colorscale suitable for debugging and measurement.
- Other existing scalar views remain unchanged.
- Decorative composite color is not claimed to encode water depth uniquely because it depends on both bed elevation and water depth.

- [ ] **5.2 Implement a three-layer decorative composite renderer for 2D only.**

The final color is composed from:

```text
terrain base color
+ optical water overlay
+ independent shoreline emphasis
```

Do not use a hard wet/dry color switch as the only normal rendering path. Do not use direct RGB multiplication such as `sandColor * waterColorCoefficient`, because it produces muddy colors and makes shoreline readability depend entirely on depth.

### Terrain base layer

Map bed elevation `b` from low pale sand to high pale green:

```text
low terrain:   #E8D6A5
middle terrain:#D8D7A0
high terrain:  #B7D2A2
```

Conceptually:

```text
tBed = normalizedBedElevation(b)
CLand = interpolate(lowSand, highGreen, tBed)
```

For submerged terrain, slightly cool and desaturate the base:

```text
CSubmergedBed = mix(CLand, paleAquaGray, 0.10...0.20)
```

The submerged bed must remain visible in shallow water.

### Water optical layer

Use depth-controlled optical opacity:

```text
alpha(h) = 1 - exp(-h / HClear)
```

Where:

- `HClear` is a configurable visual clarity depth;
- default should be approximately 20–40% of the scene's representative water-depth range;
- `alpha(0)=0`;
- deeper water asymptotically hides the bed.

Water color varies with depth:

```text
very shallow: #BDEBED
shallow:      #85D3DC
medium:       #559FC8
deep:         #2D6FA7
```

Use a smooth depth parameter:

```text
tWater = smoothstep(HShallow, HDeep, h)
CBlue = waterGradient(tWater)
```

Wet-cell color before shoreline emphasis:

```text
CWater = mix(CSubmergedBed, CBlue, alpha(h))
```

Expected appearance:

- nearly dry water shows mostly wet sand;
- shallow water shows visible sand under pale cyan;
- medium/deep water gradually becomes blue;
- depth transitions remain smooth and fresh rather than dark or muddy.

Perform interpolation in linear RGB or OKLab. Do not interpolate decorative colors directly in gamma-encoded sRGB if that produces gray/dirty intermediate colors.

### Optional shallow turquoise accent

Add a restrained near-shore turquoise contribution:

```text
q(h) = exp(-(h / HShallowAccent)^2)
CWater = mix(CWater, turquoiseAccent, beta * q(h))
```

Recommended:

```text
turquoiseAccent ≈ #77D8D0
beta = 0.10...0.25
```

This accent must fade with depth and must not replace the main depth mapping.

### Dry-cell color

For dry cells:

```text
C = CLand
```

No water optical overlay is applied.

- [ ] **5.3 Add independent shoreline detection and a two-sided shoreline treatment in 2D only.**

Shoreline clarity must not depend solely on water opacity.

For each cell, classify using `visualWetThreshold`:

```text
wet = h > visualWetThreshold
```

Water-side edge:

```text
wetEdge = wet && any 4-neighbor is dry
```

Land-side edge:

```text
dryEdge = !wet && any 4-neighbor is wet
```

Use 4-neighbor detection initially so the shoreline remains crisp and predictable on the mosaic grid. A later renderer may use a distance field, but the Engine must not store shoreline geometry.

### Water-side highlight

For `wetEdge`:

```text
C = mix(C, shoreCyan, 0.25...0.45)
shoreCyan ≈ #D3F4F1
```

This is a light cyan water-edge highlight, not a dark outline.

### Land-side wet-sand band

For `dryEdge`:

```text
C = mix(C, wetSand, 0.15...0.30)
wetSand ≈ #D3C28F
```

The intended sequence is:

```text
dry sand
-> slightly darker/cooler wet sand
-> pale cyan water edge
-> translucent shallow water
-> medium/deep blue water
```

Requirements:

- avoid pure black, dark navy, or high-contrast cartographic outlines;
- shoreline width is one cell in identical-cell mode;
- in resampled modes, preserve approximately 1–2 display pixels of shoreline emphasis where practical;
- shoreline decoration is visual-only and never feeds back into wet/dry solver logic.

- [ ] **5.4 Define stable decorative rendering parameters and range behavior.**

Add a compact renderer configuration containing:

```text
landElevationMinimum
landElevationMaximum
waterDepthMaximum
HClear
HShallow
HDeep
HShallowAccent
visualWetThreshold
shoreHighlightStrength
wetSandStrength
autoRangeEnabled
```

Rules:

- manual/stable scene ranges are the default;
- continuous brush edits must not cause visible palette range pumping;
- auto-range, when enabled, should update deliberately and may use smoothing/hysteresis;
- `visualWetThreshold` may equal or be derived from the solver wet threshold, but rendering must document the relationship;
- invalid values use an unmistakable debug color and bypass decorative blending;
- values outside configured ranges clamp to gradient endpoints.

- [ ] **5.5 Add 2D legends that correctly distinguish decorative and quantitative meaning.**

One overlay toggle controls all map annotations.

In `Decorative Composite`, show:

- a land-elevation scale from pale yellow to pale green;
- a water-depth scale from pale cyan to deep blue;
- a small shoreline key showing wet sand and water-edge highlight;
- a note or compact label indicating that shallow water is translucent and may reveal terrain.

In `Quantitative Water Depth`, show:

- one strict water-depth colorscale;
- numeric minimum/maximum and units;
- no terrain-dependent interpretation.

Legend values must use the same configured ranges as the renderer.

Do not imply that a single decorative-composite pixel color can be inverted to one exact water depth.

- [ ] **5.6 Add a physical horizontal scale bar to the 2D map only.**

Length-bar algorithm:

1. derive meters per displayed point/pixel from domain width and map content frame;
2. choose a target bar occupying approximately 20–35% of map width;
3. round down to a readable `1`, `2`, or `5 × 10^n` physical length;
4. display `0`, midpoint, endpoint, and unit;
5. format in `m` or `km`;
6. update after resize, zoom/sampling-policy change, or scene load.

The same annotation toggle shows/hides:

- color legends;
- shoreline key;
- physical scale bar.

- [ ] **5.7 Add rendering and UI tests for the natural composite.**

Required tests:

### Terrain base tests

- low bed maps exactly to pale yellow endpoint;
- high bed maps exactly to pale green endpoint;
- midpoint remains light and non-muddy;
- submerged bed cooling remains within configured strength.

### Water optical tests

- `h=0` produces no water opacity;
- increasing depth monotonically increases opacity;
- shallow water preserves visible contribution from bed color;
- deep water approaches deep blue;
- no channel overflows or non-finite color values;
- linear-RGB/OKLab interpolation path is deterministic.

### Shoreline tests

- wet cell adjacent to dry cell receives water-side highlight;
- dry cell adjacent to wet cell receives wet-sand treatment;
- interior wet/dry cells receive no shoreline treatment;
- shoreline remains visible when shallow-water alpha is near zero;
- no black/dark outline appears;
- 4-neighbor diagonal-only contact follows the documented rule.

### Mandatory visual transition test

Sequence:

1. deep water;
2. add submerged sand;
3. continue until dry;
4. add water on dry sand.

Assertions:

- deep water is deep blue;
- water becomes progressively lighter and more transparent as depth decreases;
- submerged sand remains visible;
- near shoreline shows wet-sand and pale-cyan edge treatment;
- emerged terrain becomes pale yellow/green;
- newly wetted terrain immediately becomes pale cyan/blue while retaining some sand visibility;
- polygon Apply produces the same immediate transitions.

### Legend and scale tests

- decorative land/water scales use the renderer's configured ranges;
- quantitative depth legend matches exact water-depth mapping;
- shoreline key uses the actual configured shoreline colors;
- scale-bar value is `1/2/5 × 10^n`;
- bar remains within target width fraction after resize;
- overlay toggle hides/shows all annotations.

### Editing feedback tests

- pointer-down publishes immediately;
- held brush publishes repeated updates;
- polygon Apply publishes immediately;
- add/remove water publishes immediately;
- solver time remains unchanged through every edit UI action.

### Phase 5 acceptance

- Default view has a fresh, natural beach/water appearance.
- Shallow water visibly covers rather than replaces the sand color.
- Shoreline remains clearly readable even at very small water depth.
- No dark GIS-style outline is required.
- Deep/shallow water and high/low land follow the requested directions.
- Decorative and quantitative modes are semantically distinct.
- Legends and physical scale bar are accurate and optional.
- Existing sampling policies render the composite mode correctly.

---

# Phase 6 — 3D editing integration without 3D visual redesign

- [ ] **6.1 Enable the shared editing tools while the 3D viewport is active.**

Current behavior disables the terrain tool picker in 3D. Replace this restriction with 3D interaction routing.

Requirements:

- use the same `EditTarget`, `EditOperation`, brush settings, polygon settings, world limits, Engine command API, volume accounting, and momentum-mixing path as 2D;
- do not create a second 3D-specific terrain editor;
- entering an edit tool pauses the solver in either viewport;
- camera interaction and editing interaction must be unambiguous:
  - Inspect mode retains orbit/pan/zoom;
  - edit modes route primary pointer input to editing;
  - a documented modifier or alternate mouse button retains camera orbit/pan while editing;
- tool state survives 2D ↔ 3D switching;
- an unfinished polygon either survives the switch in world coordinates or is explicitly cancelled with consistent UI feedback; choose and test one policy.

- [ ] **6.2 Implement deterministic 3D pointer-to-world picking for brush and polygon coordinates.**

The output needed by the Engine is only the horizontal physical coordinate `(x,z)` corresponding to the simulation domain.

Use the existing orbit-camera matrices and current snapshot. Choose one robust implementation:

```text
preferred:
camera ray
-> traverse regular height-field cells with 2D grid DDA
-> intersect visible water/terrain triangles
-> return nearest valid domain (x,z)

acceptable alternative:
dedicated depth/ID picking pass
-> read one pixel only on pointer events
-> unproject to world (x,z)
```

Requirements:

- no full-frame readback;
- no brute-force test against every triangle on every drag event;
- deterministic behavior at `16×16` through `512×512`;
- reject misses outside the domain;
- clamp only after a valid hit;
- use the visible top surface for location picking, but send only `(x,z)` to the shared material edit command;
- preserve engine-row/world-axis conventions;
- test top, isometric, low-oblique, opposite-oblique, zoomed, and panned cameras.

- [ ] **6.3 Render 3D edit feedback and committed geometry changes without changing 3D materials.**

Immediate committed-state update:

```text
Engine edit
-> new SimulationSnapshot generation
-> HeightFieldMetalView.updateNSView
-> HeightFieldRenderer.update(snapshot:)
-> copy changed bed/depth buffers
-> request one draw
```

Requirements:

- dimensions unchanged: reuse mesh, index buffer, pipelines, camera, and scalar-buffer allocation;
- update only scalar bed/depth buffers needed by the latest snapshot;
- do not rebuild the height-field topology for value-only edits;
- terrain vertices and water vertices immediately reflect edited `b` and `h`;
- add/remove sand updates terrain relief;
- add/remove water updates the 3D water surface;
- wet-to-dry changes disappear from the water pass through the existing wet threshold;
- do not reset or refit the camera for ordinary edits;
- do not change the current terrain/water palette or lighting.

Interactive preview:

- render brush radius and polygon points/edges as a separate neutral overlay or debug-line pass;
- do not bake preview colors into terrain/water fragment shaders;
- preview updates may redraw the active 3D viewport without publishing a new Engine snapshot;
- committed edits must come from the shared Engine snapshot, not from a renderer-only deformation.

- [ ] **6.4 Enforce active-viewport-only rendering and resource work.**

Preserve `SimulationViewport` as a real switch rather than stacking hidden 2D and 3D views.

In 2D mode:

- no `HeightFieldRenderer.update(snapshot:)`;
- no Metal scalar-buffer copy caused by simulation/edit snapshots;
- no 3D draw submission;
- no hidden 3D 60 Hz loop.

In 3D mode:

- no `MosaicRaster.image`;
- no `ScalarResampler.values`;
- no 2D pixel-buffer construction;
- no hidden 2D redraw.

On switching:

- newly active view consumes the latest snapshot;
- at most one necessary renderer initialization/resource build occurs;
- unchanged dimensions do not cause repeated 3D topology rebuilds;
- camera session state remains as currently designed.

Add lightweight debug/test counters that are absent or compiled out of Release hot paths.

- [ ] **6.5 Add 2D/3D editing parity and rendering tests.**

Numerical parity:

- apply the same brush/polygon/material command at the same world coordinates from 2D and 3D;
- compare `b`, `h`, `velX`, `velY`, edit-volume accounting, wet/dry counts, and simulation time exactly or within documented tolerance;
- cover initial-state and paused-current-state editing;
- cover all four material operations.

3D update tests:

- snapshot generation increases after every committed 3D edit;
- bed buffer changes after add/remove sand;
- water-depth buffer changes after add/remove water and displaced-water edits;
- dimensions unchanged means topology rebuild count is unchanged;
- camera state remains unchanged;
- solver time remains unchanged;
- resuming passes the same stability tests as a 2D-originated edit.

Active-renderer tests:

- while 2D is active, 3D update/upload/draw counters remain zero for repeated snapshot changes;
- while 3D is active, 2D raster/resample counters remain zero;
- switching to 3D shows all edits made in 2D;
- switching to 2D shows all edits made in 3D;
- rapid mode switching does not duplicate Engine edits or lose the newest snapshot.

Visual verification:

- retain a small bounded screenshot set;
- verify terrain relief changes, water-surface changes, dry-cell disappearance, brush preview, polygon preview, and camera preservation;
- do not evaluate or alter 3D color style in this plan.

### Phase 6 acceptance

- The same editing semantics work from both viewports.
- 3D committed edits appear immediately in the current Metal height field.
- Existing 3D materials, lighting, camera, and debug modes are unchanged.
- Inactive viewport rendering work is zero.
- Switching viewports shows one shared authoritative state.

---

# Phase 7 — Regression and documentation

- [ ] **7.1 Run the complete test matrix and update CPU golden references only after review.**

Run:

- XCTest;
- Thread Sanitizer;
- Address Sanitizer;
- Debug and Release;
- all four grid sizes;
- representative 10,000-step smoke tests;
- closed-domain conservation with explicit edit-volume accounting.

The shoreline change may legitimately change CPU fingerprints. Update them only after mathematical tests pass and the new pass behavior is recorded in `Docs/CPUReference.md` and `Docs/DesignDecisions.md`.

- [ ] **7.2 Add/update documentation under `Docs/`.**

Create `Docs/TerrainEditingAndShoreline.md` covering:

- edit contexts;
- four operations;
- world bounds;
- volume accounting;
- momentum mixing;
- shoreline reconstruction;
- reset/save behavior;
- palette and legend ranges;
- 2D-only decorative-color scope;
- 3D picking and interaction routing;
- active-viewport-only rendering contract;
- 2D/3D shared edit-state parity.

- [ ] **7.3 Commit in small verified checkpoints.**

Suggested commits:

```text
refactor: define material edit commands
fix: make initial terrain edits water-consistent
feat: support paused-state material editing
fix: mix edited water on MAC faces
fix: add hydrostatic movable shoreline faces
test: cover terrain water and shoreline invariants
feat: add composite terrain-water palette
feat: add map legends and scale bar
feat: enable shared editing in 3D viewport
feat: render 3D edit previews and snapshot updates
perf: skip inactive viewport rendering
test: verify 2D and 3D edit parity
docs: specify editing and shoreline contracts
```

---

## Required invariants

After every edit and solver step:

```text
all fields finite
worldMinimumElevation <= b <= worldMaximumElevation
0 <= h
b+h <= worldMaximumElevation
closed/disconnected face -> velocity=0
solver time unchanged while editing
2D and 3D edits call the same Engine command semantics
inactive viewport performs zero rendering/resource-update work
3D material colors and lighting remain unchanged by this plan
```

Volume accounting:

```text
VAfter = VBefore
       + directlyAddedWater
       - directlyRemovedWater
       + zeroVelocityWaterFromSandRemoval
       - waterDeletedBySandAddition
```

After editing in a closed domain, the solver conserves `VAfter` up to floating-point and documented tiny dry cleanup tolerance.

Lake at rest:

```text
eta=constant
velX=0
velY=0
```

must remain stationary over uneven bed and dry high ground.

## Definition of done

1. Initial edit mode modifies initial state, keeps zero velocity, and never runs the solver.
2. Paused-current edit mode follows the documented momentum rules.
3. Add sand deletes displaced water and preserves `eta` while submerged.
4. Remove sand fills excavation with zero-velocity water.
5. Add water mixes zero-velocity water.
6. Remove water makes a depression without negative depth.
7. Brush and polygon update visuals immediately.
8. Shoreline advances over low ground and retreats safely.
9. High dry terrain blocks lower water.
10. The three mandatory user tests pass.
11. Resume after every edit remains finite and free of artificial velocity spikes.
12. The natural composite colors, legends, and physical scale bar apply only to 2D and match the requested behavior.
13. Editing is available from both 2D and 3D and produces numerically identical shared state.
14. 3D terrain and water geometry update immediately after edits without changing existing 3D materials or camera state.
15. Inactive viewport rendering and buffer-update work is zero.
16. The focused tests pass throughout development, and the final checkpoint confirms the complete existing conservation, boundary, parallel, persistence, 2D rendering, and 3D rendering suite.
