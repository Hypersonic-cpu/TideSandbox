# Widget, Floating 3D Window, City Maps, Brush, and Ripple Plan

> Scope starts from the working tree after the currently executing accelerated-solver and boundary work.  
> Do not repeat, replace, or re-plan that work. Reuse its final backend, state, boundary, snapshot, and persistence contracts.

## 0. Product targets

Deliver two independent desktop presentations backed by one display-session simulation:

```text
A. Native WidgetKit widget
   - non-floating system widget
   - systemSmall 1:1
   - systemMedium 2:1 horizontal
   - requested visual cadence: 5 / 8 / 12 FPS
   - precomputed future keyframes selected from current time
   - system may reduce actual cadence

B. Floating 3D window
   - ordinary macOS panel, not WidgetKit
   - requested render cadence: 60 or 75 FPS
   - reuse the existing 3D Metal renderer, camera, picking, buffers, and settings
   - actual FPS follows display capability and MTKView scheduling
```

Also deliver:

```text
Bay map
Lake map
texture-land widget presentation
widget-only white shoreline foam
normal 2D preview unchanged
widget preview inside the app
orthogonal Add/Erase + Land/Water brush controls
raised-cosine brush rolloff
volume-neutral charged ripple interaction
```

## 1. Hard constraints

- [ ] Re-read the implementation working tree before changing files; the public repository may lag the in-progress solver work.
- [ ] Do not duplicate or alter the currently executing accelerated backend/boundary plan except for narrow integration hooks required here.
- [ ] Preserve `2D Normal` colors, legends, grid option, quantitative modes, and existing shoreline appearance.
- [ ] White foam/glow belongs to `2D Widget` only.
- [ ] Do not copy the colors, UI, labels, or other styling from the supplied wave-game screenshot.
- [ ] WidgetKit does not own or advance the full solver continuously.
- [ ] Do not promise an exact WidgetKit frame rate. Request 5/8/12 FPS and degrade correctly when the system supplies a slower cadence.
- [ ] The 60/75 FPS floating presentation must not depend on WidgetKit.
- [ ] Do not create a privileged system `LaunchDaemon`. Use a per-user helper/login item that requires no administrator privileges.
- [ ] No cloud service, API quota, or network request is required.
- [ ] The display agent, app, and widget communicate through one App Group and explicit IPC.
- [ ] Only one process owns a given display-session solver state at a time.
- [ ] Keep the weakly nonlinear SWE state as `h,u,v`; do not introduce vertical velocity `w`.
- [ ] Generated map art must be original/procedural and free of third-party labels, logos, watermarks, or copied map tiles.
- [ ] Codex must not be asked to invent the Bay/Lake art. It integrates generated assets and may only make mechanical format corrections.
- [ ] Tests are non-interactive unless real WidgetKit desktop cadence or real window/display scheduling cannot be validated otherwise.

## 2. Target structure

Add the following product targets/modules:

```text
TideSandbox.app
    existing main application
    full editor and normal 2D/3D previews

TideDisplayAgent.app
    LSUIElement login-item helper
    owns the display-session solver
    generates Widget prediction batches
    consumes ripple commands
    optionally displays the floating Metal window

TideSandboxWidget.appex
    WidgetKit extension
    reads immutable prediction batches
    renders time-selected/interpolated widget frames
    sends discrete AppIntent commands

TideShared
    Swift framework or target-shared module
    App Group paths
    Codable schemas
    map asset loader
    prediction-batch loader
    Widget appearance/presentation code
    command queue schema

TideEngineKit
    extracted/reused existing Engine + accelerated bridge sources
    linked by TideSandbox and TideDisplayAgent
    not linked by the Widget extension
```

Do not move the existing C++ Engine into Swift. Avoid inheritance except required Apple framework classes.

## 3. Display-agent lifecycle and ownership

### 3.1 Service type

Package `TideDisplayAgent.app` under the main bundle as an `LSUIElement` login item and register it through `SMAppService.loginItem`.

User-facing setting:

```text
Desktop Water Service
[Enable]
Status: Running / Disabled / Approval Required / Error
```

The helper is optional. Disabling it must leave:

```text
main app fully usable
widget able to display its last valid batch
floating window unavailable with a clear status
```

### 3.2 Responsibilities

The display agent owns a dedicated `DisplaySession`:

