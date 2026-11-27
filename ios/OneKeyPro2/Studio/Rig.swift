import CoreGraphics
import Foundation
import ImageIO
import simd

/// A softbox light rig: a hierarchy of nodes whose leaves are emissive quads with an alpha mask.
/// Nodes and materials can be re-posed by name (the studio keyframes), then flattened into
/// world-space quads for the environment rasteriser.
final class Rig {
    let roots: [RigNode]
    private var allNodes: [RigNode] = []
    private var allMaterials: [RigMaterial] = []
    private var nodesByName: [String: RigNode] = [:]
    private var materialsByName: [String: RigMaterial] = [:]

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        let doc = try JSONDecoder().decode(GLTFDocument.self, from: data)
        let baseURL = url.deletingLastPathComponent()
        let buffers = try doc.buffers.map { buffer -> Data in
            guard let uri = buffer.uri else { throw RigError.unsupported("embedded buffers") }
            return try Data(contentsOf: baseURL.appendingPathComponent(uri))
        }
        let reader = AccessorReader(doc: doc, buffers: buffers)

        var masks: [Int: AlphaMask] = [:]
        func mask(forTexture index: Int) -> AlphaMask? {
            guard let source = doc.textures?[index].source else { return nil }
            if let cached = masks[source] { return cached }
            guard let uri = doc.images?[source].uri else { return nil }
            let decoded = AlphaMask(url: baseURL.appendingPathComponent(uri))
            masks[source] = decoded
            return decoded
        }

        let materials = doc.materials.map { m -> RigMaterial in
            let base = m.pbrMetallicRoughness?.baseColorFactor ?? [1, 1, 1, 1]
            let emissive = m.emissiveFactor ?? [0, 0, 0]
            let state = RigMaterial.State(
                emissive: SIMD3(emissive[0], emissive[1], emissive[2]),
                emissiveIntensity: m.extensions?.emissiveStrength?.emissiveStrength ?? 1,
                opacity: base[3]
            )
            let maskTexture = m.pbrMetallicRoughness?.baseColorTexture.flatMap { mask(forTexture: $0.index) }
            return RigMaterial(name: m.name ?? "", doubleSided: m.doubleSided ?? false, mask: maskTexture, state: state)
        }
        allMaterials = materials

        let nodes = doc.nodes.map { RigNode(name: $0.name ?? "", trs: RigNode.TRS(gltf: $0)) }
        for (i, n) in doc.nodes.enumerated() {
            nodes[i].children = (n.children ?? []).map { nodes[$0] }
            if let meshIndex = n.mesh, let primitive = doc.meshes[meshIndex].primitives.first,
               let materialIndex = primitive.material {
                nodes[i].quad = try RigQuad(primitive: primitive, reader: reader, material: materials[materialIndex])
            }
        }
        allNodes = nodes

        let sceneIndex = doc.scene ?? 0
        roots = doc.scenes[sceneIndex].nodes.map { nodes[$0] }

        // Lookup by name follows a depth-first walk from the scene roots (like three.js
        // `getObjectByName`); materials are only consulted when no node matches.
        func visit(_ node: RigNode) {
            if !node.name.isEmpty, nodesByName[node.name] == nil { nodesByName[node.name] = node }
            node.children.forEach(visit)
        }
        roots.forEach(visit)
        for m in materials where !m.name.isEmpty && materialsByName[m.name] == nil {
            materialsByName[m.name] = m
        }
    }

    func reset() {
        allNodes.forEach { $0.trs = $0.initial }
        allMaterials.forEach { $0.state = $0.initial }
    }

    func apply(target: String, property: String, value: Float) {
        if let node = nodesByName[target] {
            node.set(property, value)
        } else if let material = materialsByName[target] {
            material.set(property, value)
        }
    }

    func value(target: String, property: String) -> Float? {
        if let node = nodesByName[target] { return node.get(property) }
        if let material = materialsByName[target] { return material.get(property) }
        return nil
    }

    /// Flatten the current pose into world-space quads.
    func worldQuads() -> [WorldQuad] {
        var out: [WorldQuad] = []
        func visit(_ node: RigNode, parent: simd_float4x4) {
            let world = parent * node.localMatrix
            if let quad = node.quad, let w = WorldQuad(quad: quad, world: world) { out.append(w) }
            for child in node.children { visit(child, parent: world) }
        }
        roots.forEach { visit($0, parent: matrix_identity_float4x4) }
        return out
    }
}

