# `.waterscene` package format

Schema version: **1**

A scene is a directory whose filename ends in `.waterscene`:

```text
Example.waterscene/
├── manifest.json
├── bed_elevation.bin
├── initial_water_depth.bin
├── preview.png
└── notes.md                 optional
```

## Field encoding

- `bed_elevation.bin` and `initial_water_depth.bin` contain exactly
  `gridWidth × gridHeight` IEEE-754 `Float32` values.
- Each value is little-endian, independent of the host architecture.
- Storage is contiguous row-major: index = `row × gridWidth + column`.
- Row 0 is the physical bottom/south row and columns increase right/east.
- Depth must be finite and nonnegative; bed values must be finite.
- Velocity is transient solver state and is not persisted in schema 1.
- Field matrices remain ordinary binary files. They are never embedded as JSON
  or archived into an opaque database.

## Manifest

`manifest.json` is UTF-8 JSON. It contains:

- `schemaVersion`, currently `1`;
- stable scene `id` (UUID), `name`, `createdAt`, and `modifiedAt`;
- grid and physical domain dimensions;
- initialization mode and solver parameters;
- the field, preview, and optional notes filenames;
- source type (`builtIn`, `user`, or `imported`);
- optional description and tags;
- explicit `storedByteOrder`, `storedScalarType`, and `storedRowOrder` markers.

Resource names must be unique simple filenames. Absolute paths, path
components, hidden names, and symbolic-link resources are rejected. Readers
reject unsupported schemas/encodings, invalid dimensions, byte-count mismatch,
non-finite fields, negative depth, malformed JSON, and invalid PNG previews with
readable errors.

## Storage and authority

User and imported packages are stored under:

```text
~/Library/Application Support/WaterSandbox/Scenes/<uuid>.waterscene/
```

Each package is authoritative. `catalog.json` contains only rebuildable gallery
metadata and relative package locations. Writes build and validate a sibling
temporary package before a same-volume atomic replacement. Built-in packages
ship in the signed application bundle and are always opened read-only; saving a
built-in creates a new user package with a new UUID.
