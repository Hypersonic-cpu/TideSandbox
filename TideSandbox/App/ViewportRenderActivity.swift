import Foundation

@MainActor
enum ViewportRenderActivity {
    struct Counters: Equatable, Sendable {
        var mosaicRasterizations = 0
        var scalarResamples = 0
        var metalSnapshotUpdates = 0
        var metalDraws = 0
    }

    #if DEBUG
    private(set) static var counters = Counters()

    static func reset() {
        counters = Counters()
    }

    static func recordMosaicRasterization() {
        counters.mosaicRasterizations += 1
    }

    static func recordScalarResample() {
        counters.scalarResamples += 1
    }

    static func recordMetalSnapshotUpdate() {
        counters.metalSnapshotUpdates += 1
    }

    static func recordMetalDraw() {
        counters.metalDraws += 1
    }
    #else
    static var counters: Counters { Counters() }
    static func reset() {}
    static func recordMosaicRasterization() {}
    static func recordScalarResample() {}
    static func recordMetalSnapshotUpdate() {}
    static func recordMetalDraw() {}
    #endif
}