enum RigError: Error {
    case unsupported(String)
    case badAccessor(Int)
}

// MARK: - Nodes & materials

final class RigNode {
    struct TRS {
        var position: SIMD3<Float>
        var euler: SIMD3<Float> // XYZ order, as three.js `Object3D.rotation`
        var scale: SIMD3<Float>

        init(position: SIMD3<Float>, euler: SIMD3<Float>, scale: SIMD3<Float>) {
            self.position = position
            self.euler = euler
            self.scale = scale
        }

        fileprivate init(gltf node: GLTFDocument.Node) {
            if let m = node.matrix, m.count == 16 {
                let cols = (0..<4).map { SIMD4<Float>(m[$0 * 4], m[$0 * 4 + 1], m[$0 * 4 + 2], m[$0 * 4 + 3]) }
                let sx = simd_length(SIMD3(cols[0].x, cols[0].y, cols[0].z))
                let sy = simd_length(SIMD3(cols[1].x, cols[1].y, cols[1].z))
                let sz = simd_length(SIMD3(cols[2].x, cols[2].y, cols[2].z))
                let r = simd_float3x3(SIMD3(cols[0].x, cols[0].y, cols[0].z) / sx,
                                      SIMD3(cols[1].x, cols[1].y, cols[1].z) / sy,
                                      SIMD3(cols[2].x, cols[2].y, cols[2].z) / sz)
                self.init(position: SIMD3(cols[3].x, cols[3].y, cols[3].z), euler: Euler.xyz(from: r),
                          scale: SIMD3(sx, sy, sz))
                return
            }
            let t = node.translation ?? [0, 0, 0]
            let q = node.rotation ?? [0, 0, 0, 1]
            let s = node.scale ?? [1, 1, 1]
            let rotation = simd_float3x3(simd_quatf(ix: q[0], iy: q[1], iz: q[2], r: q[3]))
            self.init(position: SIMD3(t[0], t[1], t[2]), euler: Euler.xyz(from: rotation), scale: SIMD3(s[0], s[1], s[2]))
        }
    }

    let name: String
    let initial: TRS
    var trs: TRS
    var children: [RigNode] = []
    var quad: RigQuad?

    init(name: String, trs: TRS) {
        self.name = name
        self.initial = trs
        self.trs = trs
    }

    var localMatrix: simd_float4x4 {
        let r = Euler.matrix(trs.euler)
        return simd_float4x4(
            SIMD4(r.columns.0 * trs.scale.x, 0),
            SIMD4(r.columns.1 * trs.scale.y, 0),
            SIMD4(r.columns.2 * trs.scale.z, 0),
            SIMD4(trs.position, 1)
        )
    }

    func set(_ property: String, _ v: Float) {
        switch property {
        case "positionX": trs.position.x = v
        case "positionY": trs.position.y = v
        case "positionZ": trs.position.z = v
        case "rotationX": trs.euler.x = v
        case "rotationY": trs.euler.y = v
        case "rotationZ": trs.euler.z = v
        case "scaleX": trs.scale.x = v
        case "scaleY": trs.scale.y = v
        case "scaleZ": trs.scale.z = v
        default: break
        }
    }

    func get(_ property: String) -> Float? {
        switch property {
        case "positionX": return trs.position.x
        case "positionY": return trs.position.y
        case "positionZ": return trs.position.z
        case "rotationX": return trs.euler.x
        case "rotationY": return trs.euler.y
        case "rotationZ": return trs.euler.z
        case "scaleX": return trs.scale.x
        case "scaleY": return trs.scale.y
        case "scaleZ": return trs.scale.z
        default: return nil
        }
    }
}

