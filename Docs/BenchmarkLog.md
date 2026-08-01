# TideSandbox Benchmark Log

## 2026-08-01 — Phase 5 CPU baseline and measured optimization

### Method

Measurements ran on an Apple M4 MacBook Air with 10 CPU cores (4 performance,
6 efficiency) and 16 GB RAM, macOS 26.5.2. The toolchain was Xcode 26.6,
Apple Clang 21.0.0, and Apple Swift 6.3.3. The benchmark fixes the parallel case
at four workers so runs remain comparable.

`Tools/BenchmarkTideSandbox.mm` uses a finite, uneven-bed perturbed lake. Each
reported solver and snapshot value is the median of five batches; the batch
sizes are 400, 250, 40, and 8 iterations for 16², 32², 128², and 512².
`Tools/BenchmarkRenderer.swift` likewise reports five-batch medians. Times below
are milliseconds per operation. Solver time is end-to-end `stepOnce`, including
the CFL scan, numerical substep, validation, and diagnostics. Pass timers are
opt-in and are disabled for the end-to-end samples.

Debug uses `clang++ -O0 -g` and `swiftc -Onone -D DEBUG`. Release uses
`clang++ -O3 -DNDEBUG` and `swiftc -O`. Both C++ builds use C++20 and
`-Wall -Wextra -Wpedantic -Wconversion -Wshadow -Werror`.

### Final end-to-end results

| Build | Grid | 1 worker | 4 workers | Speedup | Snapshot | Exact raster | Engine fields | Snapshot payload |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Debug | 16² | 0.0601 | 0.0600 | 1.00× | 0.0087 | 0.0966 | 23,040 B | 5,376 B |
| Debug | 32² | 0.2353 | 0.2354 | 1.00× | 0.0329 | 0.2323 | 91,136 B | 21,504 B |
| Debug | 128² | 3.7268 | 1.8941 | 1.97× | 0.5685 | 2.8342 | 1,445,888 B | 344,064 B |
| Debug | 512² | 60.3591 | 29.1459 | 2.07× | 8.4476 | 44.2490 | 23,085,056 B | 5,505,024 B |
| Release | 16² | 0.0089 | 0.0065 | 1.36× | 0.0022 | 0.0078 | 23,040 B | 5,376 B |
| Release | 32² | 0.0150 | 0.0126 | 1.19× | 0.0025 | 0.0100 | 91,136 B | 21,504 B |
| Release | 128² | 0.1558 | 0.2201 | 0.71× | 0.0245 | 0.0615 | 1,445,888 B | 344,064 B |
| Release | 512² | 2.5481 | 1.7993 | 1.42× | 0.4681 | 0.6470 | 23,085,056 B | 5,505,024 B |

At 128² Release, dispatch and synchronization cost more than the parallel row
kernels save. This is why the existing 4,096-work-item serial threshold is
retained and why worker count remains user-selectable. At 512², four workers
provide a repeatable 1.42× end-to-end speedup despite the serial CFL,
validation, and diagnostics scans.

Median absolute deviations were below 0.108 ms for every final solver row,
below 0.026 ms for snapshots, and below 0.191 ms for exact rasters. The CSV
output includes every deviation for audit.

### Release pass profile, four workers

| Pass (ms/substep) | 16² | 32² | 128² | 512² |
|---|---:|---:|---:|---:|
| CFL/stable-step scan | 0.0008 | 0.0017 | 0.0223 | 0.4292 |
| Surface derivation | 0.0001 | 0.0001 | 0.0097 | 0.0323 |
| Pressure-gradient velocity | 0.0009 | 0.0021 | 0.0305 | 0.1595 |
| Damping/boundaries | 0.0001 | 0.0002 | 0.0171 | 0.0343 |
| Upwind flux | 0.0004 | 0.0007 | 0.0205 | 0.0704 |
| Donor limiter scale | 0.0003 | 0.0007 | 0.0132 | 0.0560 |
| Flux limiting | 0.0003 | 0.0006 | 0.0199 | 0.0662 |
| Continuity update | 0.0001 | 0.0003 | 0.0107 | 0.0341 |
| Positivity cleanup | 0.0002 | 0.0003 | 0.0050 | 0.0720 |
| Dry-donor velocity | 0.0003 | 0.0006 | 0.0214 | 0.0694 |
| Finite-state validation | 0.0006 | 0.0013 | 0.0229 | 0.3309 |
| Diagnostics | 0.0008 | 0.0018 | 0.0289 | 0.4875 |
| Numerical substep total | 0.0037 | 0.0072 | 0.1711 | 0.9254 |

The total encloses the numerical passes through validation; CFL and diagnostics
are outside it. Instrumentation overhead is therefore not included in the
unprofiled end-to-end table.

### Renderer policy cost

The exact raster retains one output pixel per cell. The scaling-policy benchmark
uses a 512² scalar field and a 256 × 192 target so area averaging exercises real
downsampling.

| Release renderer operation | Median ms |
|---|---:|
| Exact 512² mosaic | 0.6470 |
| Nearest cell, 256 × 192 | 0.3333 |
| Bilinear scalar, 256 × 192 | 0.5007 |
| Area average, 256 × 192 | 0.8491 |

