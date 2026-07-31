# TideSandbox 3D Controls

Select **3D** in the Display inspector to show the current simulation snapshot
as separate terrain and water height fields. Switching between 2D and 3D does
not reset, advance, save, or dirty the scene.

## Camera

- Drag with the left mouse button to orbit. Horizontal motion accumulates yaw;
  vertical motion changes pitch within the safe viewing range.
- Shift-left-drag or middle-drag to pan in the camera plane.
- Scroll to zoom.
- Double-click the viewport, press `F`, or choose **Fit view** to frame the
  complete domain.
- Press `1`, `2`, `3`, or `4` for Top, Isometric, Low oblique, or Opposite
  oblique.
- Use the **Yaw** and **Pitch** bars for explicit angles. Pointer interaction or
  manual bar changes select the Custom camera state.

The camera state survives ordinary 2D/3D switching and Gallery presentation in
the current session. Loading a scene or preset, changing vertical exaggeration,
or choosing Fit view deliberately computes a fresh fit.

## Display

- **Vertical exaggeration** scales displayed elevation only; it never changes
  bed elevation, water depth, solver values, or saved scene data.
- **Water opacity** changes only the 3D water pass.
- **3D Debug** can show terrain/water wireframes, domain bounds, sparse surface
  normals, the wet-cell mask, and the camera target.

## Current limitations

- Terrain editing remains a 2D workflow in this version. Make edits in 2D, then
  switch to 3D to inspect the shared updated snapshot.
- Transparent water uses one stable premultiplied-alpha pass without
  per-triangle sorting, refraction, or reflection.
- Decorative waves, foam, spray, and splashing are not synthesized; the water
  surface shows only the SWE state.
- View mode, camera, debug flags, vertical exaggeration, and opacity are session
  UI state and are not stored in `.waterscene` packages.
