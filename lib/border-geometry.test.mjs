import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

let code = fs.readFileSync(new URL("../Commons/BorderGeometry.js", import.meta.url), "utf8");
code = code.replace(".pragma library", "");
const Geometry = new Function(code + "; return { borderPaths, ringPath, gradientEndpoints, normalizeRadii };")();

test("ringPath supports uniform numeric radius", () => {
  const path = Geometry.ringPath(200, 40, 20, { top: 2, right: 2, bottom: 2, left: 2 });
  assert.ok(path.length > 0, "path should not be empty");
  // Check that outer path has arc commands
  assert.ok(path.includes("A 20 20 0 0 1 200 20"));
  // Check that inner path has arc commands (radius 18)
  assert.ok(path.includes("A 18 18 0 0 0"));
});

test("ringPath supports per-corner object radii (flat top, rounded bottom)", () => {
  const path = Geometry.ringPath(
    200,
    40,
    { topLeft: 0, topRight: 0, bottomLeft: 20, bottomRight: 20 },
    { top: 2, right: 2, bottom: 2, left: 2 }
  );
  assert.ok(path.length > 0);
  // Outer top corners are sharp (straight lines to 200 and 0)
  assert.ok(path.includes("H 200 L 200 0"));
  assert.ok(path.includes("V 0 L 0 0"));
  // Outer bottom corners are arcs
  assert.ok(path.includes("A 20 20 0 0 1 180 40"));
  assert.ok(path.includes("A 20 20 0 0 1 0 20"));
  // Inner top corners are sharp
  assert.ok(path.includes("L 198 2 L 198 2 L 2 2"));
  // Inner bottom corners are arcs (radius 18)
  assert.ok(path.includes("A 18 18 0 0 0 20 38"));
});

test("ringPath handles zero/negative dimensions gracefully", () => {
  assert.equal(Geometry.ringPath(0, 40, 20, { top: 2, right: 2, bottom: 2, left: 2 }), "");
  assert.equal(Geometry.ringPath(200, 0, 20, { top: 2, right: 2, bottom: 2, left: 2 }), "");
});