```text
sceneID
authoritative solver state
wall-clock anchor
playback parameters
map presentation configuration
Widget prediction generation
floating window controller
pending command consumption
```

This session is separate from an arbitrary unsaved editor document. The main app explicitly publishes a scene/configuration to the display session.

Default display scenes:

```text
Bay
Lake
```

### 3.3 IPC

Use two channels:

```text
App Group:
    durable assets
    prediction batches
    current configuration
    durable command queue
    last valid status

NSXPCConnection:
    low-latency app <-> display-agent control
    show/hide floating window
    publish scene/configuration
    request current status
    request immediate prediction regeneration
```

Widget AppIntents write durable commands into the App Group because the widget cannot assume that the agent is already connected.

Command record:

```json
{
  "schemaVersion": 1,
  "id": "UUID",
  "createdAt": "ISO-8601",
  "expiresAt": "ISO-8601",
  "sceneGeneration": 42,
  "kind": "ripple",
  "normalizedX": 0.62,
  "normalizedY": 0.37,
  "strength": 0.55
}
```

Use atomic append/rename or a small SQLite queue. Each command is idempotent by UUID. The agent marks or removes it only after successful application.

“Consume” means:

```text
read command
validate generation and expiry
advance authoritative state to command time
apply it once
persist updated state
invalidate old predictions
generate a new batch
mark command complete
request Widget timeline reload
```

## 4. Widget prediction model

### 4.1 Prediction batch

The display agent maintains an authoritative state at wall-clock time `t0`. It clones that state into prediction scratch and simulates forward without modifying the authoritative state.

Batch structure:

```text
WidgetPredictionBatch/
    manifest.json
    static/
        land-full-light.heic
        land-full-dark.heic
        land-primary-mask.heic
        land-accent-mask.heic
    small/
        keyframes/
    medium/
        keyframes/
```

Manifest fields:

```text
schemaVersion
batchGeneration
sceneGeneration
sceneID
createdAt
startTime
endTime
requestedDisplayFPS
mapAspect
keyframe metadata
appearance-layer metadata
checksum/version for every file
```

Publish a batch by writing to a temporary directory, validating it, then atomically replacing `current-batch`.

### 4.2 Horizon and adaptive keyframes

Initial policy:

```text
prediction horizon: 120 seconds
nominal keyframe interval: 10 seconds
minimum interval: 2 seconds
maximum interval: 10 seconds
```

Do not force 10 seconds when visible motion is faster.

Generate an extra keyframe when any condition exceeds threshold:

```text
maximum water-color pixel delta
shoreline displacement > 0.75 output pixel
foam-mask difference
ripple-active flag
```

Expected behavior:

```text
slow tide:
    near 10-second spacing

surge:
    4–6-second spacing

recent ripple:
    2-second spacing until it decays
```

Begin generating the next batch before the active batch has less than 30 seconds remaining. If regeneration fails, keep the last batch and hold its final frame after expiry.

### 4.3 Widget-level interpolation

The Widget extension must not integrate SWE. It derives a normalized time from `TimelineView` context date:

```text
find bracketing keyframes k0 and k1
alpha = clamp((now - t0) / (t1 - t0), 0, 1)
render interpolation(k0, k1, alpha)
```

First implementation uses image/layer crossfade. Do not interpolate two full 512²/1024×512 solver fields inside the widget.

To avoid doubled foam edges:

```text
water layer:
    interpolate/crossfade normally

foam layer:
    use denser adaptive keyframes
    normalize combined opacity so overlap does not exceed one foam core
```

If crossfade remains visibly ghosted, upgrade only the foam layer to a compact signed-distance or displacement representation; do not move the solver into the widget.

## 5. Widget cadence and energy modes

Expose:

```text
Eco       5 FPS requested
Balanced  8 FPS requested (default)
Smooth   12 FPS requested
```

Use:

```swift
TimelineView(
    .animation(
        minimumInterval: 1.0 / requestedFPS,
        paused: false
    )
)
```

The widget must use `context.date` as the source of truth, not an incrementing local frame counter. A missed update therefore jumps to the correct time rather than slowing the simulated tide.

Use `context.cadence` to degrade:

```text
live:
    requested 5/8/12 FPS interpolation

seconds:
    update approximately once per second using correct current-time alpha

minutes:
    show nearest current keyframe and omit transient ripple details
```

