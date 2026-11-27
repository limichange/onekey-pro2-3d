import Foundation

/// `studio.json`: the product page's light studio, reduced to what a viewer needs.
///
/// Each layer is one softbox rig. `constants` are applied once; `channels` hold a value per
/// studio state, keyed `<angle>` (e.g. `front`) or `<state>+<angle>` (e.g. `Black+front`).
struct StudioDefinition: Decodable {
    struct Camera: Decodable {
        let fov: Float
        let fovScale: Float
        let near: Float
        let far: Float
        let radius: Float
    }

    struct Start: Decodable {
        let phi: Float
        let theta: Float
    }

    struct Angle: Decodable {
        let phi: Float
        let theta: Float
        let label: String?
        let threshold: Float
    }

    struct Layer: Decodable {
        let layer: Int
        let rig: String
        let envMapIntensity: Float
        let constants: [String: [String: Float]]
        let channels: [String: [String: [String: Float]]]
    }

    let camera: Camera
    let start: Start
    let angles: [Angle]
    let layers: [Layer]

    /// Unique angle labels, in file order. Each one gets its own baked environment.
    var labels: [String] {
        var seen = Set<String>()
        return angles.compactMap(\.label).filter { seen.insert($0).inserted }
    }

    /// Value of a channel for a studio state at a camera angle (same fallback order as the page).
    static func value(in channel: [String: Float], state: String?, label: String) -> Float? {
        if let state, let v = channel["\(state)+\(label)"] { return v }
        if let v = channel[label] { return v }
        if let state, let v = channel[state] { return v }
        return nil
    }
}