Area-average output is capped at the Engine dimensions because it is a
downsampling policy. Nearest and bilinear modes may supersample to the physical
display pixel size. All policies operate only on copied scalar snapshots.

### Optimization decision and result

The baseline showed two actionable costs at 512² Release:

- the flux pass wrote two complete upwind-depth face arrays that no later pass
  read;
- snapshot publication built three `double` vectors and then copied six arrays
  into `NSData` objects.

The optimized solver computes donor depth directly into the flux and removes
the unused face arrays. The bridge now allocates detached snapshot buffers once,
fills all five `Float32` fields and the wet mask in one traversal, then transfers
ownership to immutable `NSData` without another byte copy.

| 512² Release metric | Before | After | Change |
|---|---:|---:|---:|
| Engine fields | 27,287,552 B | 23,085,056 B | −15.4% |
| Upwind flux pass, 1 worker | 0.5181 ms | 0.1726 ms | −66.7% |
| Upwind flux pass, 4 workers | 0.2126 ms | 0.0704 ms | −66.9% |
| Solver end-to-end, 1 worker | 2.9795 ms | 2.5481 ms | −14.5% |
| Solver end-to-end, 4 workers | 2.0472 ms | 1.7993 ms | −12.1% |
| Snapshot publication | 1.1268 ms | 0.4681 ms | −58.5% |

The removed arrays had no readers, and snapshot conversion remains detached
from Engine storage. Numerical invariant tests, exact CPU fingerprints, and
bridge round trips passed after the change.

### Reproduction

```sh
clang++ -std=c++20 -O3 -DNDEBUG -fobjc-arc \
  -Wall -Wextra -Wpedantic -Wconversion -Wshadow -Werror \
  -I TideSandbox/Engine -I TideSandbox/Bridge \
  Tools/BenchmarkTideSandbox.mm TideSandbox/Bridge/WaterEngineBridge.mm \
  TideSandbox/Engine/*.cc -framework Foundation -o /tmp/tide_benchmark
/tmp/tide_benchmark

swiftc -O -module-cache-path /tmp/tide-swift-module-cache \
  -framework SwiftUI -framework CoreGraphics \
  TideSandbox/App/ColorMap.swift TideSandbox/App/RasterRenderer.swift \
  Tools/BenchmarkRenderer.swift -o /tmp/tide_renderer_benchmark
/tmp/tide_renderer_benchmark
```

## 2026-08-01 — Automatic accelerated SWE Release sweep

Target: MacBook Air, Apple M4 (10 CPU cores, 10 GPU cores), 16 GB, macOS
26.5.2, Metal family Apple9. The standalone C++/Objective-C++ benchmark used
C++20, `-O3 -DNDEBUG`, ARC, and
`-Wall -Wextra -Wpedantic -Wconversion -Wshadow -Werror`. Each row is the
median of five measured repetitions after 20 warm-up steps. Physics time
includes stable-dt reduction and the complete numerical substep; snapshot
readback and direct 3D handoff are reported separately. The full machine-readable
archive is `AcceleratedBenchmark_2026-08-01.csv`.

| Grid | CPU step | Metal step | Automatic | Auto speedup | Snapshot | Direct 3D handoff |
|---|---:|---:|---|---:|---:|---:|
| 64² | 0.1541 ms | 0.4493 ms | CPU, 0.1617 ms | 0.95× | 0.0106 ms | 0.000013 ms |
| 128² | 0.3794 ms | 0.4457 ms | CPU, 0.3715 ms | 1.02× | 0.0315 ms | 0.000012 ms |
| 256² | 0.7495 ms | 0.5265 ms | Metal, 0.5232 ms | 1.43× | 0.3888 ms | 0.000073 ms |
| 384² | 1.4328 ms | 0.7255 ms | Metal, 0.7120 ms | 2.01× | 0.5711 ms | 0.000072 ms |
| 512² | 2.3879 ms | 1.1134 ms | Metal, 1.0580 ms | 2.26× | 1.0424 ms | 0.000071 ms |
| 256×512 | 1.2644 ms | 0.6690 ms | Metal, 0.6554 ms | 1.93× | 0.4933 ms | 0.000072 ms |

Break-even is bracketed by the 128² and 256² samples. The classifier uses
`8 * cells + 6 * faces`; Apple9 therefore uses a conservative rounded threshold
of 1,000,000 work units. MPSGraph was slower than Metal across the accelerated
samples, so Apple9 Automatic selects Metal above the threshold. Unknown device
families retain the conservative 1,313,792-work threshold and MPSGraph-first
capability order until measured. No rule contains a 512 dimension literal.

The warmed Metal backend owned 30 state-sized persistent allocations at every
sample and the allocation count stayed constant after warm-up. Direct handoff
consumes existing device buffers; it does not include CPU snapshot readback or
re-upload. The accepted implementation exceeds 2× on representative 384² and
512² workloads. Further tuning was stopped because the functional target and
performance gate were satisfied.
