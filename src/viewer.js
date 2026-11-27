import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { MeshoptDecoder } from 'three/addons/libs/meshopt_decoder.module.js';
import { StudioRig } from './studio-rig.js';
import { OrbitCamera } from './orbit-camera.js';
import { PowerGlowEffect } from './power-glow.js';
import {
  ASSETS_BASE, PRODUCT, LENS_DEFAULT, MODEL_SCALE, OVERVIEW, INTRO, resolveView,
} from './product.js';

const TUNABLE_PROPS = ['metalness', 'roughness'];
const COLOR_TRANSITION_SECONDS = 0.7;
const BLACK = new THREE.Color(0x000000);
const RIG_PREFIX = 'rig:';

const easeInOut = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

async function fetchJSON(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${res.status} ${url}`);
  return res.json();
}

/** Widen/narrow a vertical FOV the way the studio camera does (`fovScale`). */
function scaledFov(fov, scale) {
  return THREE.MathUtils.radToDeg(2 * Math.atan(Math.tan(THREE.MathUtils.degToRad(fov) / 2) * scale));
}

/** Neutral value of a view-lighting channel. */
function channelDefault(key) {
  return key.startsWith(RIG_PREFIX) || /\.(intensity|colorSaturation|colorLightness|shadowSaturation)$/.test(key) ? 1 : 0;
}

/** Critically damped spring (Unity-style SmoothDamp). Returns [value, velocity]. */
function smoothDamp(current, target, velocity, smoothTime, dt) {
  const omega = 2 / smoothTime;
  const x = omega * dt;
  const k = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x);
  const change = current - target;
  const temp = (velocity + omega * change) * dt;
  return [target + (change + temp) * k, (velocity - omega * temp) * k];
}

/** A bag of named scalars that glide towards their targets. */
class Springs {
  constructor() {
    this.values = new Map();
    this.targets = new Map();
    this.velocities = new Map();
    this.smoothTime = 0.2;
  }

  get(key, fallback = 0) {
    return this.values.get(key) ?? fallback;
  }

  keys() {
    return this.values.keys();
  }

  /** Set targets; `smoothTime == null` jumps immediately. */
  to(entries, smoothTime) {
    for (const [key, value] of Object.entries(entries)) {
      if (!this.values.has(key)) this.values.set(key, smoothTime == null ? value : channelDefault(key));
      this.targets.set(key, value);
      if (smoothTime == null) {
        this.values.set(key, value);
        this.velocities.set(key, 0);
      }
    }
    if (smoothTime != null) this.smoothTime = smoothTime;
  }

  /** Advance; returns the set of keys that changed. */
  step(dt) {
    const changed = new Set();
    for (const [key, target] of this.targets) {
      const value = this.values.get(key);
      const velocity = this.velocities.get(key) ?? 0;
      if (Math.abs(value - target) < 1e-5 && Math.abs(velocity) < 1e-5) {
        if (value !== target) {
          this.values.set(key, target);
          changed.add(key);
        }
        continue;
      }
      const [v, vel] = smoothDamp(value, target, velocity, this.smoothTime, dt);
      this.values.set(key, v);
      this.velocities.set(key, vel);
      changed.add(key);
    }
    return changed;
  }
}

export class ProductViewer {
  constructor(container, { onAngleChange, onGrab, cubeSize = 256 } = {}) {
    this.container = container;
    this.cubeSize = cubeSize;
    this.onAngleChange = onAngleChange ?? (() => {});
    this.onGrab = onGrab ?? (() => {});
    this.materials = [];
    this.rigs = [];
    this.transition = null;
    this.lightingDirty = true;
    this.renderDirty = true;
    this.disposed = false;
    this.lastTime = performance.now();
    this.lastAngle = null;
    this.insets = { top: 0, right: 0, bottom: 0, left: 0 };
    this.mobile = false;
    this.activeView = null;
    this.viewApplied = false; // becomes true once the intro hands over to a real view
    this.effect = null;
    this.lens = new Springs(); // fovScale, radius, ox/oy/oz
    this.pose = new Springs(); // rx/ry/rz
    this.lighting = new Springs(); // `${role}.${channel}` and `rig:${layer}:${target}:${prop}`
  }

  async load({ color = PRODUCT.defaultColor, onProgress = () => {} } = {}) {
    const renderer = new THREE.WebGLRenderer({
      antialias: true,
      alpha: true,
      premultipliedAlpha: true,
      powerPreference: 'high-performance',
    });
    if (!renderer.capabilities.isWebGL2) throw new Error('WebGL2 is required');
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1;
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.setClearColor(0x000000, 0);
    renderer.domElement.classList.add('viewer-canvas');
    this.renderer = renderer;
    this.pmrem = new THREE.PMREMGenerator(renderer);
    this.pmrem.compileCubemapShader();

    // ---- loading ---------------------------------------------------------
    let modelFraction = 0;
    let items = { loaded: 0, total: 1 };
    const report = (label) => onProgress(Math.min(0.98, modelFraction * 0.7 + (items.loaded / items.total) * 0.28), label);
    const manager = new THREE.LoadingManager();
    manager.onProgress = (_url, loaded, total) => {
      items = { loaded, total };
      report('加载灯箱');
    };

    report('读取配置');
    const [studio, colors] = await Promise.all([fetchJSON(PRODUCT.studioUrl), fetchJSON(PRODUCT.colorsUrl)]);
    this.studio = studio;
    this.colorSpec = colors;

    const loader = new GLTFLoader(manager).setMeshoptDecoder(MeshoptDecoder);
    this.loader = new GLTFLoader().setMeshoptDecoder(MeshoptDecoder); // for effects loaded later
    const [gltf, ...rigGltfs] = await Promise.all([
      loader.loadAsync(PRODUCT.modelUrl, (e) => {
        if (e.total) modelFraction = e.loaded / e.total;
        report('加载模型');
      }),
      ...studio.layers.map((layer) => loader.loadAsync(`${ASSETS_BASE}studio/${layer.rig}`)),
    ]);
    if (this.disposed) return;

    // ---- scene -------------------------------------------------------------
    this.scene = new THREE.Scene();
    this.camera = new THREE.PerspectiveCamera(35, 1, 1, studio.camera.far);

    const model = gltf.scene;
    model.rotation.y = PRODUCT.rotationY;
    model.updateMatrixWorld(true);
    const size = new THREE.Box3().setFromObject(model).getSize(new THREE.Vector3());
    model.scale.multiplyScalar(PRODUCT.targetHeight / Math.max(size.y, 1e-6));
    model.updateMatrixWorld(true);
    const center = new THREE.Box3().setFromObject(model).getCenter(new THREE.Vector3());
    model.position.sub(center);
    this.model = model;
    this.root = new THREE.Group();
    this.root.scale.setScalar(MODEL_SCALE);
    this.root.add(model);
    this.scene.add(this.root);

    this.rigs = studio.layers.map((def, i) => new StudioRig(renderer, this.pmrem, def, rigGltfs[i].scene, { cubeSize: this.cubeSize }));
    this.rigByLayer = new Map(this.rigs.map((rig) => [rig.layer, rig]));

    this.classifyMaterials();
    this.groupByMaterial = new Map();
    for (const [group, names] of Object.entries(colors.groups ?? {})) {
      for (const name of names) this.groupByMaterial.set(name, group);
    }

    // ---- interaction ---------------------------------------------------------
    this.orbit = new OrbitCamera(this.camera, this.container, studio, {
      onChange: () => {
        this.renderDirty = true;
      },
      onGrab: () => this.onGrab(),
    });

    // ---- initial state: colour, intro pose (no animation) --------------------
    this.currentColor = colors.colors[color] ? color : colors.default;
    this.state = this.computeColorState(this.currentColor);
    this.applyColorState(this.state, this.state, 1);
    this.orbit.setAngle(INTRO.angle);
    this.applyViewTargets(INTRO, null);
    this.syncLens();

    this.container.prepend(renderer.domElement);
    this.resizeObserver = new ResizeObserver(() => this.resize());
    this.resizeObserver.observe(this.container);
    this.resize();

    // Warm up shaders so the first interaction doesn't stutter.
    this.orbit.update(0);
    this.updateLighting();
    renderer.compile(this.scene, this.camera);
    this.render();
    onProgress(1, '就绪');

    this.loop = this.loop.bind(this);
    this.frame = requestAnimationFrame(this.loop);
  }

  classifyMaterials() {
    const seen = new Set();
    this.model.traverse((obj) => {
      if (!obj.isMesh) return;
      const mats = Array.isArray(obj.material) ? obj.material : [obj.material];
      for (const mat of mats) {
        if (!mat || seen.has(mat)) continue;
        seen.add(mat);
        const info = PRODUCT.classifyMaterial(mat);
        PRODUCT.tuneMaterial(mat, info.role);
        const baseProps = {};
        for (const p of TUNABLE_PROPS) if (typeof mat[p] === 'number') baseProps[p] = mat[p];
        this.materials.push({
          mat,
          role: info.role,
          layer: info.layer,
          baseIntensity: info.intensity,
          intensity: info.intensity,
          viewIntensity: 1,
          baseColor: mat.color ? mat.color.clone() : null,
          stateColor: mat.color ? mat.color.clone() : null,
          baseProps,
          stateProps: { ...baseProps },
        });
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Colourways
  // ---------------------------------------------------------------------------

  /** Resolve a colourway from colors.json into concrete per-material targets. */
  computeColorState(colorId) {
    const spec = this.colorSpec.colors[colorId] ?? {};
    const roleTuning = PRODUCT.roleTuning ?? {};
    const perMaterial = new Map();
    for (const info of this.materials) {
      const { mat, role } = info;
      let color = null;
      if (info.baseColor) {
        color = info.baseColor.clone();
        const group = this.groupByMaterial.get(mat.name);
        const groupHex = group ? spec.groupColors?.[group] : undefined;
        if (groupHex) color.set(groupHex);
        const roleHex = spec.materialColors?.[mat.name] ?? spec.roleColors?.[role];
        if (roleHex) color.set(roleHex);
      }
      const props = { ...info.baseProps };
      for (const [p, v] of Object.entries(roleTuning[role] ?? {})) if (p in props) props[p] = v;
      for (const [p, v] of Object.entries(spec.roleMaterial?.[role] ?? {})) if (p in props) props[p] = v;
      const intensity = spec.roleIntensity?.[role] ?? roleTuning[role]?.intensity ?? info.baseIntensity;
      perMaterial.set(mat, { color, props, intensity });
    }
    return {
      id: colorId,
      perMaterial,
      studioState: spec.studioVariant === 'glossy-dark' ? 'Black' : null,
      studioIntensity: spec.studioIntensity ?? 1,
      background: spec.studioBackground ? new THREE.Color(spec.studioBackground) : BLACK.clone(),
    };
  }

  /** Write a blend of two colour states (k = 0..1) into the material state + rigs. */
  applyColorState(from, to, k) {
    for (const info of this.materials) {
      const a = from.perMaterial.get(info.mat);
      const b = to.perMaterial.get(info.mat);
      if (!a || !b) continue;
      if (a.color && b.color) info.stateColor.lerpColors(a.color, b.color, k);
      for (const p of Object.keys(b.props)) info.stateProps[p] = THREE.MathUtils.lerp(a.props[p], b.props[p], k);
      info.intensity = THREE.MathUtils.lerp(a.intensity, b.intensity, k);
    }
    this.studioIntensity = THREE.MathUtils.lerp(from.studioIntensity, to.studioIntensity, k);
    this.studioFrom = from.studioState;
    this.studioTo = to.studioState;
    this.studioMix = k;
    const bg = from.background.clone().lerp(to.background, k);
    for (const rig of this.rigs) rig.setBackground(bg);
    this.applyMaterialView();
  }

  setColor(colorId) {
    if (!this.colorSpec?.colors[colorId] || colorId === this.currentColor) return;
    // Start from whatever is currently on screen (handles switching mid-transition).
    const from = this.transition ? this.snapshotState() : this.state;
    const to = this.computeColorState(colorId);
    this.transition = { from, to, t: 0 };
    this.currentColor = colorId;
    this.state = to;
  }

  snapshotState() {
    const perMaterial = new Map();
    for (const info of this.materials) {
      perMaterial.set(info.mat, {
        color: info.stateColor?.clone() ?? null,
        props: { ...info.stateProps },
        intensity: info.intensity,
      });
    }
    const { from, to, t } = this.transition;
    const k = easeInOut(t);
    return {
      id: 'snapshot',
      perMaterial,
      studioState: k < 0.5 ? from.studioState : to.studioState,
      studioIntensity: this.studioIntensity,
      background: from.background.clone().lerp(to.background, k),
    };
  }

  // ---------------------------------------------------------------------------
  // Views (feature close-ups)
  // ---------------------------------------------------------------------------

  setLayout({ mobile }) {
    if (mobile === this.mobile) return;
    this.mobile = mobile;
    this.resize();
    if (this.orbit && this.viewApplied) this.setView(this.activeView, { fly: false });
  }

  overviewView() {
    return { angle: OVERVIEW.angle, pose: this.mobile ? OVERVIEW.mobilePose : OVERVIEW.pose };
  }

  /**
   * Show a feature view (`{ view, mobileView }` from FEATURE_VIEWS) or the overview (`null`).
   * `fly: false` keeps the current camera angle (used when the user grabs the model).
   */
  setView(feature, { speed = 1.2, fly = true } = {}) {
    if (!this.orbit) return;
    this.activeView = feature;
    this.viewApplied = true;
    const view = feature ? ((this.mobile && feature.mobileView) || feature.view) : this.overviewView();
    if (fly && view.angle) this.orbit.flyTo(view.angle, speed);
    this.applyViewTargets(view, 0.22 / Math.max(0.01, speed));

    const wantsGlow = view.effect === 'powerGlow';
    if (wantsGlow && !this.effect) {
      this.effect = new PowerGlowEffect({
        loader: this.loader,
        root: this.model,
        buttonMaterials: this.materials.filter((m) => m.role === 'button').map((m) => m.mat),
        invalidate: () => {
          this.renderDirty = true;
        },
      });
    } else if (!wantsGlow && this.effect) {
      this.effect.dispose();
      this.effect = null;
    }
    this.renderDirty = true;
  }

  /** Point the lens / pose / lighting springs at a view. `smoothTime == null` jumps. */
  applyViewTargets(view, smoothTime) {
    const resolved = resolveView(
      { position: [0, 0, 0], rotation: [0, 0, 0], scale: MODEL_SCALE, ...view.pose },
      view.lens ?? LENS_DEFAULT,
    );
    const { lens, model } = resolved;
    this.lens.to({
      fovScale: lens.fovScale,
      radius: lens.radius,
      ox: lens.offset[0],
      oy: lens.offset[1],
      oz: lens.offset[2],
    }, smoothTime);
    this.pose.to({ rx: model.rotation[0], ry: model.rotation[1], rz: model.rotation[2] }, smoothTime);

    // Every channel touched so far returns to neutral unless this view sets it.
    const targets = {};
    for (const key of this.lighting.keys()) targets[key] = channelDefault(key);
    for (const [role, settings] of Object.entries(view.lighting ?? {})) {
      const [ex = 0, ey = 0, ez = 0] = settings.envRotation ?? [];
      Object.assign(targets, { [`${role}.env.x`]: ex, [`${role}.env.y`]: ey, [`${role}.env.z`]: ez });
      for (const [k, v] of Object.entries(settings)) if (k !== 'envRotation') targets[`${role}.${k}`] = v;
    }
    for (const [layer, byTarget] of Object.entries(view.rigLighting ?? {})) {
      for (const [target, props] of Object.entries(byTarget)) {
        for (const [prop, v] of Object.entries(props)) targets[`${RIG_PREFIX}${layer}:${target}:${prop}`] = v;
      }
    }
    this.lighting.to(targets, smoothTime);
    if (smoothTime == null) this.applyViewLighting();
  }

  syncLens() {
    const l = this.lens;
    this.lensFov = scaledFov(this.studio.camera.fov, l.get('fovScale', LENS_DEFAULT.fovScale));
    if (Math.abs(this.camera.fov - this.lensFov) > 1e-6) {
      this.camera.fov = this.lensFov;
      this.camera.updateProjectionMatrix();
    }
    this.orbit.setLens(l.get('radius', LENS_DEFAULT.radius), new THREE.Vector3(l.get('ox'), l.get('oy'), l.get('oz')));
    this.root.rotation.set(this.pose.get('rx'), this.pose.get('ry'), this.pose.get('rz'));
  }

  /** Per-role view lighting on top of the colour state: env rotation, intensity, HSL, roughness floor. */
  applyMaterialView() {
    const hsl = { h: 0, s: 0, l: 0 };
    for (const info of this.materials) {
      const { mat, role } = info;
      const ch = (name) => this.lighting.get(`${role}.${name}`, channelDefault(`${role}.${name}`));
      if (info.stateColor && mat.color) {
        mat.color.copy(info.stateColor);
        const sat = ch('colorSaturation');
        const light = ch('colorLightness');
        const hue = ch('colorHue');
        if (sat !== 1 || light !== 1 || hue !== 0) {
          info.stateColor.getHSL(hsl, THREE.SRGBColorSpace);
          mat.color.setHSL(
            THREE.MathUtils.euclideanModulo(hsl.h + hue / 360, 1),
            THREE.MathUtils.clamp(hsl.s * sat, 0, 1),
            THREE.MathUtils.clamp(hsl.l * light, 0, 1),
            THREE.SRGBColorSpace,
          );
        }
      }
      for (const [p, v] of Object.entries(info.stateProps)) mat[p] = v;
      if (typeof mat.roughness === 'number') mat.roughness = Math.max(info.stateProps.roughness ?? mat.roughness, ch('minRoughness'));
      mat.envMapRotation?.set(ch('env.x'), ch('env.y'), ch('env.z'));
      info.viewIntensity = ch('intensity');
    }
    this.lightingDirty = true;
    this.renderDirty = true;
  }

  applyViewLighting() {
    const byLayer = new Map();
    for (const key of this.lighting.keys()) {
      if (!key.startsWith(RIG_PREFIX)) continue;
      const [layer, target, prop] = key.slice(RIG_PREFIX.length).split(':');
      const map = byLayer.get(Number(layer)) ?? {};
      (map[target] ??= {})[prop] = this.lighting.get(key);
      byLayer.set(Number(layer), map);
    }
    for (const rig of this.rigs) rig.setViewScale(byLayer.get(rig.layer) ?? {});
    this.applyMaterialView();
  }

  // ---------------------------------------------------------------------------
  // Camera helpers
  // ---------------------------------------------------------------------------

  flyTo(label, speed = 1) {
    return this.orbit?.flyTo(label, speed);
  }

  setAutoRotate(on) {
    if (!this.orbit) return;
    this.orbit.autoRotate = on;
    this.orbit.idleSince = performance.now() - 3000;
    this.renderDirty = true;
  }

  setSnap(on) {
    if (!this.orbit) return;
    this.orbit.snap = on;
    if (on) this.orbit.snapToNearest(this.orbit.theta, this.orbit.phi);
    this.renderDirty = true;
  }

  // ---------------------------------------------------------------------------
  // Frame
  // ---------------------------------------------------------------------------

  updateLighting() {
    const samples = this.orbit.weights;
    for (const rig of this.rigs) {
      rig.pose(samples, this.studioFrom, this.studioTo, this.studioMix);
      rig.bake();
    }
    for (const info of this.materials) {
      const rig = this.rigByLayer.get(info.layer) ?? this.rigs[0];
      if (!rig?.envMap) continue;
      if (info.mat.envMap !== rig.envMap) {
        info.mat.envMap = rig.envMap;
        info.mat.needsUpdate = true;
      }
      info.mat.envMapIntensity = rig.envMapIntensity * info.intensity * this.studioIntensity * info.viewIntensity;
    }
    this.lightingDirty = false;
  }

  loop(now) {
    if (this.disposed) return;
    const dt = Math.min(0.1, Math.max(0, (now - this.lastTime) / 1000));
    this.lastTime = now;

    const lensChanged = this.lens.step(dt).size > 0;
    const poseChanged = this.pose.step(dt).size > 0;
    if (lensChanged || poseChanged) {
      this.syncLens();
      this.renderDirty = true;
    }
    if (this.lighting.step(dt).size > 0) this.applyViewLighting();

    if (this.orbit.update(dt)) {
      this.lightingDirty = true;
      this.renderDirty = true;
    }
    if (this.transition) {
      const tr = this.transition;
      tr.t = Math.min(1, tr.t + dt / COLOR_TRANSITION_SECONDS);
      this.applyColorState(tr.from, tr.to, easeInOut(tr.t));
      if (tr.t >= 1) this.transition = null;
    }
    if (this.effect?.update(dt)) this.renderDirty = true;

    if (this.renderDirty) this.lightingDirty = true;
    if (this.lightingDirty) this.updateLighting();
    if (this.renderDirty) {
      this.render();
      this.renderDirty = false;
    }

    const angle = this.orbit.dominantLabel;
    if (angle && angle !== this.lastAngle) {
      this.lastAngle = angle;
      this.onAngleChange(angle);
    }
    this.frame = requestAnimationFrame(this.loop);
  }

  render() {
    this.renderer.setRenderTarget(null);
    this.renderer.render(this.scene, this.camera);
    this.effect?.afterRender(this.renderer, this.scene, this.camera);
  }

  // ---------------------------------------------------------------------------
  // Layout
  // ---------------------------------------------------------------------------

  /** Screen-space UI covering the canvas (px); the product is framed in the space between. */
  setInsets(insets) {
    this.insets = { top: 0, right: 0, bottom: 0, left: 0, ...insets };
    if (this.camera) this.resize();
  }

  resize() {
    if (!this.camera) return;
    const { width, height } = this.container.getBoundingClientRect();
    if (!width || !height) return;
    this.renderer.setSize(width, height, false);
    this.camera.aspect = width / height;

    // Fit the overview framing into the free area between overlays, and centre it there.
    // Feature views keep their relative zoom/offset on top of this.
    const { top, right, bottom, left } = this.insets;
    const availH = Math.max(height * 0.35, height - top - bottom);
    const availW = Math.max(width * 0.35, width - left - right);
    const overview = this.overviewView();
    const ref = resolveView({ scale: overview.pose.scale }, LENS_DEFAULT).lens;
    const refFov = scaledFov(this.studio.camera.fov, LENS_DEFAULT.fovScale);
    const visible = 2 * ref.radius * Math.tan(THREE.MathUtils.degToRad(refFov) / 2);
    const productPx = ((PRODUCT.targetHeight * MODEL_SCALE) / visible) * 1.02 * height;
    // The overview fills ~60% of the free height, like the site's stage, so feature close-ups
    // (authored relative to it) crop the same way.
    const zoomH = (0.62 * availH) / productPx;
    const zoomW = (0.8 * availW) / (0.62 * productPx);
    this.camera.zoom = THREE.MathUtils.clamp(Math.min(zoomH, zoomW), 0.35, 1.6);

    const shiftX = (left - right) / 2;
    const shiftY = (bottom - top) / 2;
    if (Math.abs(shiftX) > 0.5 || Math.abs(shiftY) > 0.5) {
      this.camera.setViewOffset(width, height, -shiftX, shiftY, width, height);
    } else {
      this.camera.clearViewOffset();
    }
    this.camera.updateProjectionMatrix();
    this.renderDirty = true;
    if (this.orbit) {
      this.updateLighting();
      this.render();
    }
  }

  /** Current frame as a transparent PNG data URL. */
  screenshot() {
    this.render();
    return this.renderer.domElement.toDataURL('image/png');
  }

  dispose() {
    this.disposed = true;
    cancelAnimationFrame(this.frame);
    this.resizeObserver?.disconnect();
    this.orbit?.dispose();
    this.effect?.dispose();
    for (const rig of this.rigs) rig.dispose();
    this.pmrem?.dispose();
    this.renderer?.dispose();
    this.renderer?.domElement.remove();
  }
}
