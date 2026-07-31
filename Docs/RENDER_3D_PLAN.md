# TideSandbox 3D Mode Implementation Plan

## 1. Goal

Add a switchable, interactive 3D terrain-and-water view to TideSandbox while preserving the existing 2D mosaic behavior, controls, editing workflow, numerical solver, scene persistence, and tests.

The 3D mode must:

- display terrain at `bedElevation`;
- display water at `surfaceElevation = bedElevation + waterDepth`;
- update continuously while the SWE simulation is running;
- support orbit, pan, zoom, camera reset, and several deterministic camera presets;
- render wet/dry boundaries correctly from multiple viewing directions;
- remain a display-only feature in the first implementation;
- allow switching between 2D and 3D without changing simulation state.

The first version should use SwiftUI + MetalKit. The C++ Engine and Objective-C bridge remain unchanged unless a measured rendering bottleneck proves that a new read-only snapshot representation is necessary.

---

## 2. Non-negotiable compatibility constraints

1. **Keep `MosaicGridView` intact.** Do not rewrite it as Metal, SceneKit, or a shared renderer. The existing CPU raster path remains the authoritative 2D implementation.
2. **Do not modify SWE arithmetic.** The renderer reads `SimulationSnapshot`; it never writes to the Engine.
3. **Do not change `.waterscene` schema.** Camera state and render mode are UI state, not simulation state.
4. **Keep current accessibility identifiers.** Existing UI tests must continue to find the play, step, reset, preset, resolution, gallery, and grid elements.
5. **Keep editing in 2D for Phase 1.** Raise, lower, and polygon tools continue to operate through the existing 2D mapping. The 3D viewport is view-only.
6. **Do not duplicate simulation ownership.** Both view modes observe the same `SimulationViewModel` and the same immutable snapshot.
7. **Do not create a render thread that races with the runtime queue.** Metal receives only completed Swift snapshots.
8. **Do not allocate new grid-sized Swift arrays every rendered frame.** Reuse Metal buffers and update their contents.

---

## 3. Architecture

### 3.1 View switching

Add a closed UI enum:

```swift
enum ViewportMode: String, CaseIterable, Identifiable {
    case mosaic2D
    case heightField3D

    var id: Self { self }
}
```

Add `@Published var viewportMode: ViewportMode = .mosaic2D` to `SimulationViewModel`, or keep it as `@State` in `MainWindowView` if it is not needed elsewhere. Prefer ViewModel storage because UI tests and commands can address it consistently.

Introduce a small wrapper:

```swift
struct SimulationViewport: View {
    @ObservedObject var model: SimulationViewModel

    var body: some View {
        switch model.viewportMode {
        case .mosaic2D:
            MosaicGridView(model: model)
        case .heightField3D:
            HeightField3DView(model: model)
        }
    }
}
```

Replace only this line in `MainWindowView`:

```swift
MosaicGridView(model: model)
```

with:

```swift
SimulationViewport(model: model)
```

Add a compact 2D/3D segmented picker to the existing floating toolbar or Display inspector. Keep `.mosaic2D` as the launch default.

### 3.2 New 3D renderer boundary

Add an `NSViewRepresentable` wrapper around `MTKView`:

```text
TideSandbox/Render3D/
├── HeightField3DView.swift
├── HeightFieldMetalView.swift
├── HeightFieldRenderer.swift
├── HeightFieldMesh.swift
├── OrbitCamera.swift
├── Render3DSettings.swift
└── HeightFieldShaders.metal
```

Responsibilities:

- `HeightField3DView`: SwiftUI integration and 3D-only controls/overlays.
- `HeightFieldMetalView`: owns `MTKView`, translates AppKit mouse and scroll events.
- `HeightFieldRenderer`: owns Metal pipelines, buffers, textures, frame uniforms, and draw calls.
- `HeightFieldMesh`: builds static grid indices and validates dimensions.
- `OrbitCamera`: camera state, matrices, input, fit-to-domain, and presets.
- `Render3DSettings`: vertical scale, water opacity, light direction, shoreline threshold, and debugging flags.
- `HeightFieldShaders.metal`: terrain and water vertex/fragment functions.

The renderer API should remain narrow:

```swift
func update(snapshot: SimulationSnapshot)
func resize(drawableSize: CGSize)
func draw(in view: MTKView)
```

### 3.3 Data flow

