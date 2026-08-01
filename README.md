# TideMapAssets

Extract or copy this directory structure into the TideSandbox repository root:

```text
TideSandbox/
├── Assets/
│   └── TideMaps/
│       ├── Bay.tidemap/
│       └── Lake.tidemap/
├── Tools/
│   └── MapGeneration/
│       └── generate_tide_maps.py
└── Docs/
    └── MapAssets/
        ├── asset_validation_report.md
        └── previews/
```

Codex should load the `.tidemap` packages from `Assets/TideMaps/`.
The generator is a reproducibility/development tool and should not be included in the shipping app bundle.
The preview files are review artifacts and should not be loaded at runtime.
