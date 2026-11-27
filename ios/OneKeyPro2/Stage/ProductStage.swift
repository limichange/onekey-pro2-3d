import Combine
import GLTFKit2
import RealityKit
import simd
import UIKit

/// The 3D stage: product model, per-material studio lighting, camera and view transitions.
@MainActor
final class ProductStage {
    struct PartState {
        var color: SIMD3<Float> // linear
        var metallic: Float
        var roughness: Float
        var intensity: Float
    }

    final class Part {
        let entity: ModelEntity
        let info: RoleInfo
        let materialName: String
        let base: PartState
        var current: PartState
        let template: PhysicallyBasedMaterial?
        let materialCount: Int
        var glow: Float = 0

        init(entity: ModelEntity, info: RoleInfo, materialName: String, base: PartState,
             template: PhysicallyBasedMaterial?, materialCount: Int) {
            self.entity = entity
            self.info = info
            self.materialName = materialName
            self.base = base
            self.current = base
            self.template = template
            self.materialCount = materialCount
        }
    }

    private struct ColorState {
        var parts: [PartState]
        var studioIntensity: Float
    }

    let arView: ARView
    var onAngleChange: ((String) -> Void)?
    /// The user grabbed the model (the page leaves any close-up when that happens).
    var onGrab: (() -> Void)?

    private let studio: StudioDefinition
    private let colors: ColorSpec
    private let lighting: StudioLighting
    private let orbit: OrbitCamera
    private let world = AnchorEntity(world: .zero)
    private let camera = PerspectiveCamera()
    private let root = Entity()
    private var product: Entity?
    private var parts: [Part] = []
    private var roleLights: [MaterialRole: Entity] = [:]
    private var subscription: Cancellable?

    private var lens = Springs()
    private var pose = Springs()
    private var viewLighting = Springs()
    private(set) var compact = true
    private var band: (top: CGFloat, bottom: CGFloat)?
    private var lastBounds = CGSize.zero
    private var debugSkybox = false
    private var fitZoom: Float = 1
    private var shift = SIMD2<Float>.zero
    private var framingDirty = true
    private var lightingDirty = true

    private(set) var currentColor: String
    private var activeVariant: StudioLighting.Variant
    private var studioIntensity: Float = 1
    private var colorFrom: ColorState?
    private var colorTo: ColorState?
    private var colorProgress: Float = 1
    private var lastAngle: String?
    private var glow: PowerGlow?

    /// Global exposure trim (EV) to match the page's ACES tone mapping.
    var exposureBias: Float = 0 { didSet { lightingDirty = true } }

