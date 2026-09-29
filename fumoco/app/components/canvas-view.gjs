import Component from '@glimmer/component';
import { tracked } from '@glimmer/tracking';
import { action } from '@ember/object';
import { service } from '@ember/service';
import { on } from '@ember/modifier';
import { fn } from '@ember/helper';
import { modifier } from 'ember-modifier';
import Konva from 'konva';
import { Context as SvgContext } from 'svgcanvas';
import { TrackedArray } from 'tracked-built-ins';
import {
  ElementType,
  FmcModelError,
  formatDate,
  isRoundedElementType,
} from 'fumoco/utils/fmc-model';
import { ConnectorKind, connectorRule } from 'fumoco/services/connector-tool';
import { defaultBoxSize } from 'fumoco/utils/box-layout';
import config from 'fumoco/config/environment';

const GRID = 10;
// Advisory page: a default PowerPoint slide, landscape (13.33in x 7.5in
// = 1280x720px at 96dpi), minus the export's 20px margins and ~64px
// title header -- content that fits exports to exactly one slide.
const PAGE_WIDTH = 1240;
const PAGE_HEIGHT = 610;
const ZOOM_STEP = 1.25;
const GUIDE_STRIP = 8; // px: the canvas-edge strips guides are dragged in from / back out to
const GUIDE_SNAP = 6; // px (screen): how close a box edge/center must come to snap to a guide
const MIN_ZOOM = 0.25;
const MAX_ZOOM = 4;
const MIN_SIZE = 10; // below the 15px-high default relation
const MARQUEE_THRESHOLD = 3; // px of movement before a stage mousedown counts as a drag, not a click
const NESTING_PADDING = 30;
// A node's outline should read visibly heavier than an edge's so the two
// are never ambiguous (FMC Visualization Guidelines' "line weight of
// edges and nodes"); edges stay at their existing strokeWidth: 2.
const NODE_STROKE_WIDTH = 3;
const NODE_STROKE_WIDTH_SELECTED = 4;
const MULTIPLE_OFFSET = 8; // px between the stacked copies of a "multiple" box
// Self-hosted via @fontsource/barlow (app.js) so it works offline too --
// matching the FMC diagrams this app is modeled after. `sans-serif`
// fallback covers the brief window before the webfont finishes loading
// (font-display: swap) and any glyph Barlow itself doesn't cover.
const CANVAS_FONT_FAMILY = 'Barlow, sans-serif';

// Menu hint for a Cmd (Mac) / Ctrl (everything else) shortcut.
const IS_MAC = /Mac|iPhone|iPad/.test(globalThis.navigator?.platform ?? '');
function shortcut(key) {
  return IS_MAC ? `\u2318${key}` : `Ctrl+${key}`;
}

function snapToGrid(value) {
  return Math.round(value / GRID) * GRID;
}

// Whether/under-which-parent `id` is *displayed* nested in `view` --
// independent of Element.parents (the world-model containment fact).
// An explicit `view.nestedUnder` entry always wins (a parentId to nest
// under, or null for "explicitly shown un-nested here even though the
// model still contains it somewhere"). With no explicit entry, default
// to the first model parent that's also present in this view, or null.
// This is the one place that distinction lives -- nestingDepth,
// computeEffectiveBoxes, and collectDescendantNodes all go through it so
// "does the model say X or does this view choose to show X" can't drift.
export function displayParentOf(model, view, id, includedSet) {
  if (view.nestedUnder.has(id)) return view.nestedUnder.get(id);
  const parents = (model.elements.get(id)?.parents ?? []).filter((p) =>
    includedSet.has(p),
  );
  return parents[0] ?? null;
}

// id -> the list of ids displayed nested directly under it in this view
// (per displayParentOf) -- the single pass every nesting computation below
// is built on.
export function buildDisplayChildIndex(model, view) {
  const includedSet = new Set(view.included);
  const index = new Map();
  for (const id of view.included) {
    const parent = displayParentOf(model, view, id, includedSet);
    if (parent == null) continue;
    if (!index.has(parent)) index.set(parent, []);
    index.get(parent).push(id);
  }
  return index;
}

// The order shapes are added to the Konva layer in -- which is also
// their z-order, since a later-added node draws on top. The only
// ordering constraint FMC nesting actually implies is "a container draws
// behind its own displayed children"; two elements with no nesting
// relationship to each other have no required relative order beyond
// "whichever was added to the view more recently ends up on top" (which
// falls out for free from a DFS over `view.included`, since a newly
// added element is pushed to its end). This replaces an earlier "every
// depth-0 element, then every depth-1 element, then every depth-2
// element, ..." global sort, which had a real bug: it drew *every*
// deeply-nested descendant of some container above *every* unrelated
// top-level element, including a brand new element that had nothing to
// do with that container -- a freshly-added box could render underneath
// existing nested content it was never nested in.
export function buildDrawOrder(model, view) {
  const includedSet = new Set(view.included);
  const displayChildren = buildDisplayChildIndex(model, view);
  const order = [];
  const visited = new Set();
  const visit = (id) => {
    if (visited.has(id)) return;
    visited.add(id);
    order.push(id);
    for (const childId of displayChildren.get(id) ?? []) visit(childId);
  };
  for (const id of view.included) {
    if (displayParentOf(model, view, id, includedSet) == null) visit(id);
  }
  return order;
}

// How deeply `id` is displayed nested in this view (0 for top-level).
export function nestingDepth(model, view, id, includedSet, cache) {
  if (cache.has(id)) return cache.get(id);
  const parent = displayParentOf(model, view, id, includedSet);
  const depth =
    parent == null
      ? 0
      : 1 + nestingDepth(model, view, parent, includedSet, cache);
  cache.set(id, depth);
  return depth;
}

// A container displaying at least one nested child in this view gets its
// box auto-computed as a bounding box around those children (with
// padding), UNLESS it has its own stored box (set via the same 8 resize
// handles a plain box gets -- see canvas-view's buildShape/transformend)
// that's still big enough to contain that auto-fit bbox, in which case the
// manual size wins. Shrinking/moving children until the manual box no
// longer fits them silently falls back to auto-fit again, same as an
// invalid drag-nest being silently skipped elsewhere in this file --
// no error, just stops trusting a box that no longer makes sense. Computed
// deepest-first so a grandparent's fit already sees its parent's
// (already-fit) box.
function circleAround(box) {
  const d = 2 * Math.max(box.width, box.height);
  return {
    x: box.x + box.width / 2 - d / 2,
    y: box.y + box.height / 2 - d / 2,
    width: d,
    height: d,
  };
}

// Where two boxes face each other -- parallel sides with a gap between
// them and an overlapping extent -- for a lens-drawn modify edge: the
// midpoint of that overlap on each box's facing side (`p` on `a`, `q` on
// `b`) and the overlap's length. null when they don't face each other.
export function lensEnds(a, b) {
  const overlap = (a0, a1, b0, b1) => [Math.max(a0, b0), Math.min(a1, b1)];
  const [y0, y1] = overlap(a.y, a.y + a.height, b.y, b.y + b.height);
  const [x0, x1] = overlap(a.x, a.x + a.width, b.x, b.x + b.width);
  if (y1 > y0) {
    const y = (y0 + y1) / 2;
    if (a.x + a.width < b.x) {
      return { p: { x: a.x + a.width, y }, q: { x: b.x, y }, span: y1 - y0 };
    }
    if (b.x + b.width < a.x) {
      return { p: { x: a.x, y }, q: { x: b.x + b.width, y }, span: y1 - y0 };
    }
  }
  if (x1 > x0) {
    const x = (x0 + x1) / 2;
    if (a.y + a.height < b.y) {
      return { p: { x, y: a.y + a.height }, q: { x, y: b.y }, span: x1 - x0 };
    }
    if (b.y + b.height < a.y) {
      return { p: { x, y: a.y }, q: { x, y: b.y + b.height }, span: x1 - x0 };
    }
  }
  return null;
}

// A dragged box's top-left, snapped: its left/center/right edge
// (top/middle/bottom for horizontal guides) onto the nearest guide within
// `tolerance` diagram units, else onto the grid.
export function snapBox(guides, box, tolerance) {
  const snapAxis = (axis, start, size) => {
    let best = null;
    for (const guide of guides) {
      if (guide.axis !== axis) continue;
      for (const offset of [0, size / 2, size]) {
        const distance = Math.abs(start + offset - guide.pos);
        if (distance < tolerance && (!best || distance < best.distance)) {
          best = { distance, start: guide.pos - offset };
        }
      }
    }
    return best ? best.start : snapToGrid(start);
  };
  return {
    x: snapAxis('x', box.x, box.width),
    y: snapAxis('y', box.y, box.height),
  };
}

// The same box turned 90 degrees about its center (width/height swapped).
export function swapBoxAxes({ x, y, width, height }) {
  return {
    x: x + width / 2 - height / 2,
    y: y + height / 2 - width / 2,
    width: height,
    height: width,
  };
}

// A displayed box back to what's stored: turned back if it was shown
// turned (computeEffectiveBoxes), and without the display-only flag.
function toStoredBox({ rotated, ...box }) {
  return rotated ? swapBoxAxes(box) : box;
}

// Whether an ER relation's entity sets sit above/below it rather than
// beside it: for a binary relation, the line between its two entity
// sets is steeper than 45 degrees; otherwise the entity sets' summed
// offsets from the relation are more vertical than horizontal.
export function isVerticalRelation(model, relationId, box, boxes) {
  const centerOf = (b) => ({ x: b.x + b.width / 2, y: b.y + b.height / 2 });
  const others = model.arcs
    .filter((arc) => arc.source === relationId || arc.target === relationId)
    .map((arc) =>
      boxes.get(arc.source === relationId ? arc.target : arc.source),
    )
    .filter(Boolean)
    .map(centerOf);
  if (!others.length) return false;
  if (others.length === 2) {
    return (
      Math.abs(others[1].y - others[0].y) > Math.abs(others[1].x - others[0].x)
    );
  }
  const mid = centerOf(box);
  const dx = others.reduce((sum, p) => sum + Math.abs(p.x - mid.x), 0);
  const dy = others.reduce((sum, p) => sum + Math.abs(p.y - mid.y), 0);
  return dy > dx;
}

export function computeEffectiveBoxes(model, view) {
  const includedSet = new Set(view.included);
  const effective = new Map();
  for (const id of view.included) {
    const box = view.boxes.get(id);
    if (box) effective.set(id, box);
  }
  // A relation between vertically stacked entity sets turns 90 degrees
  // automatically. The stored box stays in its unturned shape; `rotated`
  // tells drag/resize to turn it back before writing (see buildShape).
  for (const id of view.included) {
    const box = effective.get(id);
    if (!box || model.elements.get(id)?.type !== ElementType.RELATION) continue;
    if (isVerticalRelation(model, id, box, effective)) {
      effective.set(id, { ...swapBoxAxes(box), rotated: true });
    }
  }
  const depthCache = new Map();
  const byDepthDescending = [...view.included].sort(
    (a, b) =>
      nestingDepth(model, view, b, includedSet, depthCache) -
      nestingDepth(model, view, a, includedSet, depthCache),
  );
  const displayChildren = buildDisplayChildIndex(model, view);
  for (const id of byDepthDescending) {
    const childBoxes = (displayChildren.get(id) ?? [])
      .map((childId) => effective.get(childId))
      .filter(Boolean);
    if (!childBoxes.length) continue;
    const minX = Math.min(...childBoxes.map((b) => b.x));
    const minY = Math.min(...childBoxes.map((b) => b.y));
    const maxX = Math.max(...childBoxes.map((b) => b.x + b.width));
    const maxY = Math.max(...childBoxes.map((b) => b.y + b.height));
    const onlyChild = childBoxes.length === 1 && displayChildren.get(id)[0];
    // A reified relation (an entity set around exactly one relation) is
    // a circle twice the relation's longer side across -- ~6em around a
    // default 3em relation, growing with it.
    const autoFit =
      model.elements.get(id)?.type === ElementType.ENTITY_SET &&
      model.elements.get(onlyChild)?.type === ElementType.RELATION
        ? circleAround(childBoxes[0])
        : {
            x: minX - NESTING_PADDING,
            y: minY - NESTING_PADDING,
            width: maxX - minX + 2 * NESTING_PADDING,
            height: maxY - minY + 2 * NESTING_PADDING,
          };
    const stored = view.boxes.get(id);
    effective.set(
      id,
      stored && boxContains(stored, autoFit) ? stored : autoFit,
    );
  }
  return effective;
}

function boxContains(outer, inner) {
  return (
    outer.x <= inner.x &&
    outer.y <= inner.y &&
    outer.x + outer.width >= inner.x + inner.width &&
    outer.y + outer.height >= inner.y + inner.height
  );
}

function rectsIntersect(a, b) {
  return (
    a.x < b.x + b.width &&
    b.x < a.x + a.width &&
    a.y < b.y + b.height &&
    b.y < a.y + a.height
  );
}

function pointInBox(point, box) {
  return (
    point.x >= box.x &&
    point.x <= box.x + box.width &&
    point.y >= box.y &&
    point.y <= box.y + box.height
  );
}

