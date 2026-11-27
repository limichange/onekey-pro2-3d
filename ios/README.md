# OneKey Pro 2 · Native iOS Viewer

A SwiftUI + RealityKit app that renders the OneKey Pro 2 model natively. It contains no web
view and no web code: it reads the original product data (`black.glb`, `colors.json`) and the
product page's light-studio data (`studio.json` and the softbox rig glTFs) directly.

## Build

```bash
brew install xcodegen        # once
cd ios
xcodegen                     # generates OneKeyPro2.xcodeproj from project.yml
open OneKeyPro2.xcodeproj
```

- Requires iOS 18+ (per-entity image-based lighting). Runs in the Simulator as is; for a device,
  pick your team under *Signing & Capabilities*.
- Swift Package dependency: [GLTFKit2](https://github.com/warrenm/GLTFKit2) 0.5.15 (MIT), used for
  glTF parsing and `EXT_meshopt_compression` decoding.

Launch arguments (Scheme ▸ Run ▸ Arguments) for deep links and testing:
`-color Orange|Silver|Black`, `-feature color|frame|back-cover|gorilla-glass|fingerprint|g3-curve`,
`-angle front|back|left|…`, `-envDebug YES` (shows the equirect orientation test instead of the model).

## How it works

| Piece | File |
| --- | --- |
| glTF → RealityKit, dequantizing `KHR_mesh_quantization` (GLTFKit2's bundled RealityKit bridge only reads float attributes) | `Product/GLTFEntityBuilder.swift` |
| Material roles, copy, feature close-ups (ported from the page's config) | `Product/ProductConfig.swift` |
| Colourways from `colors.json` | `Product/ColorSpec.swift` |
| Softbox rigs: parse the glTF, re-pose by studio keyframes | `Studio/Rig.swift` |
| CPU ray-cast of the softbox quads into HDR equirect environments | `Studio/StudioBaker.swift` |
| Bake orchestration + `EnvironmentResource` cache per colourway / layer / angle | `Studio/StudioLighting.swift` |
| Orbit / snap camera and per-angle lighting weights | `Stage/OrbitCamera.swift` |
| Scene, per-role image-based lights, lens/pose springs, colour transitions | `Stage/ProductStage.swift` |

**Lighting.** The page lights the product with three softbox rigs (body, port, frame), each re-posed
for 12 camera angles and rendered into an environment map. At launch the app bakes the same
rigs itself: each panel is an emissive quad with an alpha mask, so a ray cast from the origin
reproduces what the page's cube camera sees. That is 36 maps per colourway, about 2 s on an M2 in the
Simulator. Every material role gets its own `ImageBasedLightComponent`, which carries the role's
intensity and rotation, and the two nearest angles are cross-faded with `.blend` as the camera moves.

**Differences from the page:** RealityKit has no transmission (the camera lens glass is
approximated with transparency), no sheen and no bloom (the fingerprint glow keeps its breathing
stroke but loses the halo). Two shader tweaks in the G3 close-up (`shadowSaturation`,
`reflectionSmoothing`) and its two softbox intensity tweaks are not ported.
