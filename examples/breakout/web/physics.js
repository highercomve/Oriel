// Breakout's rules: the world in board units (the canvas's CSS pixels),
// stepped by dt seconds. No DOM and no drawing, so another driver (a
// Zig-side simulation drawing into the canvas) can follow the same rules.

export const ROW_COLORS = ["#ff5d73", "#ff9f43", "#ffd166", "#3ad07a", "#36c5f0", "#6d8bff", "#b18cff", "#f78fb3"];

const MAX_PARTICLES = 1500;
const PADDLE_SPEED = 900; // px/s with the keys
const PADDLE_FOLLOW = 2400; // px/s at most toward a pointer

export function createWorld(w, h, opts = {}) {
  const world = {
    w, h,
    rows: opts.rows ?? 6,
    balls: [],
    particles: [],
    bricks: null,
    paddle: { x: w / 2, y: 0, w: 0, h: 12 },
    score: 0,
    lives: 3,
    level: 1,
    over: false,
  };
  resize(world, w, h);
  buildLevel(world);
  return world;
}

/** The ball speed for the world's size and level (px/s). */
export function ballSpeed(world) {
  const base = Math.min(720, Math.max(320, world.h * 0.8));
  return base * (1 + 0.08 * (world.level - 1));
}

function brickGeometry(world) {
  const b = world.bricks;
  const margin = 12, gap = 4;
  b.gap = gap;
  b.x0 = margin;
  // Room above for the stats overlay (less on a short board, a phone on
  // its side), and the grid ends by 55% of the height, well above the paddle.
  b.y0 = world.h < 420 ? Math.max(36, world.h * 0.1) : Math.max(96, world.h * 0.14);
  b.bw = (world.w - 2 * margin - gap * (b.cols - 1)) / b.cols;
  const fit = (world.h * 0.55 - b.y0) / b.rows - gap;
  b.bh = Math.max(4, Math.min(24, world.h * 0.035, fit));
}

/** A new brick grid: the top rows take more hits as levels go by. */
export function buildLevel(world) {
  const cols = Math.max(6, Math.min(16, Math.floor(world.w / 56)));
  const rows = world.rows;
  const hits = new Int8Array(cols * rows);
  const tough = Math.min(rows - 1, 1 + Math.floor(world.level / 2));
  for (let r = 0; r < rows; r++) {
    const n = r < tough ? (r === 0 && world.level > 2 ? 3 : 2) : 1;
    for (let c = 0; c < cols; c++) hits[r * cols + c] = n;
  }
  world.bricks = { cols, rows, hits, max: hits.slice(), left: cols * rows, x0: 0, y0: 0, bw: 0, bh: 0, gap: 0 };
  brickGeometry(world);
  world.balls.length = 0;
  world.balls.push(stuckBall(world));
}

/** The board changed size: everything keeps its place in proportion. */
export function resize(world, w, h) {
  const sx = world.w ? w / world.w : 1, sy = world.h ? h / world.h : 1;
  world.w = w;
  world.h = h;
  const p = world.paddle;
  p.w = Math.min(160, Math.max(70, w * 0.16));
  p.y = h - 28;
  p.x = clamp(p.x * sx, p.w / 2, w - p.w / 2);
  for (const b of world.balls) {
    b.x = clamp(b.x * sx, b.r, w - b.r);
    b.y = b.stuck ? p.y - b.r - 1 : b.y * sy;
  }
  for (const q of world.particles) { q.x *= sx; q.y *= sy; }
  if (world.bricks) brickGeometry(world);
}

function stuckBall(world) {
  const p = world.paddle;
  return { x: p.x, y: p.y - 7, vx: 0, vy: 0, r: 6, stuck: true };
}

/** Launch the ball on the paddle as `count` balls in a fan. */
export function launch(world, count = 1) {
  const stuck = world.balls.find((b) => b.stuck);
  if (!stuck || world.over) return false;
  world.balls = world.balls.filter((b) => !b.stuck);
  const speed = ballSpeed(world);
  const n = Math.max(1, Math.min(500, count | 0));
  for (let i = 0; i < n; i++) {
    // Up, spread over ±55° (one ball: a little to the right).
    const a = n === 1 ? 0.25 : ((i / (n - 1)) * 2 - 1) * 0.96;
    world.balls.push({ x: stuck.x, y: stuck.y, vx: Math.sin(a) * speed, vy: -Math.cos(a) * speed, r: stuck.r, stuck: false });
  }
  return true;
}

/**
 * One step. `input`: { target: x or null (a pointer), dir: -1, 0 or 1 (keys) }.
 * Returns what happened: { broken, lost, cleared }.
 */