// A simple rectilinear (horizontal/vertical only) path between two boxes'
// boundaries: a straight segment when they already share an axis,
// otherwise a single right-angle bend. No obstacle avoidance -- see
// attic/src/fmc/render.py's `_orthogonal_path` for the fancier version
// this is deliberately not porting yet (candidate-path scoring against
// every other box in the view); add it if crossings become a real problem.
// Exported (like verticalArcPath) purely so the swept regression test can
// call it directly.
export function orthogonalPath(a, b) {
  const ax0 = a.x,
    ay0 = a.y,
    ax1 = a.x + a.width,
    ay1 = a.y + a.height;
  const bx0 = b.x,
    by0 = b.y,
    bx1 = b.x + b.width,
    by1 = b.y + b.height;
  const acx = a.x + a.width / 2,
    acy = a.y + a.height / 2;
  const bcx = b.x + b.width / 2,
    bcy = b.y + b.height / 2;

  const xOverlap = Math.min(ax1, bx1) - Math.max(ax0, bx0);
  const yOverlap = Math.min(ay1, by1) - Math.max(ay0, by0);

  if (xOverlap > 0) {
    const x = (Math.max(ax0, bx0) + Math.min(ax1, bx1)) / 2;
    return bcy >= acy
      ? [
          { x, y: ay1 },
          { x, y: by0 },
        ]
      : [
          { x, y: ay0 },
          { x, y: by1 },
        ];
  }
  if (yOverlap > 0) {
    const y = (Math.max(ay0, by0) + Math.min(ay1, by1)) / 2;
    return bcx >= acx
      ? [
          { x: ax1, y },
          { x: bx0, y },
        ]
      : [
          { x: ax0, y },
          { x: bx1, y },
        ];
  }

  const aExitX = bcx > acx ? ax1 : ax0;
  const aExitY = bcy > acy ? ay1 : ay0;
  const bEnterX = bcx > acx ? bx0 : bx1;
  const bEnterY = bcy > acy ? by0 : by1;

  if (-xOverlap >= -yOverlap) {
    return [
      { x: aExitX, y: acy },
      { x: bcx, y: acy },
      { x: bcx, y: bEnterY },
    ];
  }
  return [
    { x: acx, y: aExitY },
    { x: acx, y: bcy },
    { x: bEnterX, y: bcy },
  ];
}

// Petri net arcs deliberately don't use orthogonalPath's "shortest route"
// logic: FMC's standard flow direction is top-to-bottom, and always
// exiting a box's bottom (south) and entering the next one's top (north)
// -- regardless of their actual relative position -- is what gives a
// Petri net that flow feel. It also fixes a real bug for free: two
// opposite-direction arcs between the same place/transition pair used to
// route identically (just traversed in reverse), so they'd draw as one
// perfectly overlapping line with an arrowhead at each end -- reading as
// a single bidirectional edge, which a Petri arc must never be. Forcing
// fixed ports makes the forward and reverse arcs take visibly different
// paths (a straight line down vs. an S-curve back up) instead of ever
// coinciding. ER arcs keep using orthogonalPath -- an ER diagram has no
// such fixed reading direction (see spec/index.html's ER section).
const ARC_ROUTE_MARGIN = 20;
// Comfortably longer than EDGE_CORNER_RADIUS so drawRoundedPolyline's
// arcTo-based rounding has room to render the *same* radius at a
// diagonal-to-orthogonal bend as it already does at every plain
// orthogonal-to-orthogonal one -- arcTo silently shrinks the radius it
// actually draws when the adjacent segment is too short to fit it, so a
// stub barely longer than the radius itself would round visibly less
// than the rest of the path.
const ARC_DIAGONAL_STUB = 28;

// A point on a box's boundary at 45 degrees into one of its corner
// quadrants (signX/signY each -1 or 1). For a circular/near-circular
// shape (a Petri place, drawn via buildShape's cornerRadius trick) this
// is the actual point ON the circle -- not the bounding box's corner,
// which sits outside the circle -- so a diagonal arc genuinely leaves
// from the place's own edge rather than from empty space beyond it. For
// a rectangular shape (a transition) the two are the same point, so the
// same formula still gives the box's corner correctly.
function diagonalBoundaryPoint(box, isCircular, signX, signY) {
  const cx = box.x + box.width / 2;
  const cy = box.y + box.height / 2;
  if (!isCircular) {
    return {
      x: cx + (signX * box.width) / 2,
      y: cy + (signY * box.height) / 2,
    };
  }
  const k = Math.SQRT1_2; // cos(45°) === sin(45°)
  return {
    x: cx + signX * (box.width / 2) * k,
    y: cy + signY * (box.height / 2) * k,
  };
}

export function verticalArcPath(
  sourceBox,
  targetBox,
  { sourceCircular = false, targetCircular = false } = {},
) {
  const sourceBottom = sourceBox.y + sourceBox.height;
  const sourceCenterX = sourceBox.x + sourceBox.width / 2;
  const targetCenterX = targetBox.x + targetBox.width / 2;

  // The common case, and the one that should apply almost always: the
  // target's top is at or below the source's bottom (the usual top-to-
  // bottom flow). A single horizontal leg at the midpoint is already
  // guaranteed clear of both boxes, since it's below the source's own
  // bottom edge and above the target's own top edge by construction.
  if (targetBox.y >= sourceBottom) {
    // A circular end (a place) has exactly one valid attachment point on
    // this side -- its own pole (center-x), the true "top"/"bottom" of
    // the circle -- and can't shift to line up with the other end; a
    // rectangular end (a transition), by contrast, can attach anywhere
    // along its flat edge, so it's free to shift and meet the other
    // end's x if that lands safely inside its own edge (inboard of each
    // corner by EDGE_CORNER_RADIUS, the same radius every bend in this
    // path already rounds to, so a "straight" line never reads as
    // clipping the corner). When both ends are rectangular, the source's
    // own center is preferred as the line's x (arbitrary but consistent
    // with which port the diagram reads as "primary"); if that can't be
    // met either, both ends fall back to their own centers and the path
    // bends between them.
    const fixedX = sourceCircular
      ? sourceCenterX
      : targetCircular
        ? targetCenterX
        : sourceCenterX;
    const flexBox = sourceCircular ? targetBox : sourceBox;
    const fitsFlexBox =
      !(sourceCircular && targetCircular) &&
      fixedX >= flexBox.x + EDGE_CORNER_RADIUS &&
      fixedX <= flexBox.x + flexBox.width - EDGE_CORNER_RADIUS;
    if (fitsFlexBox) {
      return [
        { x: fixedX, y: sourceBottom },
        { x: fixedX, y: targetBox.y },
      ];
    }
    const exit = { x: sourceCenterX, y: sourceBottom };
    const enter = { x: targetCenterX, y: targetBox.y };
    if (exit.x === enter.x) return [exit, enter];
    const midY = (exit.y + enter.y) / 2;
    return [exit, { x: exit.x, y: midY }, { x: enter.x, y: midY }, enter];
  }

  // The target isn't below the source. Two distinct shapes, chosen by
  // whether the boxes actually sit side by side with enough of a gap for
  // a short diagonal stub to clear the far one, or are more like a
  // reversed vertical pair (overlapping or merely touching x-ranges,
  // e.g. a straight-up return arc in a single column, or two boxes
  // pushed flush against each other):
  const xGap =
    sourceBox.x + sourceBox.width <= targetBox.x
      ? targetBox.x - (sourceBox.x + sourceBox.width)
      : targetBox.x + targetBox.width <= sourceBox.x
        ? sourceBox.x - (targetBox.x + targetBox.width)
        : -1; // overlapping

  if (xGap < ARC_DIAGONAL_STUB) {
    // A reversed-direction arc along a shared column, not a "beside"
    // pair -- a short diagonal corner-cut can't stay clear of both boxes
    // here: even when the x-ranges are technically disjoint, too small a
    // gap means the diagonal stub's fixed reach lands *inside* the far
    // box instead of past it (a real, confirmed case: two boxes pushed
    // flush against each other, zero gap). So route the long way around
    // instead: down from the source, out to a lane west of both, up past
    // the target, and in -- still leaving south and arriving north
    // (plain ports, no diagonal; the diagonal corner treatment below is
    // for the genuinely-beside case, with room for the stub to work).
    const exit = { x: sourceCenterX, y: sourceBottom };
    const enter = { x: targetCenterX, y: targetBox.y };
    // Both lane heights clear *both* boxes (not just the one nearer that
    // end), since this branch is no longer only reached when the target
    // is cleanly above the source -- once it also covers merely-touching
    // x-ranges (the Reg-test-4 fix), the two boxes can overlap
    // substantially in y too. A margin measured off only one box's own
    // edge (a real, swept-and-confirmed case) can then still sit inside
    // the *other* box, and the horizontal leg at that height cuts
    // straight through it.
    const belowY =
      Math.max(sourceBottom, targetBox.y + targetBox.height) + ARC_ROUTE_MARGIN;
    const aboveY = Math.min(sourceBox.y, targetBox.y) - ARC_ROUTE_MARGIN;
    const laneX = Math.min(sourceBox.x, targetBox.x) - ARC_ROUTE_MARGIN;
    return [
      exit,
      { x: exit.x, y: belowY },
      { x: laneX, y: belowY },
      { x: laneX, y: aboveY },
      { x: enter.x, y: aboveY },
      enter,
    ];
  }

  // Genuinely beside (disjoint x-ranges) -- the case this was actually
  // written for, e.g. a self-loop's return arc to a transition left or
  // right of its place rather than above/below it. A Petri arc is always
  // place<->transition (the bipartite rule), so exactly one end here is
  // circular; only that end gets the diagonal "leaves/arrives on its own
  // circle" treatment (`diagonalBoundaryPoint`, not the invisible
  // bounding-box corner) -- the other (a transition) keeps the same
  // plain south(if source)/north(if target) port the forward case above
  // already uses, since a rectangular box's edge midpoint is already a
  // clean perpendicular attachment with no need for a corner cut.
  //
  // The place's diagonal side (top when it's this arc's source, bottom
  // when it's the target) always matches the transition's plain port for
  // the same role (a transition-as-target already enters north/top; a
  // transition-as-source already exits south/bottom) -- so both ends of
  // any one arc land on the same side, above both boxes or below both.
  // A reciprocal arc swaps source and target, which swaps which end is
  // the place and therefore swaps top<->bottom too, so a loop-back pair
  // never lands on the same corner/port and never traces the same line.
  const sign = sourceCircular ? -1 : 1; // -1 = above both (top lane), 1 = below both (bottom lane)

  // Exactly one end is circular; the other is a plain rectangular port
  // with no bend of its own -- the diagonal stub is the *only* detour
  // this path needs, so the lane it turns onto is simply that stub's own
  // height (nudged out only if the straight end's own edge would
  // otherwise stick out past it), and the straight end connects to that
  // lane directly, with no bend of its own. (An earlier version gave the
  // straight end its own short vertical "bend" via ARC_ROUTE_MARGIN too,
  // then took the min/max of *both* bends as the lane -- but that margin
  // rarely lined up exactly with the diagonal stub's height, leaving a
  // near-zero-length leftover segment between them. Visually that read
  // as the diagonal overshooting into a spurious vertical hop before
  // snapping back to horizontal, and the degenerate segment gave canvas
  // arcTo an undefined direction to round against, so the next corner
  // rendered sharp instead of curved.)
  const circularBox = sourceCircular ? sourceBox : targetBox;
  const straightBox = sourceCircular ? targetBox : sourceBox;
  const signX = (
    sourceCircular
      ? targetCenterX >= sourceCenterX
      : sourceCenterX >= targetCenterX
  )
    ? 1
    : -1;
  const circularAnchor = diagonalBoundaryPoint(circularBox, true, signX, sign);
  const circularBend = {
    x: circularAnchor.x + signX * ARC_DIAGONAL_STUB,
    y: circularAnchor.y + sign * ARC_DIAGONAL_STUB,
  };
  const straightAnchor = {
    x: straightBox.x + straightBox.width / 2,
    y: sign < 0 ? straightBox.y : straightBox.y + straightBox.height,
  };
  const circularBendClears =
    sign < 0
      ? circularBend.y < straightAnchor.y
      : circularBend.y > straightAnchor.y;
  const laneY = circularBendClears
    ? circularBend.y
    : straightAnchor.y + sign * ARC_ROUTE_MARGIN;
  const lanePoint = { x: straightAnchor.x, y: laneY };
  // When the stub doesn't already clear the straight box's edge, jumping
  // straight from the bend to lanePoint would be a diagonal segment (they
  // no longer share a y) that can cut right through the straight box --
  // confirmed with a traced example where the stub landed well short of
  // the target's height, so the "shortcut" sliced through its top-left
  // corner on the way to the lane. Routing through an extra point at the
  // bend's own x first keeps every segment axis-aligned instead: that x
  // is always clear of the straight box (the diagonal stub can reach at
  // most STUB - circularBox.width/2 * (1 - k) past the circular box's own
  // edge, strictly less than ARC_DIAGONAL_STUB, and the gate above
  // already guarantees at least that much of a gap before this "beside"
  // shape is used at all), so the vertical leg down/up to the lane never
  // enters it, and the horizontal leg at the lane height is clear by the
  // same construction as the ordinary case.
  const path = circularBendClears
    ? [circularAnchor, circularBend, lanePoint]
    : [
        circularAnchor,
        circularBend,
        { x: circularBend.x, y: laneY },
        lanePoint,
      ];
  return sourceCircular
    ? [...path, straightAnchor]
    : [straightAnchor, ...path.slice().reverse()];
}

const EDGE_CORNER_RADIUS = 10;

// A user-added routing waypoint is just a point the edge must pass
// through -- representing it as a zero-size box lets orthogonalPath route
// to/from it (and between two of them) exactly like it already routes
// between two real boxes, with no separate point-to-point routing logic.
function pointBox(point) {
  return { x: point.x, y: point.y, width: 0, height: 0 };
}

// Chains orthogonalPath across every consecutive pair of anchors (real
// boxes and/or waypoint point-boxes) into one continuous route. Each
// segment's start point is the same as the previous segment's end point
// (both are the shared anchor's boundary/position), so every segment
// after the first drops its own first point to avoid duplicating it.
function buildRoutedPath(anchors) {
  let points = [];
  for (let i = 0; i < anchors.length - 1; i++) {
    const segment = orthogonalPath(anchors[i], anchors[i + 1]);
    points = points.length ? [...points, ...segment.slice(1)] : segment;
  }
  return points;
}