    init(arView: ARView, color: String) throws {
        self.arView = arView
        let resources = Bundle.main.resourceURL!.appendingPathComponent("ProductAssets", isDirectory: true)
        let decoder = JSONDecoder()
        studio = try decoder.decode(StudioDefinition.self,
                                    from: Data(contentsOf: resources.appendingPathComponent("Studio/studio.json")))
        colors = try decoder.decode(ColorSpec.self,
                                    from: Data(contentsOf: resources.appendingPathComponent("Model/colors.json")))
        lighting = try StudioLighting(definition: studio, directory: resources.appendingPathComponent("Studio"))
        orbit = OrbitCamera(studio: studio)
        currentColor = colors.colors[color] != nil ? color : colors.default
        activeVariant = StudioLighting.Variant(id: "", state: nil, background: .zero)
        activeVariant = variant(for: currentColor)

        camera.camera.near = 1
        camera.camera.far = 3000
        world.addChild(camera)
        world.addChild(root)
        arView.scene.addAnchor(world)

        subscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                self?.update(dt: Float(min(event.deltaTime, 0.1)))
            }
        }
    }

    // MARK: - Loading

    func load(progress: @escaping (Float, String) -> Void) async throws {
        progress(0.02, "读取模型")
        await Task.yield()
        let url = Bundle.main.resourceURL!.appendingPathComponent("ProductAssets/Model/black.glb")
        let asset = try GLTFAsset(url: url)
        guard let scene = asset.defaultScene else { throw CocoaError(.fileReadCorruptFile) }
        let model = try GLTFEntityBuilder.entity(for: scene) { [unowned self] material in
            self.makeMaterial(material)
        }
        setUpProduct(model, asset: asset)
        progress(0.1, "烘焙灯箱")

        // Start from the page's intro pose (small, from the back), without animation.
        orbit.jump(to: ProductConfig.intro.angle)
        applyViewTargets(ProductConfig.intro, smoothTime: nil)

        let colorState = state(for: currentColor)
        apply(colorState)
        try await lighting.prepare(activeVariant) { p in progress(0.1 + 0.9 * p, "烘焙灯箱") }
        lightingDirty = true
        framingDirty = true
        update(dt: 0)

        // Warm the other colourways in the background so switching is instant.
        Task { [weak self] in
            guard let self else { return }
            for id in self.colors.colors.keys.sorted() where id != self.currentColor {
                try? await self.lighting.prepare(self.variant(for: id))
            }
            // Re-bake the active one last so it stays in the cache.
            try? await self.lighting.prepare(self.activeVariant)
        }
    }

    /// Glide from the intro pose to the overview (the page uses speed 0.55).
    func startIntro() {
        setFeature(nil, fly: true, speed: 0.55)
    }

    private var textures: [ObjectIdentifier: TextureResource] = [:]

    /// glTF material → RealityKit PBR (base colour, metal/rough, emissive, clearcoat).
    /// Sheen / specular / transmission have no RealityKit equivalent and are handled per role.
    private func makeMaterial(_ source: GLTFMaterial?) -> any RealityKit.Material {
        var m = PhysicallyBasedMaterial()
        guard let source else { return m }
        if let pbr = source.metallicRoughness {
            let c = pbr.baseColorFactor
            m.baseColor = .init(tint: ColorMath.uiColor(linear: SIMD3(c.x, c.y, c.z)), texture: texture(pbr.baseColorTexture))
            m.metallic.scale = pbr.metallicFactor
            m.roughness.scale = pbr.roughnessFactor
        }
        if let emissive = source.emissive {
            let tex = texture(emissive.emissiveTexture)
            if tex != nil || simd_reduce_max(emissive.emissiveFactor) > 0 {
                m.emissiveColor = .init(color: ColorMath.uiColor(linear: emissive.emissiveFactor), texture: tex)
                m.emissiveIntensity = emissive.emissiveStrength
            }
        }
        if let clearcoat = source.clearcoat {
            m.clearcoat.scale = clearcoat.clearcoatFactor
            m.clearcoatRoughness.scale = clearcoat.clearcoatRoughnessFactor
        }
        m.faceCulling = source.isDoubleSided ? .none : .back
        return m
    }

    private func texture(_ params: GLTFTextureParams?) -> MaterialParameters.Texture? {
        guard let texture = params?.texture, let image = texture.webpSource ?? texture.source else { return nil }
        let key = ObjectIdentifier(image)
        if let cached = textures[key] { return .init(cached) }
        guard let cgImage = image.newCGImage()?.takeRetainedValue(),
              let resource = try? TextureResource.generate(from: cgImage, options: .init(semantic: .color))
        else { return nil }
        textures[key] = resource
        return .init(resource)
    }

    private func setUpProduct(_ model: Entity, asset: GLTFAsset) {
        let holder = Entity()
        holder.addChild(model)
        holder.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
        root.addChild(holder)
        var bounds = holder.visualBounds(relativeTo: root)
        let k = ProductConfig.targetHeight / max(bounds.extents.y, 1e-6)
        holder.scale = SIMD3(repeating: k)
        bounds = holder.visualBounds(relativeTo: root)
        holder.position = -bounds.center
        root.scale = SIMD3(repeating: ProductConfig.modelScale)
        product = model

        for node in asset.nodes {
            guard let name = node.name, let mesh = node.mesh,
                  let material = mesh.primitives.first?.material,
                  let entity = model.findEntity(named: name) as? ModelEntity,
                  let component = entity.model else { continue }
            let pbr = material.metallicRoughness
            let baseColor = pbr?.baseColorFactor ?? SIMD4<Float>(1, 1, 1, 1)
            let metallic = pbr?.metallicFactor ?? 1
            let roughness = pbr?.roughnessFactor ?? 1
            let info = ProductConfig.classify(materialName: material.name ?? "", metalness: metallic,
                                              transmission: material.transmission?.transmissionFactor ?? 0)
            let base = PartState(color: SIMD3(baseColor.x, baseColor.y, baseColor.z), metallic: metallic,
                                 roughness: roughness, intensity: info.intensity)
            parts.append(Part(entity: entity, info: info, materialName: material.name ?? "", base: base,
                              template: component.materials.first as? PhysicallyBasedMaterial,
                              materialCount: component.materials.count))
        }

        // One image-based light per role, so each role can have its own intensity / rotation.
        for role in Set(parts.map(\.info.role)) {
            let light = Entity()
            light.name = "ibl-\(role.rawValue)"
            world.addChild(light)
            roleLights[role] = light
        }
        for part in parts {
            if let light = roleLights[part.info.role] {
                part.entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: light))
            }
            if part.info.role == .screen {
                // The UI on the screen is emissive and not tone-mapped on the page.
                var screen = UnlitMaterial(applyPostProcessToneMap: false)
                screen.color = .init(tint: ColorMath.uiColor(linear: SIMD3(repeating: 0.92)),
                                     texture: part.template?.emissiveColor.texture)
                part.entity.model?.materials = Array(repeating: screen, count: part.materialCount)
            }
        }
    }

    // MARK: - Colourways

    private func variant(for colorID: String) -> StudioLighting.Variant {
        let spec = colors.colors[colorID]
        let background = spec?.studioBackground.map(ColorMath.linear(hex:)) ?? .zero
        return StudioLighting.Variant(id: colorID, state: spec?.studioState, background: background)
    }

    private func state(for colorID: String) -> ColorState {
        guard let spec = colors.colors[colorID] else {
            return ColorState(parts: parts.map(\.base), studioIntensity: 1)
        }
        let states = parts.map { part -> PartState in
            let role = part.info.role.rawValue
            var s = part.base
            if let group = colors.group(forMaterial: part.materialName), let hex = spec.groupColors?[group] {
                s.color = ColorMath.linear(hex: hex)
            }
            if let hex = spec.materialColors?[part.materialName] ?? spec.roleColors?[role] {
                s.color = ColorMath.linear(hex: hex)
            }
            let overrides = (ProductConfig.roleTuning[part.info.role] ?? [:])
                .merging(spec.roleMaterial?[role] ?? [:]) { _, new in new }
            if let v = overrides["metalness"] { s.metallic = v }
            if let v = overrides["roughness"] { s.roughness = v }
            s.intensity = spec.roleIntensity?[role] ?? part.info.intensity
            return s
        }
        return ColorState(parts: states, studioIntensity: spec.studioIntensity ?? 1)
    }

    private func apply(_ state: ColorState) {
        for (part, s) in zip(parts, state.parts) { part.current = s }
        studioIntensity = state.studioIntensity
        applyMaterials()
    }

    func setColor(_ id: String) {
        guard id != currentColor, colors.colors[id] != nil else { return }
        currentColor = id
        colorFrom = ColorState(parts: parts.map(\.current), studioIntensity: studioIntensity)
        colorTo = state(for: id)
        colorProgress = 0
        let target = variant(for: id)
        Task { [weak self] in
            guard let self else { return }
            try? await self.lighting.prepare(target)
            guard self.currentColor == id else { return }
            self.activeVariant = target
            self.lightingDirty = true
        }
    }

    // MARK: - Views

    func setLayout(compact: Bool) {
        guard compact != self.compact else { return }
        self.compact = compact
        framingDirty = true
    }

    /// Show a feature close-up, or the overview for `nil`.
    func setFeature(_ id: String?, fly: Bool = true, speed: Float = 1.2) {
        let overview = compact ? ProductConfig.compactOverview : ProductConfig.overview
        let view = id.flatMap { ProductConfig.view(for: $0, compact: compact) } ?? overview
        if fly { orbit.fly(to: view.angle, speed: speed) }
        applyViewTargets(view, smoothTime: 0.22 / max(speed, 0.01))

        if view.effect == .powerGlow {
            if glow == nil, let product {
                glow = PowerGlow(product: product, buttons: parts.filter { $0.info.role == .button })
            }
        } else if let glow {
            glow.remove()
            self.glow = nil
            applyMaterials()
        }
    }

    private func applyViewTargets(_ view: ViewSetup, smoothTime: Float?) {
        let resolved = ProductConfig.resolve(pose: view.pose, lens: view.lens ?? ProductConfig.lensDefault)
        lens.set(["fovScale": resolved.lens.fovScale, "radius": resolved.lens.radius,
                  "ox": resolved.lens.offset.x, "oy": resolved.lens.offset.y, "oz": resolved.lens.offset.z],
                 smoothTime: smoothTime)
        pose.set(["rx": resolved.rotation.x, "ry": resolved.rotation.y, "rz": resolved.rotation.z],
                 smoothTime: smoothTime)

        // Every channel touched before returns to neutral unless this view sets it.
        var targets: [String: Float] = [:]
        for key in viewLighting.keys { targets[key] = Self.channelDefault(key) }
        for (role, l) in view.lighting {
            let r = role.rawValue
            let e = l.envRotation ?? .zero
            targets["\(r).env.x"] = e.x
            targets["\(r).env.y"] = e.y
            targets["\(r).env.z"] = e.z
            if let v = l.intensity { targets["\(r).intensity"] = v }
            if let v = l.colorHue { targets["\(r).colorHue"] = v }
            if let v = l.colorLightness { targets["\(r).colorLightness"] = v }
            if let v = l.colorSaturation { targets["\(r).colorSaturation"] = v }
            if let v = l.minRoughness { targets["\(r).minRoughness"] = v }
        }
        viewLighting.set(targets, smoothTime: smoothTime, start: Self.channelDefault)
        framingDirty = true
        lightingDirty = true
        if smoothTime == nil { applyMaterials() }
    }

    private static func channelDefault(_ key: String) -> Float {
        key.hasSuffix(".intensity") || key.hasSuffix(".colorSaturation") || key.hasSuffix(".colorLightness") ? 1 : 0
    }

    private func channel(_ role: MaterialRole, _ name: String) -> Float {
        let key = "\(role.rawValue).\(name)"
        return viewLighting.value(key, default: Self.channelDefault(key))
    }

    // MARK: - Interaction

    func beginDrag() {
        orbit.beginDrag()
        onGrab?()
    }

    func drag(dx: Float, dy: Float) {
        orbit.drag(dx: dx, dy: dy, size: referenceSize)
    }

    func endDrag(velocity: CGPoint) {
        orbit.endDrag(velocityX: Float(velocity.x), velocityY: Float(velocity.y), size: referenceSize)
    }

    func pinch(scale: Float, startZoom: Float) {
        orbit.zoomTarget = min(max(startZoom / max(scale, 0.01), OrbitCamera.minZoom), OrbitCamera.maxZoom)
    }

    var zoomTarget: Float { orbit.zoomTarget }

    func resetZoom() {
        orbit.zoomTarget = 1
    }

    /// Camera distance multiplier (1 = framed; larger is farther).
    func setZoom(_ zoom: Float) {
        orbit.zoomTarget = min(max(zoom, OrbitCamera.minZoom), OrbitCamera.maxZoom)
    }

    func fly(to label: String) {
        orbit.fly(to: label)
    }

    var autoRotate: Bool {
        get { orbit.autoRotate }
        set { orbit.autoRotate = newValue }
    }

    private var referenceSize: Float {
        Float(min(arView.bounds.width, arView.bounds.height * 1.4))
    }

    // MARK: - Layout

    /// The vertical band (window coordinates) left free by the UI; the product is framed in it.
    func setBand(top: CGFloat, bottom: CGFloat) {
        band = (top, bottom)
        framingDirty = true
    }

    func setBackground(_ color: UIColor) {
        guard !debugSkybox else { return }
        arView.environment.background = .color(color)
    }

    /// Debug: show axis markers as the skybox (hides the product) to verify the equirect
    /// convention. Looking from "back" (+Z towards -Z) must show yellow in the centre, the
    /// white dot right of it and the orange dot above it.
    func showEnvironmentDebug() async {
        let image = StudioBaker.axisMarkers(width: 1024, height: 512)
        guard let cgImage = StudioBaker.cgImage(image),
              let environment = try? await EnvironmentResource(equirectangular: cgImage, withName: nil) else { return }
        debugSkybox = true
        arView.environment.background = .skybox(environment)
        root.isEnabled = false
    }

    func snapshot(_ completion: @escaping (UIImage?) -> Void) {
        arView.snapshot(saveToHDR: false) { image in completion(image) }
    }

    private func updateFraming() {
        let size = arView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let insets = band.map { UIEdgeInsets(top: $0.top, left: 0, bottom: max(0, size.height - $0.bottom), right: 0) }
            ?? .zero
        let height = Float(size.height), width = Float(size.width)
        let availH = max(height * 0.35, height - Float(insets.top + insets.bottom))
        let availW = max(width * 0.35, width - Float(insets.left + insets.right))
        // Fit the overview into the free band (as the page's stage does); close-ups keep their
        // relative zoom on top of this.
        let overview = compact ? ProductConfig.compactOverview : ProductConfig.overview
        let reference = ProductConfig.resolve(pose: overview.pose).lens
        let referenceFov = Self.fov(fovScale: ProductConfig.lensDefault.fovScale)
        let visible = 2 * reference.radius * tan(referenceFov / 2)
        let productPoints = (ProductConfig.targetHeight * ProductConfig.modelScale / visible) * 1.02 * height
        let zoomH = (compact ? 0.72 : 0.62) * availH / productPoints
        let zoomW = 0.8 * availW / (0.62 * productPoints)
        fitZoom = min(max(min(zoomH, zoomW), 0.35), 1.6)
        shift = SIMD2(Float(insets.left - insets.right) / 2, Float(insets.bottom - insets.top) / 2)
    }

    private static func fov(fovScale: Float) -> Float {
        2 * atan(tan(ProductConfig.sourceFov * .pi / 180 / 2) * fovScale)
    }

    // MARK: - Frame

    private func update(dt: Float) {
        if arView.bounds.size != lastBounds {
            lastBounds = arView.bounds.size
            framingDirty = true
        }
        let lensMoved = lens.step(dt)
        if pose.step(dt) || framingDirty {
            let euler = SIMD3(pose.value("rx"), pose.value("ry"), pose.value("rz"))
            root.orientation = simd_quatf(Euler.matrix(euler))
        }
        var materialsDirty = viewLighting.step(dt)

        if colorProgress < 1, let from = colorFrom, let to = colorTo {
            colorProgress = min(1, colorProgress + dt / 0.7)
            let t = colorProgress < 0.5 ? 4 * pow(colorProgress, 3) : 1 - pow(-2 * colorProgress + 2, 3) / 2
            for (i, part) in parts.enumerated() {
                let a = from.parts[i], b = to.parts[i]
                part.current = PartState(color: simd_mix(a.color, b.color, SIMD3(repeating: t)),
                                         metallic: a.metallic + (b.metallic - a.metallic) * t,
                                         roughness: a.roughness + (b.roughness - a.roughness) * t,
                                         intensity: a.intensity + (b.intensity - a.intensity) * t)
            }
            studioIntensity = from.studioIntensity + (to.studioIntensity - from.studioIntensity) * t
            materialsDirty = true
            if colorProgress >= 1 { colorFrom = nil }
        }
        if let glow, glow.update(dt: dt) { materialsDirty = true }
        if materialsDirty {
            applyMaterials()
            lightingDirty = true
        }

        let cameraMoved = orbit.update(dt: dt)
        if framingDirty { updateFraming() }
        if cameraMoved || lensMoved || framingDirty {
            applyCamera()
            framingDirty = false
        }
        if cameraMoved || lightingDirty {
            applyLighting()
            lightingDirty = false
        }

        if let label = orbit.dominantLabel, label != lastAngle {
            lastAngle = label
            onAngleChange?(label)
        }
    }

    private func applyCamera() {
        let fovScale = lens.value("fovScale", default: ProductConfig.lensDefault.fovScale)
        let radius = lens.value("radius", default: ProductConfig.lensDefault.radius)
        let offset = SIMD3(lens.value("ox"), lens.value("oy"), lens.value("oz"))
        let fov = 2 * atan(tan(Self.fov(fovScale: fovScale) / 2) / fitZoom)
        camera.camera.fieldOfViewInDegrees = fov * 180 / .pi

        // Look at the origin from the orbit position (three.js lookAt basis, stable at the poles),
        // then translate for the lens framing offset and the screen-space inset shift.
        let back = orbit.direction
        let right = SIMD3<Float>(cos(orbit.theta), 0, -sin(orbit.theta))
        let up = simd_cross(back, right)
        let distance = radius * orbit.zoom
        let worldPerPoint = 2 * distance * tan(fov / 2) / Float(max(arView.bounds.height, 1))
        var position = back * distance + offset
        position -= right * (shift.x * worldPerPoint) + up * (shift.y * worldPerPoint)
        camera.transform = Transform(matrix: simd_float4x4(SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0),
                                                           SIMD4(position, 1)))
    }

    private func applyMaterials() {
        let glowColor = ColorMath.uiColor(linear: ColorMath.linear(hex: PowerGlow.colorHex))
        for part in parts where part.info.role != .screen {
            guard var m = part.template else { continue }
            let role = part.info.role
            let color = ColorMath.adjust(linear: part.current.color, hueDegrees: channel(role, "colorHue"),
                                         saturation: channel(role, "colorSaturation"),
                                         lightness: channel(role, "colorLightness"))
            m.baseColor.tint = ColorMath.uiColor(linear: color)
            m.metallic.scale = part.current.metallic
            m.roughness.scale = max(part.current.roughness, channel(role, "minRoughness"))
            if role == .lens {
                // Transmission isn't available in RealityKit: approximate the clear glass.
                m.metallic.scale = 0
                m.blending = .transparent(opacity: 0.18)
            }
            if part.glow > 0 {
                m.emissiveColor.color = glowColor
                m.emissiveIntensity = part.glow
            }
            part.entity.model?.materials = Array(repeating: m, count: part.materialCount)
        }
    }

    private func applyLighting() {
        guard lighting.isReady(activeVariant.id), let a = orbit.weights.first else { return }
        let b = orbit.weights.dropFirst().first
        let t: Float = b.map { $0.weight / max(a.weight + $0.weight, 1e-6) } ?? 0
        for (role, light) in roleLights {
            guard let part = parts.first(where: { $0.info.role == role }) else { continue }
            let layer = part.info.layer
            guard let envA = lighting.environment(variant: activeVariant.id, layer: layer, label: a.label) else { continue }
            let source: ImageBasedLightComponent.Source
            if let b, t > 1e-3,
               let envB = lighting.environment(variant: activeVariant.id, layer: layer, label: b.label) {
                source = .blend(envA, envB, t)
            } else {
                source = .single(envA)
            }
            let layerIntensity = studio.layers.first { $0.layer == layer }?.envMapIntensity ?? 1
            let intensity = layerIntensity * part.current.intensity * studioIntensity * channel(role, "intensity")
            var component = ImageBasedLightComponent(source: source,
                                                     intensityExponent: log2(max(intensity, 1e-4)) + exposureBias)
            component.inheritsRotation = true
            light.components.set(component)
            let e = SIMD3(channel(role, "env.x"), channel(role, "env.y"), channel(role, "env.z"))
            light.orientation = simd_quatf(Euler.matrix(-e))
        }
    }
}