final class RigMaterial {
    struct State {
        var emissive: SIMD3<Float>
        var emissiveIntensity: Float
        var opacity: Float
    }

    let name: String
    let doubleSided: Bool
    let mask: AlphaMask?
    let initial: State
    var state: State

    init(name: String, doubleSided: Bool, mask: AlphaMask?, state: State) {
        self.name = name
        self.doubleSided = doubleSided
        self.mask = mask
        self.initial = state
        self.state = state
    }

    /// Only emission and opacity matter: the panels are black, unlit and alpha-blended.
    func set(_ property: String, _ v: Float) {
        switch property {
        case "emissiveIntensity": state.emissiveIntensity = v
        case "emissiveR": state.emissive.x = v
        case "emissiveG": state.emissive.y = v
        case "emissiveB": state.emissive.z = v
        case "opacity": state.opacity = v
        default: break // colour / metalness / roughness don't contribute without lights
        }
    }

    func get(_ property: String) -> Float? {
        switch property {
        case "emissiveIntensity": return state.emissiveIntensity
        case "emissiveR": return state.emissive.x
        case "emissiveG": return state.emissive.y
        case "emissiveB": return state.emissive.z
        case "opacity": return state.opacity
        default: return nil
        }
    }
}

// MARK: - Geometry

/// A panel quad in its node's local space, parameterised by texture coordinates:
/// `P(uv) = p0 + dPdu * (u - uv0.x) + dPdv * (v - uv0.y)`.
struct RigQuad {
    let p0: SIMD3<Float>
    let dPdu: SIMD3<Float>
    let dPdv: SIMD3<Float>
    let uv0: SIMD2<Float>
    let uvMin: SIMD2<Float>
    let uvMax: SIMD2<Float>
    let normal: SIMD3<Float>
    let corners: [SIMD3<Float>]
    let material: RigMaterial

    fileprivate init(primitive: GLTFDocument.Primitive, reader: AccessorReader, material: RigMaterial) throws {
        guard let posIndex = primitive.attributes["POSITION"], let uvIndex = primitive.attributes["TEXCOORD_0"] else {
            throw RigError.unsupported("quad without positions/uvs")
        }
        let positions = try reader.vectors3(posIndex)
        let uvs = try reader.vectors2(uvIndex)
        let normals = try primitive.attributes["NORMAL"].map { try reader.vectors3($0) } ?? []
        guard positions.count >= 3, uvs.count == positions.count else { throw RigError.badAccessor(posIndex) }

        // Pick the two edges from vertex 0 with the best-conditioned UV basis.
        var best: (Int, Int, Float) = (1, 2, 0)
        for i in 1..<positions.count {
            for j in (i + 1)..<positions.count {
                let a = uvs[i] - uvs[0], b = uvs[j] - uvs[0]
                let det = abs(a.x * b.y - a.y * b.x)
                if det > best.2 { best = (i, j, det) }
            }
        }
        let (i, j, _) = best
        let du1 = uvs[i] - uvs[0], du2 = uvs[j] - uvs[0]
        let dp1 = positions[i] - positions[0], dp2 = positions[j] - positions[0]
        let det = du1.x * du2.y - du1.y * du2.x
        // Solve [dp1 dp2] = [dPdu dPdv] * [du1 du2]
        dPdu = (dp1 * du2.y - dp2 * du1.y) / det
        dPdv = (dp2 * du1.x - dp1 * du2.x) / det
        p0 = positions[0]
        uv0 = uvs[0]
        uvMin = uvs.reduce(SIMD2(repeating: .infinity)) { simd_min($0, $1) }
        uvMax = uvs.reduce(SIMD2(repeating: -.infinity)) { simd_max($0, $1) }
        normal = normals.first ?? simd_normalize(simd_cross(dPdu, dPdv))
        corners = positions
        self.material = material
    }
}

