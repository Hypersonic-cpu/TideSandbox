import Foundation
import SwiftUI

enum DisplayMode: String, CaseIterable, Identifiable, Sendable {
    case bedElevation
    case waterDepth
    case surfaceElevation
    case surfaceDeviation
    case velocityMagnitude
    case wetDry

    var id: Self { self }

    var title: String {
        switch self {
        case .bedElevation: "Bed"
        case .waterDepth: "Water depth"
        case .surfaceElevation: "Surface"
        case .surfaceDeviation: "Deviation"
        case .velocityMagnitude: "Velocity"
        case .wetDry: "Wet / dry"
        }
    }

    var preferredPalette: ColorPalette {
        switch self {
        case .bedElevation: .sand
        case .waterDepth, .surfaceElevation, .velocityMagnitude: .blueWhite
        case .surfaceDeviation: .diverging
        case .wetDry: .grayscale
        }
    }
}

enum ColorPalette: String, CaseIterable, Identifiable, Sendable {
    case grayscale
    case blueWhite
    case sand
    case diverging

    var id: Self { self }

    var title: String {
        switch self {
        case .grayscale: "Grayscale"
        case .blueWhite: "Blue–white"
        case .sand: "Sand"
        case .diverging: "Diverging"
        }
    }
}

struct ScalarRange: Equatable, Sendable {
    let minimum: Float
    let maximum: Float

    static func finiteRange(of values: [Float], signed: Bool = false) -> ScalarRange {
        var minimum = Float.infinity
        var maximum = -Float.infinity
        for value in values where value.isFinite {
            minimum = Swift.min(minimum, value)
            maximum = Swift.max(maximum, value)
        }
        guard minimum.isFinite, maximum.isFinite else { return ScalarRange(minimum: 0, maximum: 1) }
        if signed {
            let magnitude = Swift.max(
                Swift.max(abs(minimum), abs(maximum)),
                Float.leastNonzeroMagnitude
            )
            return ScalarRange(minimum: -magnitude, maximum: magnitude)
        }
        if minimum == maximum {
            let padding = Swift.max(abs(minimum) * 0.05, 1e-6)
            return ScalarRange(minimum: minimum - padding, maximum: maximum + padding)
        }
        return ScalarRange(minimum: minimum, maximum: maximum)
    }
}

struct RGBA: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    var color: Color {
        Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}

enum ColorMap {
    static let invalid = RGBA(red: 255, green: 0, blue: 220, alpha: 255)

    static func map(_ value: Float, range: ScalarRange, palette: ColorPalette) -> RGBA {
        guard value.isFinite else { return invalid }
        let denominator = range.maximum - range.minimum
        let normalized = denominator > 0 ? (value - range.minimum) / denominator : 0.5
        let t = Swift.max(0, Swift.min(normalized, 1))
        switch palette {
        case .grayscale:
            let channel = byte(t)
            return RGBA(red: channel, green: channel, blue: channel, alpha: 255)
        case .blueWhite:
            return interpolate(
                from: RGBA(red: 8, green: 68, blue: 120, alpha: 255),
                to: RGBA(red: 226, green: 242, blue: 250, alpha: 255),
                t: t
            )
        case .sand:
            return interpolate(
                from: RGBA(red: 82, green: 61, blue: 39, alpha: 255),
                to: RGBA(red: 232, green: 207, blue: 156, alpha: 255),
                t: t
            )
        case .diverging:
            if t < 0.5 {
                return interpolate(
                    from: RGBA(red: 40, green: 96, blue: 170, alpha: 255),
                    to: RGBA(red: 241, green: 241, blue: 236, alpha: 255),
                    t: t * 2
                )
            }
            return interpolate(
                from: RGBA(red: 241, green: 241, blue: 236, alpha: 255),
                to: RGBA(red: 188, green: 61, blue: 48, alpha: 255),
                t: (t - 0.5) * 2
            )
        }
    }

    private static func interpolate(from: RGBA, to: RGBA, t: Float) -> RGBA {
        func channel(_ first: UInt8, _ second: UInt8) -> UInt8 {
            byte(Float(first) / 255 + (Float(second) - Float(first)) / 255 * t)
        }
        return RGBA(
            red: channel(from.red, to.red),
            green: channel(from.green, to.green),
            blue: channel(from.blue, to.blue),
            alpha: 255
        )
    }

    private static func byte(_ value: Float) -> UInt8 {
        UInt8((Swift.max(0, Swift.min(value, 1)) * 255).rounded())
    }
}
