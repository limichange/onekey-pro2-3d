import CoreGraphics
import Foundation
import RealityKit
import simd

/// Bakes and caches one environment per (studio variant, light rig layer, camera angle).
///
/// The page re-poses the softboxes continuously and re-bakes every frame. Here each angle is
/// baked once and neighbouring angles are cross-faded with `ImageBasedLightComponent.blend`
/// (the page does the same for its body rig).
@MainActor
final class StudioLighting {
    struct Variant: Equatable {
        /// Cache key, e.g. the colourway id.
        let id: String
        /// Studio state: "Black" for the dark studio, nil for the default one.
        let state: String?
        /// Fill colour between the softboxes (linear).
        let background: SIMD3<Float>
    }

    private struct Key: Hashable {
        let variant: String
        let layer: Int
        let label: String
    }

    let definition: StudioDefinition
    private var rigs: [Int: Rig] = [:]
    private var environments: [Key: EnvironmentResource] = [:]
    private var bakedVariants: [String] = [] // most recent last
    private var queue: Task<Void, Error>?
    private let maxCachedVariants = 3

    init(definition: StudioDefinition, directory: URL) throws {
        self.definition = definition
        for layer in definition.layers {
            rigs[layer.layer] = try Rig(url: directory.appendingPathComponent(layer.rig))
        }
    }

    func isReady(_ variantID: String) -> Bool {
        bakedVariants.contains(variantID)
    }

    func environment(variant: String, layer: Int, label: String) -> EnvironmentResource? {
        environments[Key(variant: variant, layer: layer, label: label)]
    }

    /// Bake every angle of every layer for a variant. Bakes run one at a time.
    func prepare(_ variant: Variant, progress: @escaping (Float) -> Void = { _ in }) async throws {
        if isReady(variant.id) {
            touch(variant.id)
            progress(1)
            return
        }
        let previous = queue
        let task = Task { @MainActor in
            _ = try? await previous?.value
            if self.isReady(variant.id) { return }
            try await self.bake(variant, progress: progress)
        }
        queue = task
        try await task.value
    }

    private func bake(_ variant: Variant, progress: @escaping (Float) -> Void) async throws {
        let labels = definition.labels
        let total = Float(definition.layers.count * labels.count)
        var done: Float = 0
        var baked: [Key: EnvironmentResource] = [:]
        for layer in definition.layers {
            guard let rig = rigs[layer.layer] else { continue }
            // The mirror-polished frame needs sharper reflections than the frosted back.
            let size = layer.layer == 2 ? (width: 1024, height: 512) : (width: 512, height: 256)
            let started = CFAbsoluteTimeGetCurrent()
            let images: [CGImage?] = await Task.detached(priority: .userInitiated) {
                labels.map { label in
                    StudioLighting.pose(rig, layer: layer, state: variant.state, label: label)
                    let image = StudioBaker.render(quads: rig.worldQuads(), background: variant.background,
                                                   width: size.width, height: size.height)
                    return StudioBaker.cgImage(image)
                }
            }.value
            let rasterized = CFAbsoluteTimeGetCurrent()
            for (label, image) in zip(labels, images) {
                guard let image else { continue }
                let environment = try await EnvironmentResource(equirectangular: image, withName: nil)
                baked[Key(variant: variant.id, layer: layer.layer, label: label)] = environment
                done += 1
                progress(done / total)
            }
            print(String(format: "[Studio] %@ layer %d: raster %.0f ms, environments %.0f ms",
                         variant.id, layer.layer, (rasterized - started) * 1000,
                         (CFAbsoluteTimeGetCurrent() - rasterized) * 1000))
        }
        environments.merge(baked) { _, new in new }
        touch(variant.id)
        evictOldVariants()
    }

    /// Reset a rig and apply the keyframes of one studio state at one camera angle.
    nonisolated static func pose(_ rig: Rig, layer: StudioDefinition.Layer, state: String?, label: String) {
        rig.reset()
        for (target, props) in layer.constants {
            for (property, value) in props { rig.apply(target: target, property: property, value: value) }
        }
        for (target, props) in layer.channels {
            for (property, values) in props {
                if let value = StudioDefinition.value(in: values, state: state, label: label) {
                    rig.apply(target: target, property: property, value: value)
                }
            }
        }
    }

    private func touch(_ id: String) {
        bakedVariants.removeAll { $0 == id }
        bakedVariants.append(id)
    }

    private func evictOldVariants() {
        while bakedVariants.count > maxCachedVariants {
            let old = bakedVariants.removeFirst()
            environments = environments.filter { $0.key.variant != old }
        }
    }
}