function pointToSegmentDistance(p, a, b) {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  const lengthSquared = dx * dx + dy * dy;
  const t =
    lengthSquared === 0
      ? 0
      : Math.max(
          0,
          Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared),
        );
  const projX = a.x + t * dx;
  const projY = a.y + t * dy;
  return Math.hypot(p.x - projX, p.y - projY);
}

// Where a newly double-clicked point should be inserted among an edge's
// existing waypoints: whichever straight segment (agent center -> each
// waypoint in order -> location center) it's closest to. Approximates
// against anchor *centers* rather than the actual rounded/orthogonal
// rendered path -- close enough to feel natural for picking a position,
// without needing to reproduce the rendering geometry here.
function nearestWaypointInsertIndex(point, anchorCenters) {
  let bestIndex = 0;
  let bestDistance = Infinity;
  for (let i = 0; i < anchorCenters.length - 1; i++) {
    const distance = pointToSegmentDistance(
      point,
      anchorCenters[i],
      anchorCenters[i + 1],
    );
    if (distance < bestDistance) {
      bestDistance = distance;
      bestIndex = i;
    }
  }
  return bestIndex;
}

function drawRoundedPolyline(ctx, points, radius) {
  ctx.beginPath();
  ctx.moveTo(points[0].x, points[0].y);
  for (let i = 1; i < points.length - 1; i++) {
    ctx.arcTo(
      points[i].x,
      points[i].y,
      points[i + 1].x,
      points[i + 1].y,
      radius,
    );
  }
  ctx.lineTo(points.at(-1).x, points.at(-1).y);
}

function arrowHeadPoints(tip, from, size = 9) {
  const angle = Math.atan2(tip.y - from.y, tip.x - from.x);
  const spread = Math.PI / 7;
  return [
    tip.x,
    tip.y,
    tip.x - size * Math.cos(angle - spread),
    tip.y - size * Math.sin(angle - spread),
    tip.x - size * Math.cos(angle + spread),
    tip.y - size * Math.sin(angle + spread),
  ];
}

export default class CanvasView extends Component {
  @service modelStore;
  @service selection;
  @service connectorTool;

  stage;
  shapeLayer;
  guideLayer;
  transformer;
  nodesById = new Map();
  marqueeRect;
  marqueeStart = null;
  // { x, y, items: [{label, action}] } in viewport pixel coords, or null
  // when no context menu is open.
  @tracked contextMenu = null;
  // A single copied/cut element's own properties (type/label/dashed/
  // channel) -- deliberately not its id, containment, or access edges, so
  // pasting always creates an independent element rather than something
  // that looks like an alias of the original.
  @tracked clipboard = null;
  @tracked zoom = 1;

  setupStage = modifier((element) => {
    this.stage = new Konva.Stage({
      container: element,
      width: element.clientWidth || 800,
      height: element.clientHeight || 600,
    });
    this.shapeLayer = new Konva.Layer();
    this.guideLayer = new Konva.Layer(); // guides are draggable
    this.transformer = new Konva.Transformer({
      // newBox is in screen px; MIN_SIZE is in diagram units
      boundBoxFunc: (oldBox, newBox) =>
        Math.min(newBox.width, newBox.height) / this.stage.scaleX() < MIN_SIZE
          ? oldBox
          : newBox,
      // Boxes stay axis-aligned -- rotation isn't persisted anywhere
      // (buildShape never reads back a rotation), so the handle Konva
      // shows by default did nothing but confuse users into thinking
      // rotation was a supported gesture.
      rotateEnabled: false,
    });
    this.stage.add(this.shapeLayer);
    this.stage.add(this.guideLayer);
    this.shapeLayer.add(this.transformer);

    // Canvas text is drawn with whatever font is *currently* loaded at
    // that exact instant -- unlike DOM text, it doesn't retroactively
    // re-render once a webfont finishes loading. Barlow is very likely
    // still loading on a cold page load (this modifier runs before
    // syncShapes' first draw), so without this every label would
    // silently render in the `sans-serif` fallback forever, even once
    // Barlow is available. One redraw once fonts are ready fixes it.
    document.fonts?.ready?.then(() => {
      if (!this.isDestroyed) this.shapeLayer?.batchDraw();
    });

    this.marqueeRect = new Konva.Rect({
      fill: 'rgba(0, 120, 255, 0.1)',
      stroke: '#0078ff',
      strokeWidth: 1,
      visible: false,
      listening: false,
    });
    this.guideLayer.add(this.marqueeRect);

    // Wheel/trackpad scroll pans the canvas -- there's otherwise no way
    // to reach content outside the initial viewport. Shift+wheel swaps
    // the axis, matching the common "shift scrolls horizontally"
    // convention for input devices (mice) that only report one axis.
    this.stage.on('wheel', (event) => {
      event.evt.preventDefault();
      const { deltaX, deltaY, shiftKey } = event.evt;
      const dx = shiftKey ? deltaY : deltaX;
      const dy = shiftKey ? 0 : deltaY;
      this.stage.x(this.stage.x() - dx);
      this.stage.y(this.stage.y() - dy);
      this.syncGridBackground();
      this.syncScrollbars();
      this.stage.batchDraw();
    });

    this.stage.on('mousedown', (event) => {
      if (event.evt.button !== 0) return; // right/middle click: not a marquee drag
      if (event.target !== this.stage) return;
      this.marqueeStart = this.stage.getRelativePointerPosition();
    });

    // Right-click on the empty canvas background -- per-shape/edge/handle
    // contextmenu handlers (buildShape, addRoutedEdge, syncEdgeHandles)
    // each cancelBubble their own, so this only ever fires for a genuine
    // background right-click.
    this.stage.on('contextmenu', (event) => {
      event.evt.preventDefault();
      if (event.target !== this.stage) return;
      const point = this.stage.getRelativePointerPosition();
      this.openContextMenu(event.evt, this.backgroundMenuItems(point));
    });

    this.stage.on('mousemove', () => {
      if (!this.marqueeStart) return;
      const pos = this.stage.getRelativePointerPosition();
      const x = Math.min(this.marqueeStart.x, pos.x);
      const y = Math.min(this.marqueeStart.y, pos.y);
      const width = Math.abs(pos.x - this.marqueeStart.x);
      const height = Math.abs(pos.y - this.marqueeStart.y);
      if (
        !this.marqueeRect.visible() &&
        Math.max(width, height) < MARQUEE_THRESHOLD
      )
        return;
      this.marqueeRect.setAttrs({ x, y, width, height, visible: true });
      this.guideLayer.batchDraw();
    });

    this.stage.on('mouseup', () => {
      if (!this.marqueeStart) return;
      const wasMarquee = this.marqueeRect.visible();
      if (wasMarquee) {
        const box = this.marqueeRect.getClientRect();
        const ids = [];
        for (const [id, node] of this.nodesById) {
          if (rectsIntersect(box, node.getClientRect())) ids.push(id);
        }
        this.selection.clear();
        for (const id of ids) this.selection.toggle(id);
      } else {
        this.selection.clear();
      }
      this.marqueeStart = null;
      this.marqueeRect.visible(false);
      this.guideLayer.batchDraw();
    });

    const resize = () => {
      this.stage.width(element.clientWidth);
      this.stage.height(element.clientHeight);
      this.syncScrollbars();
    };
    window.addEventListener('resize', resize);

    const keydown = (event) => {
      if (
        ['INPUT', 'TEXTAREA', 'SELECT'].includes(
          document.activeElement?.tagName,
        )
      )
        return;
      // Cmd on a Mac, Ctrl elsewhere -- either is accepted everywhere.
      if (event.metaKey || event.ctrlKey) {
        const command = {
          a: () => this.selectAll(),
          c: () => this.copySelection(),
          x: () => this.cutSelection(),
          v: () => this.pasteClipboard(null),
        }[event.key.toLowerCase()];
        if (command && this.modelStore.activeView) {
          event.preventDefault();
          command();
          return;
        }
      }
      if (event.key === 'Escape' && this.contextMenu) {
        this.contextMenu = null;
        return;
      }
      // Enter-to-rename doesn't depend on double-click/double-tap timing
      // at all -- useful since Konva suppresses click/dblclick on a
      // draggable node once it detects even a sub-pixel drag between the
      // two taps, which a trackpad's "double tap to click" triggers
      // easily.
      if (event.key === 'Enter') {
        const id = this.selection.selectedIds.at(-1);
        if (!id || this.selection.selectedIds.length !== 1) return;
        this.promptRename(id);
        return;
      }
      // Delete removes the selection from *this view only* -- the
      // elements stay in the model (and the tree), just not shown here.
      // Backspace deletes them from the model entirely (same as the
      // tree's own delete button), since diagramming tools commonly draw
      // that same distinction between the two keys. A selected *edge*
      // has no such view-vs-model split (an access edge only exists in
      // the model at all, same as the right-click menu's single "Delete
      // connector" action), so either key deletes it outright.
      if (event.key === 'Delete') {
        if (this.deleteSelectedEdge()) return;
        this.removeSelectionFromView();
      } else if (event.key === 'Backspace') {
        if (this.deleteSelectedEdge()) return;
        this.deleteSelectionFromModel();
      }
    };
    window.addEventListener('keydown', keydown);

    // Closes the context menu on any click that isn't on the menu itself
    // (a click *on* a menu item closes it via runMenuItem instead, right
    // after running the action) -- a right-click never fires a plain
    // 'click' DOM event, so opening a new menu never races with this.
    const closeContextMenu = (event) => {
      if (!this.contextMenu) return;
      if (event.target.closest?.('.canvas-context-menu')) return;
      this.contextMenu = null;
    };
    window.addEventListener('click', closeContextMenu);

    return () => {
      window.removeEventListener('resize', resize);
      window.removeEventListener('keydown', keydown);
      window.removeEventListener('click', closeContextMenu);
      this.stage.destroy();
    };
  });

  // Re-runs whenever the active view's membership/boxes (or the underlying
  // elements) change -- full teardown+rebuild of the shape layer. Simpler
  // and safer than incremental Konva-node diffing, and cheap enough at
  // diagram-sized element counts; interactive drag/resize never triggers
  // this mid-gesture since it only touches the tracked model on commit.
  syncShapes = modifier(() => {
    const view = this.modelStore.activeView;
    if (!this.shapeLayer) return;

    this.transformer.nodes([]);
    this.shapeLayer
      .find('.fumoco-shape, .fumoco-edge')
      .forEach((node) => node.destroy());
    this.nodesById.clear();

    if (!view) {
      this.drawPageFrame(null);
      this.drawGuides(null);
      this.shapeLayer.batchDraw();
      return;
    }

    const model = this.modelStore.model;
    const effectiveBoxes = computeEffectiveBoxes(model, view);
    this.drawPageFrame(effectiveBoxes);
    this.drawGuides(view);
    const displayChildren = buildDisplayChildIndex(model, view);
    const drawOrder = buildDrawOrder(model, view);

    for (const id of drawOrder) {
      const element = model.elements.get(id);
      const box = effectiveBoxes.get(id);
      if (!element || !box) continue;
      const hasNestedChildren = (displayChildren.get(id) ?? []).length > 0;
      const node = this.buildShape(element, box, view, {
        nested: hasNestedChildren,
      });
      this.nodesById.set(id, node);
      this.shapeLayer.add(node);
    }
    this.buildEdges(view, effectiveBoxes);
    this.buildArcs(view, effectiveBoxes);
    this.transformer.moveToTop();
    this.shapeLayer.batchDraw();
    // Deferred to the next runloop tick, *outside* this modifier's own
    // autotracking frame: attachTransformer/refreshNodeStyling/
    // refreshEdgeStyling all read `selection` state, and calling them
    // synchronously from inside syncShapes would make `selection` one of
    // *this modifier's* tracked dependencies too -- meaning merely
    // selecting something (any element, any edge) would re-run this
    // whole destroy-and-rebuild-everything modifier on every click. That
    // was silently happening: it doesn't corrupt state, but it destroys
    // and recreates every Konva node on each click, which breaks Konva's
    // own same-node double-click detection (a dblclick to insert an edge
    // waypoint would never fire, since the node under the second click is
    // a freshly-rebuilt one, not the node the first click landed on).
    // A queued microtask still applies current selection styling right
    // after a real rebuild, just without making the rebuild itself
    // reactive to selection changes -- `syncSelection`/`syncEdgeSelection`
    // already own reacting to those on their own. By the time this runs,
    // the modifier's own synchronous (and thus autotracked) extent has
    // already closed.
    queueMicrotask(() => {
      this.attachTransformer();
      this.refreshNodeStyling();
      this.refreshEdgeStyling();
      this.syncScrollbars();
    });
  });

  refreshEdges() {
    if (!this.shapeLayer) return;
    const view = this.modelStore.activeView;
    this.shapeLayer.find('.fumoco-edge').forEach((node) => node.destroy());
    if (view) {
      const effectiveBoxes = computeEffectiveBoxes(this.modelStore.model, view);
      this.buildEdges(view, effectiveBoxes);
      this.buildArcs(view, effectiveBoxes);
    }
    this.transformer.moveToTop();
    this.refreshEdgeStyling();
    this.shapeLayer.batchDraw();
  }

  buildEdges(view, effectiveBoxes) {
    const included = new Set(view.included);
    const model = this.modelStore.model;
    for (const access of model.accesses) {
      if (!included.has(access.agent) || !included.has(access.location))
        continue;
      const agentBox = effectiveBoxes.get(access.agent);
      const locationBox = effectiveBoxes.get(access.location);
      if (!agentBox || !locationBox) continue;
      const locationElement = model.elements.get(access.location);
      this.drawAccessEdge(access, agentBox, locationBox, locationElement, view);
    }
  }