/// A posed quad in world space, ready for ray casting from the origin.
struct WorldQuad {
    let q0: SIMD3<Float>
    let n1: SIMD3<Float>
    let n2: SIMD3<Float>
    let planeNormal: SIMD3<Float>
    let invNormalLengthSquared: Float
    let planeDistance: Float
    let front: SIMD3<Float>
    let doubleSided: Bool
    let uv0: SIMD2<Float>
    let uvMin: SIMD2<Float>
    let uvMax: SIMD2<Float>
    let radiance: SIMD3<Float>
    let opacity: Float
    let mask: AlphaMask?
    /// Bounding cone (as seen from the origin) for a cheap early-out.
    let coneAxis: SIMD3<Float>
    let coneCos: Float

    init?(quad: RigQuad, world: simd_float4x4) {
        let m = quad.material.state
        guard m.opacity > 0 else { return nil }
        let w3 = simd_float3x3(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
                               SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
                               SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z))
        func point(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let v = world * SIMD4(p, 1)
            return SIMD3(v.x, v.y, v.z)
        }
        q0 = point(quad.p0)
        n1 = w3 * quad.dPdu
        n2 = w3 * quad.dPdv
        planeNormal = simd_cross(n1, n2)
        let len2 = simd_length_squared(planeNormal)
        guard len2 > 1e-12 else { return nil }
        invNormalLengthSquared = 1 / len2
        planeDistance = simd_dot(q0, planeNormal)
        front = simd_normalize(w3.inverse.transpose * quad.normal)
        doubleSided = quad.material.doubleSided
        uv0 = quad.uv0
        uvMin = quad.uvMin
        uvMax = quad.uvMax
        radiance = m.emissive * m.emissiveIntensity
        opacity = m.opacity
        mask = quad.material.mask

        let corners = quad.corners.map(point)
        let center = corners.reduce(SIMD3<Float>.zero, +) / Float(corners.count)
        let axis = simd_normalize(center)
        coneAxis = axis
        coneCos = corners.map { simd_dot(simd_normalize($0), axis) }.min()! - 1e-3
    }
}

// MARK: - Alpha mask

/// The alpha channel of a softbox texture (glTF UV origin = top-left, no flip).
final class AlphaMask {
    let width: Int
    let height: Int
    private let alpha: [Float]

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        alpha = (0..<(w * h)).map { Float(bytes[$0 * 4 + 3]) / 255 }
    }

    /// Bilinear, repeat-wrapped sample.
    @inline(__always)
    func sample(_ uv: SIMD2<Float>) -> Float {
        let x = uv.x * Float(width) - 0.5
        let y = uv.y * Float(height) - 0.5
        let fx = x.rounded(.down), fy = y.rounded(.down)
        let tx = x - fx, ty = y - fy
        let x0 = wrap(Int(fx), width), x1 = wrap(Int(fx) + 1, width)
        let y0 = wrap(Int(fy), height), y1 = wrap(Int(fy) + 1, height)
        let a = alpha[y0 * width + x0] * (1 - tx) + alpha[y0 * width + x1] * tx
        let b = alpha[y1 * width + x0] * (1 - tx) + alpha[y1 * width + x1] * tx
        return a * (1 - ty) + b * ty
    }

    @inline(__always)
    private func wrap(_ i: Int, _ n: Int) -> Int {
        let r = i % n
        return r < 0 ? r + n : r
    }
}

// MARK: - Euler (three.js XYZ convention)

enum Euler {
    /// R = Rx(x) · Ry(y) · Rz(z)
    static func matrix(_ e: SIMD3<Float>) -> simd_float3x3 {
        let a = cos(e.x), b = sin(e.x), c = cos(e.y), d = sin(e.y), ee = cos(e.z), f = sin(e.z)
        let ae = a * ee, af = a * f, be = b * ee, bf = b * f
        return simd_float3x3(
            SIMD3(c * ee, af + be * d, bf - ae * d),
            SIMD3(-c * f, ae - bf * d, be + af * d),
            SIMD3(d, -b * c, a * c)
        )
    }

