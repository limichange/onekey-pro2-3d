import CoreGraphics
import Foundation
import simd
import UIKit

/// `colors.json`: one black base model, recoloured per colourway.
struct ColorSpec: Decodable {
    struct Colorway: Decodable {
        let swatch: String?
        /// `glossy-dark` selects the darker studio state ("Black").
        let studioVariant: String?
        /// Multiplier for every softbox reflection.
        let studioIntensity: Float?
        /// Dim fill between the softboxes so mirror metal never reflects pure black.
        let studioBackground: String?
        let groupColors: [String: String]?
        let roleColors: [String: String]?
        let roleIntensity: [String: Float]?
        let roleMaterial: [String: [String: Float]]?
        let materialColors: [String: String]?

        var studioState: String? { studioVariant == "glossy-dark" ? "Black" : nil }
    }

    let groups: [String: [String]]
    let colors: [String: Colorway]
    let `default`: String

    func group(forMaterial name: String) -> String? {
        groups.first { $0.value.contains(name) }?.key
    }
}

enum ColorMath {
    static func srgbToLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func linearToSrgb(_ c: Float) -> Float {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    static func srgb(hex: String) -> SIMD3<Float> {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        return SIMD3(Float((v >> 16) & 0xFF), Float((v >> 8) & 0xFF), Float(v & 0xFF)) / 255
    }

    static func linear(hex: String) -> SIMD3<Float> {
        let c = srgb(hex: hex)
        return SIMD3(srgbToLinear(c.x), srgbToLinear(c.y), srgbToLinear(c.z))
    }

    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// A UIColor carrying linear values in an explicit linear colour space.
    static func uiColor(linear c: SIMD3<Float>) -> UIColor {
        let components: [CGFloat] = [CGFloat(c.x), CGFloat(c.y), CGFloat(c.z), 1]
        return UIColor(cgColor: CGColor(colorSpace: linearSpace, components: components)!)
    }

    /// HSL tweak in sRGB space, like three.js `getHSL/setHSL(…, SRGBColorSpace)`.
    static func adjust(linear c: SIMD3<Float>, hueDegrees: Float, saturation: Float, lightness: Float) -> SIMD3<Float> {
        if hueDegrees == 0 && saturation == 1 && lightness == 1 { return c }
        let s = SIMD3(linearToSrgb(c.x), linearToSrgb(c.y), linearToSrgb(c.z))
        var (h, sat, l) = rgbToHsl(s)
        h = (h + hueDegrees / 360).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        sat = min(max(sat * saturation, 0), 1)
        l = min(max(l * lightness, 0), 1)
        let out = hslToRgb(h, sat, l)
        return SIMD3(srgbToLinear(out.x), srgbToLinear(out.y), srgbToLinear(out.z))
    }

    private static func rgbToHsl(_ c: SIMD3<Float>) -> (Float, Float, Float) {
        let maxC = max(c.x, c.y, c.z), minC = min(c.x, c.y, c.z)
        let l = (maxC + minC) / 2
        guard maxC != minC else { return (0, 0, l) }
        let d = maxC - minC
        let s = l <= 0.5 ? d / (maxC + minC) : d / (2 - maxC - minC)
        var h: Float
        switch maxC {
        case c.x: h = (c.y - c.z) / d + (c.y < c.z ? 6 : 0)
        case c.y: h = (c.z - c.x) / d + 2
        default: h = (c.x - c.y) / d + 4
        }
        h /= 6
        return (h, s, l)
    }

    private static func hslToRgb(_ h: Float, _ s: Float, _ l: Float) -> SIMD3<Float> {
        guard s > 0 else { return SIMD3(repeating: l) }
        func hue(_ p: Float, _ q: Float, _ t0: Float) -> Float {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * 6 * (2 / 3 - t) }
            return p
        }
        let q = l <= 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return SIMD3(hue(p, q, h + 1 / 3), hue(p, q, h), hue(p, q, h - 1 / 3))
    }
}
