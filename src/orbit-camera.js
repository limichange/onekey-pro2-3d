import * as THREE from 'three';

const TWO_PI = Math.PI * 2;
const PHI_MIN = 1e-4;
const PHI_MAX = Math.PI - 1e-4;
const MIN_ZOOM = 0.55;
const MAX_ZOOM = 1.6;

/** Frame-rate independent exponential approach (factor is "per 60fps frame"). */
function damp(current, target, factor, dt) {
  return current + (target - current) * (1 - Math.pow(1 - Math.min(factor, 0.999), dt * 60));
}

/** Signed shortest difference from `from` to `to`, in [-PI, PI). */
function wrapDelta(to, from) {
  const d = to - from;
  return ((((d + Math.PI) % TWO_PI) + TWO_PI) % TWO_PI) - Math.PI;
}

/**
 * Spherical orbit camera modelled after the product page's interactive camera:
 * drag to orbit, flick to throw, then (optionally) settle onto the nearest curated angle.
 * The lens (radius + framing offset) is driven from outside; the user zoom multiplies the radius.
 * It also reports lighting weights for the labelled camera angles.
 */
export class OrbitCamera {
  constructor(camera, surface, studio, { onChange, onGrab } = {}) {
    this.camera = camera;
    this.surface = surface;
    this.onChange = onChange ?? (() => {});
    this.onGrab = onGrab ?? (() => {});

    this.lightRadius = studio.camera.radius;
    this.radius = studio.camera.radius;
    this.framingOffset = new THREE.Vector3();
    this.zoom = 1;
    this.zoomTarget = 1;

    this.angles = studio.angles;
    const seen = new Set();
    this.lightAngles = studio.angles
      .filter((a) => a.label && !seen.has(a.label) && seen.add(a.label))
      .map((a) => ({
        label: a.label,
        threshold: a.threshold,
        vector: new THREE.Vector3().setFromSphericalCoords(this.lightRadius, a.phi, a.theta),
      }));

    this.phi = studio.start.phi;
    this.theta = studio.start.theta;
    this.phiTarget = this.phi;
    this.thetaTarget = this.theta;

    this.enabled = true;
    this.snap = true;
    this.autoRotate = false;
    this.autoRotateSpeed = 0.35; // rad/s
    this.lerpDrag = 0.2;
    this.lerpSnap = 0.095;
    this.snapFactor = this.lerpSnap;
    this.dragging = false;
    this.settling = false;
    this.velocity = new THREE.Vector2();
    this.lastPointer = new THREE.Vector2();
    this.lastMoveTime = 0;
    this.idleSince = performance.now();
    this.pointers = new Map();
    this.pinchStart = 0;
    this.pinchZoom = 1;
    this.lensDirty = true;

    this.tmp = new THREE.Vector3();
    this.weights = [];

    this.bind();
    this.apply();
    this.computeWeights();
  }

  bind() {
    const s = this.surface;
    s.style.touchAction = 'none';
    s.addEventListener('pointerdown', this.handleDown);
    window.addEventListener('pointermove', this.handleMove);
    window.addEventListener('pointerup', this.handleUp);
    window.addEventListener('pointercancel', this.handleUp);
    s.addEventListener('wheel', this.handleWheel, { passive: false });
    s.addEventListener('dblclick', this.handleDoubleClick);
  }

  dispose() {
    const s = this.surface;
    s.removeEventListener('pointerdown', this.handleDown);
    window.removeEventListener('pointermove', this.handleMove);
    window.removeEventListener('pointerup', this.handleUp);
    window.removeEventListener('pointercancel', this.handleUp);
    s.removeEventListener('wheel', this.handleWheel);
    s.removeEventListener('dblclick', this.handleDoubleClick);
  }

  handleDown = (e) => {
    if (!this.enabled) return;
    this.pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (this.pointers.size === 2) {
      this.pinchStart = this.pinchDistance();
      this.pinchZoom = this.zoomTarget;
      return;
    }
    this.surface.setPointerCapture?.(e.pointerId);
    this.dragging = true;
    this.settling = false;
    this.velocity.set(0, 0);
    this.lastPointer.set(e.clientX, e.clientY);
    this.lastMoveTime = performance.now();
    // Continue from where the camera currently is, not where it was heading.
    this.thetaTarget = this.theta;
    this.phiTarget = this.phi;
    this.surface.classList.add('is-grabbing');
    this.onGrab();
  };

