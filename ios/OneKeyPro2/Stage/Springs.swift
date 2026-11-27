import Foundation

/// Critically damped spring (Unity-style SmoothDamp), the same easing the page uses for lens,
/// pose and lighting changes.
@inline(__always)
func smoothDamp(_ current: Float, _ target: Float, velocity: inout Float, smoothTime: Float, dt: Float) -> Float {
    let omega = 2 / max(smoothTime, 1e-4)
    let x = omega * dt
    let k = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
    let change = current - target
    let temp = (velocity + omega * change) * dt
    velocity = (velocity - omega * temp) * k
    return target + (change + temp) * k
}

/// A bag of named scalars gliding towards their targets.
struct Springs {
    private(set) var values: [String: Float] = [:]
    private var targets: [String: Float] = [:]
    private var velocities: [String: Float] = [:]
    private(set) var smoothTime: Float = 0.2

    func value(_ key: String, default fallback: Float = 0) -> Float {
        values[key] ?? fallback
    }

    var keys: [String] { Array(values.keys) }

    /// Set targets; `smoothTime == nil` jumps immediately. New keys start from `start(key)`.
    mutating func set(_ entries: [String: Float], smoothTime: Float?, start: (String) -> Float = { _ in 0 }) {
        for (key, value) in entries {
            if values[key] == nil { values[key] = smoothTime == nil ? value : start(key) }
            targets[key] = value
            if smoothTime == nil {
                values[key] = value
                velocities[key] = 0
            }
        }
        if let smoothTime { self.smoothTime = smoothTime }
    }

    /// Advance all springs; returns true when anything moved.
    mutating func step(_ dt: Float) -> Bool {
        var moved = false
        for (key, target) in targets {
            let value = values[key] ?? target
            var velocity = velocities[key] ?? 0
            if abs(value - target) < 1e-5 && abs(velocity) < 1e-5 {
                if value != target {
                    values[key] = target
                    moved = true
                }
                continue
            }
            values[key] = smoothDamp(value, target, velocity: &velocity, smoothTime: smoothTime, dt: dt)
            velocities[key] = velocity
            moved = true
        }
        return moved
    }
}