  // Petri net and ER arcs -- much simpler than an access edge: always a
  // single directed leg from source to target, no read/write/modify kind,
  // no channel rendering, no routing waypoints (primitive support --
  // Milestone A's full connector treatment is deliberately not ported
  // here yet).
  buildArcs(view, effectiveBoxes) {
    const included = new Set(view.included);
    const model = this.modelStore.model;
    // relationId -> [{ attach, one }], one entry per ER arc, for
    // drawCardinalityArrow once every arc's route is known.
    const relationEnds = new Map();
    for (const arc of model.arcs) {
      if (!included.has(arc.source) || !included.has(arc.target)) continue;
      const sourceBox = effectiveBoxes.get(arc.source);
      const targetBox = effectiveBoxes.get(arc.target);
      if (!sourceBox || !targetBox) continue;
      const sourceType = model.elements.get(arc.source)?.type;
      const targetType = model.elements.get(arc.target)?.type;
      const isPetriArc =
        sourceType === ElementType.PLACE ||
        sourceType === ElementType.TRANSITION;
      const relationEnd =
        sourceType === ElementType.RELATION
          ? 'source'
          : targetType === ElementType.RELATION
            ? 'target'
            : null;
      const isPartitionArc =
        sourceType === ElementType.PARTITION ||
        targetType === ElementType.PARTITION;
      const path = this.drawArc(arc, sourceBox, targetBox, {
        vertical: isPetriArc,
        relationEnd,
        isPartitionArc,
        sourceCircular: sourceType === ElementType.PLACE,
        targetCircular: targetType === ElementType.PLACE,
      });
      if (relationEnd) {
        const relationId = relationEnd === 'target' ? arc.target : arc.source;
        const attach = relationEnd === 'target' ? path.at(-1) : path[0];
        if (!relationEnds.has(relationId)) relationEnds.set(relationId, []);
        relationEnds
          .get(relationId)
          .push({ attach, one: arc.cardinality === 'one' });
      }
    }
    for (const [relationId, ends] of relationEnds) {
      this.drawCardinalityArrow(
        effectiveBoxes.get(relationId),
        ends,
        Boolean(model.elements.get(relationId)?.label),
      );
    }
  }

  // FMC's 1:n / n:1 / 1:1 shorthand: one small thick arrow inside the
  // relation box, pointing toward each entity set that is the "1" side
  // (->, <-, <->). The connecting arcs themselves stay undirected. A
  // binary relation gets a single shaft between its two arcs' attach
  // points; an n-ary one gets a short arrow from the center toward each
  // "1" side instead.
  drawCardinalityArrow(box, ends, hasLabel) {
    if (!box || !ends.some((end) => end.one)) return;
    const mid = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
    // Always horizontal or vertical, whichever is nearer.
    const unit = (from, to) => {
      const dx = to.x - from.x;
      const dy = to.y - from.y;
      return Math.abs(dx) >= Math.abs(dy)
        ? { x: Math.sign(dx) || 1, y: 0 }
        : { x: 0, y: Math.sign(dy) };
    };
    // A shaft through the box center along `u`, sized to the box's
    // extent in that direction and, under a label, moved off the text:
    // below it for a horizontal arrow, beside it for a vertical one.
    const shaft = (u) => {
      const half = Math.min(
        0.3 * (Math.abs(u.x) * box.width + Math.abs(u.y) * box.height),
        20,
      );
      const horizontal = Math.abs(u.x) >= Math.abs(u.y);
      const c = {
        x: mid.x + (hasLabel && !horizontal ? box.width * 0.35 : 0),
        y: mid.y + (hasLabel && horizontal ? box.height / 4 : 0),
      };
      return [
        { x: c.x - u.x * half, y: c.y - u.y * half },
        { x: c.x + u.x * half, y: c.y + u.y * half },
      ];
    };
    const segments =
      ends.length === 2
        ? [
            [
              ...shaft(unit(ends[0].attach, ends[1].attach)),
              ends[1].one,
              ends[0].one,
            ],
          ]
        : ends
            .filter((end) => end.one)
            .map((end) => {
              // half a shaft: from its center out toward this "1" side
              const [back, tip] = shaft(unit(mid, end.attach));
              const tail = { x: (back.x + tip.x) / 2, y: (back.y + tip.y) / 2 };
              return [tail, tip, true, false];
            });
    // Heads per the FMC reference: nearly triangular with a slight
    // concave dent at the back; the shaft is as fine as the arcs and
    // stops inside the dent so it never blunts the tip.
    const HEAD_LENGTH = 10;
    const HEAD_HALF_WIDTH = 4.5;
    const HEAD_DENT = 2;
    const along = (p, u, d) => ({ x: p.x + u.x * d, y: p.y + u.y * d });
    for (const [from, to, headAtTo, headAtFrom] of segments) {
      const u = unit(from, to);
      const back = { x: -u.x, y: -u.y };
      const heads = [
        [to, back, headAtTo],
        [from, u, headAtFrom],
      ].filter(([, , show]) => show);
      const shaftStart = headAtFrom
        ? along(from, u, HEAD_LENGTH - HEAD_DENT)
        : from;
      const shaftEnd = headAtTo ? along(to, back, HEAD_LENGTH - HEAD_DENT) : to;
      this.shapeLayer.add(
        new Konva.Line({
          points: [shaftStart.x, shaftStart.y, shaftEnd.x, shaftEnd.y],
          stroke: '#000000',
          strokeWidth: 2,
          name: 'fumoco-edge',
          listening: false,
        }),
      );
      for (const [tip, inward] of heads) {
        const base = along(tip, inward, HEAD_LENGTH);
        const dent = along(tip, inward, HEAD_LENGTH - HEAD_DENT);
        const normal = { x: -inward.y, y: inward.x };
        this.shapeLayer.add(
          new Konva.Line({
            points: [
              tip.x,
              tip.y,
              base.x + normal.x * HEAD_HALF_WIDTH,
              base.y + normal.y * HEAD_HALF_WIDTH,
              dent.x,
              dent.y,
              base.x - normal.x * HEAD_HALF_WIDTH,
              base.y - normal.y * HEAD_HALF_WIDTH,
            ],
            closed: true,
            fill: '#000000',
            name: 'fumoco-edge',
            listening: false,
          }),
        );
      }
    }
  }

  drawArc(
    arc,
    sourceBox,
    targetBox,
    {
      vertical = false,
      relationEnd = null,
      isPartitionArc = false,
      sourceCircular = false,
      targetCircular = false,
    } = {},
  ) {
    const path = vertical
      ? verticalArcPath(sourceBox, targetBox, {
          sourceCircular,
          targetCircular,
        })
      : orthogonalPath(sourceBox, targetBox);
    // A plain ER arc (not partitioning, not Petri) can toggle its
    // cardinality; the other kinds don't have the concept.
    const isErArc = !vertical && !isPartitionArc && relationEnd;
    const mainShape = new Konva.Shape({
      stroke: '#000000',
      strokeWidth: 2,
      hitStrokeWidth: 16,
      name: 'fumoco-edge',
      sceneFunc: (ctx, shapeNode) => {
        drawRoundedPolyline(ctx, path, EDGE_CORNER_RADIUS);
        ctx.strokeShape(shapeNode);
      },
    });
    mainShape.on('contextmenu', (event) => {
      event.evt.preventDefault();
      event.cancelBubble = true;
      const items = [
        {
          label: 'Delete arc',
          action: () =>
            this.modelStore.mutate((model) => model.removeArc(arc.id)),
        },
      ];
      if (isErArc) {
        items.unshift({
          label:
            arc.cardinality === 'one'
              ? 'Unmark "1" side'
              : 'Mark entity set as "1" side',
          action: () =>
            this.modelStore.mutate((model) =>
              model.updateArcCardinality(
                arc.id,
                arc.cardinality === 'one' ? null : 'one',
              ),
            ),
        });
      }
      this.openContextMenu(event.evt, items);
    });
    this.shapeLayer.add(mainShape);
    // A partitioning arc is a plain line, no arrowhead -- the triangle
    // node itself (apex = the partitioned superset's side, base = each
    // part) already carries the meaning; an arrowhead would be redundant
    // and isn't part of the notation. ER arcs are undirected too (the
    // cardinality arrow lives inside the relation box, see
    // drawCardinalityArrow); only Petri arcs get the filled triangle.
    if (!isPartitionArc && !isErArc) {
      this.shapeLayer.add(
        new Konva.Line({
          points: arrowHeadPoints(path.at(-1), path.at(-2), 9),
          closed: true,
          fill: '#000000',
          name: 'fumoco-edge',
          listening: false,
        }),
      );
    }
    if (!isPartitionArc && arc.weight !== 1) {
      const mid = path[Math.floor(path.length / 2)];
      this.shapeLayer.add(
        new Konva.Text({
          x: mid.x,
          y: mid.y - 14,
          text: String(arc.weight),
          fontSize: 12,
          fontFamily: CANVAS_FONT_FAMILY,
          fill: '#000000',
          name: 'fumoco-edge',
          listening: false,
        }),
      );
    }
    return path;
  }

  // A single Konva.Shape drawing a rounded-corner rectilinear path (native
  // canvas arcTo does the rounding), plus separate small filled triangles
  // for whichever end(s) need an arrowhead -- Konva.Arrow doesn't support
  // rounded corners, so this replaces it for every routed edge. `edgeId`
  // and `view` are only needed to make the main path clickable (select the
  // edge) and dbl-clickable (insert a waypoint there) -- omitted for the
  // arrowhead triangles, which are purely decorative.
  addRoutedEdge(
    points,
    {
      arrowStart = false,
      arrowEnd = false,
      edgeId = null,
      view = null,
      // a different path than the rounded polyline (e.g. a lens)
      draw = (ctx) => drawRoundedPolyline(ctx, points, EDGE_CORNER_RADIUS),
    } = {},
  ) {
    const mainShape = new Konva.Shape({
      stroke: '#000000',
      strokeWidth: 2,
      hitStrokeWidth: 16, // a 2px line is hard to click on directly
      name: 'fumoco-edge',
      sceneFunc: (ctx, shapeNode) => {
        draw(ctx);
        ctx.strokeShape(shapeNode);
      },
    });
    if (edgeId) {
      mainShape.setAttr('fumocoEdgeId', edgeId);
      mainShape.setAttr('fumocoEdgeMain', true);
      mainShape.on('click', (event) => {
        event.cancelBubble = true;
        this.selection.selectEdge(edgeId);
      });
      mainShape.on('dblclick dbltap', (event) => {
        event.cancelBubble = true;
        if (!view) return;
        const point = this.stage.getRelativePointerPosition();
        this.insertWaypoint(edgeId, view, point);
      });
      mainShape.on('contextmenu', (event) => {
        event.evt.preventDefault();
        event.cancelBubble = true;
        if (!view) return;
        this.selection.selectEdge(edgeId);
        const point = this.stage.getRelativePointerPosition();
        this.openContextMenu(
          event.evt,
          this.edgeMenuItems(edgeId, view, point),
        );
      });
    }
    this.shapeLayer.add(mainShape);
    if (arrowEnd) {
      this.shapeLayer.add(
        new Konva.Line({
          points: arrowHeadPoints(points.at(-1), points.at(-2)),
          closed: true,
          fill: '#000000',
          name: 'fumoco-edge',
          listening: false,
        }),
      );
    }
    if (arrowStart) {
      this.shapeLayer.add(
        new Konva.Line({
          points: arrowHeadPoints(points[0], points[1]),
          closed: true,
          fill: '#000000',
          name: 'fumoco-edge',
          listening: false,
        }),
      );
    }
  }

  // A channel's place (locationElement.channel set) is agent<->location
  // access like any other, just rendered differently: a shorthand place's
  // label glyph (e.g. "R▶") carries direction itself, so its edges never
  // get arrowheads; a plain channel place still gets the ordinary
  // read/write arrowhead on each leg (which is what makes two such edges
  // meeting at one place look like "arrow-circle-arrow"). Modify access to
  // a channel place draws as a plain line (line-circle-line, no
  // arrowheads) instead of the double-headed curved arrow used for modify
  // access to an ordinary storage location.
  //
  // Routing: `view.edgeWaypoints` stores each edge's user-added points in
  // a fixed agent-to-location order regardless of which way it visually
  // draws; `orderedWaypoints` below re-orders them to match whichever end
  // is actually `from`/`to` for this access kind (read draws
  // location-to-agent) before chaining them into the path.
  drawAccessEdge(access, agentBox, locationBox, locationElement, view) {
    const isChannel = !!locationElement?.channel;
    const suppressArrow = locationElement?.channel?.shorthand === true;
    const waypoints = [...(view.edgeWaypoints.get(access.id) ?? [])];
    const lens =
      access.kind === 'modify' &&
      access.lens &&
      !isChannel &&
      !waypoints.length &&
      lensEnds(agentBox, locationBox);
    if (lens) {
      this.drawLensEdge(access.id, lens, view);
      return;
    }
    if (access.kind === 'modify') {
      const path = buildRoutedPath([
        agentBox,
        ...waypoints.map(pointBox),
        locationBox,
      ]);
      this.addRoutedEdge(path, {
        ...(isChannel ? {} : { arrowStart: true, arrowEnd: true }),
        edgeId: access.id,
        view,
      });
      return;
    }
    const [from, to] =
      access.kind === 'read'
        ? [locationBox, agentBox]
        : [agentBox, locationBox];
    const orderedWaypoints =
      access.kind === 'read' ? waypoints.reverse() : waypoints;
    const path = buildRoutedPath([from, ...orderedWaypoints.map(pointBox), to]);
    this.addRoutedEdge(path, {
      arrowEnd: !suppressArrow,
      edgeId: access.id,
      view,
    });
  }