Do not call `WidgetCenter.reloadTimelines` on every visual frame. Reload only when:

```text
new batch is published
scene/configuration changes
a Widget AppIntent changes state
the current batch is close to expiration
```

## 6. Widget presentation

### 6.1 Families

Support only:

```text
systemSmall  -> 1:1
systemMedium -> approximately 2:1 horizontal
```

No grid lines, map legends, debug text, or editor overlays.

### 6.2 Presentation modes

Add:

```text
Map appearance:
    Elevation
    Texture
```

#### Elevation

```text
land:
    existing green-yellow decorative ramp

water:
    existing blue depth scale

foam:
    Widget-only white edge
```

#### Texture

```text
dry land:
    preserve supplied land texture directly
    no elevation tint or hill shading

wet cells:
    dynamic TideSandbox water overlay covers texture according to depth/opacity

shoreline:
    generated from current wet/dry boundary
    never baked from the static texture
```

The static texture is visual only. Bed elevation and water fields remain the physical source of shoreline motion.

### 6.3 Rendering-mode adaptation

Read:

```swift
@Environment(\.colorScheme)
@Environment(\.widgetRenderingMode)
```

Implement separate layer composition for:

```text
fullColor + light
fullColor + dark
accented
vibrant
```

Map the requested preview names:

```text
Default -> fullColor/light
Dark    -> fullColor/dark
Clear   -> accented with removable container background
Tinted  -> accented/tinted preview
```

Do not assume full RGB map colors survive `accented` or `vibrant`.

Full-color layers:

```text
land texture or elevation color
blue water
white foam
optional low-opacity dark separator below foam
```

Accented/vibrant layers:

```text
primary mask:
    land structure, major roads, labels if any

accent mask:
    water body

high-contrast alpha:
    foam edge
```

Use `widgetAccentable(_:)`, image accented-rendering modes, and `containerBackground(for: .widget)` correctly. The appearance must remain legible when the system removes or replaces the background.

### 6.4 Widget-only foam

At final widget output resolution:

```text
current wet mask
-> antialiased shoreline distance
-> wet-side core
-> outer halo
```

Initial visual parameters:

```text
white core:      1.0–1.8 px
soft halo:       2.5–5.0 px
core alpha:      0.80–1.00
halo alpha:      0.10–0.35
dark separator:  0–1 px, enabled only when required by bright land
```

Do not trace source grid-cell edges. Generate foam after resampling/masking at the final output size.

Normal 2D does not use this foam.

## 7. App previews

Add one app preview workspace without replacing the normal viewport:

```text
Preview Mode
    2D Normal
    Widget Small
    Widget Medium
    Floating 3D
```

For Widget Small/Medium expose:

```text
Default
Dark
Clear
Tinted

Elevation
Texture

Eco / Balanced / Smooth

time scrubber across current prediction batch
```

The preview must use the same `TideShared` widget view and batch loader as the actual Widget extension.

`2D Normal` continues to use the current `MosaicGridView` and renderer unchanged.

## 8. Floating 3D window

### 8.1 Reuse boundary

Refactor the current 3D code only enough to remove its direct dependency on the full editor view model.

Reusable component input:

```text
snapshot or accelerated render buffers
camera state
Render3DSettings
playback state
picking callbacks
ripple-preview callbacks
```

Reuse:

```text
HeightFieldMetalView
HeightFieldRenderer
HeightFieldShaders.metal
HeightFieldMesh
OrbitCamera
HeightFieldPicker
existing terrain/water/debug pipelines
existing snapshot-generation and buffer-reuse behavior
```

Do not create a second 3D shader set or second camera implementation.

### 8.2 Window type

The display agent creates one resizable `NSPanel`:

```text
titleless or compact title bar
optional nonactivating behavior
level = floating
canJoinAllSpaces
fullScreenAuxiliary
hidesOnDeactivate = false
```

Settings:

```text
Always on Top
Click Through
Show on All Spaces
Aspect: Free / 1:1 / 2:1
Frame Rate: Auto / 60 / 75
Camera preset
Vertical exaggeration
Water opacity
```

Click-through disables picking and camera input but keeps rendering.

### 8.3 Frame rate

Set `MTKView.preferredFramesPerSecond` from the selected target:

```text
Auto:
    choose a stable rate no greater than 75

60:
    request 60

75:
    request 75
```

