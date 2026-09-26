import { module, test } from 'qunit';
import {
  computeEffectiveBoxes,
  displayParentOf,
  nestingDepth,
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
});