export function step(world, dt, input, opts = {}) {
  const out = { broken: 0, lost: false, cleared: false };
  if (world.over) return out;
  movePaddle(world, dt, input);
  const p = world.paddle;
  const speed = ballSpeed(world);
  const balls = world.balls;
  let alive = 0;
  for (let i = 0; i < balls.length; i++) {
    const b = balls[i];
    if (b.stuck) {
      b.x = p.x;
      b.y = p.y - b.r - 1;
      balls[alive++] = b;
      continue;
    }
    // Substeps so a fast ball can't pass through a brick.
    const dist = Math.hypot(b.vx, b.vy) * dt;
    const n = Math.max(1, Math.ceil(dist / (b.r * 0.9)));
    const h = dt / n;
    let gone = false;
    for (let s = 0; s < n && !gone; s++) {
      b.x += b.vx * h;
      b.y += b.vy * h;
      if (b.x < b.r) { b.x = b.r; b.vx = Math.abs(b.vx); }
      else if (b.x > world.w - b.r) { b.x = world.w - b.r; b.vx = -Math.abs(b.vx); }
      if (b.y < b.r) { b.y = b.r; b.vy = Math.abs(b.vy); }
      if (b.vy > 0 && b.y + b.r >= p.y && b.y - b.r <= p.y + p.h && b.x >= p.x - p.w / 2 - b.r && b.x <= p.x + p.w / 2 + b.r) {
        // The paddle sends it up at an angle from where it hit (±60°).
        const rel = clamp((b.x - p.x) / (p.w / 2), -1, 1);
        // (A touch of spread, so a centred hit doesn't go straight up forever.)
        const a = rel * (Math.PI / 3) + (Math.random() - 0.5) * 0.06;
        b.vx = Math.sin(a) * speed;
        b.vy = -Math.cos(a) * speed;
        b.y = p.y - b.r;
      }
      if (hitBrick(world, b, out, opts)) break;
      if (b.y - b.r > world.h) gone = true;
    }
    if (!gone) balls[alive++] = b;
  }
  balls.length = alive;
  stepParticles(world, dt);
  if (world.bricks.left === 0) {
    world.level++;
    buildLevel(world);
    out.cleared = true;
  } else if (alive === 0) {
    out.lost = true;
    if (!opts.endless) world.lives--;
    if (world.lives <= 0) world.over = true;
    else balls.push(stuckBall(world));
  }
  return out;
}

function movePaddle(world, dt, input) {
  const p = world.paddle;
  if (input.target != null) {
    const d = input.target - p.x;
    const max = PADDLE_FOLLOW * dt;
    p.x += Math.abs(d) <= max ? d : Math.sign(d) * max;
  } else if (input.dir) p.x += input.dir * PADDLE_SPEED * dt;
  p.x = clamp(p.x, p.w / 2, world.w - p.w / 2);
}

// The brick under the ball, if any: it bounces off the side it went in by
// least, and the brick loses a hit. One brick per substep.
function hitBrick(world, b, out, opts) {
  const g = world.bricks;
  const cw = g.bw + g.gap, ch = g.bh + g.gap;
  const c0 = Math.floor((b.x - b.r - g.x0) / cw), c1 = Math.floor((b.x + b.r - g.x0) / cw);
  const r0 = Math.floor((b.y - b.r - g.y0) / ch), r1 = Math.floor((b.y + b.r - g.y0) / ch);
  if (r1 < 0 || r0 >= g.rows || c1 < 0 || c0 >= g.cols) return false;
  for (let r = Math.max(0, r0); r <= Math.min(g.rows - 1, r1); r++) {
    for (let c = Math.max(0, c0); c <= Math.min(g.cols - 1, c1); c++) {
      const k = r * g.cols + c;
      if (g.hits[k] <= 0) continue;
      const x = g.x0 + c * cw, y = g.y0 + r * ch;
      const nx = clamp(b.x, x, x + g.bw), ny = clamp(b.y, y, y + g.bh);
      const dx = b.x - nx, dy = b.y - ny;
      if (dx * dx + dy * dy > b.r * b.r) continue;
      // The face it went in by least: pushed back out of it, and a hit only
      // when it was moving into that face (not while it leaves the brick).
      const px = Math.min(b.x + b.r - x, x + g.bw - (b.x - b.r));
      const py = Math.min(b.y + b.r - y, y + g.bh - (b.y - b.r));
      let into;
      if (px < py) {
        const left = b.x < x + g.bw / 2;
        into = left ? b.vx > 0 : b.vx < 0;
        b.x = left ? x - b.r : x + g.bw + b.r;
        if (into) b.vx = -b.vx;
      } else {
        const above = b.y < y + g.bh / 2;
        into = above ? b.vy > 0 : b.vy < 0;
        b.y = above ? y - b.r : y + g.bh + b.r;
        if (into) b.vy = -b.vy;
      }
      if (!into) return false; // pushed out; it keeps going
      g.hits[k]--;
      world.score += 10;
      if (g.hits[k] === 0) {
        g.left--;
        out.broken++;
        world.score += 10 * g.max[k];
        if (opts.particles !== false) burst(world, x + g.bw / 2, y + g.bh / 2, ROW_COLORS[r % ROW_COLORS.length]);
      }
      return true;
    }
  }
  return false;
}

function burst(world, x, y, color) {
  const ps = world.particles;
  for (let i = 0; i < 10 && ps.length < MAX_PARTICLES; i++) {
    const a = Math.random() * Math.PI * 2, v = 60 + Math.random() * 220;
    ps.push({ x, y, vx: Math.cos(a) * v, vy: Math.sin(a) * v - 80, life: 0.5 + Math.random() * 0.5, t: 0, color });
  }
}

function stepParticles(world, dt) {
  const ps = world.particles;
  let n = 0;
  for (let i = 0; i < ps.length; i++) {
    const q = ps[i];
    q.t += dt;
    if (q.t >= q.life) continue;
    q.vy += 600 * dt;
    q.x += q.vx * dt;
    q.y += q.vy * dt;
    ps[n++] = q;
  }
  ps.length = n;
}

export function clamp(v, lo, hi) {
  return v < lo ? lo : v > hi ? hi : v;
}
