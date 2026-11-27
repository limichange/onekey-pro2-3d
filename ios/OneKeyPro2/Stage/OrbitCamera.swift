import Foundation
import QuartzCore
import simd

/// Spherical orbit modelled on the product page's camera: drag to orbit, flick to throw, then
/// settle on the nearest curated angle. Also produces the lighting weights for those angles.
@MainActor
final class OrbitCamera {
    struct Sample {
        let label: String
        var weight: Float
        let distance: Float
        let multiplier: Float
    }

    private static let phiMin: Float = 1e-4
    private static let phiMax: Float = .pi - 1e-4
    static let minZoom: Float = 0.55
    static let maxZoom: Float = 1.6

    private(set) var phi: Float
    private(set) var theta: Float
    private var phiTarget: Float
    private var thetaTarget: Float
    private(set) var zoom: Float = 1
    var zoomTarget: Float = 1

    var snapEnabled = true
    var autoRotate = false
    private let autoRotateSpeed: Float = 0.35
    private let lerpDrag: Float = 0.2
    private let lerpSnap: Float = 0.095
    private var snapFactor: Float = 0.095
    private var settling = false
    private(set) var dragging = false
    private var idleSince = CACurrentMediaTime()

    private let angles: [StudioDefinition.Angle]
    private let lightAngles: [(label: String, threshold: Float, vector: SIMD3<Float>)]
    private let lightRadius: Float
    private(set) var weights: [Sample] = []
    private var needsUpdate = true

    init(studio: StudioDefinition) {
        angles = studio.angles
        lightRadius = studio.camera.radius
        var seen = Set<String>()
        lightAngles = studio.angles.compactMap { a in
            guard let label = a.label, seen.insert(label).inserted else { return nil }
            return (label, a.threshold, OrbitCamera.spherical(radius: studio.camera.radius, phi: a.phi, theta: a.theta))
        }
        phi = studio.start.phi
        theta = studio.start.theta
        phiTarget = phi
        thetaTarget = theta
        computeWeights()
    }

    /// three.js `setFromSphericalCoords`: phi from +Y, theta around Y from +Z.
    static func spherical(radius: Float, phi: Float, theta: Float) -> SIMD3<Float> {
        SIMD3(radius * sin(phi) * sin(theta), radius * cos(phi), radius * sin(phi) * cos(theta))
    }

    var direction: SIMD3<Float> { OrbitCamera.spherical(radius: 1, phi: phi, theta: theta) }

    var dominantLabel: String? { weights.first?.label }

    // MARK: - Interaction

    func beginDrag() {
        dragging = true
        settling = false
        thetaTarget = theta
        phiTarget = phi
        idleSince = CACurrentMediaTime()
    }

    /// `dx`/`dy` in points, `size` = reference size of the view in points.
    func drag(dx: Float, dy: Float, size: Float) {
        let s = max(320, size)
        thetaTarget += (-dx / s) * .pi * 1.25
        phiTarget = min(max(phiTarget + (-dy / s) * .pi * 1.1, Self.phiMin), Self.phiMax)
        idleSince = CACurrentMediaTime()
    }

    /// Velocity in points/second at release.
    func endDrag(velocityX: Float, velocityY: Float, size: Float) {
        dragging = false
        let s = max(320, size)
        let vTheta = (-velocityX / s) * .pi * 1.25
        let vPhi = (-velocityY / s) * .pi * 1.1
        thetaTarget += min(max(vTheta * 0.18, -.pi), .pi)
        phiTarget = min(max(phiTarget + vPhi * 0.12, Self.phiMin), Self.phiMax)
        idleSince = CACurrentMediaTime()
        if snapEnabled { snapToNearest() }
    }

    func snapToNearest() {
        let probe = OrbitCamera.spherical(radius: 1, phi: phiTarget, theta: thetaTarget)
        var best: StudioDefinition.Angle?
        var bestDistance = Float.infinity
        for a in angles {
            let d = simd_distance_squared(probe, OrbitCamera.spherical(radius: 1, phi: a.phi, theta: a.theta))
            if d < bestDistance {
                bestDistance = d
                best = a
            }
        }
        guard let best else { return }
        let nearPole = best.phi < 0.01 || best.phi > .pi - 0.01
        phiTarget = min(max(best.phi, Self.phiMin), Self.phiMax)
        if !nearPole { thetaTarget += OrbitCamera.wrap(best.theta - thetaTarget) }
        snapFactor = lerpSnap
        settling = true
    }