```text
C++ SWE Engine
    ↓ copied immutable bridge snapshot
SimulationRuntime
    ↓ publishes on MainActor
SimulationViewModel.snapshot
    ├── MosaicGridView → existing CPU raster path
    └── HeightField3DView → reusable Metal buffers
```

Switching the viewport must not reload a scene, reset time, pause playback, or rebuild the solver.

---

## 4. Metal height-field representation

### 4.1 Static topology

For a grid of `width × height` cells, render one vertex per cell center. Create a static index buffer containing two triangles for every adjacent 2×2 vertex block.

For each `(column, row)` except the last row and column:

```text
a = row * width + column
b = a + 1
c = a + width
d = c + 1

triangles: (a, c, b), (b, c, d)
```

Use the Engine/world convention in which rows increase upward. Do not perform the 2D raster row flip in the 3D renderer.

World coordinates:

```text
x = (column + 0.5) * dx - domainWidth / 2
z = (row + 0.5) * dy - domainHeight / 2
y = elevation * verticalScale
```

Centering the domain around the origin simplifies camera fitting and orbit rotation.

### 4.2 Dynamic scalar buffers

Maintain reusable Metal buffers for:

- `bedElevation` (`Float32`, grid-sized);
- `waterDepth` (`Float32`, grid-sized);
- optional previous `surfaceElevation` only if temporal smoothing is later required.

Use triple buffering or a small rotating buffer set so the CPU does not overwrite a buffer still used by the GPU.

On each new snapshot:

- if dimensions changed, rebuild topology and all scalar buffers;
- otherwise copy the snapshot bytes into the next reusable buffers;
- update a monotonically increasing snapshot generation number;
- skip redundant uploads when the generation has not changed.

Do not construct `[SIMD3<Float>]` positions or normals on the CPU each frame.

### 4.3 Vertex shader

Terrain pass:

```text
yTerrain = bedElevation[index] * verticalScale
```

Water pass:

```text
depth = max(waterDepth[index], 0)
yWater = (bedElevation[index] + depth) * verticalScale + renderBias
```

Calculate normals in the vertex shader from neighboring height samples using central differences and one-sided differences at boundaries.

### 4.4 Wet/dry handling

Use the same semantic threshold as the solver UI, passed as a uniform:

```text
wet = waterDepth > minimumWetDepth
```

For water fragments:

- discard fragments whose interpolated depth is below the wet threshold;
- apply a narrow `smoothstep` band above the threshold to soften the shoreline;
- use a small display-only vertical bias to avoid z-fighting;
- never write the bias back to the simulation.

---

## 5. Rendering passes

### 5.1 Terrain pass

- depth test: enabled;
- depth write: enabled;
- blending: disabled;
- back-face culling: enabled after winding has been verified;
- color: low terrain pale yellow/sand, high terrain light green, smoothly interpolated by bed elevation;
- lighting: one directional light plus low ambient light;
- optional grid overlay: off by default in 3D.

The terrain color range should be based on bed elevation, independent of the selected 2D scalar quantity.

### 5.2 Water pass

- draw after terrain;
- depth test: enabled;
- alpha blending: enabled with premultiplied alpha;
- depth write: initially disabled to reduce transparency artifacts;
- color: shallow water light blue, deep water dark blue;
- surface normal: derived from `bedElevation + waterDepth`;
- add restrained diffuse/specular lighting and a view-angle Fresnel term;
- keep the first version free of screen-space reflections, refraction, foam simulation, tessellation, and procedural waves.

The visible water shape must come only from the SWE surface. Decorative shader waves would make numerical debugging ambiguous and should not be added.

### 5.3 Optional debug pass

Add toggles for:

- wireframe terrain;
- wireframe water;
- domain bounds;
- surface normals on a sparse grid;
- wet-cell mask;
- camera target marker.

Keep these controls inside an expandable “3D Debug” inspector section.

---

## 6. Camera and interaction

Implement an orbit camera with:

```swift
struct OrbitCameraState {
    var target: SIMD3<Float>
    var yaw: Float
    var pitch: Float
    var distance: Float
    var fieldOfViewY: Float
}
```

Controls:

| Input | Action |
|---|---|
| Left drag | Orbit around target |
| Shift + left drag or middle drag | Pan target |
| Scroll wheel | Zoom |
| Double click or `F` | Fit whole domain |
| `1` | Top view |
| `2` | Isometric view |
| `3` | Low oblique view |
| `4` | Opposite-side oblique view |

