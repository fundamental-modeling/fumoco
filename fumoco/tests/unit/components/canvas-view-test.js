import { module, test } from 'qunit';
import {
  buildDrawOrder,
  computeEffectiveBoxes,
  displayParentOf,
  nestingDepth,
  verticalArcPath,
} from 'fumoco/components/canvas-view';
import { ElementType, FmcModel } from 'fumoco/utils/fmc-model';

// A plain Map stands in for View.nestedUnder in these pure-function tests
// -- displayParentOf only calls .has/.get on it, no Ember reactivity needed.
function fakeView(nestedUnderEntries = []) {
  return { nestedUnder: new Map(nestedUnderEntries) };
}

module('Unit | Component | canvas-view (nesting geometry)', function () {
  test('displayParentOf defaults to the first in-view model parent', function (assert) {
    const model = new FmcModel();
    const parent = model.addElement(ElementType.AGENT);
    const child = model.addElement(ElementType.AGENT);
    model.addContainment(parent, child);
    assert.strictEqual(
      displayParentOf(model, fakeView(), child, new Set([parent, child])),
      parent,
    );
  });

  test('displayParentOf ignores a model parent not present in the view', function (assert) {
    const model = new FmcModel();
    const parent = model.addElement(ElementType.AGENT);
    const child = model.addElement(ElementType.AGENT);
    model.addContainment(parent, child);
    assert.strictEqual(
      displayParentOf(model, fakeView(), child, new Set([child])),
      null,
    );
  });

  test('displayParentOf honors an explicit view override, including explicit un-nesting (null)', function (assert) {
    const model = new FmcModel();
    const parent = model.addElement(ElementType.AGENT);
    const child = model.addElement(ElementType.AGENT);
    model.addContainment(parent, child);
    const included = new Set([parent, child]);

    // model still says parent contains child, but this view chooses not
    // to display that -- the whole point of the view/model distinction.
    const view = fakeView([[child, null]]);
    assert.strictEqual(displayParentOf(model, view, child, included), null);
  });

  test('nestingDepth is 0 for an element with no displayed parent', function (assert) {
    const model = new FmcModel();
    const a = model.addElement(ElementType.AGENT);
    assert.strictEqual(
      nestingDepth(model, fakeView(), a, new Set([a]), new Map()),
      0,
    );
  });

  test('nestingDepth counts through multiple displayed ancestors', function (assert) {
    const model = new FmcModel();
    const grandparent = model.addElement(ElementType.AGENT);
    const parent = model.addElement(ElementType.AGENT);
    const child = model.addElement(ElementType.AGENT);
    model.addContainment(grandparent, parent);
    model.addContainment(parent, child);
    const included = new Set([grandparent, parent, child]);
    const cache = new Map();
    const view = fakeView();
    assert.strictEqual(
      nestingDepth(model, view, grandparent, included, cache),
      0,
    );
    assert.strictEqual(nestingDepth(model, view, parent, included, cache), 1);
    assert.strictEqual(nestingDepth(model, view, child, included, cache), 2);
  });

  test('nestingDepth respects a view override even though the model says otherwise', function (assert) {
    const model = new FmcModel();
    const parent = model.addElement(ElementType.AGENT);
    const child = model.addElement(ElementType.AGENT);
    model.addContainment(parent, child);
    const view = fakeView([[child, null]]); // displayed un-nested in this view
    assert.strictEqual(
      nestingDepth(model, view, child, new Set([parent, child]), new Map()),
      0,
    );
  });

  test('computeEffectiveBoxes fits a container around its in-view children with padding', function (assert) {
    const model = new FmcModel();
    const container = model.addElement(ElementType.AGENT);
    const childA = model.addElement(ElementType.AGENT);
    const childB = model.addElement(ElementType.AGENT);
    model.addContainment(container, childA);
    model.addContainment(container, childB);

    const viewId = model.createView('v');
    const view = model.views.get(viewId);
    view.included.push(container, childA, childB);
    view.boxes.set(container, { x: 0, y: 0, width: 10, height: 10 }); // stale, should be overridden
    view.boxes.set(childA, { x: 100, y: 100, width: 50, height: 40 });
    view.boxes.set(childB, { x: 200, y: 150, width: 30, height: 30 });

    const effective = computeEffectiveBoxes(model, view);
    const box = effective.get(container);

    // bounding box over childA (100,100)-(150,140) and childB
    // (200,150)-(230,180) is (100,100)-(230,180), padded by 30 on every side
    assert.strictEqual(box.x, 70);
    assert.strictEqual(box.y, 70);
    assert.strictEqual(box.width, 190);
    assert.strictEqual(box.height, 140);
  });

  test('computeEffectiveBoxes leaves a childless element using its own stored box', function (assert) {
    const model = new FmcModel();
    const solo = model.addElement(ElementType.AGENT);
    const viewId = model.createView('v');
    const view = model.views.get(viewId);
    view.included.push(solo);
    view.boxes.set(solo, { x: 5, y: 6, width: 120, height: 60 });

    const effective = computeEffectiveBoxes(model, view);
    assert.deepEqual(effective.get(solo), {
      x: 5,
      y: 6,
      width: 120,
      height: 60,
    });
  });

  test('computeEffectiveBoxes handles a grandparent by fitting around its (already-fit) child', function (assert) {
    const model = new FmcModel();
    const grandparent = model.addElement(ElementType.AGENT);
    const parent = model.addElement(ElementType.AGENT);
    const leaf = model.addElement(ElementType.AGENT);
    model.addContainment(grandparent, parent);
    model.addContainment(parent, leaf);

    const viewId = model.createView('v');
    const view = model.views.get(viewId);
    view.included.push(grandparent, parent, leaf);
    view.boxes.set(leaf, { x: 100, y: 100, width: 50, height: 50 });

    const effective = computeEffectiveBoxes(model, view);
    const parentBox = effective.get(parent);
    const grandparentBox = effective.get(grandparent);

    assert.strictEqual(parentBox.x, 70);
    assert.true(grandparentBox.x <= parentBox.x);
    assert.true(grandparentBox.y <= parentBox.y);
    assert.true(
      grandparentBox.x + grandparentBox.width >= parentBox.x + parentBox.width,
    );
    assert.true(
      grandparentBox.y + grandparentBox.height >=
        parentBox.y + parentBox.height,
    );
  });

  test('computeEffectiveBoxes honors a view override: a model-nested element displayed un-nested keeps its own box, and stops enlarging its former container', function (assert) {
    const model = new FmcModel();
    const container = model.addElement(ElementType.AGENT);
    const child = model.addElement(ElementType.AGENT);
    model.addContainment(container, child);

    const viewId = model.createView('v');
    const view = model.views.get(viewId);
    view.included.push(container, child);
    view.boxes.set(container, { x: 0, y: 0, width: 50, height: 50 });
    view.boxes.set(child, { x: 500, y: 500, width: 20, height: 20 });
    view.nestedUnder.set(child, null); // displayed un-nested despite model containment

    const effective = computeEffectiveBoxes(model, view);

    assert.deepEqual(effective.get(child), {
      x: 500,
      y: 500,
      width: 20,
      height: 20,
    });
    assert.deepEqual(effective.get(container), {
      x: 0,
      y: 0,
      width: 50,
      height: 50,
    });
  });

  test('computeEffectiveBoxes respects a manually-resized container box that still fits its children', function (assert) {
    const model = new FmcModel();
    const container = model.addElement(ElementType.AGENT);
    const child = model.addElement(ElementType.AGENT);
    model.addContainment(container, child);

    const viewId = model.createView('v');
    const view = model.views.get(viewId);
    view.included.push(container, child);
    view.boxes.set(child, { x: 100, y: 100, width: 50, height: 40 });
    // Auto-fit would be (70,70)-(180,170); this manual box is bigger on
    // every side, so it should win over the auto-fit computation.
    view.boxes.set(container, { x: 40, y: 40, width: 200, height: 180 });

    const effective = computeEffectiveBoxes(model, view);

    assert.deepEqual(effective.get(container), {
      x: 40,
      y: 40,
      width: 200,
      height: 180,
    });
  });

  test('buildDrawOrder puts a newly-added, unrelated element after every existing subtree (on top), not interleaved by nesting depth', function (assert) {
    const model = new FmcModel();
    const container = model.addElement(ElementType.AGENT);
    const grandchild = model.addElement(ElementType.AGENT);
    const child = model.addElement(ElementType.AGENT);
    model.addContainment(container, child);
    model.addContainment(child, grandchild);
    const newcomer = model.addElement(ElementType.AGENT);

    const viewId = model.createView('v');
    const view = model.views.get(viewId);
    // container's whole subtree (depth 0, 1, 2) is already in the view;
    // newcomer (depth 0, unrelated) is added last, same as a fresh
    // palette-added element would be.
    view.included.push(container, child, grandchild, newcomer);

    const order = buildDrawOrder(model, view);

    // The old "group by global depth" behavior would have sorted this as
    // [container, newcomer, child, grandchild] -- newcomer ending up
    // *below* an unrelated container's nested content. DFS instead keeps
    // each subtree together and newcomer strictly last (topmost).
    assert.deepEqual(order, [container, child, grandchild, newcomer]);
  });

  test('buildDrawOrder keeps a container immediately before its own displayed children', function (assert) {
    const model = new FmcModel();
    const a = model.addElement(ElementType.AGENT);
    const b = model.addElement(ElementType.AGENT);
    const childOfA = model.addElement(ElementType.AGENT);
    model.addContainment(a, childOfA);

    const viewId = model.createView('v');
    const view = model.views.get(viewId);
    view.included.push(a, b, childOfA);

    const order = buildDrawOrder(model, view);

    assert.true(order.indexOf(a) < order.indexOf(childOfA));
    assert.deepEqual(order, [a, childOfA, b]);
  });

  test('verticalArcPath exits the source south and enters the target north when target is below', function (assert) {
    const source = { x: 0, y: 0, width: 60, height: 60 };
    const target = { x: 0, y: 200, width: 60, height: 60 };

    const path = verticalArcPath(source, target);

    assert.deepEqual(path[0], { x: 30, y: 60 }); // source bottom-center
    assert.deepEqual(path.at(-1), { x: 30, y: 200 }); // target top-center
    // Perpendicular in and out: first/last legs share their box's x.
    assert.strictEqual(path[1].x, 30);
    assert.strictEqual(path.at(-2).x, 30);
  });

  function overlapsBox(p1, p2, box) {
    const segMinX = Math.min(p1.x, p2.x);
    const segMaxX = Math.max(p1.x, p2.x);
    const segMinY = Math.min(p1.y, p2.y);
    const segMaxY = Math.max(p1.y, p2.y);
    return (
      segMaxX > box.x &&
      segMinX < box.x + box.width &&
      segMaxY > box.y &&
      segMinY < box.y + box.height
    );
  }

  function assertPathClearOfBoxes(assert, path, boxes) {
    for (let i = 0; i < path.length - 1; i++) {
      for (const box of boxes) {
        assert.false(
          overlapsBox(path[i], path[i + 1], box),
          `segment ${i} should not cross a box`,
        );
      }
    }
  }

  test('verticalArcPath routes around, not through, the boxes when the target is directly above the source', function (assert) {
    const source = { x: 200, y: 200, width: 60, height: 60 };
    const target = { x: 200, y: 0, width: 60, height: 60 };

    const path = verticalArcPath(source, target);

    assertPathClearOfBoxes(assert, path, [source, target]);
    // A loop-back arc always exits its source's top and enters its
    // target's bottom -- fixed, direction-independent ports (per box
    // role) that keep a reciprocal pair of arcs between the same two
    // nodes from ever landing on the same corner and reading as one
    // bidirectional line.
    assert.strictEqual(path[0].y, source.y);
    assert.strictEqual(path.at(-1).y, target.y + target.height);
  });

  test('verticalArcPath exits north (source top) and enters south (target bottom) for a loop-back arc to a box beside it (not above/below)', function (assert) {
    // The case this was actually written for: a transition to the right
    // of a place at roughly the same height, e.g. a self-loop's return
    // arc -- forcing a due-south exit here would have to loop all the
    // way around instead of taking the short way via the near corners.
    const place = { x: 0, y: 0, width: 60, height: 60 };
    const transition = { x: 200, y: 0, width: 120, height: 60 };

    const path = verticalArcPath(place, transition);

    assertPathClearOfBoxes(assert, path, [place, transition]);
    // Exits via place's top-right corner (facing the transition, to its
    // right) instead of straight down from the bottom-center.
    assert.deepEqual(path[0], { x: 60, y: 0 });
    // Enters via transition's bottom-left corner (facing the place, to
    // its left) -- source exits top, target enters bottom, always, so a
    // reciprocal return arc (transition -> place) would use place's
    // bottom and transition's top instead, never colliding with this one.
    assert.deepEqual(path.at(-1), { x: 200, y: 60 });
  });

  test('verticalArcPath mirrors left/right corner choice when the boxes are swapped', function (assert) {
    const transition = { x: 0, y: 0, width: 120, height: 60 };
    const place = { x: 200, y: 0, width: 60, height: 60 };

    const path = verticalArcPath(transition, place);

    assertPathClearOfBoxes(assert, path, [transition, place]);
    // Exits via the transition's top-right corner (facing the place).
    assert.deepEqual(path[0], { x: 120, y: 0 });
    // Enters via the place's bottom-left corner (facing the transition).
    assert.deepEqual(path.at(-1), { x: 200, y: 60 });
  });

  test('verticalArcPath never lands reciprocal arcs on the same corner of either box', function (assert) {
    const place = { x: 0, y: 0, width: 60, height: 60 };
    const transition = { x: 200, y: 0, width: 120, height: 60 };

    const forward = verticalArcPath(place, transition, {
      sourceCircular: true,
    });
    const backward = verticalArcPath(transition, place, {
      targetCircular: true,
    });

    // forward: place is source (exits top) / transition is target (enters
    // bottom). backward: transition is source (exits top) / place is
    // target (enters bottom) -- every anchor below must differ from its
    // counterpart in the other arc, on both boxes.
    assert.notDeepEqual(forward[0], backward.at(-1)); // both touch place
    assert.notDeepEqual(forward.at(-1), backward[0]); // both touch transition
  });

  test('verticalArcPath leaves a circular place from its actual circle, not its bounding-box corner, in the loop-back case', function (assert) {
    const place = { x: 0, y: 0, width: 60, height: 60 };
    const transition = { x: 200, y: 0, width: 120, height: 60 };

    const path = verticalArcPath(place, transition, {
      sourceCircular: true,
    });

    // The box corner would be (60, 0); the point 45° into that quadrant
    // on a circle of radius 30 centered at (30, 30) is further in and
    // down along the circle's own curve.
    const k = Math.SQRT1_2;
    assert.ok(Math.abs(path[0].x - (30 + 30 * k)) < 1e-9);
    assert.ok(Math.abs(path[0].y - (30 - 30 * k)) < 1e-9);
    assert.notDeepEqual(path[0], { x: 60, y: 0 });
    // Still genuinely on the circle: distance from center is the radius.
    const dx = path[0].x - 30;
    const dy = path[0].y - 30;
    assert.ok(Math.abs(Math.hypot(dx, dy) - 30) < 1e-9);
  });

  test('verticalArcPath leaves and arrives via a genuinely diagonal stub before bending to horizontal/vertical', function (assert) {
    const place = { x: 0, y: 0, width: 60, height: 60 };
    const transition = { x: 200, y: 0, width: 120, height: 60 };

    const path = verticalArcPath(place, transition);

    // First segment (anchor -> bend) moves in both x and y -- a diagonal,
    // not an axis-aligned leg.
    assert.notStrictEqual(path[0].x, path[1].x);
    assert.notStrictEqual(path[0].y, path[1].y);
    // Last segment (bend -> anchor) is diagonal too.
    assert.notStrictEqual(path.at(-1).x, path.at(-2).x);
    assert.notStrictEqual(path.at(-1).y, path.at(-2).y);
    // Everything in between stays axis-aligned (horizontal or vertical).
    for (let i = 1; i < path.length - 2; i++) {
      const isAxisAligned =
        path[i].x === path[i + 1].x || path[i].y === path[i + 1].y;
      assert.true(isAxisAligned, `segment ${i} should be axis-aligned`);
    }
  });
});