  handleMove = (e) => {
    if (!this.pointers.has(e.pointerId)) return;
    this.pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (this.pointers.size === 2 && this.pinchStart > 0) {
      const scale = this.pinchStart / Math.max(1, this.pinchDistance());
      this.zoomTarget = THREE.MathUtils.clamp(this.pinchZoom * scale, MIN_ZOOM, MAX_ZOOM);
      this.onChange();
      return;
    }
    if (!this.dragging) return;
    const now = performance.now();
    const dx = e.clientX - this.lastPointer.x;
    const dy = e.clientY - this.lastPointer.y;
    this.lastPointer.set(e.clientX, e.clientY);
    const rect = this.surface.getBoundingClientRect();
    const size = Math.max(320, Math.min(rect.width, rect.height * 1.4));
    const dTheta = (-dx / size) * Math.PI * 1.25;
    const dPhi = (-dy / size) * Math.PI * 1.1;
    this.thetaTarget += dTheta;
    this.phiTarget = THREE.MathUtils.clamp(this.phiTarget + dPhi, PHI_MIN, PHI_MAX);
    const dt = Math.max(1, now - this.lastMoveTime) / 1000;
    this.velocity.set(
      THREE.MathUtils.lerp(this.velocity.x, dTheta / dt, 0.5),
      THREE.MathUtils.lerp(this.velocity.y, dPhi / dt, 0.5),
    );
    this.lastMoveTime = now;
    this.idleSince = now;
    this.onChange();
  };

  handleUp = (e) => {
    this.pointers.delete(e.pointerId);
    if (this.pointers.size < 2) this.pinchStart = 0;
    if (this.pointers.size === 1) {
      // Pinch ended with one finger still down: continue dragging from that finger.
      const [rest] = this.pointers.values();
      this.lastPointer.set(rest.x, rest.y);
      this.velocity.set(0, 0);
      return;
    }
    if (!this.dragging || this.pointers.size > 0) return;
    this.dragging = false;
    this.surface.classList.remove('is-grabbing');
    // Flick: carry recent velocity forward; stale velocity (paused before release) is dropped.
    if (performance.now() - this.lastMoveTime < 80) {
      this.thetaTarget += THREE.MathUtils.clamp(this.velocity.x * 0.18, -Math.PI, Math.PI);
      this.phiTarget = THREE.MathUtils.clamp(this.phiTarget + this.velocity.y * 0.12, PHI_MIN, PHI_MAX);
    }
    this.idleSince = performance.now();
    if (this.snap) this.snapToNearest(this.thetaTarget, this.phiTarget);
    this.onChange();
  };

  handleWheel = (e) => {
    if (!this.enabled) return;
    e.preventDefault();
    const factor = Math.exp(e.deltaY * (e.ctrlKey ? 0.01 : 0.0012));
    this.zoomTarget = THREE.MathUtils.clamp(this.zoomTarget * factor, MIN_ZOOM, MAX_ZOOM);
    this.idleSince = performance.now();
    this.onChange();
  };

  handleDoubleClick = () => {
    this.zoomTarget = 1;
    this.onChange();
  };

  pinchDistance() {
    const [a, b] = [...this.pointers.values()];
    return Math.hypot(a.x - b.x, a.y - b.y);
  }

  /** Closest equivalent of `theta` to the current theta (avoid spinning the long way). */
  nearestTurn(theta) {
    return theta + Math.round((this.theta - theta) / TWO_PI) * TWO_PI;
  }

  snapToNearest(theta, phi) {
    const probe = new THREE.Vector3().setFromSphericalCoords(1, phi, theta);
    const v = new THREE.Vector3();
    let best = null;
    let bestDist = Infinity;
    for (const a of this.angles) {
      const d = probe.distanceToSquared(v.setFromSphericalCoords(1, a.phi, a.theta));
      if (d < bestDist) {
        bestDist = d;
        best = a;
      }
    }
    if (!best) return;
    // Near the poles theta is meaningless; keep the current heading.
    const nearPole = best.phi < 0.01 || best.phi > Math.PI - 0.01;
    this.phiTarget = THREE.MathUtils.clamp(best.phi, PHI_MIN, PHI_MAX);
    this.thetaTarget = nearPole ? theta : theta + wrapDelta(best.theta, theta);
    this.snapFactor = this.lerpSnap;
    this.settling = true;
  }