Clamp pitch to avoid singularity, for example `[-89°, -5°]`. Clamp distance to a domain-dependent range.

Deterministic presets:

- **Top:** yaw `0°`, pitch `-89°`;
- **Isometric:** yaw `45°`, pitch `-35°`;
- **Low oblique:** yaw `135°`, pitch `-18°`;
- **Opposite oblique:** yaw `225°`, pitch `-35°`.

`fitToDomain()` must account for domain width, domain height, maximum absolute elevation, field of view, and viewport aspect ratio.

Camera interaction must never modify terrain. In 3D mode, terrain-tool controls may remain visible but should be disabled with the explanation “Terrain editing is available in 2D mode.”

---

## 7. UI integration

### 7.1 Display inspector

Add:

- `View: 2D | 3D` segmented picker;
- in 3D mode only:
  - vertical exaggeration slider;
  - water opacity slider;
  - camera preset menu;
  - “Fit view” button;
  - optional debug disclosure group.

Keep the existing 2D controls—Quantity, Colors, Sampling, Grid lines—unchanged. They may remain visible in 3D but should either be disabled or clearly marked as 2D-only. Prefer conditional sections to avoid ambiguous controls.

### 7.2 Toolbar behavior

Play, pause, step, reset, gallery, save, and scene loading must behave identically in both modes.

Switching modes while playing must preserve playback. Switching modes while paused must preserve the exact snapshot.

### 7.3 Persistence

Do not write viewport mode, camera orientation, or render settings into `.waterscene` in this phase. Optionally store the last viewport mode and camera settings using app preferences after the core implementation is stable.

---

## 8. Implementation sequence

### Phase 0 — Baseline lock

1. Run all current unit and UI tests before changes.
2. Record current test count and results.
3. Capture one baseline 2D screenshot of the default scene.
4. Record default scene diagnostics after a fixed number of steps: simulated time, total volume, maximum depth, maximum speed, and wet-cell count.
5. Commit this baseline separately.

Exit criterion: all existing tests pass and the baseline data is recorded.

### Phase 1 — Viewport abstraction with unchanged 2D path

1. Add `ViewportMode`.
2. Add `SimulationViewport`.
3. Replace the direct `MosaicGridView` reference in `MainWindowView`.
4. Add the 2D/3D picker, but render a placeholder in 3D.
5. Run all existing tests.
6. Add a UI test that switches 2D → 3D placeholder → 2D and confirms the same grid diagnostics remain present.

Exit criterion: 2D visual behavior and existing UI tests remain unchanged.

### Phase 2 — Metal renderer skeleton

1. Add `MTKView` wrapper and renderer lifecycle.
2. Clear with a neutral background and draw a simple diagnostic triangle.
3. Handle resize and Retina drawable size correctly.
4. Add an accessibility identifier to the 3D viewport.
5. Add a smoke UI test that enters 3D and confirms the view exists.

Exit criterion: stable 3D view creation, resize, and mode switching without leaks or crashes.

### Phase 3 — Terrain mesh

1. Add static grid topology generation.
2. Upload `bedElevation` to reusable Metal buffers.
3. Render the terrain with vertical scale and directional lighting.
4. Add camera fit and the four deterministic presets.
5. Verify row orientation using an asymmetric uneven-bed preset.
6. Add pure unit tests for index generation, bounds, winding, and coordinate mapping.

Exit criterion: terrain orientation and elevations are correct from all preset views.

### Phase 4 — Dynamic water surface

1. Upload `waterDepth` on every new snapshot.
2. Render `bedElevation + waterDepth` as the water surface.
3. Add wet/dry clipping, shoreline fade, water depth color, lighting, and render bias.
4. Verify that the surface changes during Play and Step.
5. Verify that dry terrain is not covered by residual water triangles.
6. Verify no NaN or invalid Metal buffer access occurs during reset or scene-size changes.

Exit criterion: visibly moving water follows the simulation and remains correctly attached to terrain.

### Phase 5 — Interaction and inspector polish

1. Add orbit, pan, zoom, fit, and keyboard presets.
2. Disable terrain editing in 3D.
3. Add 3D settings and debug toggles.
4. Ensure pointer events over inspector and toolbar do not move the camera.
5. Ensure mode switching preserves camera state during the session.

Exit criterion: camera controls are predictable and do not interfere with application controls.