  // A modify edge as a lens: two curves between the facing sides' points,
  // bowing opposite ways, one arrowhead each -- agent-to-location on one,
  // location-to-agent on the other.
  drawLensEdge(edgeId, { p, q, span }, view) {
    const length = Math.hypot(q.x - p.x, q.y - p.y);
    const normal = { x: -(q.y - p.y) / length, y: (q.x - p.x) / length };
    // control point 2x the bulge out, so the curve's apex bows by `bulge`
    const bulge = Math.min(length * 0.3, span / 2, 24);
    const mid = { x: (p.x + q.x) / 2, y: (p.y + q.y) / 2 };
    const [c1, c2] = [1, -1].map((side) => ({
      x: mid.x + normal.x * 2 * bulge * side,
      y: mid.y + normal.y * 2 * bulge * side,
    }));
    this.addRoutedEdge([p, q], {
      edgeId,
      view,
      draw: (ctx) => {
        ctx.beginPath();
        ctx.moveTo(p.x, p.y);
        ctx.quadraticCurveTo(c1.x, c1.y, q.x, q.y);
        ctx.moveTo(q.x, q.y);
        ctx.quadraticCurveTo(c2.x, c2.y, p.x, p.y);
      },
    });
    for (const [tip, control] of [
      [q, c1],
      [p, c2],
    ]) {
      this.shapeLayer.add(
        new Konva.Line({
          points: arrowHeadPoints(tip, control),
          closed: true,
          fill: '#000000',
          name: 'fumoco-edge',
          listening: false,
        }),
      );
    }
  }

  // Inserts a new waypoint at `point`, positioned among the edge's
  // existing waypoints by proximity (see nearestWaypointInsertIndex),
  // always stored in agent-to-location order regardless of draw direction
  // (drawAccessEdge re-orders for display -- see its comment).
  insertWaypoint(edgeId, view, point) {
    const model = this.modelStore.model;
    const access = model.accesses.find((a) => a.id === edgeId);
    if (!access) return;
    const effectiveBoxes = computeEffectiveBoxes(model, view);
    const agentBox = effectiveBoxes.get(access.agent);
    const locationBox = effectiveBoxes.get(access.location);
    if (!agentBox || !locationBox) return;
    this.modelStore.mutate(() => {
      if (!view.edgeWaypoints.has(edgeId)) {
        view.edgeWaypoints.set(edgeId, new TrackedArray());
      }
      const waypoints = view.edgeWaypoints.get(edgeId);
      const anchorCenters = [
        {
          x: agentBox.x + agentBox.width / 2,
          y: agentBox.y + agentBox.height / 2,
        },
        ...waypoints,
        {
          x: locationBox.x + locationBox.width / 2,
          y: locationBox.y + locationBox.height / 2,
        },
      ];
      const index = nearestWaypointInsertIndex(point, anchorCenters);
      waypoints.splice(index, 0, { x: point.x, y: point.y });
    });
    this.refreshEdges();
    this.syncEdgeHandles();
  }

  removeWaypoint(edgeId, view, index) {
    this.modelStore.mutate(() => {
      view.edgeWaypoints.get(edgeId)?.splice(index, 1);
    });
    this.refreshEdges();
    this.syncEdgeHandles();
  }

  // Re-runs on selection changes only, without touching shape geometry.
  // The Transformer (resize handles) only ever attaches to a *single*
  // selected node (see attachTransformer) -- multi-select would otherwise
  // have zero visual feedback, so every selected shape also gets an
  // explicit highlight border here, independent of the Transformer.
  syncSelection = modifier(() => {
    this.attachTransformer();
    this.refreshNodeStyling();
  });

  // Re-runs whenever the selected edge changes -- highlights its path and
  // (re)builds its draggable waypoint handles. A separate modifier from
  // syncSelection since edge selection and element selection are mutually
  // exclusive but independently tracked (see selection.js).
  //
  // Deferred to a queued microtask for the same reason syncShapes defers
  // its own selection-dependent calls: syncEdgeHandles reads
  // `view.edgeWaypoints`, and calling it synchronously here would make
  // *this modifier* depend on that tracked array too -- so dragging a
  // handle (which live-writes into that same array on every `dragmove`,
  // for immediate visual feedback) would re-fire this modifier on every
  // pixel of the drag, destroying and recreating the very handle Konva is
  // in the middle of dragging. That's exactly what made dragging (and,
  // transitively, double-clicking to remove a handle right after
  // dragging one) feel broken. Queuing the read outside this modifier's
  // synchronous extent breaks that dependency without losing the
  // "reflect the current selection right when it changes" behavior.
  syncEdgeSelection = modifier(() => {
    void this.selection.selectedEdgeId;
    queueMicrotask(() => {
      this.refreshEdgeStyling();
      this.syncEdgeHandles();
    });
  });

  // Re-runs whenever the armed connector kind or its pending source changes
  // -- dims elements that aren't valid picks for the current step, without
  // rebuilding the shape layer (so it doesn't disturb an in-progress drag).
  syncConnectorEligibility = modifier(() => {
    void this.connectorTool.kind;
    void this.connectorTool.pendingSourceId;
    this.refreshNodeStyling();
  });

  // Applies both the selection highlight (stroke) and the connector
  // eligibility dimming (opacity) to every current node. Called directly
  // from syncShapes after a rebuild (rather than having syncShapes write a
  // tracked "version" counter for the other modifiers to react to, which
  // is a backtracking-rerender violation -- Ember asserts if a tracked
  // value is written after being read earlier in the same render pass),
  // and from syncSelection/syncConnectorEligibility whenever selection or
  // the armed connector kind changes on their own.
  refreshNodeStyling() {
    const kind = this.connectorTool.kind;
    const pendingSourceId = this.connectorTool.pendingSourceId;
    for (const [id, node] of this.nodesById) {
      const element = this.modelStore.model.elements.get(id);
      node.opacity(
        this.isEligibleForConnector(element, id, kind, pendingSourceId)
          ? 1
          : 0.25,
      );
      const rect = node.findOne('.fumoco-body');
      if (!rect) continue;
      const selected = this.selection.isSelected(id);
      rect.stroke(selected ? '#0078ff' : '#000000');
      rect.strokeWidth(
        selected ? NODE_STROKE_WIDTH_SELECTED : NODE_STROKE_WIDTH,
      );
    }
    this.shapeLayer?.batchDraw();
  }

  isEligibleForConnector(element, id, kind, pendingSourceId) {
    if (!kind || !element) return true;
    const rule = connectorRule(kind);
    if (!pendingSourceId) return rule.source.includes(element.type);
    if (id === pendingSourceId) return false;
    return rule.target.includes(element.type);
  }

  // Highlights the selected edge's main path the same way a selected
  // node gets a blue stroke -- skips the arrowhead triangles (not tagged
  // `fumocoEdgeMain`), which stay solid black regardless of selection.
  refreshEdgeStyling() {
    if (!this.shapeLayer) return;
    const selectedId = this.selection.selectedEdgeId;
    this.shapeLayer.find('.fumoco-edge').forEach((node) => {
      if (!node.getAttr('fumocoEdgeMain')) return;
      const selected = node.getAttr('fumocoEdgeId') === selectedId;
      node.stroke(selected ? '#0078ff' : '#000000');
      node.strokeWidth(selected ? 3 : 2);
    });
    this.shapeLayer.batchDraw();
  }

  // Small draggable circles at the selected edge's current waypoints (in
  // their stored agent-to-location order -- display order doesn't matter
  // here since each handle just needs to show/move its own point).
  // Rebuilt from scratch on every selection/edit rather than diffed, same
  // as the shape layer itself -- there are never more than a handful.
  syncEdgeHandles() {
    if (!this.shapeLayer) return;
    this.shapeLayer
      .find('.fumoco-edge-handle')
      .forEach((node) => node.destroy());
    const edgeId = this.selection.selectedEdgeId;
    const view = this.modelStore.activeView;
    if (!edgeId || !view) {
      this.shapeLayer.batchDraw();
      return;
    }
    const waypoints = view.edgeWaypoints.get(edgeId);
    if (!waypoints) {
      this.shapeLayer.batchDraw();
      return;
    }
    waypoints.forEach((point, index) => {
      const handle = new Konva.Circle({
        x: point.x,
        y: point.y,
        radius: 7, // a bit larger than the visual dot, easier to grab
        fill: '#0078ff',
        stroke: '#ffffff',
        strokeWidth: 1,
        draggable: true,
        name: 'fumoco-edge-handle',
      });
      handle.on('dragmove', () => {
        waypoints[index] = { x: handle.x(), y: handle.y() };
        this.refreshEdges();
        this.shapeLayer.batchDraw();
      });
      handle.on('dragend', () => {
        this.modelStore.mutate(() => {
          waypoints[index] = { x: handle.x(), y: handle.y() };
        });
        this.refreshEdges();
      });
      handle.on('click', (event) => {
        event.cancelBubble = true;
      });
      handle.on('dblclick dbltap', (event) => {
        event.cancelBubble = true;
        this.removeWaypoint(edgeId, view, index);
      });
      handle.on('contextmenu', (event) => {
        event.evt.preventDefault();
        event.cancelBubble = true;
        this.openContextMenu(
          event.evt,
          this.handleMenuItems(edgeId, view, index),
        );
      });
      this.shapeLayer.add(handle);
    });
    this.shapeLayer.batchDraw();
  }

  attachTransformer() {
    if (!this.transformer) return;
    const ids = this.selection.selectedIds;
    // A container gets the same 8 handles as a plain box (see buildShape's
    // nested transformend handler) -- resizing it just sets an explicit
    // view.boxes entry that computeEffectiveBoxes then prefers over
    // auto-fit as long as it's still big enough for the current children.
    const nodes =
      ids.length === 1 ? [this.nodesById.get(ids[0])].filter(Boolean) : [];
    this.transformer.nodes(nodes);
    this.transformer.getLayer()?.batchDraw();
  }

  // The bounding box over every element actually shown in this view
  // (post-nesting-fit, via computeEffectiveBoxes) -- what "export the
  // whole diagram" has to mean, since the canvas itself is an infinite
  // pannable surface with no fixed extent of its own.
  contentBounds(view) {
    const boxes = [
      ...computeEffectiveBoxes(this.modelStore.model, view).values(),
    ];
    if (!boxes.length) return null;
    const minX = Math.min(...boxes.map((b) => b.x));
    const minY = Math.min(...boxes.map((b) => b.y));
    const maxX = Math.max(...boxes.map((b) => b.x + b.width));
    const maxY = Math.max(...boxes.map((b) => b.y + b.height));
    return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
  }

  guideLine(axis, pos) {
    const far = 100000;
    return new Konva.Line({
      name: 'fumoco-guide',
      x: axis === 'x' ? pos : 0,
      y: axis === 'y' ? pos : 0,
      points: axis === 'x' ? [0, -far, 0, far] : [-far, 0, far, 0],
      stroke: '#2a9df4',
      strokeWidth: 1,
      hitStrokeWidth: 8,
      strokeScaleEnabled: false,
    });
  }

  // Guides are draggable along their own axis only; dropped back onto
  // the canvas edge strip they came from, they're removed.
  drawGuides(view) {
    this.guideLayer.find('.fumoco-guide').forEach((node) => node.destroy());
    (view?.guides ?? []).forEach((guide, index) => {
      const line = this.guideLine(guide.axis, guide.pos);
      line.draggable(true);
      line.dragBoundFunc((pos) =>
        guide.axis === 'x'
          ? { x: pos.x, y: line.absolutePosition().y }
          : { x: line.absolutePosition().x, y: pos.y },
      );
      line.on('mouseenter', () => {
        this.stage.container().style.cursor =
          guide.axis === 'x' ? 'col-resize' : 'row-resize';
      });
      line.on('mouseleave', () => {
        this.stage.container().style.cursor = '';
      });
      line.on('dragend', () => {
        const screen = line.absolutePosition();
        const removed =
          (guide.axis === 'x' ? screen.x : screen.y) < GUIDE_STRIP;
        const pos = snapToGrid(guide.axis === 'x' ? line.x() : line.y());
        this.stage.container().style.cursor = '';
        this.modelStore.mutate(() => {
          if (removed) view.guides.splice(index, 1);
          else view.guides.splice(index, 1, { axis: guide.axis, pos });
        });
      });
      this.guideLayer.add(line);
    });
    this.guideLayer.batchDraw();
  }

  // A drag handle needs mousedown, attached here rather than via {{on}}
  // (ember-template-lint rejects pointer-down bindings on a div).
  guideStrip = modifier((element, [axis]) => {
    const handler = (event) => this.startGuide(axis, event);
    element.addEventListener('mousedown', handler);
    return () => element.removeEventListener('mousedown', handler);
  });

  // Mousedown on the top (axis 'y') or left (axis 'x') edge strip: a new
  // guide follows the pointer and is added where it's released -- unless
  // that's still on the strip, which cancels it.
  startGuide(axis, event) {
    const view = this.modelStore.activeView;
    if (!view || !this.stage) return;
    event.preventDefault();
    const origin = this.stage.container().getBoundingClientRect();
    const toWorld = (evt) =>
      axis === 'x'
        ? (evt.clientX - origin.left - this.stage.x()) / this.stage.scaleX()
        : (evt.clientY - origin.top - this.stage.y()) / this.stage.scaleY();
    const line = this.guideLine(axis, toWorld(event));
    line.listening(false);
    this.guideLayer.add(line);
    this.guideLayer.batchDraw();
    const move = (evt) => {
      line[axis](toWorld(evt));
      this.guideLayer.batchDraw();
    };
    const up = (evt) => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      line.destroy();
      this.guideLayer.batchDraw();
      const screen =
        axis === 'x' ? evt.clientX - origin.left : evt.clientY - origin.top;
      if (screen < GUIDE_STRIP) return;
      this.modelStore.mutate(() => {
        view.guides.push({ axis, pos: snapToGrid(toWorld(evt)) });
      });
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  }

