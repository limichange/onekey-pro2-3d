import * as THREE from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { POWER_GLOW } from './product.js';

const GLOW_LAYER = 31;

/**
 * Renders only the glow layer at half resolution through a bloom pass, then adds the result
 * on top of the already-rendered frame. Alpha carries only the added light, so a transparent
 * canvas stays transparent outside the halo.
 */
class BloomComposite {
  constructor() {
    this.size = new THREE.Vector2();
    this.width = 0;
    this.height = 0;
    this.composer = null;
    this.bloomPass = null;
    this.quadScene = new THREE.Scene();
    this.quadCamera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
    this.material = new THREE.ShaderMaterial({
      uniforms: { uMap: { value: null }, uStrength: { value: 0 } },
      vertexShader: /* glsl */ `
        varying vec2 vUv;
        void main() {
          vUv = uv;
          gl_Position = vec4(position.xy, 0.0, 1.0);
        }`,
      fragmentShader: /* glsl */ `
        uniform sampler2D uMap;
        uniform float uStrength;
        varying vec2 vUv;
        void main() {
          vec3 glow = texture2D(uMap, vUv).rgb * uStrength;
          gl_FragColor = vec4(glow, clamp(max(max(glow.r, glow.g), glow.b), 0.0, 1.0));
        }`,
      blending: THREE.CustomBlending,
      blendEquation: THREE.AddEquation,
      blendSrc: THREE.OneFactor,
      blendDst: THREE.OneFactor,
      blendSrcAlpha: THREE.OneFactor,
      blendDstAlpha: THREE.OneFactor,
      transparent: true,
      depthTest: false,
      depthWrite: false,
    });
    this.quad = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.material);
    this.quad.frustumCulled = false;
    this.quadScene.add(this.quad);
  }

  render(renderer, scene, camera, strength) {
    if (strength <= 0) return;
    const buffer = renderer.getDrawingBufferSize(this.size);
    const w = Math.max(4, Math.round(buffer.x / 2));
    const h = Math.max(4, Math.round(buffer.y / 2));
    if (!this.composer) {
      const target = new THREE.WebGLRenderTarget(w, h, { type: THREE.HalfFloatType, samples: 4 });
      this.composer = new EffectComposer(renderer, target);
      this.composer.renderToScreen = false;
      this.composer.setPixelRatio(1);
      this.bloomPass = new UnrealBloomPass(new THREE.Vector2(w, h), 1, POWER_GLOW.bloomRadius, 0);
      this.composer.addPass(new RenderPass(scene, camera, undefined, new THREE.Color(0), 0));
      this.composer.addPass(this.bloomPass);
    }
    if (w !== this.width || h !== this.height) {
      this.width = w;
      this.height = h;
      this.composer.setSize(w, h);
    }
    const mask = camera.layers.mask;
    camera.layers.set(GLOW_LAYER);
    this.bloomPass.strength = POWER_GLOW.bloomStrength;
    this.bloomPass.radius = POWER_GLOW.bloomRadius;
    this.composer.render();
    camera.layers.mask = mask;

    this.material.uniforms.uMap.value = this.composer.renderTarget2.texture;
    this.material.uniforms.uStrength.value = strength;
    const autoClear = renderer.autoClear;
    renderer.setRenderTarget(null);
    renderer.autoClear = false;
    renderer.render(this.quadScene, this.quadCamera);
    renderer.autoClear = autoClear;
  }

  dispose() {
    this.bloomPass?.dispose();
    this.composer?.dispose();
    this.composer = null;
    this.quad.geometry.dispose();
    this.material.dispose();
  }
}

let strokePromise = null;

function loadStroke(loader) {
  strokePromise ??= loader.loadAsync(POWER_GLOW.url).then((gltf) => {
    let mesh = null;
    gltf.scene.traverse((o) => {
      if (o.isMesh) mesh = o;
    });
    if (!mesh) throw new Error('button-glow stroke has no mesh');
    mesh.material.toneMapped = false;
    mesh.material.emissive.set(POWER_GLOW.glowColor);
    mesh.material.emissiveIntensity = 0;
    mesh.layers.enable(GLOW_LAYER);
    // The stroke is authored in the raw glTF frame of the product node.
    const node = new THREE.Group();
    node.rotation.x = -Math.PI / 2;
    node.add(mesh);
    return { node, material: mesh.material };
  }).catch((err) => {
    strokePromise = null;
    throw err;
  });
  return strokePromise;
}

/** "Press to wake" glow around the fingerprint power button: a breathing stroke + bloom halo. */
export class PowerGlowEffect {
  constructor({ loader, root, buttonMaterials, invalidate }) {
    this.loader = loader;
    this.root = root;
    this.button = buttonMaterials[0] ?? null;
    this.invalidate = invalidate;
    this.alive = true;
    this.time = 0;
    this.level = 0;
    this.stroke = null;
    this.bloom = new BloomComposite();
    if (this.button) {
      this.savedEmissive = this.button.emissive.clone();
      this.savedIntensity = this.button.emissiveIntensity;
      this.button.emissive.set(POWER_GLOW.glowColor);
      this.button.emissiveIntensity = 0;
    }
    loadStroke(loader).then((stroke) => {
      if (!this.alive) return;
      const host = root.getObjectByName('Pro2_Black') ?? root;
      host.add(stroke.node);
      this.stroke = stroke;
      this.invalidate();
    }).catch((err) => console.warn('power glow unavailable:', err));
  }

  /** Returns true to keep the render loop running. */
  update(dt) {
    this.time += dt;
    const fade = Math.min(this.time / POWER_GLOW.fadeInSeconds, 1);
    const breathe = 0.5 - 0.5 * Math.cos(this.time * POWER_GLOW.breatheSpeed);
    this.level = fade * fade * (3 - 2 * fade)
      * (POWER_GLOW.breatheFloor + (1 - POWER_GLOW.breatheFloor) * breathe);
    if (this.stroke) this.stroke.material.emissiveIntensity = this.level * POWER_GLOW.strokeIntensity;
    if (this.button) this.button.emissiveIntensity = this.level * POWER_GLOW.buttonIntensity;
    return true;
  }

  afterRender(renderer, scene, camera) {
    if (this.stroke) this.bloom.render(renderer, scene, camera, this.level * POWER_GLOW.glowStrength);
  }

  dispose() {
    this.alive = false;
    this.bloom.dispose();
    if (this.stroke) {
      this.stroke.node.removeFromParent();
      this.stroke.material.emissiveIntensity = 0;
      this.stroke = null;
    }
    if (this.button) {
      this.button.emissive.copy(this.savedEmissive);
      this.button.emissiveIntensity = this.savedIntensity;
    }
  }
}
