import Foundation
import SwiftUI

enum DisplayMode: String, CaseIterable, Identifiable, Sendable {
    case decorativeComposite
    case bedElevation
    case waterDepth
    case surfaceElevation
    case surfaceDeviation
    case velocityMagnitude
    case wetDry

    var id: Self { self }

    var title: String {
        switch self {
        case .decorativeComposite: "Decorative composite"
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
        case .decorativeComposite: .blueWhite
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

struct DecorativeMapConfiguration: Equatable, Sendable {
    let landElevationMinimum: Float
    let landElevationMaximum: Float
    let waterDepthMaximum: Float
    let hClear: Float
    let hShallow: Float
    let hDeep: Float
    let hShallowAccent: Float
    let visualWetThreshold: Float
    let shoreHighlightStrength: Float
    let wetSandStrength: Float
    let autoRangeEnabled: Bool
    let submergedBedCoolingStrength: Float = 0.15

    static let `default` = DecorativeMapConfiguration(
        landElevationMinimum: -1,
        landElevationMaximum: 1,
        waterDepthMaximum: 2,
        hClear: 0.6,
        hShallow: 0.1,
        hDeep: 2,
        hShallowAccent: 0.25,
        visualWetThreshold: 1.0e-6,
        shoreHighlightStrength: 0.35,
        wetSandStrength: 0.2,
        autoRangeEnabled: false
    )

    static func stableScene(
        bedElevation: [Float],
        waterDepth: [Float],
        visualWetThreshold: Float = 1.0e-6
    ) -> DecorativeMapConfiguration {
        let bedRange = ScalarRange.finiteRange(of: bedElevation)
        let representativeDepth = max(
            waterDepth.lazy.filter { $0.isFinite && $0 >= 0 }.max() ?? 0,
            0.1
        )
        return DecorativeMapConfiguration(
            landElevationMinimum: bedRange.minimum,
            landElevationMaximum: bedRange.maximum,
            waterDepthMaximum: representativeDepth,
            hClear: representativeDepth * 0.3,
            hShallow: representativeDepth * 0.05,
            hDeep: representativeDepth * 0.85,
            hShallowAccent: representativeDepth * 0.15,
            visualWetThreshold: max(visualWetThreshold, 0),
            shoreHighlightStrength: 0.35,
            wetSandStrength: 0.2,
            autoRangeEnabled: false
        )
    }

    var isValid: Bool {
        landElevationMinimum.isFinite && landElevationMaximum.isFinite &&
        landElevationMaximum > landElevationMinimum &&
        waterDepthMaximum.isFinite && waterDepthMaximum > 0 &&
        hClear.isFinite && hClear > 0 &&
        hShallow.isFinite && hDeep.isFinite && hDeep > hShallow &&
        hShallowAccent.isFinite && hShallowAccent > 0 &&
        visualWetThreshold.isFinite && visualWetThreshold >= 0 &&
        shoreHighlightStrength.isFinite && (0...1).contains(shoreHighlightStrength) &&
        wetSandStrength.isFinite && (0...1).contains(wetSandStrength) &&
        submergedBedCoolingStrength.isFinite &&
        (0...1).contains(submergedBedCoolingStrength)
    }
}

enum ColorMap {
    static let invalid = RGBA(red: 255, green: 0, blue: 220, alpha: 255)
    static let landLow = RGBA(red: 0xE8, green: 0xD6, blue: 0xA5, alpha: 255)
    static let landMiddle = RGBA(red: 0xD8, green: 0xD7, blue: 0xA0, alpha: 255)
    static let landHigh = RGBA(red: 0xB7, green: 0xD2, blue: 0xA2, alpha: 255)
    static let submergedBed = RGBA(red: 0xD4, green: 0xE6, blue: 0xE4, alpha: 255)
    static let waterVeryShallow = RGBA(red: 0xBD, green: 0xEB, blue: 0xED, alpha: 255)
    static let waterShallow = RGBA(red: 0x85, green: 0xD3, blue: 0xDC, alpha: 255)
    static let waterMedium = RGBA(red: 0x55, green: 0x9F, blue: 0xC8, alpha: 255)
    static let waterDeep = RGBA(red: 0x2D, green: 0x6F, blue: 0xA7, alpha: 255)
    static let turquoiseAccent = RGBA(red: 0x77, green: 0xD8, blue: 0xD0, alpha: 255)
    static let shoreCyan = RGBA(red: 0xD3, green: 0xF4, blue: 0xF1, alpha: 255)
    static let wetSand = RGBA(red: 0xD3, green: 0xC2, blue: 0x8F, alpha: 255)

    static func decorativeComposite(
        bedElevation: Float,
        waterDepth: Float,
        configuration: DecorativeMapConfiguration
    ) -> RGBA {
        guard bedElevation.isFinite,
              waterDepth.isFinite,
              waterDepth >= 0,
              configuration.isValid else { return invalid }
        let land = terrainBase(bedElevation, configuration: configuration)
        guard waterDepth > 0 else { return land }
        let cooledBed = submergedTerrainBase(
            bedElevation,
            configuration: configuration
        )
        let water = waterGradient(depth: waterDepth, configuration: configuration)
        let opacity = waterOpticalOpacity(depth: waterDepth, configuration: configuration)
        let optical = interpolateLinear(from: cooledBed, to: water, t: opacity)
        let shallowAccent = exp(-pow(waterDepth / configuration.hShallowAccent, 2)) * 0.16
        return interpolateLinear(from: optical, to: turquoiseAccent, t: shallowAccent)
    }

    static func submergedTerrainBase(
        _ bedElevation: Float,
        configuration: DecorativeMapConfiguration
    ) -> RGBA {
        let land = terrainBase(bedElevation, configuration: configuration)
        guard land != invalid, configuration.isValid else { return invalid }
        return interpolateLinear(
            from: land,
            to: submergedBed,
            t: configuration.submergedBedCoolingStrength
        )
    }

    static func decorativeShoreline(
        _ color: RGBA,
        isWet: Bool,
        wetEdge: Bool,
        dryEdge: Bool,
        configuration: DecorativeMapConfiguration
    ) -> RGBA {
        guard configuration.isValid else { return invalid }
        if isWet && wetEdge {
            return interpolateLinear(
                from: color,
                to: shoreCyan,
                t: configuration.shoreHighlightStrength
            )
        }
        if !isWet && dryEdge {
            return interpolateLinear(from: color, to: wetSand, t: configuration.wetSandStrength)
        }
        return color
    }

    static func terrainBase(
        _ bedElevation: Float,
        configuration: DecorativeMapConfiguration
    ) -> RGBA {
        guard bedElevation.isFinite, configuration.isValid else { return invalid }
        let normalized = clamp(
            (bedElevation - configuration.landElevationMinimum) /
            (configuration.landElevationMaximum - configuration.landElevationMinimum)
        )
        if normalized <= 0.5 {
            return interpolateLinear(from: landLow, to: landMiddle, t: normalized * 2)
        }
        return interpolateLinear(from: landMiddle, to: landHigh, t: (normalized - 0.5) * 2)
    }

    static func waterGradient(
        depth: Float,
        configuration: DecorativeMapConfiguration
    ) -> RGBA {
        guard depth.isFinite, depth >= 0, configuration.isValid else { return invalid }
        let normalized = smoothstep(
            configuration.hShallow,
            configuration.hDeep,
            clamp(depth / configuration.waterDepthMaximum) * configuration.waterDepthMaximum
        )
        if normalized <= 1 / 3 {
            return interpolateLinear(from: waterVeryShallow, to: waterShallow, t: normalized * 3)
        }
        if normalized <= 2 / 3 {
            return interpolateLinear(from: waterShallow, to: waterMedium,
                                     t: (normalized - 1 / 3) * 3)
        }
        return interpolateLinear(from: waterMedium, to: waterDeep,
                                 t: (normalized - 2 / 3) * 3)
    }

    static func waterOpticalOpacity(
        depth: Float,
        configuration: DecorativeMapConfiguration
    ) -> Float {
        guard depth.isFinite, depth >= 0, configuration.isValid else { return .nan }
        return 1 - exp(-depth / configuration.hClear)
    }

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

    private static func interpolateLinear(from: RGBA, to: RGBA, t: Float) -> RGBA {
        let clamped = clamp(t)
        if clamped == 0 { return from }
        if clamped == 1 { return to }
        func linear(_ component: UInt8) -> Float {
            let srgb = Float(component) / 255
            return srgb <= 0.04045 ? srgb / 12.92 : pow((srgb + 0.055) / 1.055, 2.4)
        }
        func srgb(_ component: Float) -> UInt8 {
            let linear = clamp(component)
            let encoded = linear <= 0.0031308
                ? linear * 12.92
                : 1.055 * pow(linear, 1 / 2.4) - 0.055
            return byte(encoded)
        }
        return RGBA(
            red: srgb(linear(from.red) + (linear(to.red) - linear(from.red)) * clamped),
            green: srgb(linear(from.green) + (linear(to.green) - linear(from.green)) * clamped),
            blue: srgb(linear(from.blue) + (linear(to.blue) - linear(from.blue)) * clamped),
            alpha: 255
        )
    }

    private static func smoothstep(_ minimum: Float, _ maximum: Float, _ value: Float) -> Float {
        let normalized = clamp((value - minimum) / (maximum - minimum))
        return normalized * normalized * (3 - 2 * normalized)
    }

    private static func clamp(_ value: Float) -> Float {
        Swift.max(0, Swift.min(value, 1))
    }

    private static func byte(_ value: Float) -> UInt8 {
        UInt8((Swift.max(0, Swift.min(value, 1)) * 255).rounded())
    }
}
