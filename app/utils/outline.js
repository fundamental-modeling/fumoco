// This file is part of Fumoco.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Holger Peters -- see the LICENSE file.

// Rectilinear outlines for shaped locations (L shapes, U shapes, ...): a
// closed polygon of horizontal and vertical edges, as a list of vertices
// ({x, y}), each edge running from one vertex to the next and the last
// back to the first. Stored on a view box (`box.outline`) relative to the
// box's top-left; the box itself stays the outline's bounding box.

export function rectOutline(width, height) {
  return [
    { x: 0, y: 0 },
    { x: width, y: 0 },
    { x: width, y: height },
    { x: 0, y: height },
  ];
}

const same = (a, b) => a.x === b.x && a.y === b.y;
const collinear = (a, b, c) =>
  (a.x === b.x && b.x === c.x) || (a.y === b.y && b.y === c.y);

// Drops repeated vertices and vertices in the middle of a straight run.
export function normalizeOutline(points) {
  let pts = points.map((p) => ({ x: p.x, y: p.y }));
  let changed = true;
  while (changed && pts.length > 2) {
    changed = false;
    for (let i = 0; i < pts.length; i++) {
      const prev = pts[(i - 1 + pts.length) % pts.length];
      const next = pts[(i + 1) % pts.length];
      if (same(pts[i], next) || collinear(prev, pts[i], next)) {
        pts.splice(i, 1);
        changed = true;
        break;
      }
    }
  }
  return pts;
}

function edges(points) {
  return points.map((p, i) => [p, points[(i + 1) % points.length]]);
}

function signedArea(points) {
  return (
    edges(points).reduce((sum, [a, b]) => sum + (a.x * b.y - b.x * a.y), 0) / 2
  );
}

// Do two axis-aligned segments share any point?
function segmentsTouch([a, b], [c, d]) {
  const [ax0, ax1] = [Math.min(a.x, b.x), Math.max(a.x, b.x)];
  const [ay0, ay1] = [Math.min(a.y, b.y), Math.max(a.y, b.y)];
  const [cx0, cx1] = [Math.min(c.x, d.x), Math.max(c.x, d.x)];
  const [cy0, cy1] = [Math.min(c.y, d.y), Math.max(c.y, d.y)];
  return ax0 <= cx1 && cx0 <= ax1 && ay0 <= cy1 && cy0 <= ay1;
}

// A usable outline: at least a rectangle's four vertices, only
// horizontal/vertical edges, a nonzero area, and no edge touching any
// edge other than its two neighbours (no crossings, no zero-width
// spikes, no parts pinched together).
export function isValidOutline(points) {
  if (points.length < 4) return false;
  const es = edges(points);
  if (es.some(([a, b]) => a.x !== b.x && a.y !== b.y)) return false;
  if (es.some(([a, b]) => same(a, b))) return false;
  if (signedArea(points) === 0) return false;
  for (let i = 0; i < es.length; i++) {
    for (let j = i + 1; j < es.length; j++) {
      const adjacent = j === i + 1 || (i === 0 && j === es.length - 1);
      if (!adjacent && segmentsTouch(es[i], es[j])) return false;
    }
  }
  return true;
}

export function outlineBounds(points) {
  const xs = points.map((p) => p.x);
  const ys = points.map((p) => p.y);
  const x = Math.min(...xs);
  const y = Math.min(...ys);
  return {
    x,
    y,
    width: Math.max(...xs) - x,
    height: Math.max(...ys) - y,
  };
}

// Pushes the section of edge `index` between positions `from` and `to`
// along it (x for a horizontal edge, y for a vertical one) out or in by
// `delta`, perpendicular to the edge -- adding the two edges that join
// the moved section to the rest. A section spanning the whole edge moves
// the edge itself, its neighbours stretching. Returns the normalized
// outline, or null when the result isn't a valid outline.
export function pushSegment(points, index, from, to, delta) {
  const p = points[index];
  const q = points[(index + 1) % points.length];
  const horizontal = p.y === q.y;
  const along = horizontal ? 'x' : 'y';
  const lo = Math.min(p[along], q[along]);
  const hi = Math.max(p[along], q[along]);
  const clamp = (v) => Math.min(hi, Math.max(lo, v));
  // the section's ends in the edge's own direction, p -> q
  const forward = q[along] > p[along];
  let [s1, s2] = [clamp(from), clamp(to)].sort((a, b) => a - b);
  if (!forward) [s1, s2] = [s2, s1];
  if (s1 === s2 || !delta) return null;
  const at = (a, c) => (horizontal ? { x: a, y: c } : { x: c, y: a });
  const base = horizontal ? p.y : p.x;
  const inserted = [
    at(s1, base),
    at(s1, base + delta),
    at(s2, base + delta),
    at(s2, base),
  ];
  const result = normalizeOutline([
    ...points.slice(0, index + 1),
    ...inserted,
    ...points.slice(index + 1),
  ]);
  return isValidOutline(result) ? result : null;
}

