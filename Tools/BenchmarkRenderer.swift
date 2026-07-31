import CoreGraphics
import Foundation

@main
enum BenchmarkRenderer {
    private struct Summary {
        let medianMilliseconds: Double
        let medianAbsoluteDeviationMilliseconds: Double
    }

    private static func summarize(_ values: [Double]) -> Summary {
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        let deviations = sorted.map { abs($0 - median) }.sorted()
        return Summary(
            medianMilliseconds: median,
            medianAbsoluteDeviationMilliseconds: deviations[deviations.count / 2]
        )
    }

    private static func values(size: Int) -> [Float] {
        (0..<(size * size)).map { index in
            let row = index / size
            let column = index % size
            return 2 + 0.2 * sin(Float(column) * 0.17) * cos(Float(row) * 0.13)
        }
    }

    private static func iterationCount(size: Int) -> Int {
        switch size {
        case ...16: 500
        case ...32: 300
        case ...128: 80
        default: 15
        }
    }

    private static func benchmark(
        values: [Float],
        size: Int,
        policy: DisplayResolutionPolicy,
        target: CGSize,
        iterations: Int
    ) -> Summary {
        let warmup = ScalarRasterizer.image(
            engineValues: values,
            width: size,
            height: size,
            signed: false,
            palette: .blueWhite,
            policy: policy,
            targetPixelSize: target
        )
        precondition(warmup != nil)
        var samples: [Double] = []
        var observedWidth = 0
        for _ in 0..<5 {
            let start = ContinuousClock.now
            for _ in 0..<iterations {
                autoreleasepool {
                    let image = ScalarRasterizer.image(
                        engineValues: values,
                        width: size,
                        height: size,
                        signed: false,
                        palette: .blueWhite,
                        policy: policy,
                        targetPixelSize: target
                    )
                    observedWidth += image?.width ?? 0
                }
            }
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) +
                Double(elapsed.components.attoseconds) / 1e18
            samples.append(seconds * 1_000 / Double(iterations))
        }
        precondition(observedWidth > 0)
        return summarize(samples)
    }

    static func main() {
#if DEBUG
        let build = "Debug"
#else
        let build = "Release"
#endif
        print("RENDER_META,\(build)")
        for size in [16, 32, 128, 512] {
            let source = values(size: size)
            let iterations = iterationCount(size: size)
            let summary = benchmark(
                values: source,
                size: size,
                policy: .identicalCells,
                target: CGSize(width: size, height: size),
                iterations: iterations
            )
            print("RENDER,\(size),\(iterations),\(summary.medianMilliseconds)," +
                  "\(summary.medianAbsoluteDeviationMilliseconds)")
        }
        let source = values(size: 512)
        for policy in DisplayResolutionPolicy.allCases where policy != .identicalCells {
            let summary = benchmark(
                values: source,
                size: 512,
                policy: policy,
                target: CGSize(width: 256, height: 192),
                iterations: 10
            )
            print("POLICY,\(policy.rawValue),512,256,192," +
                  "\(summary.medianMilliseconds)," +
                  "\(summary.medianAbsoluteDeviationMilliseconds)")
        }
    }
}