    static func xyz(from m: simd_float3x3) -> SIMD3<Float> {
        let m11 = m.columns.0.x, m12 = m.columns.1.x, m13 = m.columns.2.x
        let m22 = m.columns.1.y, m23 = m.columns.2.y
        let m32 = m.columns.1.z, m33 = m.columns.2.z
        let y = asin(min(max(m13, -1), 1))
        if abs(m13) < 0.9999999 {
            return SIMD3(atan2(-m23, m33), y, atan2(-m12, m11))
        }
        return SIMD3(atan2(m32, m22), y, 0)
    }
}

// MARK: - Minimal glTF reader

fileprivate struct GLTFDocument: Decodable {
    struct Node: Decodable {
        let name: String?
        let children: [Int]?
        let mesh: Int?
        let translation: [Float]?
        let rotation: [Float]?
        let scale: [Float]?
        let matrix: [Float]?
    }

    struct Scene: Decodable { let nodes: [Int] }

    struct Primitive: Decodable {
        let attributes: [String: Int]
        let indices: Int?
        let material: Int?
    }

    struct Mesh: Decodable { let primitives: [Primitive] }
    struct TextureRef: Decodable { let index: Int }

    struct PBR: Decodable {
        let baseColorFactor: [Float]?
        let baseColorTexture: TextureRef?
    }

    struct EmissiveStrength: Decodable { let emissiveStrength: Float? }

    struct MaterialExtensions: Decodable {
        let emissiveStrength: EmissiveStrength?
        enum CodingKeys: String, CodingKey { case emissiveStrength = "KHR_materials_emissive_strength" }
    }

    struct Material: Decodable {
        let name: String?
        let pbrMetallicRoughness: PBR?
        let emissiveFactor: [Float]?
        let extensions: MaterialExtensions?
        let doubleSided: Bool?
    }

    struct Texture: Decodable { let source: Int? }
    struct Image: Decodable { let uri: String? }

    struct Accessor: Decodable {
        let bufferView: Int?
        let byteOffset: Int?
        let componentType: Int
        let count: Int
        let type: String
    }

    struct BufferView: Decodable {
        let buffer: Int
        let byteOffset: Int?
        let byteLength: Int
        let byteStride: Int?
    }

    struct Buffer: Decodable {
        let uri: String?
        let byteLength: Int
    }

    let scene: Int?
    let scenes: [Scene]
    let nodes: [Node]
    let meshes: [Mesh]
    let materials: [Material]
    let textures: [Texture]?
    let images: [Image]?
    let accessors: [Accessor]
    let bufferViews: [BufferView]
    let buffers: [Buffer]
}

fileprivate struct AccessorReader {
    let doc: GLTFDocument
    let buffers: [Data]

    private func floats(_ index: Int, components: Int) throws -> [Float] {
        let accessor = doc.accessors[index]
        guard accessor.componentType == 5126, let viewIndex = accessor.bufferView else { throw RigError.badAccessor(index) }
        let view = doc.bufferViews[viewIndex]
        let stride = view.byteStride ?? components * 4
        let start = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        let data = buffers[view.buffer]
        var out = [Float](repeating: 0, count: accessor.count * components)
        data.withUnsafeBytes { raw in
            for i in 0..<accessor.count {
                for c in 0..<components {
                    out[i * components + c] = raw.loadUnaligned(fromByteOffset: start + i * stride + c * 4, as: Float.self)
                }
            }
        }
        return out
    }

    func vectors3(_ index: Int) throws -> [SIMD3<Float>] {
        let f = try floats(index, components: 3)
        return stride(from: 0, to: f.count, by: 3).map { SIMD3(f[$0], f[$0 + 1], f[$0 + 2]) }
    }

    func vectors2(_ index: Int) throws -> [SIMD2<Float>] {
        let f = try floats(index, components: 2)
        return stride(from: 0, to: f.count, by: 2).map { SIMD2(f[$0], f[$0 + 1]) }
    }
}