// Where a connector arriving at `point` on side `side` ('n' | 'e' | 's' |
// 'w') of the outline's bounding box actually meets the outline: the
// first outline edge straight in from there. `point` itself if nothing
// is hit (it already lies on the outline, or exactly at a corner).
export function outlineEntry(points, point, side) {
  const vertical = side === 'e' || side === 'w';
  let best = null;
  for (const [a, b] of edges(points)) {
    if (vertical ? a.x !== b.x : a.y !== b.y) continue; // perpendicular only
    const [k0, k1] = vertical
      ? [Math.min(a.y, b.y), Math.max(a.y, b.y)]
      : [Math.min(a.x, b.x), Math.max(a.x, b.x)];
    const k = vertical ? point.y : point.x;
    if (k <= k0 || k >= k1) continue;
    const at = vertical ? a.x : a.y;
    const distance = {
      e: point.x - at,
      w: at - point.x,
      s: point.y - at,
      n: at - point.y,
    }[side];
    if (distance >= 0 && (!best || distance < best.distance)) {
      best = { distance, at };
    }
  }
  if (!best) return point;
  return vertical ? { x: best.at, y: point.y } : { x: point.x, y: best.at };
}

export function scaleOutline(points, sx, sy) {
  return points.map((p) => ({ x: p.x * sx, y: p.y * sy }));
}

// A box's outline stretched to the box's current size (resizing, "same
// size" and the like change only width/height), relative to its top-left;
// null for a plain rectangle.
export function fittedOutline(box) {
  if (!box?.outline) return null;
  const bounds = outlineBounds(box.outline);
  return box.outline.map((p) => ({
    x: ((p.x - bounds.x) * box.width) / (bounds.width || 1),
    y: ((p.y - bounds.y) * box.height) / (bounds.height || 1),
  }));
}

// The outline split into rectangles along horizontal slabs (between
// consecutive vertex heights): what's inside it, as rectangles.
export function outlineRects(points) {
  const ys = [...new Set(points.map((p) => p.y))].sort((a, b) => a - b);
  const verticals = edges(points).filter(([a, b]) => a.x === b.x);
  const rects = [];
  for (let i = 0; i < ys.length - 1; i++) {
    const [y0, y1] = [ys[i], ys[i + 1]];
    const mid = (y0 + y1) / 2;
    // inside between alternate crossings of the vertical edges
    const xs = verticals
      .filter(([a, b]) => Math.min(a.y, b.y) < mid && mid < Math.max(a.y, b.y))
      .map(([a]) => a.x)
      .sort((a, b) => a - b);
    for (let j = 0; j + 1 < xs.length; j += 2) {
      rects.push({
        x: xs[j],
        y: y0,
        width: xs[j + 1] - xs[j],
        height: y1 - y0,
      });
    }
  }
  return rects;
}

// Where a shaped location's label goes: the largest of outlineRects (a
// U's bottom bar, an L's longer leg), so it sits inside the shape rather
// than on a notch.
export function labelArea(points) {
  const rects = outlineRects(points);
  if (!rects.length) return outlineBounds(points);
  return rects.reduce((best, r) =>
    r.width * r.height > best.width * best.height ? r : best,
  );
}

// Is `point` inside the outline (or on its edge)?
export function pointInOutline(points, point) {
  return outlineRects(points).some(
    (r) =>
      point.x >= r.x &&
      point.x <= r.x + r.width &&
      point.y >= r.y &&
      point.y <= r.y + r.height,
  );
}

// Is `rect` (relative to the outline's origin) wholly inside the outline?
// Its center is inside and no outline edge runs through its interior --
// for a rectilinear outline, that's all it takes.
export function rectInOutline(points, rect) {
  const center = { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
  if (!pointInOutline(points, center)) return false;
  const [x0, x1, y0, y1] = [
    rect.x,
    rect.x + rect.width,
    rect.y,
    rect.y + rect.height,
  ];
  return edges(points).every(([a, b]) =>
    a.y === b.y
      ? !(
          y0 < a.y &&
          a.y < y1 &&
          Math.max(Math.min(a.x, b.x), x0) < Math.min(Math.max(a.x, b.x), x1)
        )
      : !(
          x0 < a.x &&
          a.x < x1 &&
          Math.max(Math.min(a.y, b.y), y0) < Math.min(Math.max(a.y, b.y), y1)
        ),
  );
}