### Phase 6 — Regression, visual verification, and performance

Execute the complete test matrix in Section 9. Fix correctness issues before visual polish.

Exit criterion: all automated tests pass, visual checks pass, screenshot count remains within the stated budget, and 512² interaction remains responsive.

### Phase 7 — Documentation and cleanup

1. Add a design decision describing the dual renderer architecture.
2. Document camera controls.
3. Document 3D limitations: display-only editing, simple transparency, and no decorative waves.
4. Remove temporary debug code and unused assets.
5. Keep commits separated by architecture, renderer, water, interaction, and tests.

---

## 9. Test plan

### 9.1 Existing regression suite

Every implementation phase must run:

- all C++ Engine tests;
- Swift display tests;
- persistence tests;
- current UI tests;
- launch tests.

A failure in an existing 2D test blocks further 3D work until resolved.

### 9.2 New unit tests

Add tests for:

1. correct vertex and index count for 2×2, 3×2, 16×16, and 512×512 grids;
2. every index remaining within the vertex range;
3. triangle winding producing upward-facing normals on a flat field;
4. Engine row-up orientation mapping to world positive-Z;
5. `surfaceElevation = bedElevation + waterDepth` at representative cells;
6. dry-cell classification at and around `minimumWetDepth`;
7. camera matrices remaining finite for all presets and extreme viewport aspect ratios;
8. `fitToDomain()` containing all domain corners;
9. buffer rebuild only when dimensions change;
10. switching viewport mode not mutating any `SimulationSnapshot` field.

### 9.3 New UI tests

Add stable accessibility identifiers:

```text
viewport-mode-picker
mosaic-grid
height-field-3d
camera-preset-picker
fit-camera-button
```

UI scenarios:

1. launch defaults to 2D and the current 2D view exists;
2. switch to 3D and confirm the Metal view exists;
3. switch back to 2D and confirm the mosaic returns;
4. Play in 3D, wait for simulated time to increase, pause, and confirm diagnostics remain finite;
5. Step in 3D and confirm simulated time changes;
6. switch 3D → 2D during the same run and confirm time/volume diagnostics are preserved;
7. load all built-in presets in 3D, including 512×512;
8. reset while in 3D and confirm no crash and valid diagnostics;
9. verify terrain tools are disabled or redirected while in 3D;
10. verify save and gallery workflows remain available from 3D.

Avoid asserting exact rendered pixels in the general UI suite because GPU shading may vary slightly. Test deterministic geometry and state numerically; use bounded visual inspection for appearance.

### 9.4 Required moving-water visual scenarios

The following scenarios must be tested while the liquid is actively moving:

#### Scenario A — Center bump wave

- preset: `32 × 32 Center Bump`;
- capture initial isometric view;
- run until the wave has visibly propagated;
- inspect isometric and low-oblique views;
- verify radial propagation, surface continuity, and absence of detached triangles.

#### Scenario B — Uneven bed inundation

- preset: `128 × 128 Uneven Bed`;
- run from top and opposite-oblique views;
- verify terrain orientation, downhill water movement, and shoreline migration;
- verify high terrain remains exposed.

#### Scenario C — Coast channel stress case

- preset: `512 × 512 Coast Channel`;
- run while orbiting and zooming;
- verify water updates continuously, the UI remains responsive, no buffer-size mismatch occurs, and wet/dry boundaries are stable.

### 9.5 Required camera-angle coverage

For at least one actively flowing scene, inspect all four deterministic camera presets:

- Top;
- Isometric;
- Low oblique;
- Opposite oblique.

Also perform one free orbit across at least 180° around the scene and one zoom from whole-domain framing to a shoreline close-up.

Look specifically for:

- reversed row orientation;
- inverted triangle winding;
- missing back faces;
- terrain/water z-fighting;
- water visible through terrain;
- near-plane clipping;
- transparent sorting artifacts;
- surface normals flipping with camera direction;
- stale water after reset or scene change.

---

## 10. Visual-assistance policy

Visual inspection is permitted when automated tests cannot confidently validate camera composition, lighting, transparency, shoreline appearance, or motion continuity.

Rules:

1. Do not record video.
2. Do not create continuous screenshot sequences exceeding 10 images.
3. Use a maximum of **8 retained screenshots per complete validation run**.
4. Prefer deterministic scene, simulation time, viewport size, and camera presets.
5. If a failure needs an extra diagnostic image, replace a redundant retained screenshot rather than growing the set beyond 8.
6. Attach screenshots to UI test results only at meaningful checkpoints or on failure.
7. Do not use screenshots as a substitute for numerical tests of volume, finite values, dimensions, or state preservation.