/// The page's "press to wake" effect on the fingerprint button: a breathing glow stroke.
@MainActor
final class PowerGlow {
    static let colorHex = "#e9f6ff"
    private static let breatheSpeed: Float = 2.4
    private static let fadeIn: Float = 0.8
    private static let floor: Float = 0.35

    private let buttons: [ProductStage.Part]
    private var stroke: ModelEntity?
    private var holder: Entity?
    private var time: Float = 0
    private var removed = false

    init(product: Entity, buttons: [ProductStage.Part]) {
        self.buttons = buttons
        let url = Bundle.main.resourceURL!.appendingPathComponent("ProductAssets/Model/effects/button-glow-stroke.glb")
        guard let asset = try? GLTFAsset(url: url), let scene = asset.defaultScene,
              let glowRoot = try? GLTFEntityBuilder.entity(for: scene, materials: { _ in UnlitMaterial() })
        else { return }
        let holder = Entity()
        // The stroke is authored in the raw glTF frame of the product node.
        holder.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        holder.addChild(glowRoot)
        (product.findEntity(named: "Pro2 Black") ?? product).addChild(holder)
        self.holder = holder
        stroke = Self.firstModel(in: glowRoot)
        _ = update(dt: 0)
    }

    private static func firstModel(in entity: Entity) -> ModelEntity? {
        if let model = entity as? ModelEntity, model.model != nil { return model }
        for child in entity.children {
            if let found = firstModel(in: child) { return found }
        }
        return nil
    }

    /// Returns true while animating.
    func update(dt: Float) -> Bool {
        guard !removed else { return false }
        time += dt
        let fade = min(time / Self.fadeIn, 1)
        let breathe = 0.5 - 0.5 * cos(time * Self.breatheSpeed)
        let level = fade * fade * (3 - 2 * fade) * (Self.floor + (1 - Self.floor) * breathe)
        if let stroke, var model = stroke.model {
            var m = UnlitMaterial(applyPostProcessToneMap: false)
            m.color = .init(tint: ColorMath.uiColor(linear: ColorMath.linear(hex: Self.colorHex) * min(1.5 * level, 1)))
            m.blending = .transparent(opacity: .init(floatLiteral: min(1.5 * level, 1)))
            model.materials = Array(repeating: m, count: max(model.materials.count, 1))
            stroke.model = model
        }
        for part in buttons { part.glow = level * 0.25 }
        return true
    }

    func remove() {
        removed = true
        holder?.removeFromParent()
        for part in buttons { part.glow = 0 }
    }
}
