# 3D Renderer 2D Baseline

This baseline was recorded on 2026-08-01 before any product source was changed
for `RENDER_3D_PLAN.md`. The parent product commit is `2c8341e`.

## Regression baseline

The complete product unit suite passed in Debug:

```text
Engine, bridge, display, persistence: 28/28 passed
Result bundle: /private/tmp/TideSandboxRender3DBaselineTests.xcresult
```

The complete normally signed macOS UI suite then passed in one run:

```text
Product UI tests: 5/5 passed
Launch tests (light and dark): 2/2 passed
Total: 7/7 passed, 99.313 s
Result bundle: /private/tmp/TideSandboxRender3DBaselineUIRetry.xcresult
```

## Default-scene numerical checkpoint

`Tools/RecordRender3DBaseline.cc` reconstructs the exact Float32-rounded
`32 × 32 Center Bump` launch seed, uses the default solver configuration, and
advances 120 deterministic 1/60-second frames with one worker. The checkpoint
is therefore independent of wall-clock UI scheduling.

```text
frames=120
frame_duration=0.016666666666666666
simulated_time=1.9999999999999978
total_volume=997.94238066673302
maximum_depth=1.0000000096825417
maximum_speed=9.1571385829100175e-08
wet_cell_count=1024
```

Reproduce it with strict warnings:

```sh
clang++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Wconversion -Wshadow -Werror \
  -I TideSandbox/Engine Tools/RecordRender3DBaseline.cc \
  TideSandbox/Engine/*.cc -o /private/tmp/record_render3d_baseline
/private/tmp/record_render3d_baseline
```

The nearly zero speed is expected: the default bed bump is initialized beneath
a level free surface, so it is a lake-at-rest balance case.

## Visual checkpoint

The existing `testLaunchAndCoreSimulationControls` produced a window-only PNG
after play, pause, step, and reset. It is 1960 × 1424 pixels and has SHA-256:

```text
c2e6a2ce6f8bcc0abce45bae8afb5032dc2d78005b0e22b8b1613f3c4e2f24ab
```

The retained attachment for this validation run was exported to:

```text
/private/tmp/TideSandboxRender3DBaselineAttachments/
  B6C0C093-0FDE-49F9-A871-4FBC1C560698.png
```

Visual inspection confirmed the original top-down row orientation, crisp
one-pixel-per-cell mosaic, aligned grid overlay, centered floating toolbar, and
an unclipped inspector. The screenshot is scoped to the application window and
does not capture the desktop.
