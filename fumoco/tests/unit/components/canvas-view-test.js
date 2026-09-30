import { module, test } from 'qunit';
import {
  buildDrawOrder,
  channelFlow,
  branchPath,
  bundledSideToward,
  computeEffectiveBoxes,
  displayParentOf,
  dividerLine,
  ellipsisDots,
  lensEnds,
  nestingDepth,
  joinLegs,
  orthogonalPath,
  pathMidpoint,
  outsideLabelPosition,
  snapBox,
  swapBoxAxes,
  trunkPoints,
  verticalArcPath,
  withFlowArrow,
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

  test('verticalArcPath routes around, not through, the boxes when the target is directly above the source (overlapping x-ranges)', function (assert) {
    const source = { x: 200, y: 200, width: 60, height: 60 };
    const target = { x: 200, y: 0, width: 60, height: 60 };

    const path = verticalArcPath(source, target);

    assertPathClearOfBoxes(assert, path, [source, target]);
    // Same x-range as the target -- not a "beside" pair, so this keeps
    // the plain south-exit/north-enter ports and routes around via a
    // lane to the side, same as the ordinary forward case's ports.
    assert.strictEqual(path[0].y, source.y + source.height);
    assert.strictEqual(path.at(-1).y, target.y);
  });

  test('verticalArcPath exits the place diagonally and enters the transition straight from the north, for a loop-back arc to a box beside it', function (assert) {
    // The case this was actually written for: a transition to the right
    // of a place at roughly the same height, e.g. a self-loop's return
    // arc -- forcing a due-south exit here would have to loop all the
    // way around instead of taking the short way via the near corner.
    // Petri arcs are always place<->transition, so only the place (the
    // circular end) gets the diagonal corner; the transition keeps its
    // plain perpendicular port, same as the forward case.
    const place = { x: 0, y: 0, width: 60, height: 60 };
    const transition = { x: 200, y: 0, width: 120, height: 60 };

    const path = verticalArcPath(place, transition, {
      sourceCircular: true,
    });

    // Only checked against the *other* box: the exit stub necessarily
    // grazes the place's own bounding-square corner on its way out (it
    // leaves from the circle, which sits just inside that corner), which
    // is the harmless, intended effect of that technique, not a real
    // crossing -- see the dedicated circle-boundary test below.
    assertPathClearOfBoxes(assert, path, [transition]);
    // Exits via the actual point on the place's circle at 45°, not its
    // bounding-box corner (which would be (60, 0)).
    const k = Math.SQRT1_2;
    assert.deepEqual(path[0], { x: 30 + 30 * k, y: 30 - 30 * k });
    // Enters via the transition's plain top-center port, perpendicular to
    // its northern edge -- no corner, since only the circular end needs
    // the diagonal treatment.
    assert.deepEqual(path.at(-1), { x: 260, y: 0 });
  });

  test('verticalArcPath exits the transition straight south and enters the place diagonally, for the reciprocal return arc', function (assert) {
    const transition = { x: 0, y: 0, width: 120, height: 60 };
    const place = { x: 200, y: 0, width: 60, height: 60 };

    const path = verticalArcPath(transition, place, {
      targetCircular: true,
    });

    // Only checked against the *other* box; see the comment on the
    // previous test for why the circular end's own box is excluded here.
    assertPathClearOfBoxes(assert, path, [transition]);
    // Exits via the transition's plain bottom-center port.
    assert.deepEqual(path[0], { x: 60, y: 60 });
    // Enters via the actual point on the place's circle at 45° (facing
    // the transition), not its bounding-box corner.
    const k = Math.SQRT1_2;
    assert.deepEqual(path.at(-1), { x: 230 - 30 * k, y: 30 + 30 * k });
  });

  test('verticalArcPath never lands reciprocal arcs on the same corner/port of either box', function (assert) {
    const place = { x: 0, y: 0, width: 60, height: 60 };
    const transition = { x: 200, y: 0, width: 120, height: 60 };

    const forward = verticalArcPath(place, transition, {
      sourceCircular: true,
    });
    const backward = verticalArcPath(transition, place, {
      targetCircular: true,
    });

    // forward: place is source (top lane) / transition is target (top
    // port). backward: transition is source (bottom port) / place is
    // target (bottom lane) -- every anchor below must differ from its
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

  test('verticalArcPath leaves the circular end via a genuinely diagonal stub before bending to horizontal/vertical', function (assert) {
    const place = { x: 0, y: 0, width: 60, height: 60 };
    const transition = { x: 200, y: 0, width: 120, height: 60 };

    const path = verticalArcPath(place, transition, {
      sourceCircular: true,
    });

    // First segment (anchor -> bend) moves in both x and y -- a diagonal,
    // not an axis-aligned leg, since the place (source) is circular.
    assert.notStrictEqual(path[0].x, path[1].x);
    assert.notStrictEqual(path[0].y, path[1].y);
    // Everything else stays axis-aligned (horizontal or vertical): the
    // transition (target) is rectangular, so its own port is a plain
    // perpendicular attachment with no diagonal stub.
    for (let i = 1; i < path.length - 1; i++) {
      const isAxisAligned =
        path[i].x === path[i + 1].x || path[i].y === path[i + 1].y;
      assert.true(isAxisAligned, `segment ${i} should be axis-aligned`);
    }
  });

  // Human-provided regression tests: real box layouts the user pasted in
  // from the running app after spotting a routing defect, traced by hand
  // against the actual algorithm rather than invented from the code.

  test('Reg test 1 (human-provided): a place with straight arcs above/below and a reciprocal loop-back pair beside it', function (assert) {
    const P = { x: 130, y: 170, width: 60, height: 60 };
    const A = { x: 100, y: 10, width: 120, height: 60 }; // above P
    const C = { x: 100, y: 370, width: 120, height: 60 }; // below P
    const B = { x: 350, y: 170, width: 120, height: 60 }; // beside P

    // A -> P and P -> C both share x-center 160 with their neighbor, so
    // each is the plain forward case collapsed to a straight line.
    assert.deepEqual(verticalArcPath(A, P, { targetCircular: true }), [
      { x: 160, y: 70 },
      { x: 160, y: 170 },
    ]);
    assert.deepEqual(verticalArcPath(P, C, { sourceCircular: true }), [
      { x: 160, y: 230 },
      { x: 160, y: 370 },
    ]);

    const k = Math.SQRT1_2;
    // P -> B: leaves P's circle to the NE, bends onto a lane above both
    // boxes, then straight down into B's plain north port.
    const pToB = verticalArcPath(P, B, { sourceCircular: true });
    assert.deepEqual(pToB, [
      { x: 160 + 30 * k, y: 200 - 30 * k },
      { x: 160 + 30 * k + 28, y: 200 - 30 * k - 28 },
      { x: 410, y: 200 - 30 * k - 28 },
      { x: 410, y: 170 },
    ]);
    // B -> P (the reciprocal arc): straight south out of B, then into
    // P's circle from the SE -- never the same corner/port as P -> B.
    const bToP = verticalArcPath(B, P, { targetCircular: true });
    assert.deepEqual(bToP, [
      { x: 410, y: 230 },
      { x: 410, y: 200 + 30 * k + 28 },
      { x: 160 + 30 * k + 28, y: 200 + 30 * k + 28 },
      { x: 160 + 30 * k, y: 200 + 30 * k },
    ]);
    // The two never share an anchor on either box.
    assert.notDeepEqual(pToB[0], bToP.at(-1));
    assert.notDeepEqual(pToB.at(-1), bToP[0]);
  });

  test('Reg test 2 (human-provided): a straight plumb line beats a forced bend to the target center when it lands clear of the corners', function (assert) {
    const P = { x: 130, y: 170, width: 60, height: 60 };
    // C's own x-center (170) differs from P's (160), but P is a place,
    // so its exit is fixed at its own circle pole (160) regardless --
    // and that x still lands inside C's top edge, clear of both corners
    // by more than EDGE_CORNER_RADIUS, so C's (flexible, rectangular)
    // entry can shift to meet it with a straight vertical line.
    const C = { x: 110, y: 280, width: 120, height: 60 };

    const path = verticalArcPath(P, C, { sourceCircular: true });

    assert.deepEqual(path, [
      { x: 160, y: 230 },
      { x: 160, y: 280 },
    ]);
  });

  test('Reg test 3 (human-provided): a circular target keeps its own pole fixed -- the flexible (rectangular) source shifts to meet it, not the other way around', function (assert) {
    const A = { x: 110, y: 10, width: 120, height: 60 };
    // P is a place: its entry point must always be its own circle pole
    // (x=160, the true "top" of the circle), never wherever A's own
    // center (170) happens to land. Since 160 still falls safely inside
    // A's own top edge (clear of both corners), A's exit shifts to meet
    // it instead -- a straight line at x=160, not A's own center.
    const P = { x: 130, y: 170, width: 60, height: 60 };

    const path = verticalArcPath(A, P, { targetCircular: true });

    assert.deepEqual(path, [
      { x: 160, y: 70 },
      { x: 160, y: 170 },
    ]);
  });

  test('Reg test 4 (human-provided): two boxes pushed flush against each other (zero x-gap) fall back to the safe wraparound, not the diagonal stub', function (assert) {
    const P = { x: 130, y: 170, width: 60, height: 60 };
    // C's left edge (190) exactly meets P's right edge (190) -- disjoint
    // x-ranges, but zero gap between them. The diagonal stub's fixed
    // 28px reach isn't enough to clear C's left edge from there, so the
    // stub would land *inside* C and the path would cut through it.
    const C = { x: 190, y: 40, width: 120, height: 60 };

    const path = verticalArcPath(P, C, { sourceCircular: true });

    assertPathClearOfBoxes(assert, path, [P, C]);
    // Falls back to the safe wraparound: south out of P, west of both,
    // north past C, then straight into C's own top edge.
    assert.deepEqual(path, [
      { x: 160, y: 230 },
      { x: 160, y: 250 },
      { x: 110, y: 250 },
      { x: 110, y: 20 },
      { x: 250, y: 20 },
      { x: 250, y: 40 },
    ]);
  });

  test('Reg test 5 (human-provided): the diagonal-stub shortcut can still cut through the transition when the stub does not reach the lane height', function (assert) {
    const P = { x: 130, y: 170, width: 60, height: 60 };
    // C sits well clear of P horizontally (a 64px gap, past the
    // Reg-test-4 fallback threshold) but far enough above that the
    // diagonal stub's fixed 28px reach doesn't get anywhere near C's own
    // top edge -- jumping straight from the stub to the lane used to be
    // a diagonal segment that sliced through C's top-left corner.
    const C = { x: 254, y: 40.6044921875, width: 120, height: 60 };

    assertPathClearOfBoxes(
      assert,
      verticalArcPath(P, C, { sourceCircular: true }),
      [C],
    );
    assertPathClearOfBoxes(
      assert,
      verticalArcPath(C, P, { targetCircular: true }),
      [C],
    );
  });

  test('verticalArcPath never crosses the transition box, swept across many place/transition placements (general regression guard)', function (assert) {
    // A broader, systematic version of Reg test 4/5: those were each one
    // specific placement that happened to cut through the transition.
    // Rather than wait for the next one-off report, sweep a grid of
    // transition positions around a fixed place and check every one, in
    // both arc directions -- this is the standing guard the user asked
    // for after finding two separate crossings this way.
    const place = { x: 0, y: 0, width: 60, height: 60 };

    function overlapsBoxes(a, b) {
      return (
        a.x < b.x + b.width &&
        b.x < a.x + a.width &&
        a.y < b.y + b.height &&
        b.y < a.y + a.height
      );
    }

    let checked = 0;
    for (let dx = -400; dx <= 400; dx += 40) {
      for (let dy = -400; dy <= 400; dy += 40) {
        const transition = { x: dx, y: dy, width: 120, height: 60 };
        if (overlapsBoxes(place, transition)) continue; // not a real layout
        checked += 1;
        assertPathClearOfBoxes(
          assert,
          verticalArcPath(place, transition, { sourceCircular: true }),
          [transition],
        );
        assertPathClearOfBoxes(
          assert,
          verticalArcPath(transition, place, { targetCircular: true }),
          [transition],
        );
      }
    }
    assert.true(checked > 100, 'the sweep actually exercised many placements');
  });

  test('verticalArcPath never crosses the transition box, swept across many place/transition sizes too (not just positions)', function (assert) {
    // The position sweep above holds both boxes at their default sizes.
    // This sweeps place and transition *sizes* as well -- tiny places,
    // very wide/narrow transitions, etc. -- since the diagonal stub's
    // safety margins (ARC_DIAGONAL_STUB vs. EDGE_CORNER_RADIUS) were
    // derived assuming roughly-default proportions and could plausibly
    // break down at the extremes.
    function overlapsBoxes(a, b) {
      return (
        a.x < b.x + b.width &&
        b.x < a.x + a.width &&
        a.y < b.y + b.height &&
        b.y < a.y + a.height
      );
    }

    const placeSizes = [
      [20, 20],
      [60, 60],
      [100, 100],
      [60, 120],
      [120, 60],
    ];
    const transitionSizes = [
      [60, 60],
      [120, 60],
      [200, 40],
      [40, 200],
      [20, 20],
    ];

    let checked = 0;
    for (const [pw, ph] of placeSizes) {
      const place = { x: 0, y: 0, width: pw, height: ph };
      for (const [tw, th] of transitionSizes) {
        for (let dx = -300; dx <= 300; dx += 150) {
          for (let dy = -300; dy <= 300; dy += 150) {
            const transition = { x: dx, y: dy, width: tw, height: th };
            if (overlapsBoxes(place, transition)) continue;
            checked += 1;
            assertPathClearOfBoxes(
              assert,
              verticalArcPath(place, transition, { sourceCircular: true }),
              [transition],
            );
            assertPathClearOfBoxes(
              assert,
              verticalArcPath(transition, place, { targetCircular: true }),
              [transition],
            );
          }
        }
      }
    }
    assert.true(
      checked > 300,
      'the sweep actually exercised many combinations',
    );
  });

  test('orthogonalPath (block diagram / ER routing) never crosses either box, swept across many placements and sizes', function (assert) {
    // orthogonalPath has no obstacle-avoidance for *other* boxes in the
    // view (documented, accepted limitation) -- but it must never cut
    // through the interior of the two boxes it's actually connecting,
    // regardless of their relative position or size. Zero prior test
    // coverage of this function before this sweep.
    function overlapsBoxes(a, b) {
      return (
        a.x < b.x + b.width &&
        b.x < a.x + a.width &&
        a.y < b.y + b.height &&
        b.y < a.y + a.height
      );
    }

    const a = { x: 0, y: 0, width: 60, height: 60 };
    const sizes = [
      [60, 60],
      [120, 60],
      [200, 40],
      [40, 200],
    ];

    let checked = 0;
    for (const [w, h] of sizes) {
      for (let dx = -300; dx <= 300; dx += 75) {
        for (let dy = -300; dy <= 300; dy += 75) {
          const b = { x: dx, y: dy, width: w, height: h };
          if (overlapsBoxes(a, b)) continue;
          checked += 1;
          assertPathClearOfBoxes(assert, orthogonalPath(a, b), [a, b]);
        }
      }
    }
    assert.true(checked > 200, 'the sweep actually exercised many placements');
  });
});

module('Unit | Component | canvas-view (turned ER relations)', function () {
  function erView(entityA, entityB) {
    const model = new FmcModel();
    const a = model.addElement(ElementType.ENTITY_SET);
    const b = model.addElement(ElementType.ENTITY_SET);
    const r = model.addElement(ElementType.RELATION);
    model.addArc(a, r);
    model.addArc(r, b);
    const view = model.views.get(model.createView('v', 'er'));
    view.included.push(a, b, r);
    view.boxes.set(a, { ...entityA, width: 120, height: 60 });
    view.boxes.set(b, { ...entityB, width: 120, height: 60 });
    view.boxes.set(r, { x: 100, y: 200, width: 120, height: 60 });
    return { model, view, r };
  }

  test('a relation between side-by-side entity sets keeps its stored box', function (assert) {
    const { model, view, r } = erView({ x: 0, y: 200 }, { x: 400, y: 200 });
    assert.deepEqual(computeEffectiveBoxes(model, view).get(r), {
      x: 100,
      y: 200,
      width: 120,
      height: 60,
    });
  });

  test('a relation between stacked entity sets turns 90 degrees about its center', function (assert) {
    const { model, view, r } = erView({ x: 100, y: 0 }, { x: 100, y: 400 });
    const box = computeEffectiveBoxes(model, view).get(r);
    // center (160,230) kept, width/height swapped
    assert.deepEqual(box, {
      x: 130,
      y: 170,
      width: 60,
      height: 120,
      rotated: true,
    });
    assert.deepEqual(
      swapBoxAxes(box),
      { x: 100, y: 200, width: 120, height: 60 },
      'turning it back restores the stored box',
    );
  });
});

module('Unit | Component | canvas-view (reified relation circle)', function () {
  test('an entity set around one relation is a circle twice its longer side', function (assert) {
    const model = new FmcModel();
    const relation = model.addElement(ElementType.RELATION);
    const entitySet = model.reifyRelation(relation);
    const view = model.views.get(model.createView('v', 'er'));
    view.included.push(relation, entitySet);
    view.nestedUnder.set(relation, entitySet);
    view.boxes.set(relation, { x: 100, y: 100, width: 45, height: 15 });
    // center (122.5, 107.5), diameter 90
    assert.deepEqual(computeEffectiveBoxes(model, view).get(entitySet), {
      x: 77.5,
      y: 62.5,
      width: 90,
      height: 90,
    });
  });
});

module('Unit | Component | canvas-view (guide snapping)', function () {
  const box = { x: 0, y: 0, width: 45, height: 15 };

  test('snaps the nearest of left/center/right onto a guide within tolerance', function (assert) {
    const guides = [{ axis: 'x', pos: 300 }];
    // right edge 297 -> 300
    assert.strictEqual(snapBox(guides, { ...box, x: 252 }, 6).x, 255);
    // center 302.5 -> 300
    assert.strictEqual(snapBox(guides, { ...box, x: 280 }, 6).x, 277.5);
    // left edge 303 -> 300
    assert.strictEqual(snapBox(guides, { ...box, x: 303 }, 6).x, 300);
  });

  test('falls back to the grid outside tolerance or on the other axis', function (assert) {
    const guides = [{ axis: 'x', pos: 300 }];
    assert.deepEqual(snapBox(guides, { ...box, x: 233, y: 107 }, 6), {
      x: 230,
      y: 110,
    });
  });
});

module('Unit | Component | canvas-view (lens edges)', function () {
  test('side-by-side boxes face each other at the middle of their overlap', function (assert) {
    const a = { x: 0, y: 0, width: 100, height: 60 };
    const b = { x: 200, y: 20, width: 100, height: 60 };
    assert.deepEqual(lensEnds(a, b), {
      p: { x: 100, y: 40 },
      q: { x: 200, y: 40 },
      span: 40,
    });
  });

  test('stacked boxes face each other vertically', function (assert) {
    const a = { x: 0, y: 200, width: 100, height: 60 };
    const b = { x: 50, y: 0, width: 100, height: 60 };
    assert.deepEqual(lensEnds(a, b), {
      p: { x: 75, y: 200 },
      q: { x: 75, y: 60 },
      span: 50,
    });
  });

  test('boxes too close for a legible lens do not (Evaluator and SP in the user model)', function (assert) {
    // SP's bottom at 53.5, Evaluator's top at 79: a 26px gap
    const sp = { x: 632, y: 13, width: 63, height: 40.5 };
    const evaluator = { x: 631, y: 79, width: 203, height: 60 };
    assert.strictEqual(lensEnds(evaluator, sp), null);
  });

  test('diagonally offset boxes (no overlapping sides) do not', function (assert) {
    const a = { x: 0, y: 0, width: 100, height: 60 };
    const b = { x: 200, y: 100, width: 100, height: 60 };
    assert.strictEqual(lensEnds(a, b), null);
  });
});

module('Unit | Component | canvas-view (edge trees)', function () {
  const box = { x: 100, y: 100, width: 120, height: 60 };

  test('bundledSideToward picks a bundled side the other box lies beyond', function (assert) {
    const aboveLeft = { x: 0, y: 0, width: 60, height: 30 };
    assert.strictEqual(bundledSideToward(box, ['n'], aboveLeft), 'n');
    assert.strictEqual(bundledSideToward(box, ['s'], aboveLeft), null);
    const beside = { x: 300, y: 110, width: 60, height: 30 };
    assert.strictEqual(bundledSideToward(box, ['n', 'e'], beside), 'e');
  });

  test('branchPath: down to the junction level, then across into it', function (assert) {
    const parser = { x: 40, y: 60, width: 120, height: 60 };
    assert.deepEqual(branchPath(parser, { x: 300, y: 256 }, 'n'), [
      { x: 100, y: 120 },
      { x: 100, y: 256 },
      { x: 300, y: 256 },
    ]);
  });

  test('branchPath: straight in when the box sits over the junction', function (assert) {
    const checker = { x: 240, y: 60, width: 120, height: 60 };
    assert.deepEqual(branchPath(checker, { x: 300, y: 256 }, 'n'), [
      { x: 300, y: 120 },
      { x: 300, y: 256 },
    ]);
  });

  test('trunkPoints: side midpoint and a junction 24px out', function (assert) {
    assert.deepEqual(trunkPoints(box, 'n'), {
      mid: { x: 160, y: 100 },
      junction: { x: 160, y: 76 },
    });
    assert.deepEqual(trunkPoints(box, 'e'), {
      mid: { x: 220, y: 130 },
      junction: { x: 244, y: 130 },
    });
  });
});

module('Unit | Component | canvas-view (waypoint routing)', function () {
  // Waypoint (238,137) beside "New location" (100..220 x 100..160) -- the
  // last leg drops perpendicular onto its right side.
  test('Reg test 6 (human-provided): a waypoint beside a box meets it at the foot of the perpendicular', function (assert) {
    const waypoint = { x: 238, y: 137, width: 0, height: 0 };
    const location = { x: 100, y: 100, width: 120, height: 60 };
    assert.deepEqual(orthogonalPath(waypoint, location), [
      { x: 238, y: 137 },
      { x: 220, y: 137 },
    ]);
  });

  test('a waypoint above a box drops straight down into it', function (assert) {
    const waypoint = { x: 150, y: 40, width: 0, height: 0 };
    const location = { x: 100, y: 100, width: 120, height: 60 };
    assert.deepEqual(orthogonalPath(waypoint, location), [
      { x: 150, y: 40 },
      { x: 150, y: 100 },
    ]);
  });

  test('two waypoints on one vertical line join straight', function (assert) {
    const a = { x: 50, y: 0, width: 0, height: 0 };
    const b = { x: 50, y: 90, width: 0, height: 0 };
    assert.deepEqual(orthogonalPath(a, b), [
      { x: 50, y: 0 },
      { x: 50, y: 90 },
    ]);
  });
});

module(
  'Unit | Component | canvas-view (no reversal at a waypoint)',
  function () {
    // A read edge from "New location" (200..320 x 130..190) through a
    // waypoint (366,203) to "New agent" (350..470 x 10..70). The default
    // bend (right, then down to the waypoint) makes the next leg climb
    // straight back up the same line: a spike. A waypoint may never turn
    // the path around.
    test('Reg test 7 (human-provided): a waypoint never makes the path double back', function (assert) {
      const location = { x: 200, y: 130, width: 120, height: 60 };
      const waypoint = { x: 366, y: 203, width: 0, height: 0 };
      const agent = { x: 350, y: 10, width: 120, height: 60 };
      const legs = [
        [
          orthogonalPath(location, waypoint),
          orthogonalPath(location, waypoint, true),
        ],
        [orthogonalPath(waypoint, agent)],
      ];
      assert.deepEqual(joinLegs(legs), [
        { x: 260, y: 190 },
        { x: 260, y: 203 },
        { x: 366, y: 203 },
        { x: 366, y: 70 },
      ]);
    });

    test('joinLegs keeps the default bends when nothing doubles back', function (assert) {
      const a = { x: 0, y: 0, width: 100, height: 50 };
      const waypoint = { x: 300, y: 200, width: 0, height: 0 };
      const b = { x: 400, y: 170, width: 100, height: 60 };
      const legs = [
        [orthogonalPath(a, waypoint), orthogonalPath(a, waypoint, true)],
        [orthogonalPath(waypoint, b)],
      ];
      assert.deepEqual(joinLegs(legs), [
        ...orthogonalPath(a, waypoint),
        ...orthogonalPath(waypoint, b).slice(1),
      ]);
    });
  },
);

module('Unit | Component | canvas-view (channel labels)', function () {
  function reqRes(sourceBox, targetBox) {
    const model = new FmcModel();
    const source = model.addElement(ElementType.AGENT);
    const target = model.addElement(ElementType.AGENT);
    const [place] = model.addReqRes(source, target, { shorthand: true });
    const boxes = new Map([
      [source, sourceBox],
      [target, targetBox],
    ]);
    return { model, place, boxes };
  }

  test('the R triangle points from requester to server', function (assert) {
    const left = { x: 0, y: 0, width: 100, height: 60 };
    const right = { x: 300, y: 0, width: 100, height: 60 };
    const below = { x: 0, y: 300, width: 100, height: 60 };
    for (const [from, to, expected] of [
      [left, right, 'R\u2009▶'],
      [right, left, 'R\u2009◀'],
      [left, below, 'R\u2009▼'],
      [below, left, 'R\u2009▲'],
    ]) {
      const { model, place, boxes } = reqRes(from, to);
      assert.strictEqual(
        withFlowArrow('R▶', channelFlow(model, place, boxes)),
        expected,
      );
    }
  });

  test('a bidirectional channel has an axis but no direction', function (assert) {
    const model = new FmcModel();
    const a = model.addElement(ElementType.AGENT);
    const b = model.addElement(ElementType.AGENT);
    const place = model.addChannel(a, b, false);
    const boxes = new Map([
      [a, { x: 0, y: 0, width: 100, height: 60 }],
      [b, { x: 0, y: 300, width: 100, height: 60 }],
    ]);
    assert.deepEqual(channelFlow(model, place, boxes), { axis: 'y', sign: 0 });
  });

  test('outside labels sit centered above, or beside a vertical channel', function (assert) {
    const circle = { x: 100, y: 100, width: 28, height: 28 };
    const size = { width: 20, height: 15 };
    assert.deepEqual(outsideLabelPosition(circle, size), { x: 104, y: 81 });
    assert.deepEqual(outsideLabelPosition(circle, size, 'right'), {
      x: 132,
      y: 106.5,
    });
  });
});

module('Unit | Component | canvas-view (ellipsis)', function () {
  test('three dots along the longer side', function (assert) {
    assert.deepEqual(ellipsisDots({ width: 45, height: 15 }), [
      { x: 7.5, y: 7.5, radius: 3 },
      { x: 22.5, y: 7.5, radius: 3 },
      { x: 37.5, y: 7.5, radius: 3 },
    ]);
    assert.deepEqual(
      ellipsisDots({ width: 15, height: 45 }).map((d) => [d.x, d.y]),
      [
        [7.5, 7.5],
        [7.5, 22.5],
        [7.5, 37.5],
      ],
      'a tall ellipsis runs vertically',
    );
  });

  test('an explicit orientation overrides the shape, including diagonals', function (assert) {
    const box = { width: 30, height: 30 };
    const at = (o) => ellipsisDots(box, o).map((d) => [d.x, d.y]);
    assert.deepEqual(at('diagonal-down'), [
      [5, 5],
      [15, 15],
      [25, 25],
    ]);
    assert.deepEqual(at('diagonal-up'), [
      [5, 25],
      [15, 15],
      [25, 5],
    ]);
    assert.deepEqual(at('vertical'), [
      [15, 5],
      [15, 15],
      [15, 25],
    ]);
  });
});

module('Unit | Component | canvas-view (swimlane divider)', function () {
  test('the dashed line runs through the middle along the longer side', function (assert) {
    assert.deepEqual(dividerLine({ width: 10, height: 300 }), [5, 0, 5, 300]);
    assert.deepEqual(dividerLine({ width: 300, height: 10 }), [0, 5, 300, 5]);
  });
});

module('Unit | Component | canvas-view (connector annotations)', function () {
  test('pathMidpoint is halfway along the whole route, not the middle vertex', function (assert) {
    // 100 across, then 300 down: halfway (200) is 100 into the second leg
    assert.deepEqual(
      pathMidpoint([
        { x: 0, y: 0 },
        { x: 100, y: 0 },
        { x: 100, y: 300 },
      ]),
      { x: 100, y: 100 },
    );
  });
});