The display chooses the nearest supported scheduling rate. Record actual presented FPS; never label the panel “75 FPS” solely because 75 was requested.

Rendering policy:

```text
visible and waves active:
    continuous draw

visible but nearly static:
    retain target FPS only if user selected it;
    Auto may reduce to 30 or pause with on-demand redraw

occluded/minimized:
    pause renderer

panel closed:
    no 3D draw work
```

Simulation cadence remains independent of display cadence and uses the authoritative solver's time integration.

### 8.4 Ownership advantage

The display-session solver and floating renderer run in the same display-agent process. Therefore:

```text
no 60-FPS App Group file traffic
no 60-FPS XPC transfer of full fields
no per-frame Widget prediction decoding
```

Use the accelerated backend's direct render-buffer path when available. Use snapshot upload fallback only when required.

## 9. Map asset format

Define a self-contained directory format:

```text
<MapName>.tidemap/
    manifest.json
    bed_elevation.f32
    initial_water_depth.f32
    land_mask.png
    texture/
        land-default.png
        land-dark.png
        primary-mask.png
        accent-mask.png
    source/
        map.svg
        generation.json
    preview/
        normal-2d.png
        widget-small-default.png
        widget-small-dark.png
        widget-small-clear.png
        widget-small-tinted.png
        widget-medium-default.png
        widget-medium-dark.png
        widget-medium-clear.png
        widget-medium-tinted.png
```

Manifest:

```json
{
  "schemaVersion": 1,
  "id": "bay",
  "name": "Bay",
  "gridWidth": 1024,
  "gridHeight": 512,
  "domainWidthMeters": 40000,
  "domainHeightMeters": 20000,
  "rowOrder": "bottom-to-top",
  "textureOrigin": "top-left",
  "textureUVTransform": [1, 0, 0, -1, 0, 1],
  "recommendedAspect": 2.0,
  "landTextureColorSpace": "sRGB",
  "bankElevationMetersASL": 2.0
}
```

Binary fields use little-endian Float32 row-major bottom-to-top, matching the scene-field contract. Textures use top-left image coordinates and the explicit UV transform.

### 9.1 Asset ownership

The following artifacts are generated outside Codex and delivered ready to integrate:

```text
Bay.tidemap
Lake.tidemap
generate_tide_maps.py
asset validation report
preview contact sheets
```

Codex tasks:

```text
implement loader
copy assets into bundle
validate manifest and dimensions
wire scenes into gallery/widget
```

Codex must not redraw roads, shorelines, parks, blocks, or bathymetry unless a generated asset is corrupt.

## 10. Bay map specification

Name:

```text
Bay
```

Dimensions:

```text
solver grid:       1024×512
widget aspect:     2:1
physical extent:   approximately 40 km × 20 km
```

Composition, loosely inspired by a funnel-shaped estuary:

```text
wide open water on the right
estuary narrowing toward the left
curved north and south banks
one main river entering from the west
shallow bars and secondary channels
urban road/block texture on both banks
several park/green zones
no geographic labels required
```

Physical terrain:

```text
main river/ocean bed: negative ASL
shoals: shallow but mostly submerged
river embankment: at least 2 m ASL
urban land behind embankment: generally above 2 m ASL
selected low basins may remain floodable for visual testing
```

The embankment must be represented in `bed_elevation.f32`, not only painted in the texture.

Default display-session behavior:

```text
slow driven tide or smooth surge
mostly stable shoreline with visible movement near bars/basins
suitable for 5–12 FPS interpolation
```

## 11. Lake map specification

Name:

```text
Lake
```

Dimensions:

```text
solver grid:       512×512
widget aspect:     1:1
physical extent:   approximately 4 km × 4 km
```

Composition, loosely inspired by West Lake:

```text
irregular main lake
one or more narrow causeways
small islands
separated coves
dense urban texture outside the lake
parks and tree belts near parts of the shore
no copied labels or map tiles
```

Physical terrain:

```text
lake bed below water surface
lake bank: at least 1 m ASL
causeways and islands represented as real raised bed
urban land generally above the bank
```

Default behavior:

```text
calm water
small periodic seiche or low-amplitude tide-like forcing
clear response to click ripple
```

## 12. Brush redesign

### 12.1 Tool state

Replace the four separate brush tools with:

