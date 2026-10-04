import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// The page's .js module has no package.json; load the actual source as ESM.
const source = readFileSync(new URL('../web/physics.js', import.meta.url), 'utf8');
const { createWorld, launch, step, ballSpeed } = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const world = createWorld(412, 850, { rows: 12 });
const base = ballSpeed(world);
world.level = 2;
assert.equal(ballSpeed(world), base * 1.08);
for (const level of [26, 100, 4000, 39222, 0xffffffff]) {
  world.level = level;
  assert.equal(ballSpeed(world), base * 3);
}
assert.equal(launch(world, 500), true);
assert.equal(world.balls.length, 500);
assert.ok(world.balls.every(b => Math.abs(Math.hypot(b.vx, b.vy) - base * 3) < 1e-8));
step(world, 1 / 60, { target: 206 }, { endless: true, particles: false });
assert.ok(world.balls.every(b => [b.x, b.y, b.vx, b.vy].every(Number.isFinite)));
console.log('Breakout physics: long-run speed bound and 500-ball step passed');
