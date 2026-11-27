import simd
import UIKit

/// What a product material is, for lighting purposes.
enum MaterialRole: String, CaseIterable {
    case screen, bezel, camera, frame, button, port, logo, body
    case backOverlay = "back-overlay"
    case lens, other
}

struct RoleInfo {
    let role: MaterialRole
    /// Studio light rig the material reflects: 0 = body, 1 = port, 2 = frame.
    let layer: Int
    /// Environment reflection strength.
    let intensity: Float
}

/// Camera lens: `fovScale` widens/narrows the studio camera's FOV; radius/offset place it.
struct Lens {
    var fovScale: Float
    var radius: Float
    var offset: SIMD3<Float> = .zero
}

/// A view pose: `scale` zooms (relative to `ProductConfig.modelScale`), `position` frames,
/// `rotation` tilts the product.
struct Pose {
    var scale: Float = ProductConfig.modelScale
    var position: SIMD3<Float> = .zero
    var rotation: SIMD3<Float> = .zero
}

/// Per-role lighting tweaks a view can apply on top of the colourway.
struct RoleLighting {
    var envRotation: SIMD3<Float>?
    var intensity: Float?
    var colorHue: Float?
    var colorLightness: Float?
    var colorSaturation: Float?
    var minRoughness: Float?
}

enum ViewEffect {
    case powerGlow
}

struct ViewSetup {
    var angle: String
    var pose: Pose
    var lens: Lens?
    var lighting: [MaterialRole: RoleLighting] = [:]
    var effect: ViewEffect?
}

struct Feature: Identifiable, Hashable {
    let id: String
    let label: String
    let description: String
    let showsSwatches: Bool

    static func == (a: Feature, b: Feature) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct Swatch: Identifiable {
    let id: String
    let label: String
    let zh: String
    let fill: UIColor
    let stroke: UIColor
}

enum ProductConfig {
    /// Product height in studio units (the studio camera orbits at radius 35).
    static let targetHeight: Float = 15.45
    /// Root scale of the product; view poses are expressed relative to it.
    static let modelScale: Float = 1.4
    /// Vertical FOV of the studio camera before `fovScale`.
    static let sourceFov: Float = 35.7
    /// The page's default lens: long and far away, so there is little perspective distortion.
    static let lensDefault = Lens(fovScale: 0.6, radius: 70)
    static let defaultColor = "Orange"

    static let overview = ViewSetup(angle: "frontLeft", pose: Pose(scale: 0.75 * modelScale))
    static let compactOverview = ViewSetup(angle: "frontLeft", pose: Pose(scale: 0.88 * modelScale))
    /// Shown while loading; the camera then glides to the overview.
    static let intro = ViewSetup(angle: "back", pose: Pose(scale: 0.6 * modelScale))

    /// Per-role material overrides applied on top of the glTF values.
    static let roleTuning: [MaterialRole: [String: Float]] = [.logo: ["roughness": 0.325]]

    static func classify(materialName name: String, metalness: Float, transmission: Float) -> RoleInfo {
        if transmission > 0 { return RoleInfo(role: .lens, layer: 2, intensity: 1.35) }
        if name.hasPrefix("材质.") && metalness > 0.5 { return RoleInfo(role: .backOverlay, layer: 0, intensity: 0.5) }
        let lower = name.lowercased()
        if name.contains("屏幕") && !name.contains("屏幕黑边") { return RoleInfo(role: .screen, layer: 2, intensity: 0.16) }
        if name.contains("黑边") { return RoleInfo(role: .bezel, layer: 2, intensity: 0.48) }
        if name.contains("镜头") || lower.contains("cam") || name.contains("绝对黑") {
            return RoleInfo(role: .camera, layer: 2, intensity: 1.35)
        }
        if name.contains("中框") { return RoleInfo(role: .frame, layer: 2, intensity: 1) }
        if name.contains("电源键") { return RoleInfo(role: .button, layer: 2, intensity: 1) }
        if name.contains("USB") { return RoleInfo(role: .port, layer: 1, intensity: 0.78) }
        if lower.contains("logo") { return RoleInfo(role: .logo, layer: 0, intensity: 0.72) }
        if name.contains("背盖") { return RoleInfo(role: .body, layer: 0, intensity: 0.68) }
        return RoleInfo(role: .other, layer: 0, intensity: 0.9)
    }

    // MARK: - Copy (zh_CN, from the product page's design section)

    static let eyebrow = "设计"
    static let title = "每一处细节，\n成就一身质感。"
    static let summary = "Pro 2 从颜色、材质到握持曲线，围绕日常使用精心设计。远看简洁，近看讲究。"
    static let closerLook = "定睛细看"

