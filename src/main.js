import { ProductViewer } from './viewer.js';
import {
  PRODUCT, SWATCHES, VIEWS, COPY, FEATURES, FEATURE_VIEWS,
} from './product.js';

const $ = (id) => document.getElementById(id);
const stage = $('stage');
const viewport = $('viewport');
const MOBILE_QUERY = window.matchMedia('(max-width: 860px)');

const params = new URLSearchParams(location.search);
const initialColor = SWATCHES.some((s) => s.id === params.get('color')) ? params.get('color') : PRODUCT.defaultColor;
const initialFeature = FEATURES.some((f) => f.id === params.get('feature')) ? params.get('feature') : null;
if (params.get('bg') === 'dark') stage.dataset.theme = 'dark';

let activeFeature = null;
let activeColor = initialColor;

// ---------- copy ----------

$('copy-eyebrow').textContent = COPY.eyebrow;
$('copy-title').textContent = COPY.title; // contains a \n; CSS keeps the line break
$('copy-desc').textContent = COPY.description;
$('copy-closer').textContent = COPY.closerLook;

// ---------- swatches (desktop: inside the colour item; mobile: in the sheet) ----------

const swatchGroups = [];
function buildSwatches(container) {
  const buttons = new Map();
  for (const s of SWATCHES) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'swatch';
    btn.setAttribute('role', 'radio');
    btn.setAttribute('aria-label', `${s.zh} ${s.label}`);
    btn.title = `${s.zh} · ${s.label}`;
    btn.style.setProperty('--fill', s.fill);
    btn.style.setProperty('--stroke', s.stroke);
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      selectColor(s.id);
    });
    container.append(btn);
    buttons.set(s.id, btn);
  }
  swatchGroups.push(buttons);
}

// ---------- feature list ----------

const featureItems = new Map();
for (const f of FEATURES) {
  const li = document.createElement('li');
  li.className = 'feature';
  li.dataset.id = f.id;

  const head = document.createElement('button');
  head.type = 'button';
  head.className = 'feature-head';
  head.setAttribute('aria-expanded', 'false');
  head.innerHTML = '<span class="feature-mark" aria-hidden="true"></span><span class="feature-label"></span>';
  head.querySelector('.feature-label').textContent = f.label;
  head.addEventListener('click', () => selectFeature(activeFeature === f.id ? null : f.id));
  li.append(head);

  if (f.swatches) {
    const group = document.createElement('div');
    group.className = 'swatches';
    group.setAttribute('role', 'radiogroup');
    group.setAttribute('aria-label', '配色');
    buildSwatches(group);
    li.append(group);
  }

  const body = document.createElement('div');
  body.className = 'feature-body';
  const inner = document.createElement('div');
  inner.className = 'feature-body-inner';
  const p = document.createElement('p');
  p.textContent = f.description;
  inner.append(p);
  if (f.swatches) {
    const name = document.createElement('p');
    name.className = 'color-name';
    inner.append(name);
  }
  body.append(inner);
  li.append(body);

  $('features').append(li);
  featureItems.set(f.id, li);
}
buildSwatches($('sheet-swatches'));

// ---------- free-view chips ----------

const viewButtons = new Map();
for (const v of VIEWS) {
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'view-chip';
  btn.textContent = v.label;
  btn.addEventListener('click', () => freeFly(v.id));
  $('views').append(btn);
  viewButtons.set(v.id, btn);
}

// ---------- state rendering ----------

function renderColor() {
  const s = SWATCHES.find((x) => x.id === activeColor);
  for (const group of swatchGroups) {
    for (const [key, btn] of group) btn.setAttribute('aria-checked', String(key === activeColor));
  }
  for (const el of document.querySelectorAll('.color-name')) el.textContent = `${s.zh} · ${s.label}`;
}

function renderFeature() {
  for (const [id, li] of featureItems) {
    const on = id === activeFeature;
    li.classList.toggle('is-active', on);
    li.querySelector('.feature-head').setAttribute('aria-expanded', String(on));
  }
  if (activeFeature && MOBILE_QUERY.matches) {
    featureItems.get(activeFeature).scrollIntoView({ inline: 'center', block: 'nearest', behavior: 'smooth' });
  }
  const f = FEATURES.find((x) => x.id === activeFeature);
  $('feature-caption').textContent = f ? f.description : COPY.description;
  stage.dataset.feature = activeFeature ?? '';
}

function renderAngle(label) {
  for (const [key, btn] of viewButtons) btn.classList.toggle('is-active', !activeFeature && key === label);
}

function syncUrl() {
  const url = new URL(location.href);
  url.searchParams.set('color', activeColor);
  if (activeFeature) url.searchParams.set('feature', activeFeature);
  else url.searchParams.delete('feature');
  history.replaceState(null, '', url);
}

// ---------- actions ----------

const viewer = new ProductViewer(viewport, {
  onAngleChange: renderAngle,
  // Grabbing the model leaves the close-up and returns to the overview pose (as on the site).
  onGrab: () => {
    hideHint();
    if (activeFeature) selectFeature(null, { fly: false });
  },
});

function selectColor(id) {
  activeColor = id;
  renderColor();
  viewer.setColor(id);
  syncUrl();
}

