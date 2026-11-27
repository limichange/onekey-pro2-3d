// Product definition for the OneKey Pro 2 model, mirroring the config used on the product page.

export const ASSETS_BASE = new URL('../assets/', import.meta.url).href;

/**
 * Environment layers:
 *   0 = body rig  (back cover, logo, misc)
 *   1 = port rig  (USB-C)
 *   2 = frame rig (mirror frame, button, glass, camera)
 */
const ROLE_RULES = [
  { match: /屏幕(?!黑边)/, layer: 2, intensity: 0.16, role: 'screen' },
  { match: /黑边/, layer: 2, intensity: 0.48, role: 'bezel' },
  { match: /镜头|cam|绝对黑/i, layer: 2, intensity: 1.35, role: 'camera' },
  { match: /中框/, layer: 2, intensity: 1, role: 'frame' },
  { match: /电源键/, layer: 2, intensity: 1, role: 'button' },
  { match: /USB/, layer: 1, intensity: 0.78, role: 'port' },
  { match: /logo/i, layer: 0, intensity: 0.72, role: 'logo' },
  { match: /背盖/i, layer: 0, intensity: 0.68, role: 'body' },
];

export const PRODUCT = {
  modelUrl: `${ASSETS_BASE}model/black.glb`,
  colorsUrl: `${ASSETS_BASE}model/colors.json`,
  studioUrl: `${ASSETS_BASE}studio/studio.json`,
  targetHeight: 15.45,
  rotationY: Math.PI,
  defaultColor: 'Orange',

  /** Per-role material overrides applied on top of the GLB values. */
  roleTuning: {
    logo: { roughness: 0.325 },
  },

  classifyMaterial(material) {
    if ((material.transmission ?? 0) > 0) {
      return { layer: 2, intensity: 1.35, role: 'lens' };
    }
    if (/^材质\./.test(material.name ?? '') && (material.metalness ?? 0) > 0.5) {
      return { layer: 0, intensity: 0.5, role: 'back-overlay' };
    }
    return ROLE_RULES.find((rule) => rule.match.test(material.name ?? ''))
      ?? { layer: 0, intensity: 0.9, role: 'other' };
  },

  tuneMaterial(material, role) {
    if (role === 'screen') {
      if (material.emissiveMap) material.emissiveMap.anisotropy = 8;
      material.toneMapped = false;
      material.emissiveIntensity = 0.92;
    } else if (role === 'body' || role === 'back-overlay' || role === 'logo') {
      if ('sheen' in material) material.sheen = 0;
      material.sheenColor?.setRGB(0.02, 0.022, 0.028);
      if ('sheenRoughness' in material) material.sheenRoughness = 0.45;
    }
  },
};

export const SWATCHES = [
  { id: 'Orange', label: 'Horizon Orange', zh: '初日橘', fill: '#F7931A', stroke: '#CD7000' },
  { id: 'Silver', label: 'Glacier Silver', zh: '冰川银', fill: '#FFFFFF', stroke: 'rgba(0,0,0,0.16)' },
  { id: 'Black', label: 'Graphite Black', zh: '墨岩黑', fill: '#111111', stroke: 'rgba(255,255,255,0.5)' },
];

export const VIEWS = [
  { id: 'frontLeft', label: '左前' },
  { id: 'front', label: '正面' },
  { id: 'frontRight', label: '右前' },
  { id: 'right', label: '右侧' },
  { id: 'back', label: '背面' },
  { id: 'left', label: '左侧' },
  { id: 'frontTop', label: '顶部' },
  { id: 'frontBottom', label: '底部' },
];

// ---------------------------------------------------------------------------
// Copy + per-feature camera views, taken from the product page's design section.
// ---------------------------------------------------------------------------

export const COPY = {
  eyebrow: '设计',
  title: '每一处细节，\n成就一身质感。',
  description: 'Pro 2 从颜色、材质到握持曲线，围绕日常使用精心设计。远看简洁，近看讲究。',
  closerLook: '定睛细看',
};

export const FEATURES = [
  { id: 'color', label: '颜色', description: '三款配色，款款出色。', swatches: true },
  { id: 'frame', label: '光面铝合金中框', description: '轻盈好拿，坚固耐用，光泽随光线自然流动。' },
  { id: 'back-cover', label: '磨砂玻璃后盖', description: '细腻雾面，触感温润，握持更舒服。' },
  { id: 'gorilla-glass', label: '康宁® Gorilla® Glass 5', description: '耐磨防刮，让屏幕保持清晰通透。' },
  { id: 'fingerprint', label: '二合一指纹电源', description: '按下唤醒，指纹解锁，一气呵成。' },
  { id: 'g3-curve', label: 'G3 混接曲线', description: '曲线自然衔接，视觉连贯，握持贴手。' },
];