    static let features: [Feature] = [
        Feature(id: "color", label: "颜色", description: "三款配色，款款出色。", showsSwatches: true),
        Feature(id: "frame", label: "光面铝合金中框", description: "轻盈好拿，坚固耐用，光泽随光线自然流动。", showsSwatches: false),
        Feature(id: "back-cover", label: "磨砂玻璃后盖", description: "细腻雾面，触感温润，握持更舒服。", showsSwatches: false),
        Feature(id: "gorilla-glass", label: "康宁® Gorilla® Glass 5", description: "耐磨防刮，让屏幕保持清晰通透。", showsSwatches: false),
        Feature(id: "fingerprint", label: "二合一指纹电源", description: "按下唤醒，指纹解锁，一气呵成。", showsSwatches: false),
        Feature(id: "g3-curve", label: "G3 混接曲线", description: "曲线自然衔接，视觉连贯，握持贴手。", showsSwatches: false),
    ]

    static let swatches: [Swatch] = [
        Swatch(id: "Orange", label: "Horizon Orange", zh: "初日橘",
               fill: UIColor(hex: "#F7931A"), stroke: UIColor(hex: "#CD7000")),
        Swatch(id: "Silver", label: "Glacier Silver", zh: "冰川银",
               fill: .white, stroke: UIColor(white: 0, alpha: 0.16)),
        Swatch(id: "Black", label: "Graphite Black", zh: "墨岩黑",
               fill: UIColor(hex: "#111111"), stroke: UIColor(white: 1, alpha: 0.5)),
    ]

    // MARK: - Feature close-ups (the page's view definitions)

    private static let s = modelScale

    /// `compact` picks the phone variant where the page defines one.
    static func view(for featureID: String, compact: Bool) -> ViewSetup? {
        switch featureID {
        case "color":
            return compact
                ? ViewSetup(angle: "backLeft", pose: Pose(scale: 1.25 * s, position: [0.32, -5, 0.32]))
                : ViewSetup(angle: "backLeft", pose: Pose(scale: 1.61 * s, position: [1.1, -8.3, 1.1]))
        case "frame":
            return ViewSetup(angle: "left", pose: Pose(scale: 0.97 * s, rotation: [0, -0.007, 0]))
        case "back-cover":
            return ViewSetup(angle: "backLeft",
                             pose: Pose(scale: 0.92 * s, position: [0.4, 0, 0.4], rotation: [0.007, -0.091, 0.006]))
        case "gorilla-glass":
            return ViewSetup(angle: "frontLeft", pose: Pose(scale: 0.96 * s, rotation: [0.032, -0.169, -0.039]))
        case "fingerprint":
            let position: SIMD3<Float> = compact ? [-2.1, -12.6, -1.7] : [-2.1, -12.3, -1.7]
            return ViewSetup(angle: "left",
                             pose: Pose(scale: (compact ? 1.85 : 2.04) * s, position: position,
                                        rotation: [0.049, 0.272, -0.177]),
                             effect: .powerGlow)
        case "g3-curve":
            return ViewSetup(
                angle: "backLeft",
                pose: Pose(scale: 3.05 * s, position: [7.6, -15.6, 7.6], rotation: [0.381, 0.164, 0.419]),
                lens: Lens(fovScale: 0.388, radius: 108),
                lighting: [
                    .body: RoleLighting(envRotation: [0.4, 0.4, 0], intensity: 0.95, colorHue: 8, colorLightness: 0.92),
                    .logo: RoleLighting(colorHue: 8),
                    .camera: RoleLighting(envRotation: [-0.6, 1, 0], intensity: 1.5),
                    .lens: RoleLighting(envRotation: [-0.6, 1, 0], intensity: 0.065, minRoughness: 0.12),
                    .frame: RoleLighting(envRotation: [-0.8, -0.4, 0], colorHue: 7, colorLightness: 0.95,
                                         colorSaturation: 0.86, minRoughness: 0.28),
                    .button: RoleLighting(envRotation: [-0.8, -0.4, 0], colorHue: 7),
                ]
            )
        default:
            return nil
        }
    }

    /// Turn a pose into a model rotation + camera lens. The model never moves; zoom and framing
    /// are expressed by moving the camera, as on the page.
    static func resolve(pose: Pose, lens: Lens = lensDefault) -> (rotation: SIMD3<Float>, lens: Lens) {
        let r = pose.scale / modelScale
        return (pose.rotation, Lens(fovScale: lens.fovScale, radius: lens.radius / r,
                                    offset: (lens.offset - pose.position) / r))
    }
}

extension UIColor {
    convenience init(hex: String) {
        let v = ColorMath.srgb(hex: hex)
        self.init(red: CGFloat(v.x), green: CGFloat(v.y), blue: CGFloat(v.z), alpha: 1)
    }
}
