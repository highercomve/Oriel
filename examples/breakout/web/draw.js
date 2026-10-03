// Breakout's drawing: the world (physics.js) into a 2d context, with the
// calls Oriel's native canvas records (fillRect, paths, arc, fillText,
// globalAlpha, save/restore, scale). Each frame starts with an opaque
// fillRect over the whole bitmap and no transform, so the native recorder
// keeps one frame's program, not every frame's.

import { ROW_COLORS } from "./physics.js";

const BG = "#0d1119";

export function draw(ctx, world, dpr, hint) {
  const cv = ctx.canvas;
  ctx.globalAlpha = 1;
  ctx.fillStyle = BG;
  ctx.fillRect(0, 0, cv.width, cv.height);
  ctx.save();
  if (dpr !== 1) ctx.scale(dpr, dpr);
  bricks(ctx, world);
  particles(ctx, world);
  paddle(ctx, world);
  balls(ctx, world);
  if (hint) {
    ctx.globalAlpha = 0.8;
    ctx.fillStyle = "#c9d1e3";
    ctx.font = "15px sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(hint, world.w / 2, world.h * 0.62);
    ctx.globalAlpha = 1;
  }
  ctx.restore();
}

function bricks(ctx, world) {
  const g = world.bricks;
  for (let r = 0; r < g.rows; r++) {
    const color = ROW_COLORS[r % ROW_COLORS.length];
    const y = g.y0 + r * (g.bh + g.gap);
    for (let c = 0; c < g.cols; c++) {
      const k = r * g.cols + c, hits = g.hits[k];
      if (hits <= 0) continue;
      const x = g.x0 + c * (g.bw + g.gap);
      // Fainter as it takes hits; a light edge on top.
      ctx.globalAlpha = 0.45 + 0.55 * (hits / g.max[k]);
      ctx.fillStyle = color;
      ctx.fillRect(x, y, g.bw, g.bh);
      ctx.globalAlpha = 0.35;
      ctx.fillStyle = "#ffffff";
      ctx.fillRect(x, y, g.bw, 2);
      if (g.max[k] > 1) {
        // A dot per hit left.
        ctx.globalAlpha = 0.8;
        ctx.fillStyle = "#0d1119";
        for (let i = 0; i < hits; i++) ctx.fillRect(x + g.bw / 2 - (hits * 6) / 2 + i * 6 + 1, y + g.bh / 2 - 2, 4, 4);
      }
    }
  }
  ctx.globalAlpha = 1;
}

function particles(ctx, world) {
  for (const q of world.particles) {
    ctx.globalAlpha = 1 - q.t / q.life;
    ctx.fillStyle = q.color;
    ctx.fillRect(q.x - 1.5, q.y - 1.5, 3, 3);
  }
  ctx.globalAlpha = 1;
}

function paddle(ctx, world) {
  const p = world.paddle, r = p.h / 2;
  ctx.fillStyle = "#e8eaee";
  ctx.beginPath();
  ctx.arc(p.x - p.w / 2 + r, p.y + r, r, Math.PI / 2, Math.PI * 1.5);
  ctx.lineTo(p.x + p.w / 2 - r, p.y);
  ctx.arc(p.x + p.w / 2 - r, p.y + r, r, -Math.PI / 2, Math.PI / 2);
  ctx.closePath();
  ctx.fill();
  ctx.fillStyle = "#6d8bff";
  ctx.fillRect(p.x - p.w / 2 + r, p.y + p.h - 3, p.w - 2 * r, 3);
}

// Balls a path: few fills, and few edges per scanline for the rasterizer.
// (CoreGraphics on one path of 500 circles: 50–120 fps on macOS; 16 a
// path: a steady 120.)
const BALLS_PER_PATH = 16;

function balls(ctx, world) {
  ctx.fillStyle = "#ffffff";
  const per = BALLS_PER_PATH, bs = world.balls;
  for (let i = 0; i < bs.length; i += per) {
    ctx.beginPath();
    for (let j = i; j < Math.min(bs.length, i + per); j++) {
      const b = bs[j];
      ctx.moveTo(b.x + b.r, b.y);
      ctx.arc(b.x, b.y, b.r, 0, Math.PI * 2);
    }
    ctx.fill();
  }
}
