import Component from '@glimmer/component';
import { tracked } from '@glimmer/tracking';
import { action } from '@ember/object';
import { service } from '@ember/service';
import { on } from '@ember/modifier';
import { fn } from '@ember/helper';
import { modifier } from 'ember-modifier';
import Konva from 'konva';
import { TrackedArray } from 'tracked-built-ins';
import {
  ElementType,
  FmcModelError,
  isRoundedElementType,
} from 'fumoco/utils/fmc-model';
import { ConnectorKind, connectorRule } from 'fumoco/services/connector-tool';
import { nextFreeBoxPosition } from 'fumoco/utils/box-layout';

const GRID = 10;
const MIN_SIZE = 20;
const MARQUEE_THRESHOLD = 3; // px of movement before a stage mousedown counts as a drag, not a click
const NESTING_PADDING = 30;
// A node's outline should read visibly heavier than an edge's so the two
// are never ambiguous (FMC Visualization Guidelines' "line weight of
// edges and nodes"); edges stay at their existing strokeWidth: 2.
const NODE_STROKE_WIDTH = 3;
const NODE_STROKE_WIDTH_SELECTED = 4;

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
export function computeEffectiveBoxes(model, view) {
  const includedSet = new Set(view.included);
  const effective = new Map();
  for (const id of view.included) {
    const box = view.boxes.get(id);
    if (box) effective.set(id, box);
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
    const autoFit = {
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
function orthogonalPath(a, b) {
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
    const exit = { x: sourceCenterX, y: sourceBottom };
    const enter = { x: targetCenterX, y: targetBox.y };
    if (exit.x === enter.x) return [exit, enter];
    const midY = (exit.y + enter.y) / 2;
    return [exit, { x: exit.x, y: midY }, { x: enter.x, y: midY }, enter];
  }

  // The target isn't below the source -- a particular case, typically a
  // loop-back arc where the other node sits roughly level with (or to
  // the side of) this one, not above or below it. The arc leaves
  // diagonally out of the *source's* top corner (north-west/north-east,
  // facing whichever side the target is on) and arrives diagonally into
  // the *target's* bottom corner (south-west/south-east, facing back
  // toward the source), each via a short stub segment right at the
  // shape's own boundary before bending onto the ordinary horizontal/
  // vertical routing for the transit between them -- only this stub is a
  // free-angle segment, never the whole path.
  //
  // Using the source's top and the target's bottom (rather than the same
  // side on both ends) is deliberate, not just a style choice: a
  // reciprocal pair of arcs between the same two nodes (A->B and B->A)
  // each exits its own source's top and enters its own target's bottom,
  // so the two arcs always land on two *different* corners of each box
  // (one node's "exit" corner is never the other arc's "entry" corner) --
  // this is what keeps a loop-back pair from ever tracing the same line
  // and reading as one bidirectional arrow.
  const exitSignX = targetCenterX >= sourceCenterX ? 1 : -1;
  const exitAnchor = diagonalBoundaryPoint(
    sourceBox,
    sourceCircular,
    exitSignX,
    -1,
  );
  const exitBend = {
    x: exitAnchor.x + exitSignX * ARC_DIAGONAL_STUB,
    y: exitAnchor.y - ARC_DIAGONAL_STUB,
  };

  const enterSignX = sourceCenterX >= targetCenterX ? 1 : -1;
  const enterAnchor = diagonalBoundaryPoint(
    targetBox,
    targetCircular,
    enterSignX,
    1,
  );
  const enterBend = {
    x: enterAnchor.x + enterSignX * ARC_DIAGONAL_STUB,
    y: enterAnchor.y + ARC_DIAGONAL_STUB,
  };

  // Since exit and enter are now on opposite (top vs. bottom) sides, a
  // single shared lane can't safely connect them when the two boxes
  // overlap vertically (a "beside" pair, the usual loop-back shape) --
  // any lane positioned relative to only one box's edge risks cutting
  // through the other. So the detour instead fully encloses *both*
  // boxes: up from the exit stub to a lane above both tops, sideways to
  // a lane to the west of both left edges, down to a lane below both
  // bottoms, then across into the enter stub -- each of those three
  // legs is, by construction, entirely outside the other box's extent
  // along the axis that matters, so none of them can ever cross either
  // box's interior regardless of how the two are arranged.
  const aboveY = Math.min(sourceBox.y, targetBox.y) - ARC_ROUTE_MARGIN;
  const belowY =
    Math.max(sourceBottom, targetBox.y + targetBox.height) + ARC_ROUTE_MARGIN;
  const laneX = Math.min(sourceBox.x, targetBox.x) - ARC_ROUTE_MARGIN;
  return [
    exitAnchor,
    exitBend,
    { x: exitBend.x, y: aboveY },
    { x: laneX, y: aboveY },
    { x: laneX, y: belowY },
    { x: enterBend.x, y: belowY },
    enterBend,
    enterAnchor,
  ];
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

  setupStage = modifier((element) => {
    this.stage = new Konva.Stage({
      container: element,
      width: element.clientWidth || 800,
      height: element.clientHeight || 600,
    });
    this.shapeLayer = new Konva.Layer();
    this.guideLayer = new Konva.Layer({ listening: false });
    this.transformer = new Konva.Transformer({
      boundBoxFunc: (oldBox, newBox) =>
        newBox.width < MIN_SIZE || newBox.height < MIN_SIZE ? oldBox : newBox,
    });
    this.stage.add(this.shapeLayer);
    this.stage.add(this.guideLayer);
    this.shapeLayer.add(this.transformer);

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
    };
    window.addEventListener('resize', resize);

    const keydown = (event) => {
      if (document.activeElement?.tagName === 'INPUT') return;
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
      // that same distinction between the two keys.
      if (event.key === 'Delete') {
        this.removeSelectionFromView();
      } else if (event.key === 'Backspace') {
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
      this.shapeLayer.batchDraw();
      return;
    }

    const model = this.modelStore.model;
    const effectiveBoxes = computeEffectiveBoxes(model, view);
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
      this.drawArc(arc, sourceBox, targetBox, {
        vertical: isPetriArc,
        relationEnd,
        sourceCircular: sourceType === ElementType.PLACE,
        targetCircular: targetType === ElementType.PLACE,
      });
    }
  }

  drawArc(
    arc,
    sourceBox,
    targetBox,
    {
      vertical = false,
      relationEnd = null,
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
    const isInheritance = arc.kind === 'inheritance';
    // A plain ER arc (not inheritance, not Petri) can toggle its
    // cardinality; the other two kinds don't have the concept.
    const isErArc = !vertical && !isInheritance && relationEnd;
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
              ? 'Clear cardinality (many)'
              : 'Set cardinality: one (functional)',
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
    // An ER "is-a" (generalization) arc gets a hollow (white-filled,
    // outlined) triangle at the supertype end instead of the ordinary
    // filled one -- the standard ER/UML convention for inheritance, and
    // slightly larger so the outline reads clearly.
    this.shapeLayer.add(
      new Konva.Line({
        points: arrowHeadPoints(
          path.at(-1),
          path.at(-2),
          isInheritance ? 13 : 9,
        ),
        closed: true,
        fill: isInheritance ? '#ffffff' : '#000000',
        stroke: isInheritance ? '#000000' : undefined,
        strokeWidth: isInheritance ? 2 : undefined,
        name: 'fumoco-edge',
        listening: false,
      }),
    );
    if (!isInheritance && arc.weight !== 1) {
      const mid = path[Math.floor(path.length / 2)];
      this.shapeLayer.add(
        new Konva.Text({
          x: mid.x,
          y: mid.y - 14,
          text: String(arc.weight),
          fontSize: 12,
          fill: '#000000',
          name: 'fumoco-edge',
          listening: false,
        }),
      );
    }
    // A 1:n/1:1 relation marks its functional side with a small arrow
    // drawn a bit inside the relation's own box, pointing further inward
    // -- FMC's "arrow inside the relation symbol" convention for
    // cardinality (spec/index.html's Cardinality and roles section),
    // distinct from the main edge's own end (which just reflects
    // whichever way this arc happened to be drawn, not a semantic
    // direction for an ER connection).
    if (isErArc && arc.cardinality === 'one') {
      const atTarget = relationEnd === 'target';
      const border = atTarget ? path.at(-1) : path[0];
      const from = atTarget ? path.at(-2) : path[1];
      const dx = border.x - from.x;
      const dy = border.y - from.y;
      const len = Math.hypot(dx, dy) || 1;
      const inset = 14;
      const tip = {
        x: border.x + (dx / len) * inset,
        y: border.y + (dy / len) * inset,
      };
      this.shapeLayer.add(
        new Konva.Line({
          points: arrowHeadPoints(tip, border, 7),
          closed: true,
          fill: '#000000',
          name: 'fumoco-edge',
          listening: false,
        }),
      );
    }
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
    { arrowStart = false, arrowEnd = false, edgeId = null, view = null } = {},
  ) {
    const mainShape = new Konva.Shape({
      stroke: '#000000',
      strokeWidth: 2,
      hitStrokeWidth: 16, // a 2px line is hard to click on directly
      name: 'fumoco-edge',
      sceneFunc: (ctx, shapeNode) => {
        drawRoundedPolyline(ctx, points, EDGE_CORNER_RADIUS);
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
      const rect = node.findOne('Rect');
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

  copyElement(id) {
    const element = this.modelStore.model.elements.get(id);
    if (!element) return;
    this.clipboard = {
      type: element.type,
      label: element.label,
      dashed: element.dashed,
      channel: element.channel ? { ...element.channel } : null,
    };
  }

  cutElement(id) {
    this.copyElement(id);
    this.modelStore.mutate((model) => model.removeElement(id));
    this.selection.clear();
  }

  pasteClipboard(point) {
    if (!this.clipboard) return;
    const view = this.modelStore.activeView;
    if (!view) return;
    const width = 120;
    const height = 60;
    this.modelStore.mutate((model) => {
      const id = model.addElement(this.clipboard.type, {
        label: this.clipboard.label,
        dashed: this.clipboard.dashed,
        channel: this.clipboard.channel,
      });
      view.included.push(id);
      view.boxes.set(id, {
        x: point.x - width / 2,
        y: point.y - height / 2,
        width,
        height,
      });
      this.selection.select(id);
    });
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

  elementMenuItems(id) {
    const element = this.modelStore.model.elements.get(id);
    const items = [
      { label: 'Rename', action: () => this.promptRename(id) },
      { label: 'Copy', action: () => this.copyElement(id) },
      { label: 'Cut', action: () => this.cutElement(id) },
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
        const relationBox = view.boxes.get(relationId);
        const { x, y } = relationBox ?? nextFreeBoxPosition(view);
        view.included.push(entitySetId);
        view.boxes.set(entitySetId, { x, y, width: 160, height: 120 });
        view.nestedUnder.set(relationId, entitySetId);
      }
      this.selection.select(entitySetId);
    });
  }

  edgeMenuItems(edgeId, view, point) {
    return [
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
    if (!this.clipboard) return [];
    return [{ label: 'Paste', action: () => this.pasteClipboard(point) }];
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
          case ConnectorKind.INHERITANCE:
            return model.addArc(sourceId, id, 1, { kind: 'inheritance' });
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
      dragBoundFunc: (pos) => ({ x: snapToGrid(pos.x), y: snapToGrid(pos.y) }),
    });
    const isLocation = element.type === ElementType.LOCATION;
    const isChannel = !!element.channel;
    const isPlace = element.type === ElementType.PLACE;
    const isEntitySet = element.type === ElementType.ENTITY_SET;
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
    const rect = new Konva.Rect({
      width: box.width,
      height: box.height,
      fill: '#ffffff',
      stroke: '#000000',
      strokeWidth: NODE_STROKE_WIDTH,
      cornerRadius,
      dash: isLocation && element.dashed ? [6, 4] : undefined,
    });
    group.add(rect);

    if (element.type === ElementType.HUMAN_AGENT) {
      group.add(this.buildStickFigure(box));
    }

    // A start place gets a short, unconnected stub arrow pointing into
    // its left side -- the standard automaton/Petri net "entry point"
    // marker, distinct from just holding tokens (a place can have a
    // nonzero marking without being where the net's flow begins).
    if (isPlace && element.isStart) {
      const midY = box.height / 2;
      group.add(
        new Konva.Line({
          points: arrowHeadPoints({ x: 0, y: midY }, { x: -18, y: midY }, 7),
          closed: true,
          fill: '#000000',
        }),
      );
      group.add(
        new Konva.Line({
          points: [-18, midY, -4, midY],
          stroke: '#000000',
          strokeWidth: 2,
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
        padding: 8,
        // A shorthand channel's label glyph (e.g. "R▶") is what carries
        // direction, in place of arrowheads -- bold makes that glyph the
        // thing your eye catches, matching the FMC convention.
        fontStyle: isChannel && element.channel.shorthand ? 'bold' : 'normal',
      });
    }
    group.add(label);

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
      this.selection.select(element.id);
      this.openContextMenu(event.evt, this.elementMenuItems(element.id));
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
          view.boxes.set(element.id, { ...box, x: group.x(), y: group.y() });
          this.updateContainmentAfterDrag(element.id, view);
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
      const newBox = {
        x: group.x(),
        y: group.y(),
        width: Math.max(MIN_SIZE, rect.width() * group.scaleX()),
        height: Math.max(MIN_SIZE, rect.height() * group.scaleY()),
      };
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

  // After a leaf element's own drag commits its new box: if it's no longer
  // inside the box of the container it was *displayed* nested under, that
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
  updateContainmentAfterDrag(elementId, view) {
    const model = this.modelStore.model;
    const element = model.elements.get(elementId);
    const box = view.boxes.get(elementId);
    if (!element || !box) return;
    const center = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
    const includedSet = new Set(view.included);
    const effectiveBoxes = computeEffectiveBoxes(model, view);
    const currentParent = displayParentOf(model, view, elementId, includedSet);
    const currentParentBox =
      currentParent == null ? null : effectiveBoxes.get(currentParent);
    const stillInsideCurrentParent =
      currentParentBox && pointInBox(center, currentParentBox);

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
    }
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
    <div
      class="canvas-view"
      {{this.setupStage}}
      {{this.syncShapes}}
      {{this.syncSelection}}
      {{this.syncEdgeSelection}}
      {{this.syncConnectorEligibility}}
    ></div>
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
            >{{item.label}}</button>
          </li>
        {{/each}}
      </ul>
    {{/if}}
  </template>
}
