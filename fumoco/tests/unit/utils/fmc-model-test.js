import { module, test } from 'qunit';
import { ElementType, FmcModel, FmcModelError } from 'fumoco/utils/fmc-model';

module('Unit | Utility | fmc-model', function () {
  test('addAccess rejects a non-agent source', function (assert) {
    const model = new FmcModel();
    const location1 = model.addElement(ElementType.LOCATION);
    const location2 = model.addElement(ElementType.LOCATION);
    assert.throws(
      () => model.addAccess(location1, 'read', location2),
      FmcModelError,
    );
  });

  test('addAccess rejects a non-location target', function (assert) {
    const model = new FmcModel();
    const agent1 = model.addElement(ElementType.AGENT);
    const agent2 = model.addElement(ElementType.AGENT);
    assert.throws(() => model.addAccess(agent1, 'read', agent2), FmcModelError);
  });

  test('addChannel rejects a location endpoint', function (assert) {
    const model = new FmcModel();
    const agent = model.addElement(ElementType.AGENT);
    const location = model.addElement(ElementType.LOCATION);
    assert.throws(() => model.addChannel(agent, location, true), FmcModelError);
  });

  test('an element cannot contain itself', function (assert) {
    const model = new FmcModel();
    const agent = model.addElement(ElementType.AGENT);
    assert.throws(() => model.addContainment(agent, agent), FmcModelError);
  });

  test('containment cannot create a cycle', function (assert) {
    const model = new FmcModel();
    const a = model.addElement(ElementType.AGENT);
    const b = model.addElement(ElementType.AGENT);
    model.addContainment(a, b); // a contains b
    assert.throws(() => model.addContainment(b, a), FmcModelError);
  });

  test('containment cannot create a cycle through an indirect ancestor', function (assert) {
    const model = new FmcModel();
    const a = model.addElement(ElementType.AGENT);
    const b = model.addElement(ElementType.AGENT);
    const c = model.addElement(ElementType.AGENT);
    model.addContainment(a, b); // a contains b
    model.addContainment(b, c); // b contains c
    assert.throws(() => model.addContainment(c, a), FmcModelError);
  });

  test('an element can be nested inside more than one container at once', function (assert) {
    const model = new FmcModel();
    const a = model.addElement(ElementType.AGENT);
    const b = model.addElement(ElementType.AGENT);
    const child = model.addElement(ElementType.AGENT);
    model.addContainment(a, child);
    model.addContainment(b, child);

    assert.deepEqual(
      [...model.elements.get(child).parents].sort(),
      [a, b].sort(),
    );
    assert.deepEqual(
      model.childrenOf(a).map((e) => e.id),
      [child],
    );
    assert.deepEqual(
      model.childrenOf(b).map((e) => e.id),
      [child],
    );
  });

  test('removeContainment detaches just that one relationship', function (assert) {
    const model = new FmcModel();
    const a = model.addElement(ElementType.AGENT);
    const b = model.addElement(ElementType.AGENT);
    const child = model.addElement(ElementType.AGENT);
    model.addContainment(a, child);
    model.addContainment(b, child);

    model.removeContainment(a, child);

    assert.deepEqual([...model.elements.get(child).parents], [b]);
  });

  test('removeContainment clears a view display choice that pointed at that relationship', function (assert) {
    const model = new FmcModel();
    const a = model.addElement(ElementType.AGENT);
    const child = model.addElement(ElementType.AGENT);
    model.addContainment(a, child);
    const viewId = model.createView('v');
    model.views.get(viewId).nestedUnder.set(child, a);

    model.removeContainment(a, child);

    assert.false(model.views.get(viewId).nestedUnder.has(child));
  });

  test('removeContainment leaves a view display choice pointing at a different (still-real) parent alone', function (assert) {
    const model = new FmcModel();
    const a = model.addElement(ElementType.AGENT);
    const b = model.addElement(ElementType.AGENT);
    const child = model.addElement(ElementType.AGENT);
    model.addContainment(a, child);
    model.addContainment(b, child);
    const viewId = model.createView('v');
    model.views.get(viewId).nestedUnder.set(child, b);

    model.removeContainment(a, child); // unrelated to the view's b-display choice

    assert.strictEqual(model.views.get(viewId).nestedUnder.get(child), b);
  });

  test("removeElement clears that element as a view display choice, both as the element and as someone else's chosen parent", function (assert) {
    const model = new FmcModel();
    const parent = model.addElement(ElementType.AGENT);
    const child = model.addElement(ElementType.AGENT);
    model.addContainment(parent, child);
    const viewId = model.createView('v');
    const view = model.views.get(viewId);
    view.nestedUnder.set(child, parent);

    model.removeElement(parent);

    assert.false(view.nestedUnder.has(child));
    assert.false(view.nestedUnder.has(parent));
  });

  test('removeElement detaches children and drops incident edges', function (assert) {
    const model = new FmcModel();
    const parent = model.addElement(ElementType.AGENT);
    const child = model.addElement(ElementType.AGENT);
    const location = model.addElement(ElementType.LOCATION);
    model.addContainment(parent, child);
    model.addAccess(parent, 'read', location);

    model.removeElement(parent);

    assert.deepEqual([...model.elements.get(child).parents], []);
    assert.strictEqual(model.accesses.length, 0);
    assert.false(model.elements.has(parent));
  });

  test('toJSON/fromJSON round-trips a model', function (assert) {
    const model = new FmcModel();
    const agent = model.addElement(ElementType.AGENT, { label: 'A' });
    const location = model.addElement(ElementType.LOCATION, {
      label: 'S',
      dashed: true,
    });
    model.addAccess(agent, 'modify', location);
    const viewId = model.createView('overview', 'block');
    model.views.get(viewId).included.push(agent, location);
    model.views
      .get(viewId)
      .boxes.set(agent, { x: 0, y: 0, width: 120, height: 60 });

    const restored = FmcModel.fromJSON(model.toJSON());

    assert.strictEqual(restored.elements.get(agent).label, 'A');
    assert.true(restored.elements.get(location).dashed);
    assert.strictEqual(restored.accesses.length, 1);
    assert.strictEqual(restored.views.get(viewId).included.length, 2);
    assert.strictEqual(restored.views.get(viewId).boxes.get(agent).width, 120);
  });

  test("a view's nestedUnder display choices round-trip, including an explicit un-nest (null)", function (assert) {
    const model = new FmcModel();
    const container = model.addElement(ElementType.AGENT);
    const nested = model.addElement(ElementType.AGENT);
    const unnested = model.addElement(ElementType.AGENT);
    model.addContainment(container, nested);
    model.addContainment(container, unnested);
    const viewId = model.createView('v');
    const view = model.views.get(viewId);
    view.nestedUnder.set(nested, container);
    view.nestedUnder.set(unnested, null); // explicitly displayed un-nested

    const restored = FmcModel.fromJSON(model.toJSON());
    const restoredView = restored.views.get(viewId);

    assert.strictEqual(restoredView.nestedUnder.get(nested), container);
    assert.strictEqual(restoredView.nestedUnder.get(unnested), null);
  });

  module('channels as locations', function () {
    test('addChannel(directed) creates a location with write/read access, not a separate edge type', function (assert) {
      const model = new FmcModel();
      const a = model.addElement(ElementType.AGENT);
      const b = model.addElement(ElementType.AGENT);

      const placeId = model.addChannel(a, b, true);

      const place = model.elements.get(placeId);
      assert.strictEqual(place.type, ElementType.LOCATION);
      assert.deepEqual(place.channel, { shorthand: false });
      assert.deepEqual(
        model.accesses.map((edge) => [edge.agent, edge.kind, edge.location]),
        [
          [a, 'write', placeId],
          [b, 'read', placeId],
        ],
      );
    });

    test('addChannel(bidirectional) gives both agents modify access to the place', function (assert) {
      const model = new FmcModel();
      const a = model.addElement(ElementType.AGENT);
      const b = model.addElement(ElementType.AGENT);

      const placeId = model.addChannel(a, b, false);

      assert.deepEqual(
        model.accesses.map((edge) => [edge.agent, edge.kind]),
        [
          [a, 'modify'],
          [b, 'modify'],
        ],
      );
      assert.strictEqual(model.accesses[0].location, placeId);
      assert.strictEqual(model.accesses[1].location, placeId);
    });

    test('addReqRes(shorthand) creates one bold-labeled place with write/read access', function (assert) {
      const model = new FmcModel();
      const a = model.addElement(ElementType.AGENT);
      const b = model.addElement(ElementType.AGENT);

      const [placeId] = model.addReqRes(a, b, { shorthand: true });

      const place = model.elements.get(placeId);
      assert.strictEqual(place.label, 'R▶');
      assert.deepEqual(place.channel, { shorthand: true });
      assert.deepEqual(
        model.accesses.map((edge) => [edge.agent, edge.kind]),
        [
          [a, 'write'],
          [b, 'read'],
        ],
      );
    });

    test('addReqRes(long form) creates two places, REQ and RES, with opposite access directions', function (assert) {
      const model = new FmcModel();
      const a = model.addElement(ElementType.AGENT);
      const b = model.addElement(ElementType.AGENT);

      const [reqId, resId] = model.addReqRes(a, b, { shorthand: false });

      assert.strictEqual(model.elements.get(reqId).label, 'REQ');
      assert.strictEqual(model.elements.get(resId).label, 'RES');
      assert.deepEqual(
        model.accesses.map((edge) => [edge.agent, edge.kind, edge.location]),
        [
          [a, 'write', reqId],
          [b, 'read', reqId],
          [b, 'write', resId],
          [a, 'read', resId],
        ],
      );
    });

    test('removing a channel place removes its access edges like any other location', function (assert) {
      const model = new FmcModel();
      const a = model.addElement(ElementType.AGENT);
      const b = model.addElement(ElementType.AGENT);
      const placeId = model.addChannel(a, b, true);

      model.removeElement(placeId);

      assert.strictEqual(model.accesses.length, 0);
      assert.false(model.elements.has(placeId));
    });
  });
});
