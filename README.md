# OneKey Pro 2 · Standalone 3D Viewer

A standalone page for the interactive 3D model from
<https://onekey.so/zh_CN/products/onekey-pro-2/>. It reproduces the site's
lighting pipeline with plain three.js (r165, vendored), with no build step and no CDN.

## Run

ES modules and model fetches don't work over `file://`, so serve the folder over HTTP:

```bash
cd onekey-pro2-3d
python3 -m http.server 8080
# open http://localhost:8080
```

URL params: `?color=Orange|Silver|Black`, `&feature=color|frame|back-cover|gorilla-glass|fingerprint|g3-curve`, `&bg=dark`.

Controls: drag to orbit, wheel/pinch to zoom, double-click to reset zoom, ←/→ to step around,
↑/↓ for top/bottom, 1–3 to switch colours, F / Shift+F to step through features, Esc for the overview.

## Design copy + feature close-ups

The left column (a bottom sheet on mobile) carries the zh_CN copy from the page's design section
(「设计 · 每一处细节，成就一身质感。」 and the 「定睛细看」 list). Each feature reuses the site's view
definition (`FEATURE_VIEWS` in `src/product.js`):

| Feature | Angle | Close-up |
| --- | --- | --- |
| 颜色 | backLeft | 1.61× on the camera corner |
| 光面铝合金中框 | left | full side profile |
| 磨砂玻璃后盖 | backLeft | back, slight tilt |
| 康宁® Gorilla® Glass 5 | frontLeft | screen, slight tilt |
| 二合一指纹电源 | left | 2.04× on the button + breathing glow stroke with bloom |
| G3 混接曲线 | backLeft | 3.05× on the corner with a longer lens and per-material lighting tweaks |

A pose's scale and position are turned into camera distance and framing offset; the model itself
only rotates. Lens, pose and lighting glide with a critically damped spring, and grabbing the
model returns to the overview, as on the site. Not ported: two shader-level tweaks in the G3 view
(`shadowSaturation`, `reflectionSmoothing`).

## How the lighting works

The site doesn't use a static HDRI. It reuses a product-photography light studio (`glossy`):

- **3 light rigs** (`assets/studio/rigs/layer{0,1,2}-*.gltf`), each a set of emissive softbox panels.
  Every product material is assigned to one rig by name (`src/product.js`):
  layer 0 = back cover/logo, layer 1 = USB-C port, layer 2 = frame/button/glass/camera.
- **Per-angle keyframes** (`assets/studio/studio.json`): for 12 camera angles (front, back, left,
  …) each softbox has its own transform and brightness, with an extra `Black+<angle>` set for the
  dark colourway (`glossy-dark`).
- Every frame, the camera direction is turned into weights for the nearest labelled angles. Each
  rig's softboxes are interpolated to those weights, rendered into a cube map, and prefiltered
  (PMREM) into that layer's environment map (`src/studio-rig.js`).
- `colors.json` recolours a single black base model per colourway: base colours, role overrides,
  studio intensity, and background fill.

## Layout

```
index.html            page + import map
src/main.js           UI wiring
src/viewer.js         renderer, materials, colour transitions, render loop
src/studio-rig.js     softbox rig posing + env-map baking
src/orbit-camera.js   orbit / throw / snap-to-angle camera + lighting weights
src/power-glow.js     fingerprint button glow (stroke mesh + half-res bloom composite)
src/product.js        material classification, copy, feature views, product config
assets/model/         black.glb (meshopt + webp), colors.json, effects/button-glow-stroke.glb
assets/studio/        studio.json (keyframes), slimmed rig glTFs, softbox textures (AVIF)
vendor/three/         three.js r165 (MIT) + GLTFLoader, meshopt decoder, bloom post-processing
```

The model, textures and studio data are © their respective owners (OneKey and the studio
rig authors). This is for personal study and preview only.