function selectFeature(id, { fly = true } = {}) {
  activeFeature = id;
  renderFeature();
  renderAngle(viewer.orbit?.dominantLabel);
  viewer.setView(id ? FEATURE_VIEWS[id] : null, { fly });
  syncUrl();
  hideHint();
}

function freeFly(label) {
  if (activeFeature) selectFeature(null, { fly: false });
  viewer.flyTo(label);
  hideHint();
}

let hintTimer = 0;
function hideHint() {
  clearTimeout(hintTimer);
  $('hint').classList.add('is-hidden');
}

renderColor();
renderFeature();

$('opt-snap').addEventListener('change', (e) => viewer.setSnap(e.target.checked));
$('opt-spin').addEventListener('change', (e) => {
  if (e.target.checked && activeFeature) selectFeature(null, { fly: false });
  viewer.setAutoRotate(e.target.checked);
});

$('btn-theme').addEventListener('click', () => {
  stage.dataset.theme = stage.dataset.theme === 'dark' ? 'light' : 'dark';
});

$('btn-shot').addEventListener('click', () => {
  const a = document.createElement('a');
  a.href = viewer.screenshot();
  a.download = `onekey-pro-2-${activeColor.toLowerCase()}${activeFeature ? `-${activeFeature}` : ''}.png`;
  a.click();
});

$('btn-full').addEventListener('click', () => {
  if (document.fullscreenElement) document.exitFullscreen();
  else stage.requestFullscreen?.();
});

// Arrow keys orbit, number keys pick a colour, F / Shift+F step through features, Esc = overview.
const RING = ['back', 'backRight', 'right', 'frontRight', 'front', 'frontLeft', 'left', 'backLeft'];
window.addEventListener('keydown', (e) => {
  if (e.target instanceof HTMLInputElement || e.metaKey || e.ctrlKey || e.altKey) return;
  const current = viewer.orbit?.dominantLabel;
  if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
    const i = Math.max(0, RING.indexOf(current));
    freeFly(RING[(i + (e.key === 'ArrowRight' ? -1 : 1) + RING.length) % RING.length]);
  } else if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
    const side = current?.startsWith('back') ? 'back' : 'front';
    const leaving = e.key === 'ArrowUp' ? 'Bottom' : 'Top';
    const toward = e.key === 'ArrowUp' ? 'Top' : 'Bottom';
    freeFly(current?.endsWith(leaving) ? side : `${side}${toward}`);
  } else if (/^[1-3]$/.test(e.key)) {
    selectColor(SWATCHES[Number(e.key) - 1].id);
  } else if (e.key === 'f' || e.key === 'F') {
    const i = FEATURES.findIndex((f) => f.id === activeFeature);
    const step = e.shiftKey ? -1 : 1;
    const next = i < 0 ? (step > 0 ? 0 : FEATURES.length - 1) : (i + step + FEATURES.length) % FEATURES.length;
    selectFeature(FEATURES[next].id);
  } else if (e.key === 'Escape' && activeFeature) {
    selectFeature(null);
  }
});

// ---------- layout ----------

/** Frame the product in the area not covered by the story panel / dock / top bar. */
function syncLayout() {
  const mobile = MOBILE_QUERY.matches;
  viewer.setLayout({ mobile });
  const stageRect = stage.getBoundingClientRect();
  const top = document.querySelector('.topbar').getBoundingClientRect().bottom - stageRect.top + 8;
  const story = $('story');
  if (mobile) {
    // Bottom sheet: measure its resting position (offsetTop ignores the entrance transform).
    viewer.setInsets({ top, bottom: stageRect.height - story.offsetTop + 8, left: 0, right: 0 });
  } else {
    const dock = document.querySelector('.dock');
    viewer.setInsets({
      top,
      bottom: stageRect.height - dock.offsetTop + 12,
      left: story.offsetLeft + story.offsetWidth + 16,
      right: 24,
    });
  }
}

const loader = $('loader');
viewer
  .load({
    color: initialColor,
    onProgress: (p, msg) => {
      $('loader-pct').textContent = Math.round(p * 100);
      $('loader-bar').style.transform = `scaleX(${p})`;
      if (msg) $('loader-msg').textContent = msg;
    },
  })
  .then(() => {
    syncLayout();
    new ResizeObserver(syncLayout).observe($('story'));
    new ResizeObserver(syncLayout).observe(document.querySelector('.dock'));
    window.addEventListener('resize', syncLayout);
    MOBILE_QUERY.addEventListener('change', syncLayout);
    stage.classList.add('is-ready');
    // Intro: the model starts small from the back, then glides to the overview (or deep link).
    setTimeout(() => {
      if (initialFeature) selectFeature(initialFeature);
      else viewer.setView(null, { speed: 0.55 });
    }, 400);
    hintTimer = setTimeout(hideHint, 7000);
  })
  .catch((err) => {
    console.error(err);
    loader.classList.add('is-error');
    $('loader-msg').textContent = location.protocol === 'file:'
      ? '请通过本地 HTTP 服务打开（例如 python3 -m http.server），浏览器不允许 file:// 加载模块和模型。'
      : `加载失败：${err.message}`;
  });

// Expose for console tinkering.
window.viewer = viewer;
