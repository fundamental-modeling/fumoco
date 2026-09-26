import Component from '@glimmer/component';
import { service } from '@ember/service';
import { modifier } from 'ember-modifier';
import Konva from 'konva';
import { FmcModelError } from 'fumoco/utils/fmc-model';
import { ConnectorKind, connectorRule } from 'fumoco/services/connector-tool';

const GRID = 10;
const SNAP_TOLERANCE = 6;
const MIN_SIZE = 20;
const MARQUEE_THRESHOLD = 3; // px of movement before a stage mousedown counts as a drag, not a click

function snapToGrid(value) {
  return Math.round(value / GRID) * GRID;
}

function rectsIntersect(a, b) {
  return (
    a.x < b.x + b.width &&
    b.x < a.x + a.width &&
    a.y < b.y + b.height &&
    b.y < a.y + a.height
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

const EDGE_CORNER_RADIUS = 10;

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

    this.stage.on('mousedown', (event) => {
      if (event.target !== this.stage) return;
      this.marqueeStart = this.stage.getPointerPosition();
    });

    this.stage.on('mousemove', () => {
      if (!this.marqueeStart) return;
      const pos = this.stage.getPointerPosition();
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

    return () => {
      window.removeEventListener('resize', resize);
      window.removeEventListener('keydown', keydown);
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

    for (const id of view.included) {
      const element = this.modelStore.model.elements.get(id);
      const box = view.boxes.get(id);
      if (!element || !box) continue;
      const node = this.buildShape(element, box, view);
      this.nodesById.set(id, node);
      this.shapeLayer.add(node);
    }
    this.buildEdges(view);
    this.transformer.moveToTop();
    this.attachTransformer();
    this.refreshNodeStyling();
    this.shapeLayer.batchDraw();
  });

  refreshEdges() {
    if (!this.shapeLayer) return;
    const view = this.modelStore.activeView;
    this.shapeLayer.find('.fumoco-edge').forEach((node) => node.destroy());
    if (view) this.buildEdges(view);
    this.transformer.moveToTop();
    this.shapeLayer.batchDraw();
  }

  buildEdges(view) {
    const included = new Set(view.included);
    for (const access of this.modelStore.model.accesses) {
      if (!included.has(access.agent) || !included.has(access.storage))
        continue;
      const agentBox = view.boxes.get(access.agent);
      const storageBox = view.boxes.get(access.storage);
      if (!agentBox || !storageBox) continue;
      this.drawAccessEdge(access, agentBox, storageBox);
    }
    for (const channel of this.modelStore.model.channels) {
      if (!included.has(channel.source) || !included.has(channel.target))
        continue;
      const sourceBox = view.boxes.get(channel.source);
      const targetBox = view.boxes.get(channel.target);
      if (!sourceBox || !targetBox) continue;
      this.drawChannel(channel, sourceBox, targetBox, view);
    }
  }

  // A single Konva.Shape drawing a rounded-corner rectilinear path (native
  // canvas arcTo does the rounding), plus separate small filled triangles
  // for whichever end(s) need an arrowhead -- Konva.Arrow doesn't support
  // rounded corners, so this replaces it for every routed edge.
  addRoutedEdge(points, { arrowStart = false, arrowEnd = false } = {}) {
    this.shapeLayer.add(
      new Konva.Shape({
        stroke: '#000000',
        strokeWidth: 2,
        name: 'fumoco-edge',
        sceneFunc: (ctx, shapeNode) => {
          drawRoundedPolyline(ctx, points, EDGE_CORNER_RADIUS);
          ctx.strokeShape(shapeNode);
        },
      }),
    );
    if (arrowEnd) {
      this.shapeLayer.add(
        new Konva.Line({
          points: arrowHeadPoints(points.at(-1), points.at(-2)),
          closed: true,
          fill: '#000000',
          name: 'fumoco-edge',
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
        }),
      );
    }
  }

  drawAccessEdge(access, agentBox, storageBox) {
    if (access.kind === 'modify') {
      const path = orthogonalPath(agentBox, storageBox);
      this.addRoutedEdge(path, { arrowStart: true, arrowEnd: true });
      return;
    }
    const [from, to] =
      access.kind === 'read' ? [storageBox, agentBox] : [agentBox, storageBox];
    const path = orthogonalPath(from, to);
    this.addRoutedEdge(path, { arrowEnd: true });
  }

  drawChannel(channel, sourceBox, targetBox, view) {
    const override = view.channelPlaces.get(channel.id);
    let path, mid;
    if (override) {
      // Route through the user-placed point as a zero-size "box" -- keeps
      // both legs rectilinear via the same orthogonalPath logic, just
      // split into two hops instead of one.
      const point = { x: override.x, y: override.y, width: 0, height: 0 };
      const firstLeg = orthogonalPath(sourceBox, point);
      const secondLeg = orthogonalPath(point, targetBox);
      path = [...firstLeg, ...secondLeg.slice(1)];
      mid = override;
    } else {
      path = orthogonalPath(sourceBox, targetBox);
      mid =
        path.length === 3
          ? path[1]
          : { x: (path[0].x + path[1].x) / 2, y: (path[0].y + path[1].y) / 2 };
    }
    const drawArrows = channel.directed && !channel.place.shorthand;

    this.addRoutedEdge(path, { arrowEnd: drawArrows });
    const placeCircle = new Konva.Circle({
      x: mid.x,
      y: mid.y,
      radius: 7,
      fill: '#ffffff',
      stroke: '#000000',
      strokeWidth: 2,
      name: 'fumoco-edge',
      draggable: true,
      dragBoundFunc: (pos) => ({ x: snapToGrid(pos.x), y: snapToGrid(pos.y) }),
    });
    placeCircle.on('dragend', () => {
      this.modelStore.mutate(() => {
        view.channelPlaces.set(channel.id, {
          x: placeCircle.x(),
          y: placeCircle.y(),
        });
      });
      this.refreshEdges();
    });
    this.shapeLayer.add(placeCircle);
    if (channel.place.label) {
      this.shapeLayer.add(
        new Konva.Text({
          x: mid.x - 20,
          y: mid.y - 22,
          width: 40,
          text: channel.place.label,
          align: 'center',
          fontSize: 13,
          fontStyle: channel.place.shorthand ? 'bold' : 'normal',
          name: 'fumoco-edge',
        }),
      );
    }
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
      rect.strokeWidth(selected ? 3 : 2);
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

  attachTransformer() {
    if (!this.transformer) return;
    const ids = this.selection.selectedIds;
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
            return model.addChannel(sourceId, id, true);
          case ConnectorKind.CHANNEL_BIDIRECTIONAL:
            return model.addChannel(sourceId, id, false);
          case ConnectorKind.REQRES_LONG:
            return model.addReqRes(sourceId, id, { shorthand: false });
          case ConnectorKind.REQRES_SHORTHAND:
            return model.addReqRes(sourceId, id, { shorthand: true });
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

  buildShape(element, box, view) {
    const group = new Konva.Group({
      x: box.x,
      y: box.y,
      draggable: true,
      name: 'fumoco-shape',
      id: element.id,
      dragBoundFunc: (pos) => ({ x: snapToGrid(pos.x), y: snapToGrid(pos.y) }),
    });

    const isStorage = element.type === 'storage';
    const rect = new Konva.Rect({
      width: box.width,
      height: box.height,
      fill: '#ffffff',
      stroke: '#000000',
      strokeWidth: 2,
      cornerRadius: isStorage ? Math.min(12, box.width / 2, box.height / 2) : 0,
      dash: isStorage && element.dashed ? [6, 4] : undefined,
    });
    group.add(rect);

    if (element.type === 'human_agent') {
      group.add(this.buildStickFigure(box));
    }

    const label = new Konva.Text({
      text: element.label ?? '',
      width: box.width,
      height: box.height,
      align: 'center',
      verticalAlign: 'middle',
      fontSize: 15,
      padding: 8,
    });
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

    group.on('dragmove', () => this.showSnapGuides(group, view));
    group.on('dragend', () => {
      this.guideLayer.destroyChildren();
      this.guideLayer.batchDraw();
      this.modelStore.mutate(() => {
        view.boxes.set(element.id, { ...box, x: group.x(), y: group.y() });
      });
      // Don't wait on/depend on the tracked-collection update rebuilding
      // the whole shape layer -- refresh edges directly, right here, so
      // they always follow the box that just moved. This also avoids
      // tearing down and recreating the dragged node (and detaching the
      // Transformer from it) on every single drag.
      this.refreshEdges();
    });

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

  showSnapGuides(node, view) {
    this.guideLayer.destroyChildren();
    const w = node.findOne('Rect').width();
    const h = node.findOne('Rect').height();
    const x0 = node.x();
    const y0 = node.y();
    const targetsX = [
      { v: x0, e: 'left' },
      { v: x0 + w / 2, e: 'centerx' },
      { v: x0 + w, e: 'right' },
    ];
    const targetsY = [
      { v: y0, e: 'top' },
      { v: y0 + h / 2, e: 'centery' },
      { v: y0 + h, e: 'bottom' },
    ];

    for (const [id, other] of view.boxes) {
      if (id === node.id()) continue;
      const others = [
        { v: other.x, e: 'left' },
        { v: other.x + other.width / 2, e: 'centerx' },
        { v: other.x + other.width, e: 'right' },
      ];
      const othersY = [
        { v: other.y, e: 'top' },
        { v: other.y + other.height / 2, e: 'centery' },
        { v: other.y + other.height, e: 'bottom' },
      ];
      for (const target of targetsX) {
        for (const candidate of others) {
          if (Math.abs(target.v - candidate.v) <= SNAP_TOLERANCE) {
            node.x(node.x() + (candidate.v - target.v));
            this.guideLayer.add(
              new Konva.Line({
                points: [candidate.v, -4000, candidate.v, 4000],
                stroke: '#ff4081',
                strokeWidth: 1,
              }),
            );
          }
        }
      }
      for (const target of targetsY) {
        for (const candidate of othersY) {
          if (Math.abs(target.v - candidate.v) <= SNAP_TOLERANCE) {
            node.y(node.y() + (candidate.v - target.v));
            this.guideLayer.add(
              new Konva.Line({
                points: [-4000, candidate.v, 4000, candidate.v],
                stroke: '#ff4081',
                strokeWidth: 1,
              }),
            );
          }
        }
      }
    }
    this.guideLayer.batchDraw();
  }

  <template>
    <div
      class="canvas-view"
      {{this.setupStage}}
      {{this.syncShapes}}
      {{this.syncSelection}}
      {{this.syncConnectorEligibility}}
    ></div>
  </template>
}