Recommended screenshot budget:

| # | Checkpoint |
|---:|---|
| 1 | Baseline 2D default scene |
| 2 | 3D top view, initial state |
| 3 | 3D isometric view, initial state |
| 4 | 3D isometric view, moving water |
| 5 | 3D low-oblique view, moving water |
| 6 | 3D opposite-oblique view, moving water |
| 7 | 512×512 coast-channel moving-water view |
| 8 | Returned 2D view after running in 3D |

When uncertain, compare screenshots side by side for geometry and shoreline consistency. Do not require exact pixel identity across GPUs.

---

## 11. 2D preservation checks

Before merging, explicitly verify:

- `MosaicGridView.swift` retains its raster generation, row flip, interpolation, grid overlay, brush preview, polygon overlay, and pointer mapping;
- 2D launch remains the default;
- all four display sampling policies still render;
- display quantity and palette behavior are unchanged;
- brush and polygon editing still pause simulation and update the existing snapshot path;
- scene loading, reset, save, restore, gallery, and dirty-warning behavior are unchanged;
- 3D render settings do not affect 2D colors or sampling;
- mode switching does not mark the scene dirty;
- camera movement does not mark the scene dirty;
- the C++ Engine and bridge have no rendering-framework dependencies.

A useful state-preservation test is:

1. load a deterministic preset;
2. advance exactly N steps;
3. record diagnostics and selected scalar values;
4. switch 2D → 3D → camera changes → 2D;
5. verify all recorded simulation values are unchanged.

---

## 12. Performance and resource checks

Target behavior on a 512×512 scene:

- no per-frame topology rebuild;
- no per-frame creation of grid-sized Swift arrays;
- scalar data upload only when a new snapshot arrives;
- camera-only movement redraws without re-uploading the simulation fields;
- renderer survives repeated 16² ↔ 512² preset changes;
- no unbounded Metal buffer growth;
- no MainActor stalls caused by shader compilation after initial setup;
- interactive camera movement remains usable while the simulation is running.

Suggested release-build target on Apple Silicon: maintain at least 30 FPS during the 512×512 visual stress test. Treat this as a measured target rather than a solver-correctness requirement. If missed, profile before changing architecture.

---

## 13. Failure handling and fallback order

When a visual or runtime problem occurs, diagnose in this order:

1. confirm snapshot dimensions and array counts;
2. confirm world coordinate and row orientation;
3. render terrain wireframe only;
4. render water as opaque flat color;
5. disable culling;
6. disable alpha blending;
7. display wet-cell mask;
8. inspect normals;
9. use one deterministic screenshot from the failing camera;
10. inspect a Metal frame capture only if the simpler checks are insufficient.

Do not change the solver to compensate for a renderer error.

If transparent water remains unreliable, ship the first version with high-opacity water and stable depth behavior, then improve transparency in a separate change.

---

## 14. Commit strategy

Use small, reversible commits:

1. `test: lock 2D baseline before 3D viewport work`
2. `refactor: add switchable simulation viewport`
3. `feat: add Metal height-field renderer skeleton`
4. `feat: render terrain height field`
5. `feat: render dynamic SWE water surface`
6. `feat: add orbit camera and 3D display controls`
7. `test: cover 3D mode switching and moving water`
8. `docs: record dual-renderer design and controls`

Do not combine solver changes, persistence schema changes, and 3D rendering into the same branch.

---

## 15. Completion criteria

The 3D feature is complete when all of the following hold:

- TideSandbox launches in the existing 2D mode;
- all existing automated tests pass;
- 2D editing and display behavior remain intact;
- users can switch between 2D and 3D without resetting or mutating the simulation;
- terrain and water geometry use the current immutable snapshot;
- water visibly evolves during Play and Step;
- Top, Isometric, Low oblique, and Opposite oblique views all render correctly during active flow;
- the 512×512 coast-channel case remains responsive and stable;
- reset and scene-size changes do not leave stale geometry;
- screenshot validation uses no recording and at most 8 retained screenshots per run;
- no C++ Engine code depends on Metal, AppKit, or SwiftUI;
- documentation states that 3D editing is deferred and 2D remains the editing surface.

