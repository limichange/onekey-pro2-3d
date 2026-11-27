import CoreGraphics
import Foundation
import simd

/// Rasterises softbox quads into an HDR equirectangular environment, the way a cube camera at
/// the origin would see them: alpha-blended back to front over a flat fill colour.
enum StudioBaker {
    struct Image {
        let width: Int
        let height: Int
        let pixels: [Float] // RGBA, linear
    }

    /// World direction through the centre of an equirect texel (u, v in 0…1, v = 0 at the top).
    /// The image centre looks down -Z, +X is to the right: RealityKit's skybox convention.
    @inline(__always)
    static func direction(u: Float, v: Float) -> SIMD3<Float> {
        let lon = (u - 0.5) * 2 * .pi
        let lat = (0.5 - v) * .pi
        return SIMD3(sin(lon) * cos(lat), sin(lat), -cos(lon) * cos(lat))
    }

    static func render(quads: [WorldQuad], background: SIMD3<Float>, width: Int, height: Int) -> Image {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let maxHits = 8
        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let out = buffer.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: height) { y in
                var hitT = [Float](repeating: 0, count: maxHits)
                var hitColor = [SIMD3<Float>](repeating: .zero, count: maxHits)
                var hitAlpha = [Float](repeating: 0, count: maxHits)
                let v = (Float(y) + 0.5) / Float(height)
                for x in 0..<width {
                    let d = direction(u: (Float(x) + 0.5) / Float(width), v: v)
                    var count = 0
                    for q in quads {
                        if simd_dot(d, q.coneAxis) < q.coneCos { continue }
                        let denom = simd_dot(d, q.planeNormal)
                        if abs(denom) < 1e-9 { continue }
                        let t = q.planeDistance / denom
                        if t <= 3 || t > 2000 { continue } // cube camera near/far
                        if !q.doubleSided && simd_dot(d, q.front) >= 0 { continue } // back face
                        let r = d * t - q.q0
                        let w1 = simd_dot(simd_cross(r, q.n2), q.planeNormal) * q.invNormalLengthSquared
                        let w2 = simd_dot(simd_cross(q.n1, r), q.planeNormal) * q.invNormalLengthSquared
                        let uv = q.uv0 + SIMD2(w1, w2)
                        if uv.x < q.uvMin.x || uv.x > q.uvMax.x || uv.y < q.uvMin.y || uv.y > q.uvMax.y { continue }
                        let alpha = (q.mask?.sample(uv) ?? 1) * q.opacity
                        if alpha <= 1e-4 { continue }
                        // Insert sorted far → near.
                        var i = min(count, maxHits - 1)
                        while i > 0 && hitT[i - 1] < t {
                            hitT[i] = hitT[i - 1]; hitColor[i] = hitColor[i - 1]; hitAlpha[i] = hitAlpha[i - 1]
                            i -= 1
                        }
                        hitT[i] = t; hitColor[i] = q.radiance; hitAlpha[i] = min(alpha, 1)
                        count = min(count + 1, maxHits)
                    }
                    var c = background
                    for i in 0..<count {
                        c = hitColor[i] * hitAlpha[i] + c * (1 - hitAlpha[i])
                    }
                    let o = (y * width + x) * 4
                    out[o] = c.x
                    out[o + 1] = c.y
                    out[o + 2] = c.z
                    out[o + 3] = 1
                }
            }
        }
        return Image(width: width, height: height, pixels: pixels)
    }

    /// 32-bit float, extended linear sRGB: keeps the softboxes' HDR values (up to ~11).
    static func cgImage(_ image: Image) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
            | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        let data = image.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 32, bitsPerPixel: 128,
                       bytesPerRow: image.width * 16, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Debug environment with a coloured blob on each axis, to verify the equirect convention.
    static func axisMarkers(width: Int, height: Int) -> Image {
        let markers: [(SIMD3<Float>, SIMD3<Float>)] = [
            ([1, 0, 0], [1, 0, 0]), ([-1, 0, 0], [0, 1, 1]),
            ([0, 1, 0], [0, 1, 0]), ([0, -1, 0], [1, 0, 1]),
            ([0, 0, 1], [0, 0, 1]), ([0, 0, -1], [1, 1, 0]),
        ]
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let d = direction(u: (Float(x) + 0.5) / Float(width), v: (Float(y) + 0.5) / Float(height))
                var c = SIMD3<Float>(repeating: 0.05)
                for (axis, color) in markers where simd_dot(d, axis) > 0.97 { c = color }
                // 10° right of -Z (towards +X) and 10° above -Z: handedness / flip check.
                if simd_dot(d, simd_normalize(SIMD3(0.18, 0, -1))) > 0.9995 { c = [1, 1, 1] }
                if simd_dot(d, simd_normalize(SIMD3(0, 0.18, -1))) > 0.9995 { c = [1, 0.5, 0] }
                let o = (y * width + x) * 4
                pixels[o] = c.x; pixels[o + 1] = c.y; pixels[o + 2] = c.z; pixels[o + 3] = 1
            }
        }
        return Image(width: width, height: height, pixels: pixels)
    }
}