  // A faint dashed landscape-slide frame anchored at the diagram's
  // top-left; turns orange with a note once the content outgrows it.
  // Advisory only -- never blocks, never exported (guide layer).
  drawPageFrame(effectiveBoxes) {
    this.guideLayer.find('.fumoco-page').forEach((node) => node.destroy());
    const boxes = [...(effectiveBoxes?.values() ?? [])];
    if (!boxes.length) return this.guideLayer.batchDraw();
    const x = Math.min(...boxes.map((b) => b.x));
    const y = Math.min(...boxes.map((b) => b.y));
    const width = Math.max(...boxes.map((b) => b.x + b.width)) - x;
    const height = Math.max(...boxes.map((b) => b.y + b.height)) - y;
    const exceeds = width > PAGE_WIDTH || height > PAGE_HEIGHT;
    const color = exceeds ? '#e08a00' : '#a8a8a8';
    this.guideLayer.add(
      new Konva.Rect({
        name: 'fumoco-page',
        listening: false,
        x,
        y,
        width: PAGE_WIDTH,
        height: PAGE_HEIGHT,
        stroke: color,
        strokeWidth: 1,
        dash: [8, 6],
      }),
    );
    if (exceeds) {
      this.guideLayer.add(
        new Konva.Text({
          name: 'fumoco-page',
          listening: false,
          x,
          y: y - 18,
          text: 'Diagram exceeds a landscape slide',
          fontSize: 12,
          fontFamily: CANVAS_FONT_FAMILY,
          fill: color,
        }),
      );
    }
    this.guideLayer.batchDraw();
  }