```text
Tool:
    Inspect
    Brush
    Polygon
    Ripple

Brush action segmented control:
    Add      icon: plus
    Erase    icon: eraser/minus

Brush material segmented control:
    Land     icon: mountain/land
    Water    icon: drop
```

Mapping:

```text
Add   + Land  -> addSand
Erase + Land  -> removeSand
Add   + Water -> addWater
Erase + Water -> removeWater
```

Both selectors use icon segmented pickers. Do not use Boolean switches or checkboxes.

Polygon uses the same action/material state unless a separate polygon override is strictly required.

### 12.2 Raised-cosine rolloff

Parameters:

```text
r = half-amplitude radius
L = rolloff length, 0 <= L <= r
R = distance from brush center
support radius = r + L
```

Weight:

```text
w(R) = 1
    when R <= r - L

w(R) = 0.5 * [1 + cos(pi * (R - r + L) / (2L))]
    when r - L < R < r + L and L > 0

w(R) = 0
    when R >= r + L
```

Required points:

```text
w(r-L) = 1
w(r)   = 0.5
w(r+L) = 0
```

`L=0` is a hard disk of radius `r`.

UI:

```text
Radius slider
Rolloff slider: 0 ... Radius
Rate/Amount slider
```

Preview rings:

```text
full-strength boundary: r-L
half-strength boundary: r
support boundary: r+L
```

Resample drag strokes by world distance. Paint result must not depend materially on mouse event frequency.

## 13. Ripple interaction

### 13.1 Physical model

Do not add vertical velocity.

Apply a discrete volume-neutral depth perturbation on wet cells:

```text
center:
    negative displacement

surrounding ring:
    positive displacement

sum(deltaH * cellArea) = 0 after clipping and discrete correction
```

This represents a surface press followed by release. Gravity produces the outward circular wave.

Optional later enhancement:

```text
small horizontal radial velocity impulse in u/v
```

Do not include it in the first implementation unless depth-only ripple is visually insufficient.

### 13.2 Charge

App and floating window:

```text
pointer down:
    begin charging and show preview

pointer held:
    charge increases with time and saturates

pointer release:
    submit one ripple
```

Recommended mapping:

```text
charge = smoothstep(0, maximumHoldTime, heldTime)
radius = mix(minRadius, maxRadius, charge)
amplitude = maxAmplitude * (1 - exp(-k * charge))
```

Before commit, scale the perturbation so no cell becomes negative and volume remains zero to numerical tolerance.

### 13.3 Surfaces

Support:

```text
2D Normal:
    precise coordinate and hold duration

App Widget Preview:
    precise coordinate and hold duration

Floating 3D:
    existing 3D picker + hold duration
    preview projected on visible water

Actual Widget:
    coarse discrete hotspots through Button + AppIntent
    no reliable hold-duration measurement
```

Actual Widget ripple strength is selected in widget configuration:

```text
Gentle
Medium
Strong
```

Use an invisible but accessibility-valid hotspot grid:

```text
systemSmall:  6×6 maximum
systemMedium: 10×5 maximum
```

Do not create hundreds of buttons. Reject hotspots whose mapped point is dry using the latest batch's coarse water mask.

## 14. Macro implementation stages

These are the only execution stages. Do not stop after every subsection.

### Stage A — Shared contracts, display agent, and map loader

Implement together:

```text
TideShared schemas
App Group container paths
TideEngineKit extraction/reuse
TideDisplayAgent login-item target
SMAppService enable/disable/status
XPC control
durable command queue
tidemap loader and validation
```

Gate:

```text
targets build and sign
agent registration state works
app/agent/widget read the same App Group
command idempotency tests
map-loader tests
no privileged daemon installation
```

### Stage B — Generated maps and Widget presentation

Inputs produced outside Codex:

```text
Bay.tidemap
Lake.tidemap
generator source
preview contact sheets
```

Codex implements:

```text
scene integration
Widget-only renderer
texture/elevation modes
final-resolution foam
fullColor/accented/vibrant layer handling
app preview workspace
```

Gate:

```text
all asset validations
Bay/Lake physical-height assertions
normal 2D unchanged
small/medium snapshots for Default/Dark/Clear/Tinted
no visible grid-cell shoreline
texture mode preserves dry-land RGB
```

### Stage C — Prediction generation and WidgetKit extension

Implement:

```text
authoritative display session
prediction scratch clone
adaptive 2–10 second keyframes
atomic batch publication
Widget TimelineProvider
TimelineView 5/8/12 requested cadence
current-time frame selection
AppIntent ripple hotspots
batch invalidation/regeneration
```

Gate:

```text
deterministic frame selection from arbitrary Date
missed update jumps to correct time
expired batch holds final frame
ripple command invalidates old generation
no per-frame timeline reload
Widget extension never creates the full solver
```

### Stage D — Floating 3D panel and charged ripple

Implement:

```text
reusable 3D renderer input boundary
display-agent NSPanel
60/75 requested FPS controls
actual FPS instrumentation
visibility/occlusion pause policy
camera/picking reuse
charged ripple in 2D preview and 3D panel
raised-cosine brush controls and Engine kernel
```

Gate:

```text
existing 3D renderer/shaders reused
no duplicate renderer implementation
panel closed -> zero draw work
actual frame pacing recorded
ripple volume neutral
brush falloff exact at r-L, r, r+L
stroke result insensitive to event sampling
```

### Stage E — Consolidated validation and documentation

Run grouped suites:

```text
MapAssetSuite
WidgetAppearanceSuite
PredictionTimelineSuite
DisplayAgentIPCSuite
BrushRippleSuite
FloatingMetalSuite
ExistingRegressionSuite
```

Required real-system checks:

```text
one installed WidgetKit cadence observation:
    Eco/Balanced/Smooth
    record actual update intervals and system degradation

one floating-panel frame-pacing observation:
    60 and 75 requested
    record display refresh and achieved FPS
```

These are the only tests that require a real visible desktop/window. They do not require automated mouse takeover unless the AppIntent or pointer-hold behavior cannot be triggered through focused test APIs.

Do not run a broad interactive UI suite merely to confirm static layout.

## 15. Suggested commits

Target five or six substantial commits:

```text
feat: add shared display service and tidemap contracts
feat: integrate Bay and Lake widget map presentations
feat: add predicted-frame WidgetKit extension
feat: add reusable floating Metal display panel
feat: add raised-cosine brush and charged ripples
test: validate widget agent maps and floating rendering
```

Do not create separate commits for each icon, slider, mask file, or performance counter.

## 16. Definition of Done

- [ ] A native `systemSmall` 1:1 widget and `systemMedium` 2:1 widget are available from macOS Widget Gallery.
- [ ] Widget requests 5/8/12 FPS using current-time animation scheduling and remains correct when the system lowers cadence.
- [ ] Widget visual state comes from a valid precomputed prediction batch; it never advances the full solver per display update.
- [ ] No recurring per-frame WidgetKit timeline reload is used.
- [ ] The optional per-user display agent is user-controlled and requires no administrator privilege.
- [ ] The display agent consumes Widget ripple commands exactly once.
- [ ] The floating panel requests 60/75 FPS, reports actual FPS, and reuses the existing 3D Metal renderer.
- [ ] Closing or occluding the floating panel stops unnecessary draw work.
- [ ] `2D Normal` remains visually and behaviorally unchanged except for the explicitly requested brush/ripple tool redesign.
- [ ] Widget-only shoreline foam is white, antialiased, non-grid-like, and does not copy other reference-game colors.
- [ ] Default, Dark, Clear, and Tinted widget previews are available inside the app and match the actual shared widget view.
- [ ] Texture mode preserves dry-land texture colors and overlays dynamic water only where wet.
- [ ] Elevation mode uses the existing green-yellow land and blue water scales.
- [ ] `Bay` provides a 2:1 estuary/city scene with a physical 2 m ASL embankment.
- [ ] `Lake` provides a 1:1 lake/city scene with a physical 1 m ASL bank and real raised causeways/islands.
- [ ] Bay/Lake art, masks, fields, previews, and source generator are delivered as ready-to-integrate assets rather than delegated to Codex.
- [ ] Add/Erase and Land/Water are icon segmented controls.
- [ ] Raised-cosine rolloff satisfies the exact support and half-amplitude definitions.
- [ ] App and floating-window ripple size depends on hold duration.
- [ ] Actual Widget ripple uses discrete hotspots and configured strength.
- [ ] Ripple is volume neutral and does not introduce vertical velocity.
- [ ] Final non-interactive regression suite passes; only the two justified real-system cadence checks require visible UI.