/** Root scale of the product group; view poses are expressed relative to it. */
export const MODEL_SCALE = 1.4;

/** Default studio lens on the page: a long lens far away (little perspective distortion). */
export const LENS_DEFAULT = { fovScale: 0.6, radius: 70 };

const S = MODEL_SCALE;

export const OVERVIEW = {
  angle: 'frontLeft',
  pose: { scale: 0.75 * S },
  mobilePose: { scale: 0.88 * S },
};

/** Pose shown while loading; the camera then glides to the overview. */
export const INTRO = { angle: 'back', pose: { scale: 0.6 * S } };

export const FEATURE_VIEWS = {
  color: {
    view: { angle: 'backLeft', pose: { scale: 1.61 * S, position: [1.1, -8.3, 1.1] } },
    mobileView: { angle: 'backLeft', pose: { scale: 1.25 * S, position: [0.32, -5, 0.32] } },
  },
  frame: {
    view: { angle: 'left', pose: { scale: 0.97 * S, rotation: [0, -0.007, 0] } },
  },
  'back-cover': {
    view: { angle: 'backLeft', pose: { scale: 0.92 * S, rotation: [0.007, -0.091, 0.006], position: [0.4, 0, 0.4] } },
  },
  'gorilla-glass': {
    view: { angle: 'frontLeft', pose: { scale: 0.96 * S, rotation: [0.032, -0.169, -0.039] } },
  },
  fingerprint: {
    view: {
      angle: 'left',
      pose: { scale: 2.04 * S, rotation: [0.049, 0.272, -0.177], position: [-2.1, -12.3, -1.7] },
      effect: 'powerGlow',
    },
    mobileView: {
      angle: 'left',
      pose: { scale: 1.85 * S, rotation: [0.049, 0.272, -0.177], position: [-2.1, -12.6, -1.7] },
      effect: 'powerGlow',
    },
  },
  'g3-curve': {
    view: {
      angle: 'backLeft',
      lens: { fovScale: 0.388, radius: 108 },
      lighting: {
        body: { envRotation: [0.4, 0.4, 0], intensity: 0.95, colorHue: 8, colorLightness: 0.92 },
        logo: { colorHue: 8 },
        camera: { envRotation: [-0.6, 1, 0], intensity: 1.5 },
        lens: { envRotation: [-0.6, 1, 0], intensity: 0.065, minRoughness: 0.12 },
        frame: {
          envRotation: [-0.8, -0.4, 0], minRoughness: 0.28, colorSaturation: 0.86, colorLightness: 0.95,
          colorHue: 7, shadowSaturation: 0.73, reflectionSmoothing: 0.35,
        },
        button: { envRotation: [-0.8, -0.4, 0], colorHue: 7 },
      },
      rigLighting: { 2: { 'softbox-09-panel-mat': { emissiveIntensity: 0.97 }, 'softbox-14-panel-mat': { emissiveIntensity: 0 } } },
      pose: { scale: 3.05 * S, rotation: [0.381, 0.164, 0.419], position: [7.6, -15.6, 7.6] },
    },
  },
};

/**
 * Turn a view pose into a model transform + camera lens. The model stays at the origin; zoom and
 * translation are expressed by moving the camera (radius / framing offset), as on the site.
 */
export function resolveView(pose = {}, lens = LENS_DEFAULT) {
  const r = (pose.scale ?? S) / S;
  const position = pose.position ?? [0, 0, 0];
  return {
    model: { rotation: pose.rotation ?? [0, 0, 0], scale: S },
    lens: {
      fovScale: lens.fovScale,
      radius: lens.radius / r,
      offset: position.map((p, i) => ((lens.offset?.[i] ?? 0) - p) / r),
    },
  };
}

export const POWER_GLOW = {
  url: `${ASSETS_BASE}model/effects/button-glow-stroke.glb`,
  breatheSpeed: 2.4,
  fadeInSeconds: 0.8,
  breatheFloor: 0.35,
  strokeIntensity: 1.5,
  buttonIntensity: 0.25,
  bloomStrength: 0.8,
  bloomRadius: 0.32,
  glowStrength: 0.65,
  glowColor: '#e9f6ff',
};
