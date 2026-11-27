import * as THREE from 'three';

const TWO_PI = Math.PI * 2;
const VECTOR_PROP = /^(position|rotation|scale|color|emissive)([XYZRGB])$/;

/** Wrap an angle difference into [-PI, PI). */
function wrapAngle(x) {
  return ((((x + Math.PI) % TWO_PI) + TWO_PI) % TWO_PI) - Math.PI;
}

function getProp(el, prop) {
  const m = VECTOR_PROP.exec(prop);
  if (m) return el[m[1]]?.[m[2].toLowerCase()];
  return el[prop];
}

function setProp(el, prop, value) {
  const m = VECTOR_PROP.exec(prop);
  if (m) {
    const vec = el[m[1]];
    if (vec) vec[m[2].toLowerCase()] = value;
    return;
  }
  if (prop in el) el[prop] = value;
}

/**
 * One light rig ("layer") of the product studio: a set of emissive softbox panels that is
 * re-posed per camera angle and baked into a PMREM environment map used by the product
 * materials assigned to this layer.
 */
export class StudioRig {
  constructor(renderer, pmrem, def, rigScene, { cubeSize = 256 } = {}) {
    this.renderer = renderer;
    this.layer = def.layer;
    this.envMapIntensity = def.envMapIntensity ?? 1;

    this.scene = new THREE.Scene();
    this.scene.background = new THREE.Color(0x000000);
    this.scene.add(rigScene);

    // Dim fill behind the softboxes so mirror metal never reflects pure black.
    this.fill = new THREE.Mesh(
      new THREE.BoxGeometry(1000, 1000, 1000),
      new THREE.MeshBasicMaterial({ side: THREE.BackSide, depthWrite: false, color: 0x000000 }),
    );
    this.fill.visible = false;
    this.scene.add(this.fill);

    this.targets = new Map();
    rigScene.traverse((obj) => {
      if (obj.name && !this.targets.has(obj.name)) this.targets.set(obj.name, obj);
    });
    rigScene.traverse((obj) => {
      const mats = Array.isArray(obj.material) ? obj.material : obj.material ? [obj.material] : [];
      for (const mat of mats) if (mat.name && !this.targets.has(mat.name)) this.targets.set(mat.name, mat);
    });

    for (const [name, props] of Object.entries(def.constants ?? {})) {
      const el = this.targets.get(name);
      if (el) for (const [prop, value] of Object.entries(props)) setProp(el, prop, value);
    }

    this.channels = [];
    for (const [name, props] of Object.entries(def.channels ?? {})) {
      const el = this.targets.get(name);
      if (!el) continue;
      for (const [prop, values] of Object.entries(props)) {
        this.channels.push({
          el,
          prop,
          values,
          base: getProp(el, prop) ?? 0,
          isRotation: prop.startsWith('rotation'),
          unwrapped: new Map(),
          last: 0,
        });
      }
    }
    this.channelByKey = new Map(this.channels.map((ch) => [`${ch.el.uuid}:${ch.prop}`, ch]));
    /** Per-view multipliers, e.g. { 'softbox-09-panel-mat': { emissiveIntensity: 0.97 } }. */
    this.viewScale = {};
    this.unscaled = new Map(); // original values of non-animated props we scale

    this.cubeTarget = new THREE.WebGLCubeRenderTarget(cubeSize, { type: THREE.HalfFloatType });
    this.cubeCamera = new THREE.CubeCamera(3, 2000, this.cubeTarget);
    this.scene.add(this.cubeCamera);
    this.pmrem = pmrem; // shared across rigs (PMREMGenerator keeps static state)
    this.envTarget = null;
  }

  get envMap() {
    return this.envTarget?.texture ?? null;
  }

  setBackground(color) {
    if (color == null) {
      this.fill.visible = false;
      return;
    }
    this.fill.visible = true;
    this.fill.material.color.copy(color);
  }

  channelValue(ch, studio, label) {
    const v = ch.values;
    return v[`${studio}+${label}`] ?? v[label] ?? v[studio] ?? ch.base;
  }

  /**
   * Pose the softboxes for the weighted camera-angle samples, optionally blending between
   * two studio states (e.g. glossy -> glossy-dark) by `studioMix`.
   */
  pose(samples, studioFrom, studioTo = studioFrom, studioMix = 1) {
    for (const ch of this.channels) {
      const sampleValue = (label) => {
        const b = this.channelValue(ch, studioTo, label);
        if (studioMix >= 1 || studioFrom === studioTo) return b;
        const a = this.channelValue(ch, studioFrom, label);
        return a + (ch.isRotation ? wrapAngle(b - a) : b - a) * studioMix;
      };

      let value = 0;
      if (!ch.isRotation) {
        for (const s of samples) value += sampleValue(s.label) * s.weight;
      } else {
        // Unwrap each sample relative to its previous value (or the last applied value when it
        // first becomes active) so the blend never spins the long way round.
        const active = new Set();
        for (const s of samples) {
          if (Math.abs(s.weight) <= 1e-4) continue;
          active.add(s.label);
          const prev = ch.unwrapped.get(s.label) ?? ch.last;
          ch.unwrapped.set(s.label, prev - wrapAngle(prev - sampleValue(s.label)));
        }
        for (const key of [...ch.unwrapped.keys()]) if (!active.has(key)) ch.unwrapped.delete(key);
        // Keep the cache bounded around (-PI, PI].
        const first = ch.unwrapped.values().next();
        if (!first.done && Math.abs(first.value) > Math.PI) {
          const shift = first.value > Math.PI ? -TWO_PI : TWO_PI;
          for (const [k, v] of ch.unwrapped) ch.unwrapped.set(k, v + shift);
        }
        for (const s of samples) {
          const v = ch.unwrapped.get(s.label);
          if (v !== undefined) value += v * s.weight;
        }
        ch.last = value;
      }
      setProp(ch.el, ch.prop, value);
    }
    this.applyViewScale();
  }

  setViewScale(scale) {
    this.viewScale = scale ?? {};
  }

  /** Multiply selected properties on top of the posed (or original) values. */
  applyViewScale() {
    for (const [name, props] of Object.entries(this.viewScale)) {
      const el = this.targets.get(name);
      if (!el) continue;
      for (const [prop, factor] of Object.entries(props)) {
        const key = `${el.uuid}:${prop}`;
        let base;
        if (this.channelByKey.has(key)) {
          base = getProp(el, prop); // freshly written by pose()
        } else {
          if (!this.unscaled.has(key)) this.unscaled.set(key, getProp(el, prop) ?? 0);
          base = this.unscaled.get(key);
        }
        setProp(el, prop, base * factor);
      }
    }
  }

  /** Clear cached rotation unwrapping (needed when the studio state changes abruptly). */
  resetRotationCache() {
    for (const ch of this.channels) ch.unwrapped.clear();
  }

  bake() {
    this.scene.updateMatrixWorld(true);
    this.cubeCamera.update(this.renderer, this.scene);
    const target = this.pmrem.fromCubemap(this.cubeTarget.texture, this.envTarget);
    this.envTarget = target;
    return target.texture;
  }

  dispose() {
    this.cubeTarget.dispose();
    this.envTarget?.dispose();
    this.fill.geometry.dispose();
    this.fill.material.dispose();
  }
}