  // Zooms around the viewport center, so whatever's in the middle of the
  // screen stays put.
  setZoom(next) {
    if (!this.stage) return;
    const zoom = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, next));
    const old = this.stage.scaleX();
    const center = { x: this.stage.width() / 2, y: this.stage.height() / 2 };
    const { x, y } = this.stage.position();
    this.stage.scale({ x: zoom, y: zoom });
    this.stage.position({
      x: center.x - ((center.x - x) / old) * zoom,
      y: center.y - ((center.y - y) / old) * zoom,
    });
    this.zoom = zoom;
    this.syncGridBackground();
    this.syncScrollbars();
    this.stage.batchDraw();
  }

  @action zoomIn() {
    this.setZoom(this.zoom * ZOOM_STEP);
  }

  @action zoomOut() {
    this.setZoom(this.zoom / ZOOM_STEP);
  }

  @action resetZoom() {
    this.setZoom(1);
  }

  get zoomLabel() {
    return `${Math.round(this.zoom * 100)}%`;
  }

  // Native scrollbars over a virtual extent: each bar is a thin overflow
  // strip whose spacer is the extent's size in screen px -- the diagram's
  // bounds plus one viewport of slack (half each side), always covering
  // the current viewport. Scrolling a bar pans the stage; panning or
  // zooming any other way moves the bars.
  scrollbar = modifier((element, [axis]) => {
    this.scrollbars[axis] = element;
    const onScroll = () => {
      const extent = this.scrollExtent;
      if (!extent || !this.stage) return;
      const scale = this.stage.scaleX();
      const offset = axis === 'x' ? element.scrollLeft : element.scrollTop;
      const next = -(extent[axis] * scale + offset);
      if (Math.abs(next - this.stage[axis]()) < 1) return; // our own sync
      this.stage[axis](next);
      this.syncGridBackground();
      this.stage.batchDraw();
    };
    element.addEventListener('scroll', onScroll);
    queueMicrotask(() => this.syncScrollbars());
    return () => {
      element.removeEventListener('scroll', onScroll);
      delete this.scrollbars[axis];
    };
  });

  scrollbars = {};

  syncScrollbars() {
    if (!this.stage) return;
    const scale = this.stage.scaleX();
    const viewport = {
      x: -this.stage.x() / scale,
      y: -this.stage.y() / scale,
      width: this.stage.width() / scale,
      height: this.stage.height() / scale,
    };
    const view = this.modelStore.activeView;
    const content = view && this.contentBounds(view);
    const areas = [viewport];
    if (content) {
      areas.push({
        x: content.x - viewport.width / 2,
        y: content.y - viewport.height / 2,
        width: content.width + viewport.width,
        height: content.height + viewport.height,
      });
    }
    const x = Math.min(...areas.map((a) => a.x));
    const y = Math.min(...areas.map((a) => a.y));
    const extent = {
      x,
      y,
      width: Math.max(...areas.map((a) => a.x + a.width)) - x,
      height: Math.max(...areas.map((a) => a.y + a.height)) - y,
    };
    this.scrollExtent = extent;
    const { x: barX, y: barY } = this.scrollbars;
    if (barX) {
      barX.firstElementChild.style.width = `${extent.width * scale}px`;
      barX.scrollLeft = (viewport.x - extent.x) * scale;
    }
    if (barY) {
      barY.firstElementChild.style.height = `${extent.height * scale}px`;
      barY.scrollTop = (viewport.y - extent.y) * scale;
    }
  }

  // The dotted grid is a CSS background on the container; keep it
  // aligned with the stage's pan and zoom so snapped boxes sit on dots.
  syncGridBackground() {
    const style = this.stage.container().style;
    const step = GRID * this.stage.scaleX();
    style.backgroundSize = `${step}px ${step}px`;
    style.backgroundPosition = `${this.stage.x()}px ${this.stage.y()}px`;
  }

  // Title, authors and dates above an exported diagram, separated from
  // it by a thin rule. Built at the origin; the caller positions it.
  buildExportHeader(view) {
    const header = new Konva.Group({ listening: false });
    const lines = [
      { text: view.name || 'Untitled view', fontSize: 18, fontStyle: 'bold' },
      {
        text: `Author: ${view.author || '—'} · Contributors: ${view.contributors || '—'}`,
      },
      {
        text: `Created: ${formatDate(view.createdAt, { withTime: false })} · Last modified: ${formatDate(view.updatedAt, { withTime: false })}`,
      },
    ];
    let y = 0;
    for (const { text, fontSize = 12, fontStyle = 'normal' } of lines) {
      header.add(
        new Konva.Text({
          y,
          text,
          fontSize,
          fontStyle,
          fontFamily: CANVAS_FONT_FAMILY,
          fill: fontSize === 12 ? '#555555' : '#000000',
        }),
      );
      y += fontSize + 6;
    }
    return header;
  }

  // Export covers the whole diagram, not just whatever's currently
  // scrolled into view: temporarily resize/reposition the stage to fit
  // the full content plus a header (buildExportHeader), on a white page
  // behind everything -- the stage itself has no background, and an
  // export must never come out transparent. Runs `render(width,
  // height)`, then restores. Synchronous start to finish, so it never
  // paints on screen.
  withExportStage(render) {
    const view = this.modelStore.activeView;
    if (!this.stage || !view) return null;
    const content = this.contentBounds(view);
    if (!content) return null;
    const margin = 20;
    const headerGap = 16;
    const header = this.buildExportHeader(view);
    const headerSize = header.getClientRect({ skipTransform: true });
    header.position({
      x: content.x,
      y: content.y - headerGap - headerSize.height,
    });
    // "Fumoco vX.Y.Z", right-aligned on the title line.
    const credit = new Konva.Text({
      text: `Fumoco v${config.APP.version}`,
      fontSize: 12,
      fontFamily: CANVAS_FONT_FAMILY,
      fill: '#999999',
    });
    const bounds = {
      x: content.x,
      y: header.y(),
      width: Math.max(
        content.width,
        headerSize.width,
        header.findOne('Text').width() + 24 + credit.width(),
      ),
      height: content.height + headerGap + headerSize.height,
    };
    credit.position({ x: bounds.width - credit.width(), y: 4 });
    header.add(credit);
    header.add(
      new Konva.Line({
        points: [
          0,
          headerSize.height + headerGap / 2,
          bounds.width,
          headerSize.height + headerGap / 2,
        ],
        stroke: '#cccccc',
        strokeWidth: 1,
      }),
    );
    this.shapeLayer.add(header);
    const width = bounds.width + margin * 2;
    const height = bounds.height + margin * 2;

    const originalPos = { x: this.stage.x(), y: this.stage.y() };
    const originalScale = this.stage.scale();
    this.stage.scale({ x: 1, y: 1 }); // export at 100%, whatever the zoom
    const originalSize = {
      width: this.stage.width(),
      height: this.stage.height(),
    };
    this.transformer.nodes([]); // hide selection handles for the export
    this.guideLayer.hide(); // page frame, marquee
    this.stage.position({ x: -bounds.x + margin, y: -bounds.y + margin });
    this.stage.size({ width, height });
    const background = new Konva.Rect({
      x: bounds.x - margin,
      y: bounds.y - margin,
      width,
      height,
      fill: '#ffffff',
      listening: false,
    });
    this.shapeLayer.add(background);
    background.moveToBottom();
    this.stage.batchDraw();

    try {
      return render(width, height);
    } finally {
      background.destroy();
      header.destroy();
      this.guideLayer.show();
      this.stage.scale(originalScale);
      this.stage.position(originalPos);
      this.stage.size(originalSize);
      this.attachTransformer();
      this.stage.batchDraw();
    }
  }

  download(href, extension) {
    const view = this.modelStore.activeView;
    const link = document.createElement('a');
    link.href = href;
    link.download = `${(view.name || 'fumoco-view').replace(/[^a-z0-9_-]+/gi, '_')}.${extension}`;
    link.click();
  }

  @action
  exportPng() {
    const dataUrl = this.withExportStage(() =>
      this.stage.toDataURL({ pixelRatio: 2, mimeType: 'image/png' }),
    );
    if (dataUrl) this.download(dataUrl, 'png');
  }

  // Vector export: Konva has no SVG output of its own, so the shape layer
  // is redrawn once into svgcanvas's recording 2D context -- same draw
  // code as the canvas (custom edge sceneFuncs included), SVG out.
  @action
  exportSvg() {
    const svg = this.withExportStage((width, height) => {
      const canvas = this.shapeLayer.getCanvas();
      const context = canvas.getContext();
      const native = context._context;
      const recorder = new SvgContext(width, height);
      context._context = recorder;
      const pixelRatio = canvas.getPixelRatio();
      canvas.setPixelRatio(1);
      try {
        this.shapeLayer.drawScene();
      } finally {
        context._context = native;
        canvas.setPixelRatio(pixelRatio);
      }
      return recorder.getSerializedSvg(true);
    });
    if (!svg) return;
    const url = URL.createObjectURL(new Blob([svg], { type: 'image/svg+xml' }));
    this.download(url, 'svg');
    URL.revokeObjectURL(url);
  }

  promptRename(id) {
    const element = this.modelStore.model.elements.get(id);
    if (!element) return;
    // A native prompt is the deliberately lazy choice here over an
    // in-canvas HTML overlay input -- revisit if inline editing turns out
    // to matter enough to justify the extra positioning/z-index code.
    const next = window.prompt('Rename element', element.label ?? '');
    if (next === null) return;
    this.modelStore.mutate(() => {
      element.label = next.trim() || null;
    });
  }

  // Deletes the selected access edge (if any), matching the right-click
  // menu's "Delete connector" action -- returns true when it handled the
  // key, so the keydown handler can skip the element-selection path
  // instead of also acting on whatever elements happen to be selected.
  deleteSelectedEdge() {
    const edgeId = this.selection.selectedEdgeId;
    if (!edgeId) return false;
    this.modelStore.mutate((model) => model.removeAccess(edgeId));
    this.selection.clear();
    return true;
  }

  removeSelectionFromView() {
    const view = this.modelStore.activeView;
    const ids = [...this.selection.selectedIds];
    if (!view || !ids.length) return;
    this.modelStore.mutate(() => {
      for (const id of ids) {
        const index = view.included.indexOf(id);
        if (index !== -1) view.included.splice(index, 1);
        view.boxes.delete(id);
      }
    });
    this.selection.clear();
  }

  deleteSelectionFromModel() {
    const ids = [...this.selection.selectedIds];
    if (!ids.length) return;
    this.modelStore.mutate((model) => {
      for (const id of ids) model.removeElement(id);
    });
    this.selection.clear();
  }

  // Back to each selected box's type default, keeping its center. A
  // container's manual size is dropped, so it auto-fits again.
  resetSelectionSize() {
    const view = this.modelStore.activeView;
    if (!view) return;
    const model = this.modelStore.model;
    const containers = new Set(
      [...buildDisplayChildIndex(model, view)]
        .filter(([, children]) => children.length)
        .map(([id]) => id),
    );
    this.modelStore.mutate(() => {
      for (const id of this.selection.selectedIds) {
        const box = view.boxes.get(id);
        if (!box) continue;
        if (containers.has(id)) {
          view.boxes.delete(id);
          continue;
        }
        const { width, height } = defaultBoxSize(model.elements.get(id));
        view.boxes.set(id, {
          x: snapToGrid(box.x + box.width / 2 - width / 2),
          y: snapToGrid(box.y + box.height / 2 - height / 2),
          width,
          height,
        });
      }
    });
  }

  selectAll() {
    const view = this.modelStore.activeView;
    if (!view) return;
    this.selection.clear();
    for (const id of view.included) this.selection.toggle(id);
  }

  // Copies the selected elements (with their boxes, as stored) and every
  // access edge / arc running between two of them. Nesting isn't copied.
  copySelection() {
    const view = this.modelStore.activeView;
    const model = this.modelStore.model;
    const ids = this.selection.selectedIds.filter((id) =>
      view?.included.includes(id),
    );
    if (!ids.length) return;
    const copied = new Set(ids);
    const boxes = computeEffectiveBoxes(model, view);
    this.clipboard = {
      elements: ids.map((id) => {
        const element = model.elements.get(id);
        return {
          id,
          type: element.type,
          label: element.label,
          dashed: element.dashed,
          channel: element.channel ? { ...element.channel } : null,
          tokens: element.tokens,
          isStart: element.isStart,
          isNop: element.isNop,
          fill: element.fill,
          multiple: element.multiple,
          box: toStoredBox(boxes.get(id)),
        };
      }),
      accesses: model.accesses
        .filter((a) => copied.has(a.agent) && copied.has(a.location))
        .map((a) => ({ ...a })),
      arcs: model.arcs
        .filter((a) => copied.has(a.source) && copied.has(a.target))
        .map((a) => ({ ...a })),
      pastes: 0,
    };
  }

  cutSelection() {
    this.copySelection();
    if (this.clipboard) this.deleteSelectionFromModel();
  }

  // Pastes the clipboard as fresh elements, connections included: centered
  // on `point` (context menu), or -- from the keyboard, point = null --
  // offset 20px further from the originals with each paste. The pasted
  // elements become the selection.
  pasteClipboard(point) {
    const clip = this.clipboard;
    const view = this.modelStore.activeView;
    if (!clip || !view) return;
    const boxes = clip.elements.map((e) => e.box);
    let dx;
    let dy;
    if (point) {
      const minX = Math.min(...boxes.map((b) => b.x));
      const minY = Math.min(...boxes.map((b) => b.y));
      const maxX = Math.max(...boxes.map((b) => b.x + b.width));
      const maxY = Math.max(...boxes.map((b) => b.y + b.height));
      dx = snapToGrid(point.x - (minX + maxX) / 2);
      dy = snapToGrid(point.y - (minY + maxY) / 2);
    } else {
      clip.pastes += 1;
      dx = dy = GRID * 2 * clip.pastes;
    }
    const newIds = new Map();
    this.modelStore.mutate((model) => {
      for (const { id, box, ...props } of clip.elements) {
        const newId = model.addElement(props.type, {
          ...props,
          channel: props.channel ? { ...props.channel } : null,
        });
        newIds.set(id, newId);
        view.included.push(newId);
        view.boxes.set(newId, { ...box, x: box.x + dx, y: box.y + dy });
      }
      for (const a of clip.accesses) {
        model.addAccess(newIds.get(a.agent), a.kind, newIds.get(a.location));
      }
      for (const a of clip.arcs) {
        model.addArc(newIds.get(a.source), newIds.get(a.target), a.weight, {
          cardinality: a.cardinality,
        });
      }
    });
    this.selection.clear();
    for (const newId of newIds.values()) this.selection.toggle(newId);
  }

  // Runs a context-menu item's action then always closes the menu --
  // separate from the window-level `closeContextMenu` click listener,
  // which only closes it on a click *outside* the menu (a click on an
  // item is "inside" as far as that listener is concerned).
  @action
  runMenuItem(itemAction) {
    itemAction();
    this.contextMenu = null;
  }

  // Sets the menu's viewport position imperatively rather than through a
  // template `style="..."` attribute (disallowed by ember-template-lint's
  // no-inline-styles rule) -- functionally identical, just expressed as a
  // tiny element modifier instead.
  positionContextMenu = modifier((element, [x, y]) => {
    element.style.left = `${x}px`;
    element.style.top = `${y}px`;
  });

  openContextMenu(domEvent, items) {
    if (!items.length) return;
    this.contextMenu = { x: domEvent.clientX, y: domEvent.clientY, items };
  }

  // Cut/copy/paste entries shared by the element and background menus.
  clipboardMenuItems(point, { withCutCopy }) {
    const items = [];
    if (withCutCopy) {
      items.push(
        {
          label: 'Cut',
          shortcut: shortcut('X'),
          action: () => this.cutSelection(),
        },
        {
          label: 'Copy',
          shortcut: shortcut('C'),
          action: () => this.copySelection(),
        },
      );
    }
    if (this.clipboard) {
      items.push({
        label: 'Paste',
        shortcut: shortcut('V'),
        action: () => this.pasteClipboard(point),
      });
    }
    return items;
  }

  elementMenuItems(id, point) {
    const element = this.modelStore.model.elements.get(id);
    const items = [
      { label: 'Rename', action: () => this.promptRename(id) },
      ...this.clipboardMenuItems(point, { withCutCopy: true }),
      { label: 'Reset size', action: () => this.resetSelectionSize() },
    ];
    if (element?.type === ElementType.RELATION) {
      items.push({
        label: 'Reify into entity set',
        action: () => this.reifyRelation(id),
      });
    }
    items.push(
      {
        label: 'Delete from view',
        action: () => this.removeSelectionFromView(),
      },
      {
        label: 'Delete from model',
        action: () => this.deleteSelectionFromModel(),
      },
    );
    return items;
  }

  // Nests the relation inside a freshly-created entity set (see
  // FmcModel.reifyRelation's comment) and also displays it nested in the
  // active view -- same "establish the relationship in both the model
  // and this view's display" convention drag-to-nest and the properties
  // panel's "Add to container" already follow.
  reifyRelation(relationId) {
    const view = this.modelStore.activeView;
    this.modelStore.mutate((model) => {
      const entitySetId = model.reifyRelation(relationId);
      if (view) {
        // No stored box: the entity set auto-fits around the relation as
        // a circle (see computeEffectiveBoxes).
        view.included.push(entitySetId);
        view.nestedUnder.set(relationId, entitySetId);
      }
      this.selection.select(entitySetId);
    });
  }

  edgeMenuItems(edgeId, view, point) {
    const access = this.modelStore.model.accesses.find((a) => a.id === edgeId);
    const lensItem =
      access?.kind === 'modify'
        ? [
            {
              label: access.lens
                ? 'Draw as straight line'
                : 'Draw as two curved arrows',
              action: () =>
                this.modelStore.mutate((model) =>
                  model.setAccessLens(edgeId, !access.lens),
                ),
            },
          ]
        : [];
    return [
      ...lensItem,
      {
        label: 'Insert waypoint here',
        action: () => this.insertWaypoint(edgeId, view, point),
      },
      {
        label: 'Delete connector',
        action: () => {
          this.modelStore.mutate((model) => model.removeAccess(edgeId));
          if (this.selection.selectedEdgeId === edgeId) this.selection.clear();
        },
      },
    ];
  }

  handleMenuItems(edgeId, view, index) {
    return [
      {
        label: 'Remove point',
        action: () => this.removeWaypoint(edgeId, view, index),
      },
    ];
  }

  backgroundMenuItems(point) {
    return [
      ...this.clipboardMenuItems(point, { withCutCopy: false }),
      {
        label: 'Select all',
        shortcut: shortcut('A'),
        action: () => this.selectAll(),
      },
    ];
  }

  handleConnectorClick(id) {
    const tool = this.connectorTool;
    if (!tool.pendingSourceId) {
      if (
        !this.isEligibleForConnector(
          this.modelStore.model.elements.get(id),
          id,
          tool.kind,
          null,
        )
      )
        return;
      tool.pendingSourceId = id;
      return;
    }
    if (id === tool.pendingSourceId) return; // can't connect an element to itself
    if (
      !this.isEligibleForConnector(
        this.modelStore.model.elements.get(id),
        id,
        tool.kind,
        tool.pendingSourceId,
      )
    ) {
      return;
    }
    const sourceId = tool.pendingSourceId;
    tool.pendingSourceId = null;
    const view = this.modelStore.activeView;
    try {
      this.modelStore.mutate((model) => {
        switch (tool.kind) {
          case ConnectorKind.READ:
            return model.addAccess(sourceId, 'read', id);
          case ConnectorKind.WRITE:
            return model.addAccess(sourceId, 'write', id);
          case ConnectorKind.MODIFY:
            return model.addAccess(sourceId, 'modify', id);
          case ConnectorKind.CHANNEL_DIRECTED:
            return this.placeChannelElementsInView(view, sourceId, id, [
              model.addChannel(sourceId, id, true),
            ]);
          case ConnectorKind.CHANNEL_BIDIRECTIONAL:
            return this.placeChannelElementsInView(view, sourceId, id, [
              model.addChannel(sourceId, id, false),
            ]);
          case ConnectorKind.REQRES_LONG:
            return this.placeChannelElementsInView(
              view,
              sourceId,
              id,
              model.addReqRes(sourceId, id, { shorthand: false }),
            );
          case ConnectorKind.REQRES_SHORTHAND:
            return this.placeChannelElementsInView(
              view,
              sourceId,
              id,
              model.addReqRes(sourceId, id, { shorthand: true }),
            );
          case ConnectorKind.ARC:
            return model.addArc(sourceId, id);
          default:
            throw new FmcModelError(`unknown connector kind: ${tool.kind}`);
        }
      });
    } catch (error) {
      if (error instanceof FmcModelError) {
        window.alert(error.message);
      } else {
        throw error;
      }
    }
  }

  // A channel/reqres's place(s) are now ordinary Location elements (see
  // FmcModel.addChannel/addReqRes) -- they need an actual box in the
  // active view to be visible at all, unlike the old dedicated
  // Channel/channelPlaces concept. Default position: the midpoint between
  // source and target, offset sideways per place so a req/res pair
  // doesn't start out overlapping. Freely draggable afterward, like any
  // other element.
  placeChannelElementsInView(view, sourceId, targetId, placeIds) {
    if (!view) return;
    const sourceBox = view.boxes.get(sourceId);
    const targetBox = view.boxes.get(targetId);
    const midX =
      sourceBox && targetBox
        ? (sourceBox.x +
            sourceBox.width / 2 +
            targetBox.x +
            targetBox.width / 2) /
          2
        : 200;
    const midY =
      sourceBox && targetBox
        ? (sourceBox.y +
            sourceBox.height / 2 +
            targetBox.y +
            targetBox.height / 2) /
          2
        : 200;
    const size = 28;
    placeIds.forEach((placeId, index) => {
      view.included.push(placeId);
      view.boxes.set(placeId, {
        x:
          midX -
          size / 2 +
          index * (size + 10) -
          ((placeIds.length - 1) * (size + 10)) / 2,
        y: midY - size / 2,
        width: size,
        height: size,
      });
    });
  }

  // `nested`: this element has at least one child also present in the
  // view, so `box` is an auto-computed bounding box around those children
  // (see computeEffectiveBoxes) unless a manual resize (below) is still big
  // enough to contain them, in which case that wins instead -- either way
  // it's drawn as a container, with its label moved to the top-left corner
  // so it doesn't sit on top of the nested content. Dragging it moves every
  // currently-visible descendant along with it by the same delta (see the
  // dragmove/dragend handlers below), same as always; a manual resize (via
  // the same 8 handles a plain box gets -- see the shared `transformend`
  // handler) is a separate, independent action from that move.
  buildShape(element, box, view, { nested = false } = {}) {
    const group = new Konva.Group({
      x: box.x,
      y: box.y,
      draggable: true,
      name: 'fumoco-shape',
      id: element.id,
      // pos is absolute (screen) -- snap in diagram units, so the grid
      // (and guides) hold at any pan offset and zoom level
      dragBoundFunc: (pos) => {
        const scale = this.stage.scaleX();
        const { x, y } = this.stage.position();
        const snapped = snapBox(
          view.guides,
          {
            x: (pos.x - x) / scale,
            y: (pos.y - y) / scale,
            width: box.width,
            height: box.height,
          },
          GUIDE_SNAP / scale,
        );
        return { x: snapped.x * scale + x, y: snapped.y * scale + y };
      },
    });
    const isLocation = element.type === ElementType.LOCATION;
    const isChannel = !!element.channel;
    const isPlace = element.type === ElementType.PLACE;
    const isEntitySet = element.type === ElementType.ENTITY_SET;
    const isPartition = element.type === ElementType.PARTITION;
    const isNopTransition =
      element.type === ElementType.TRANSITION && element.isNop;
    // A channel's place, a Petri net place, or an ER entity set all use
    // the same trick: cornerRadius = half the *smaller* box dimension.
    // For a square box that reads as a perfect circle (channel/place);
    // for a wider-than-tall box it reads as a stadium/pill shape (two
    // half-circles joined by a rectangle) -- which is exactly what
    // distinguishes an entity set from a plain location's much smaller,
    // fixed 12px corner rounding. A plain location gets that smaller
    // rounding instead; the angular family (agent, transition, relation)
    // gets square corners.
    const cornerRadius =
      isChannel || isPlace || isEntitySet
        ? Math.min(box.width, box.height) / 2
        : isRoundedElementType(element.type)
          ? Math.min(12, box.width / 2, box.height / 2)
          : 0;
    // An orthogonal-partitioning node is a triangle, not a box: apex at
    // the top (where the partitioned superset's arc attaches) and base at
    // the bottom (where each part/subset's arc attaches) -- see
    // spec/index.html's "Orthogonal partitioning" section.
    const rect = isPartition
      ? new Konva.Line({
          points: [box.width / 2, 0, box.width, box.height, 0, box.height],
          closed: true,
          fill: '#ffffff',
          stroke: '#000000',
          strokeWidth: NODE_STROKE_WIDTH,
        })
      : new Konva.Rect({
          name: 'fumoco-body',
          width: box.width,
          height: box.height,
          fill: element.fill ?? '#ffffff',
          stroke: '#000000',
          strokeWidth: NODE_STROKE_WIDTH,
          cornerRadius,
          dash: isLocation && element.dashed ? [6, 4] : undefined,
        });
    // "N similar boxes": two copies stacked behind, offset down-right.
    if (element.multiple) {
      for (const offset of [2 * MULTIPLE_OFFSET, MULTIPLE_OFFSET]) {
        const copy = rect.clone({ name: '', x: offset, y: offset });
        group.add(copy);
      }
    }
    group.add(rect);

    if (element.type === ElementType.HUMAN_AGENT) {
      group.add(this.buildStickFigure(box));
    }

    // A start place is marked by a small filled black circle concentric
    // with the place, with a visible white gap to the place's own
    // outline -- not a stub arrow (that was wrong; FMC's actual
    // convention, per a measured reference screenshot: the inner circle
    // reads at roughly 0.45-0.5x the place's own diameter, leaving most
    // of the place's radius as the gap). Distinct from just holding
    // tokens (a place can have a nonzero marking without being where the
    // net's flow begins).
    if (isPlace && element.isStart) {
      group.add(
        new Konva.Circle({
          x: box.width / 2,
          y: box.height / 2,
          radius: (Math.min(box.width, box.height) * 0.47) / 2,
          fill: '#000000',
        }),
      );
    }

    // A place's marking (token count) is shown alongside its label rather
    // than as separate dots per token -- simple, and legible at any
    // marking size, which drawing one dot per token stops being once a
    // place holds more than a handful.
    const labelText =
      isPlace && element.tokens
        ? `${element.label ?? ''} (${element.tokens})`.trim()
        : (element.label ?? '');

    let label;
    if (nested) {
      // A container's label must never render smaller than a leaf's --
      // parent labels shrinking below their children's was a real,
      // repeatedly-flagged complaint about the old Python auto-layouter
      // too. Same fontSize as a leaf, just top-left-positioned and gray
      // so it still reads as a container label rather than centered
      // content.
      label = new Konva.Text({
        text: labelText,
        x: 8,
        y: 6,
        fontSize: 15,
        fontFamily: CANVAS_FONT_FAMILY,
        fill: '#666666',
      });
    } else {
      label = new Konva.Text({
        text: labelText,
        width: box.width,
        height: box.height,
        align: 'center',
        verticalAlign: 'middle',
        fontSize: 15,
        fontFamily: CANVAS_FONT_FAMILY,
        padding: 8,
        // A shorthand channel's label glyph (e.g. "R▶") is what carries
        // direction, in place of arrowheads -- bold makes that glyph the
        // thing your eye catches, matching the FMC convention.
        fontStyle: isChannel && element.channel.shorthand ? 'bold' : 'normal',
      });
    }
    // A NOP transition carries no label -- it's a solid bar, and any text
    // on top of a black fill wouldn't read anyway.
    if (!isNopTransition) group.add(label);

    group.on('click', (event) => {
      event.cancelBubble = true;
      if (this.connectorTool.kind) {
        this.handleConnectorClick(element.id);
        return;
      }
      if (event.evt.shiftKey || event.evt.metaKey || event.evt.ctrlKey) {
        this.selection.toggle(element.id);
      } else {
        this.selection.select(element.id);
      }
    });

    // Bind both -- Konva emits 'dblclick' for mouse double-clicks but
    // 'dbltap' for touch/trackpad double-taps; a trackpad's "double tap to
    // click" doesn't reliably synthesize a real dblclick event.
    group.on('dblclick dbltap', (event) => {
      event.cancelBubble = true;
      this.promptRename(element.id);
    });

    group.on('contextmenu', (event) => {
      event.evt.preventDefault();
      event.cancelBubble = true;
      // Right-clicking inside a multi-selection keeps it, so Cut/Copy
      // act on all of it; anywhere else selects just this element.
      if (!this.selection.isSelected(element.id)) {
        this.selection.select(element.id);
      }
      this.openContextMenu(
        event.evt,
        this.elementMenuItems(
          element.id,
          this.stage.getRelativePointerPosition(),
        ),
      );
    });

    if (nested) {
      let dragStart = null;
      let descendants = [];
      group.on('dragstart', () => {
        dragStart = { x: group.x(), y: group.y() };
        descendants = this.collectDescendantNodes(element.id, view);
      });
      group.on('dragmove', () => {
        const dx = group.x() - dragStart.x;
        const dy = group.y() - dragStart.y;
        for (const descendant of descendants) {
          descendant.node.position({
            x: descendant.x0 + dx,
            y: descendant.y0 + dy,
          });
        }
        this.shapeLayer.batchDraw();
      });
      group.on('dragend', () => {
        const dx = group.x() - dragStart.x;
        const dy = group.y() - dragStart.y;
        this.modelStore.mutate(() => {
          for (const descendant of descendants) {
            const descendantBox = view.boxes.get(descendant.id);
            if (descendantBox) {
              view.boxes.set(descendant.id, {
                ...descendantBox,
                x: descendantBox.x + dx,
                y: descendantBox.y + dy,
              });
            }
          }
          // A container's own stored box only exists at all once it's been
          // manually resized (see the shared transformend handler below) --
          // when it does, it needs to move with its children too, or the
          // next render would snap it back to its pre-drag position.
          const ownBox = view.boxes.get(element.id);
          if (ownBox) {
            view.boxes.set(element.id, {
              ...ownBox,
              x: ownBox.x + dx,
              y: ownBox.y + dy,
            });
          }
        });
        this.refreshEdges();
      });
    } else {
      group.on('dragend', () => {
        this.modelStore.mutate(() => {
          const previousBox = view.boxes.get(element.id);
          view.boxes.set(
            element.id,
            toStoredBox({ ...box, x: group.x(), y: group.y() }),
          );
          this.updateContainmentAfterDrag(element.id, view, previousBox);
        });
        // Don't wait on/depend on the tracked-collection update rebuilding
        // the whole shape layer -- refresh edges directly, right here, so
        // they always follow the box that just moved. This also avoids
        // tearing down and recreating the dragged node (and detaching the
        // Transformer from it) on every single drag.
        this.refreshEdges();
      });
    }

    // Shared by both leaf and container nodes: whichever box the 8 resize
    // handles are dragging (the leaf's own, or a container's manual
    // override -- see computeEffectiveBoxes) is committed the same way.
    group.on('transformend', () => {
      const newBox = toStoredBox({
        x: group.x(),
        y: group.y(),
        width: Math.max(MIN_SIZE, rect.width() * group.scaleX()),
        height: Math.max(MIN_SIZE, rect.height() * group.scaleY()),
        rotated: box.rotated,
      });
      group.scaleX(1);
      group.scaleY(1);
      this.modelStore.mutate(() => view.boxes.set(element.id, newBox));
      this.refreshEdges();
    });

    return group;
  }

  // Every descendant *displayed* nested (children, grandchildren, ..., per
  // displayParentOf) under `containerId` in this view, with their Konva
  // node and starting position -- used to drag a container's whole nested
  // content together, since children are plain sibling nodes in absolute
  // coordinates, not real Konva-group children of the container. Uses the
  // view's display relationship, not raw model containment, so dragging a
  // container never moves something the view currently shows un-nested
  // even though the model still contains it there.
  collectDescendantNodes(containerId, view) {
    const model = this.modelStore.model;
    const displayChildren = buildDisplayChildIndex(model, view);
    const result = [];
    const visit = (id) => {
      for (const childId of displayChildren.get(id) ?? []) {
        const node = this.nodesById.get(childId);
        if (node)
          result.push({ id: childId, node, x0: node.x(), y0: node.y() });
        visit(childId);
      }
    };
    visit(containerId);
    return result;
  }

  // After a leaf element's own drag commits its new box: once it no longer
  // overlaps the box of the container it was *displayed* nested under at
  // all (full clearance -- that box measured *without* this child, since
  // an auto-fit container otherwise just grows to follow it), that
  // display choice is cleared for this view only (view.nestedUnder = null)
  // -- the world-model containment (Element.parents) is deliberately left
  // untouched; dragging something out of view is not the same as deciding
  // it was never really contained. If its new center lands inside some
  // *other* element's box (the smallest one, if several overlap), that
  // establishes real containment in the model (addContainment) *and*
  // chooses to display it nested there in this view (nestedUnder) --
  // dragging in does both, per the user's explicit distinction; dragging
  // out only ever changes the view. Only for the dragged element itself,
  // not its descendants -- a container being dragged uses
  // collectDescendantNodes instead and never changes containment.
  updateContainmentAfterDrag(elementId, view, previousBox) {
    const model = this.modelStore.model;
    const element = model.elements.get(elementId);
    const box = view.boxes.get(elementId);
    if (!element || !box) return;
    const center = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
    const includedSet = new Set(view.included);
    const effectiveBoxes = computeEffectiveBoxes(model, view);
    const currentParent = displayParentOf(model, view, elementId, includedSet);
    const parentBoxWithoutChild =
      currentParent == null
        ? null
        : this.containerBoxWithout(view, currentParent, elementId, previousBox);
    const stillInsideCurrentParent =
      parentBoxWithoutChild && rectsIntersect(box, parentBoxWithoutChild);

    let bestCandidateId = null;
    let bestArea = Infinity;
    for (const id of view.included) {
      if (id === elementId || id === currentParent) continue;
      const candidateBox = effectiveBoxes.get(id);
      if (!candidateBox || !pointInBox(center, candidateBox)) continue;
      const area = candidateBox.width * candidateBox.height;
      if (area < bestArea) {
        bestArea = area;
        bestCandidateId = id;
      }
    }

    if (bestCandidateId) {
      try {
        model.addContainment(bestCandidateId, elementId);
        view.nestedUnder.set(elementId, bestCandidateId);
      } catch (error) {
        if (!(error instanceof FmcModelError)) throw error;
        // e.g. would create a cycle -- an incidental drag-over shouldn't
        // pop an alert for this, silently skip nesting instead.
      }
    } else if (currentParent != null && !stillInsideCurrentParent) {
      view.nestedUnder.set(elementId, null);
      // Its last child gone, a parent without a manual size would have
      // no box left at all -- give it the one it was measured with.
      if (!view.boxes.has(currentParent)) {
        view.boxes.set(currentParent, parentBoxWithoutChild);
      }
    }
  }

  // `containerId`'s box as if `childId` weren't displayed nested in it:
  // auto-fit around its other children, else its manual size, else a
  // default-size box where it was before the child moved (its auto-fit
  // around the child's `previousBox`).
  containerBoxWithout(view, containerId, childId, previousBox) {
    const model = this.modelStore.model;
    const probe = {
      included: view.included,
      boxes: view.boxes,
      nestedUnder: new Map([...view.nestedUnder, [childId, null]]),
    };
    const box = computeEffectiveBoxes(model, probe).get(containerId);
    if (box) return toStoredBox(box);
    const before = {
      ...probe,
      nestedUnder: view.nestedUnder,
      boxes: new Map([...view.boxes, [childId, previousBox]]),
    };
    const current =
      previousBox && computeEffectiveBoxes(model, before).get(containerId);
    if (!current) return null;
    return {
      x: current.x,
      y: current.y,
      ...defaultBoxSize(model.elements.get(containerId)),
    };
  }

  buildStickFigure(box) {
    const cx = 20;
    const cy = box.height / 2;
    const stroke = '#000000';
    const group = new Konva.Group();
    group.add(
      new Konva.Circle({
        x: cx,
        y: cy - 12,
        radius: 5,
        stroke,
        strokeWidth: 1.5,
      }),
    );
    group.add(
      new Konva.Line({
        points: [cx, cy - 7, cx, cy + 8],
        stroke,
        strokeWidth: 1.5,
      }),
    );
    group.add(
      new Konva.Line({
        points: [cx - 6, cy - 2, cx + 6, cy - 2],
        stroke,
        strokeWidth: 1.5,
      }),
    );
    group.add(
      new Konva.Line({
        points: [cx, cy + 8, cx - 5, cy + 16],
        stroke,
        strokeWidth: 1.5,
      }),
    );
    group.add(
      new Konva.Line({
        points: [cx, cy + 8, cx + 5, cy + 16],
        stroke,
        strokeWidth: 1.5,
      }),
    );
    return group;
  }

  <template>
    <div class="canvas-view-wrapper">
      <div
        class="canvas-view"
        {{this.setupStage}}
        {{this.syncShapes}}
        {{this.syncSelection}}
        {{this.syncEdgeSelection}}
        {{this.syncConnectorEligibility}}
      ></div>
      <div
        class="canvas-guide-strip canvas-guide-strip-top"
        title="Drag down to add a horizontal guide"
        aria-hidden="true"
        {{this.guideStrip "y"}}
      ></div>
      <div
        class="canvas-guide-strip canvas-guide-strip-left"
        title="Drag right to add a vertical guide"
        aria-hidden="true"
        {{this.guideStrip "x"}}
      ></div>
      <div class="canvas-scrollbar canvas-scrollbar-x" {{this.scrollbar "x"}}>
        <div class="canvas-scrollbar-extent"></div>
      </div>
      <div class="canvas-scrollbar canvas-scrollbar-y" {{this.scrollbar "y"}}>
        <div class="canvas-scrollbar-extent"></div>
      </div>
      <div class="canvas-export-toolbar">
        <button type="button" {{on "click" this.exportPng}}>Export PNG</button>
        <button type="button" {{on "click" this.exportSvg}}>Export SVG</button>
      </div>
      <div class="canvas-zoom-toolbar">
        <button
          type="button"
          title="Zoom out"
          {{on "click" this.zoomOut}}
        >&minus;</button>
        <button
          type="button"
          title="Reset zoom to 100%"
          {{on "click" this.resetZoom}}
        >{{this.zoomLabel}}</button>
        <button
          type="button"
          title="Zoom in"
          {{on "click" this.zoomIn}}
        >+</button>
      </div>
    </div>
    {{#if this.contextMenu}}
      <ul
        class="canvas-context-menu"
        {{this.positionContextMenu this.contextMenu.x this.contextMenu.y}}
      >
        {{#each this.contextMenu.items as |item|}}
          <li>
            <button
              type="button"
              {{on "click" (fn this.runMenuItem item.action)}}
            >{{item.label}}{{#if item.shortcut}}<span
                  class="canvas-context-menu-shortcut"
                >{{item.shortcut}}</span>{{/if}}</button>
          </li>
        {{/each}}
      </ul>
    {{/if}}
  </template>
}
