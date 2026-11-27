import GLTFKit2
import RealityKit
import simd

/// Builds RealityKit entities from a GLTFKit2 asset.
///
/// GLTFKit2 parses the file and undoes `EXT_meshopt_compression`, but its RealityKit bridge only
/// reads float attributes. The product model uses `KHR_mesh_quantization` (int16 positions,
/// int8/int16 normals, uint16 UVs), so meshes are rebuilt here with dequantized attributes.
@MainActor
enum GLTFEntityBuilder {
    typealias MaterialProvider = (GLTFMaterial?) -> any RealityKit.Material

    static func entity(for scene: GLTFScene, materials: MaterialProvider) throws -> Entity {
        let root = Entity()
        for node in scene.nodes {
            root.addChild(try entity(for: node, materials: materials))
        }
        return root
    }

    private static func entity(for node: GLTFNode, materials: MaterialProvider) throws -> Entity {
        let entity: Entity
        if let mesh = node.mesh, let model = try modelComponent(for: mesh, materials: materials) {
            let modelEntity = ModelEntity()
            modelEntity.model = model
            entity = modelEntity
        } else {
            entity = Entity()
        }
        entity.name = node.name ?? ""
        entity.transform = Transform(matrix: node.matrix)
        for child in node.childNodes {
            entity.addChild(try self.entity(for: child, materials: materials))
        }
        return entity
    }

    private static func modelComponent(for mesh: GLTFMesh, materials: MaterialProvider) throws -> ModelComponent? {
        var descriptors: [MeshDescriptor] = []
        var resolved: [any RealityKit.Material] = []
        for primitive in mesh.primitives where primitive.primitiveType == .triangles {
            guard let positionAccessor = primitive.attribute(forName: "POSITION")?.accessor else { continue }
            let positions = vectors3(positionAccessor)
            guard !positions.isEmpty else { continue }

            var descriptor = MeshDescriptor(name: mesh.name ?? "mesh")
            descriptor.positions = MeshBuffers.Positions(positions)
            if let accessor = primitive.attribute(forName: "NORMAL")?.accessor {
                descriptor.normals = MeshBuffers.Normals(vectors3(accessor).map { n in
                    let length = simd_length(n)
                    return length > 1e-8 ? n / length : SIMD3(0, 1, 0)
                })
            }
            if let accessor = primitive.attribute(forName: "TEXCOORD_0")?.accessor {
                // glTF's UV origin is top-left; RealityKit's is bottom-left.
                descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(vectors2(accessor).map { SIMD2($0.x, 1 - $0.y) })
            }
            let indices = primitive.indices.map(indexArray) ?? Array(0..<UInt32(positions.count))
            descriptor.primitives = .triangles(indices)
            descriptor.materials = .allFaces(UInt32(resolved.count))
            descriptors.append(descriptor)
            resolved.append(materials(primitive.material))
        }
        guard !descriptors.isEmpty else { return nil }
        return ModelComponent(mesh: try MeshResource.generate(from: descriptors), materials: resolved)
    }

    // MARK: - Accessors

    /// All components of an accessor as floats, applying `normalized` the glTF way.
    static func floats(_ accessor: GLTFAccessor) -> [Float] {
        guard let view = accessor.bufferView, let data = view.buffer.data else { return [] }
        let components = Int(GLTFComponentCountForDimension(accessor.dimension))
        let size = Int(GLTFBytesPerComponentForComponentType(accessor.componentType))
        guard components > 0, size > 0 else { return [] }
        let stride = view.stride == 0 ? components * size : view.stride
        let base = view.offset + accessor.offset
        let normalized = accessor.isNormalized
        let type = accessor.componentType
        var out = [Float](repeating: 0, count: accessor.count * components)
        data.withUnsafeBytes { raw in
            guard base + (accessor.count - 1) * stride + components * size <= raw.count else { return }
            for i in 0..<accessor.count {
                for c in 0..<components {
                    let o = base + i * stride + c * size
                    let value: Float
                    switch type {
                    case .float:
                        value = raw.loadUnaligned(fromByteOffset: o, as: Float.self)
                    case .byte:
                        let x = Float(raw.loadUnaligned(fromByteOffset: o, as: Int8.self))
                        value = normalized ? max(x / 127, -1) : x
                    case .unsignedByte:
                        let x = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt8.self))
                        value = normalized ? x / 255 : x
                    case .short:
                        let x = Float(raw.loadUnaligned(fromByteOffset: o, as: Int16.self))
                        value = normalized ? max(x / 32767, -1) : x
                    case .unsignedShort:
                        let x = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self))
                        value = normalized ? x / 65535 : x
                    case .unsignedInt:
                        value = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))
                    default:
                        value = 0
                    }
                    out[i * components + c] = value
                }
            }
        }
        return out
    }

    static func vectors3(_ accessor: GLTFAccessor) -> [SIMD3<Float>] {
        let f = floats(accessor)
        guard Int(GLTFComponentCountForDimension(accessor.dimension)) == 3 else { return [] }
        return Swift.stride(from: 0, to: f.count, by: 3).map { SIMD3(f[$0], f[$0 + 1], f[$0 + 2]) }
    }

    static func vectors2(_ accessor: GLTFAccessor) -> [SIMD2<Float>] {
        let f = floats(accessor)
        guard Int(GLTFComponentCountForDimension(accessor.dimension)) == 2 else { return [] }
        return Swift.stride(from: 0, to: f.count, by: 2).map { SIMD2(f[$0], f[$0 + 1]) }
    }

    static func indexArray(_ accessor: GLTFAccessor) -> [UInt32] {
        guard let view = accessor.bufferView, let data = view.buffer.data else { return [] }
        let size = Int(GLTFBytesPerComponentForComponentType(accessor.componentType))
        let stride = view.stride == 0 ? size : view.stride
        let base = view.offset + accessor.offset
        var out = [UInt32](repeating: 0, count: accessor.count)
        data.withUnsafeBytes { raw in
            guard base + (accessor.count - 1) * stride + size <= raw.count else { return }
            for i in 0..<accessor.count {
                let o = base + i * stride
                switch accessor.componentType {
                case .unsignedByte: out[i] = UInt32(raw.loadUnaligned(fromByteOffset: o, as: UInt8.self))
                case .unsignedShort: out[i] = UInt32(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self))
                default: out[i] = raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)
                }
            }
        }
        return out
    }
}