  /** Glide to a labelled angle; `speed` scales the snap rate (site uses 0.55 for the intro). */
  flyTo(label, speed = 1) {
    const a = this.angles.find((x) => x.label === label);
    if (!a) return false;
    this.phiTarget = THREE.MathUtils.clamp(a.phi, PHI_MIN, PHI_MAX);
    this.thetaTarget = this.nearestTurn(a.theta);
    this.snapFactor = Math.min(this.lerpSnap * speed, 1);
    this.settling = true;
    this.idleSince = performance.now();
    this.onChange();
    return true;
  }

  /** Jump to a labelled angle without animating. */
  setAngle(label) {
    const a = this.angles.find((x) => x.label === label);
    if (!a) return false;
    this.phi = this.phiTarget = THREE.MathUtils.clamp(a.phi, PHI_MIN, PHI_MAX);
    this.theta = this.thetaTarget = a.theta;
    this.settling = false;
    this.lensDirty = true;
    return true;
  }

  /** Lens from the active view: camera distance and framing translation (world units). */
  setLens(radius, offset) {
    this.radius = radius;
    this.framingOffset.copy(offset);
    this.lensDirty = true;
  }

  apply() {
    this.camera.position.setFromSphericalCoords(this.radius * this.zoom, this.phi, this.theta);
    this.camera.up.set(0, 1, 0);
    this.camera.lookAt(0, 0, 0);
    this.camera.position.add(this.framingOffset);
  }

  computeWeights() {
    // Lighting depends on the viewing direction only.
    this.tmp.copy(this.camera.position).sub(this.framingOffset).normalize().multiplyScalar(this.lightRadius);
    const scored = this.lightAngles.map((a) => {
      const distance = this.tmp.distanceTo(a.vector);
      const multiplier = THREE.MathUtils.clamp(1 - distance / a.threshold, 0, 1);
      return { label: a.label, distance, multiplier, weight: 0 };
    });
    scored.sort((a, b) => b.multiplier - a.multiplier);
    const top = scored.slice(0, 4);
    let sum = 0;
    for (const s of top) {
      s.weight = (s.distance < 1e-5 ? 1e9 : 1 / s.distance) * s.multiplier;
      sum += s.weight;
    }
    if (sum > 0) {
      for (const s of top) s.weight /= sum;
    } else {
      // Outside every threshold: fall back to the closest angle.
      const closest = [...scored].sort((a, b) => a.distance - b.distance)[0];
      for (const s of top) s.weight = 0;
      top[0] = { ...closest, weight: 1 };
    }
    this.weights = top;
    return top;
  }

  get dominantLabel() {
    return this.weights[0]?.label;
  }

  /** Advance the camera. Returns true while it is still moving. */
  update(dt) {
    const now = performance.now();
    if (this.autoRotate && !this.dragging && now - this.idleSince > 2500) {
      this.settling = false;
      this.thetaTarget += this.autoRotateSpeed * dt;
      this.phiTarget = damp(this.phiTarget, Math.PI / 2 - 0.12, 0.02, dt);
    }

    const factor = this.dragging ? this.lerpDrag : this.settling ? this.snapFactor : 0.12;
    const prev = { theta: this.theta, phi: this.phi, zoom: this.zoom };
    this.theta = damp(this.theta, this.thetaTarget, factor, dt);
    this.phi = damp(this.phi, this.phiTarget, factor, dt);
    this.zoom = damp(this.zoom, this.zoomTarget, 0.15, dt);

    // Keep theta bounded without visible jumps.
    if (Math.abs(this.theta) > TWO_PI * 4) {
      const k = Math.round(this.theta / TWO_PI) * TWO_PI;
      this.theta -= k;
      this.thetaTarget -= k;
    }

    const moving = Math.abs(this.theta - prev.theta) > 1e-5
      || Math.abs(this.phi - prev.phi) > 1e-5
      || Math.abs(this.zoom - prev.zoom) > 1e-4;
    if (moving || this.lensDirty) {
      this.lensDirty = false;
      this.apply();
      this.computeWeights();
    } else if (this.settling) {
      this.settling = false;
    }
    return moving || (this.autoRotate && !this.dragging);
  }
}