    /// Glide to a labelled angle; `speed` scales the snap rate (the page uses 0.55 for its intro).
    @discardableResult
    func fly(to label: String, speed: Float = 1) -> Bool {
        guard let a = angles.first(where: { $0.label == label }) else { return false }
        phiTarget = min(max(a.phi, Self.phiMin), Self.phiMax)
        thetaTarget = a.theta + ((theta - a.theta) / (2 * .pi)).rounded() * 2 * .pi
        snapFactor = min(lerpSnap * speed, 1)
        settling = true
        idleSince = CACurrentMediaTime()
        return true
    }

    func jump(to label: String) {
        guard let a = angles.first(where: { $0.label == label }) else { return }
        phi = min(max(a.phi, Self.phiMin), Self.phiMax)
        theta = a.theta
        phiTarget = phi
        thetaTarget = theta
        settling = false
        needsUpdate = true
        computeWeights()
    }

    // MARK: - Frame

    /// Advance; returns true when the camera moved.
    func update(dt: Float) -> Bool {
        let now = CACurrentMediaTime()
        if autoRotate && !dragging && now - idleSince > 2.5 {
            settling = false
            thetaTarget += autoRotateSpeed * dt
            phiTarget = OrbitCamera.damp(phiTarget, .pi / 2 - 0.12, factor: 0.02, dt: dt)
        }
        let factor = dragging ? lerpDrag : settling ? snapFactor : 0.12
        let previous = (theta, phi, zoom)
        theta = OrbitCamera.damp(theta, thetaTarget, factor: factor, dt: dt)
        phi = OrbitCamera.damp(phi, phiTarget, factor: factor, dt: dt)
        zoom = OrbitCamera.damp(zoom, zoomTarget, factor: 0.15, dt: dt)
        if abs(theta) > 8 * .pi {
            let k = (theta / (2 * .pi)).rounded() * 2 * .pi
            theta -= k
            thetaTarget -= k
        }
        let moved = abs(theta - previous.0) > 1e-5 || abs(phi - previous.1) > 1e-5 || abs(zoom - previous.2) > 1e-4
        if moved || needsUpdate {
            needsUpdate = false
            computeWeights()
            return true
        }
        if settling { settling = false }
        return autoRotate && !dragging
    }

    /// Lighting weights of the up-to-four nearest labelled angles (the page's formula).
    private func computeWeights() {
        let p = OrbitCamera.spherical(radius: lightRadius, phi: phi, theta: theta)
        var scored = lightAngles.map { a -> Sample in
            let distance = simd_distance(p, a.vector)
            let multiplier = min(max(1 - distance / a.threshold, 0), 1)
            return Sample(label: a.label, weight: 0, distance: distance, multiplier: multiplier)
        }
        scored.sort { $0.multiplier > $1.multiplier }
        var top = Array(scored.prefix(4))
        var sum: Float = 0
        for i in top.indices {
            top[i].weight = (top[i].distance < 1e-5 ? 1e9 : 1 / top[i].distance) * top[i].multiplier
            sum += top[i].weight
        }
        if sum > 0 {
            for i in top.indices { top[i].weight /= sum }
        } else if let closest = scored.min(by: { $0.distance < $1.distance }) {
            top = [Sample(label: closest.label, weight: 1, distance: closest.distance, multiplier: 0)]
        }
        weights = top.sorted { $0.weight > $1.weight }
    }

    private static func damp(_ current: Float, _ target: Float, factor: Float, dt: Float) -> Float {
        current + (target - current) * (1 - pow(1 - min(factor, 0.999), dt * 60))
    }

    private static func wrap(_ x: Float) -> Float {
        let twoPi = 2 * Float.pi
        var r = (x + .pi).truncatingRemainder(dividingBy: twoPi)
        if r < 0 { r += twoPi }
        return r - .pi
    }
}
