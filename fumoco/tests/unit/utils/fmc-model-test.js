import { module, test } from 'qunit';
import {
  ElementType,
  FmcModel,
  FmcModelError,
  isRoundedElementType,
} from 'fumoco/utils/fmc-model';

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

  module('access edges as addressable entities', function () {
    test('addAccess gives each edge a stable, distinct id', function (assert) {
      const model = new FmcModel();
      const agent = model.addElement(ElementType.AGENT);
      const location = model.addElement(ElementType.LOCATION);

      const edge1 = model.addAccess(agent, 'read', location);
      const edge2 = model.addAccess(agent, 'write', location);

      assert.ok(edge1.id);
      assert.ok(edge2.id);
      assert.notStrictEqual(edge1.id, edge2.id);
    });

    test('updateAccessKind changes just that edge, leaving its id and endpoints alone', function (assert) {
      const model = new FmcModel();
      const agent = model.addElement(ElementType.AGENT);
      const location = model.addElement(ElementType.LOCATION);
      const edge = model.addAccess(agent, 'read', location);

      model.updateAccessKind(edge.id, 'write');

      assert.strictEqual(model.accesses.length, 1);
      assert.strictEqual(model.accesses[0].id, edge.id);
      assert.strictEqual(model.accesses[0].kind, 'write');
      assert.strictEqual(model.accesses[0].agent, agent);
      assert.strictEqual(model.accesses[0].location, location);
    });

    test('removeAccess deletes just that edge and its routing waypoints, leaving others alone', function (assert) {
      const model = new FmcModel();
      const agent = model.addElement(ElementType.AGENT);
      const location = model.addElement(ElementType.LOCATION);
      const edge1 = model.addAccess(agent, 'read', location);
      const edge2 = model.addAccess(agent, 'write', location);
      const viewId = model.createView('v');
      const view = model.views.get(viewId);
      view.edgeWaypoints.set(edge1.id, [{ x: 10, y: 10 }]);

      model.removeAccess(edge1.id);

      assert.strictEqual(model.accesses.length, 1);
      assert.strictEqual(model.accesses[0].id, edge2.id);
      assert.false(view.edgeWaypoints.has(edge1.id));
    });

    test('removeElement also drops routing waypoints for any edge it was part of', function (assert) {
      const model = new FmcModel();
      const agent = model.addElement(ElementType.AGENT);
      const location = model.addElement(ElementType.LOCATION);
      const edge = model.addAccess(agent, 'read', location);
      const viewId = model.createView('v');
      const view = model.views.get(viewId);
      view.edgeWaypoints.set(edge.id, [{ x: 10, y: 10 }]);

      model.removeElement(agent);

      assert.false(view.edgeWaypoints.has(edge.id));
    });

    test("a view's edge routing waypoints round-trip", function (assert) {
      const model = new FmcModel();
      const agent = model.addElement(ElementType.AGENT);
      const location = model.addElement(ElementType.LOCATION);
      const edge = model.addAccess(agent, 'read', location);
      const viewId = model.createView('v');
      model.views.get(viewId).edgeWaypoints.set(edge.id, [
        { x: 10, y: 20 },
        { x: 30, y: 40 },
      ]);

      const restored = FmcModel.fromJSON(model.toJSON());
      const restoredEdge = restored.accesses[0];
      const waypoints = restored.views
        .get(viewId)
        .edgeWaypoints.get(restoredEdge.id);

      assert.strictEqual(restoredEdge.id, edge.id);
      assert.deepEqual(
        [...waypoints],
        [
          { x: 10, y: 20 },
          { x: 30, y: 40 },
        ],
      );
    });

    test('a legacy access edge with no id gets one assigned on load', function (assert) {
      const restored = FmcModel.fromJSON({
        elements: {
          a: { type: 'agent', label: 'A', parents: [], dashed: false },
          l: { type: 'location', label: 'L', parents: [], dashed: false },
        },
        accesses: [{ agent: 'a', kind: 'read', location: 'l' }],
      });

      assert.ok(restored.accesses[0].id);
    });
  });

  module('validate (well-formedness of a finished diagram)', function () {
    test('flags a channel with fewer than 2 accessing agents', function (assert) {
      const model = new FmcModel();
      const agent = model.addElement(ElementType.AGENT);
      const channel = model.addElement(ElementType.LOCATION, {
        label: 'C',
        channel: { shorthand: false },
      });
      model.addAccess(agent, 'write', channel);

      const issues = model.validate();

      assert.strictEqual(issues.length, 1);
      assert.strictEqual(issues[0].elementId, channel);
      assert.true(issues[0].message.includes('Channel "C"'));
    });

    test('flags a storage with no accessing agent', function (assert) {
      const model = new FmcModel();
      const storage = model.addElement(ElementType.LOCATION, { label: 'S' });

      const issues = model.validate();

      assert.strictEqual(issues.length, 1);
      assert.strictEqual(issues[0].elementId, storage);
      assert.true(issues[0].message.includes('Storage "S"'));
    });

    test('does not flag a fully-connected channel or storage', function (assert) {
      const model = new FmcModel();
      const a = model.addElement(ElementType.AGENT);
      const b = model.addElement(ElementType.AGENT);
      const channel = model.addElement(ElementType.LOCATION, {
        channel: { shorthand: false },
      });
      const storage = model.addElement(ElementType.LOCATION);
      model.addAccess(a, 'write', channel);
      model.addAccess(b, 'read', channel);
      model.addAccess(a, 'modify', storage);

      assert.deepEqual(model.validate(), []);
    });
  });

  module('Petri net and ER arcs (primitive support)', function () {
    test('isRoundedElementType is true for location/place/entity_set, false for agent/transition/relation', function (assert) {
      assert.true(isRoundedElementType(ElementType.LOCATION));
      assert.true(isRoundedElementType(ElementType.PLACE));
      assert.true(isRoundedElementType(ElementType.ENTITY_SET));
      assert.false(isRoundedElementType(ElementType.AGENT));
      assert.false(isRoundedElementType(ElementType.TRANSITION));
      assert.false(isRoundedElementType(ElementType.RELATION));
    });

    test('addArc connects a place and a transition, in either order', function (assert) {
      const model = new FmcModel();
      const place = model.addElement(ElementType.PLACE);
      const transition = model.addElement(ElementType.TRANSITION);

      const arc1 = model.addArc(place, transition);
      const arc2 = model.addArc(transition, place, 3);

      assert.strictEqual(model.arcs.length, 2);
      assert.strictEqual(arc1.weight, 1);
      assert.strictEqual(arc2.weight, 3);
    });

    test('addArc connects an entity set and a relation', function (assert) {
      const model = new FmcModel();
      const entitySet = model.addElement(ElementType.ENTITY_SET);
      const relation = model.addElement(ElementType.RELATION);

      const arc = model.addArc(entitySet, relation);

      assert.strictEqual(arc.source, entitySet);
      assert.strictEqual(arc.target, relation);
    });

    test('addArc rejects a place connected to a relation (wrong diagram type pairing)', function (assert) {
      const model = new FmcModel();
      const place = model.addElement(ElementType.PLACE);
      const relation = model.addElement(ElementType.RELATION);

      assert.throws(() => model.addArc(place, relation), FmcModelError);
    });

    test('addArc rejects two places (same-kind pairing)', function (assert) {
      const model = new FmcModel();
      const a = model.addElement(ElementType.PLACE);
      const b = model.addElement(ElementType.PLACE);

      assert.throws(() => model.addArc(a, b), FmcModelError);
    });

    test('removeArc removes just that arc', function (assert) {
      const model = new FmcModel();
      const place = model.addElement(ElementType.PLACE);
      const transition = model.addElement(ElementType.TRANSITION);
      const arc1 = model.addArc(place, transition);
      const arc2 = model.addArc(transition, place);

      model.removeArc(arc1.id);

      assert.strictEqual(model.arcs.length, 1);
      assert.strictEqual(model.arcs[0].id, arc2.id);
    });

    test('removeElement drops every arc touching it', function (assert) {
      const model = new FmcModel();
      const place = model.addElement(ElementType.PLACE);
      const transition = model.addElement(ElementType.TRANSITION);
      model.addArc(place, transition);

      model.removeElement(place);

      assert.strictEqual(model.arcs.length, 0);
    });

    test('a place element has a default token count of 0, settable via addElement', function (assert) {
      const model = new FmcModel();
      const place = model.addElement(ElementType.PLACE);
      const markedPlace = model.addElement(ElementType.PLACE, { tokens: 2 });

      assert.strictEqual(model.elements.get(place).tokens, 0);
      assert.strictEqual(model.elements.get(markedPlace).tokens, 2);
    });

    test('arcs and token counts round-trip through toJSON/fromJSON', function (assert) {
      const model = new FmcModel();
      const place = model.addElement(ElementType.PLACE, { tokens: 2 });
      const transition = model.addElement(ElementType.TRANSITION);
      model.addArc(place, transition, 5);

      const restored = FmcModel.fromJSON(model.toJSON());

      assert.strictEqual(restored.elements.get(place).tokens, 2);
      assert.strictEqual(restored.arcs.length, 1);
      assert.strictEqual(restored.arcs[0].source, place);
      assert.strictEqual(restored.arcs[0].target, transition);
      assert.strictEqual(restored.arcs[0].weight, 5);
    });

    test('addArc rejects two entity sets connected directly (partitioning goes through a partition node)', function (assert) {
      const model = new FmcModel();
      const a = model.addElement(ElementType.ENTITY_SET);
      const b = model.addElement(ElementType.ENTITY_SET);

      assert.throws(() => model.addArc(a, b), FmcModelError);
    });

    test('addArc connects an entity set and a partition, in either order', function (assert) {
      const model = new FmcModel();
      const parent = model.addElement(ElementType.ENTITY_SET);
      const partition = model.addElement(ElementType.PARTITION);
      const child = model.addElement(ElementType.ENTITY_SET);

      const apexArc = model.addArc(parent, partition);
      const baseArc = model.addArc(partition, child);

      assert.strictEqual(apexArc.source, parent);
      assert.strictEqual(apexArc.target, partition);
      assert.strictEqual(baseArc.source, partition);
      assert.strictEqual(baseArc.target, child);
    });

    test('updateArcCardinality changes just that arc, leaving its id and endpoints alone', function (assert) {
      const model = new FmcModel();
      const entitySet = model.addElement(ElementType.ENTITY_SET);
      const relation = model.addElement(ElementType.RELATION);
      const arc = model.addArc(entitySet, relation);

      model.updateArcCardinality(arc.id, 'one');

      assert.strictEqual(model.arcs.length, 1);
      assert.strictEqual(model.arcs[0].id, arc.id);
      assert.strictEqual(model.arcs[0].cardinality, 'one');
      assert.strictEqual(model.arcs[0].source, entitySet);
      assert.strictEqual(model.arcs[0].target, relation);
    });

    test('reifyRelation nests the relation inside a fresh entity set', function (assert) {
      const model = new FmcModel();
      const relation = model.addElement(ElementType.RELATION);

      const entitySetId = model.reifyRelation(relation, { label: 'Booking' });

      const entitySet = model.elements.get(entitySetId);
      assert.strictEqual(entitySet.type, ElementType.ENTITY_SET);
      assert.strictEqual(entitySet.label, 'Booking');
      assert.deepEqual(
        [...model.elements.get(relation).parents],
        [entitySetId],
      );
    });

    test('reifyRelation rejects anything but a relation', function (assert) {
      const model = new FmcModel();
      const entitySet = model.addElement(ElementType.ENTITY_SET);

      assert.throws(() => model.reifyRelation(entitySet), FmcModelError);
    });

    test('a place element defaults isStart to false, settable via addElement, and round-trips', function (assert) {
      const model = new FmcModel();
      const place = model.addElement(ElementType.PLACE, { isStart: true });

      assert.true(model.elements.get(place).isStart);

      const restored = FmcModel.fromJSON(model.toJSON());
      assert.true(restored.elements.get(place).isStart);
    });

    test('a transition element defaults isNop to false, settable via addElement, and round-trips', function (assert) {
      const model = new FmcModel();
      const transition = model.addElement(ElementType.TRANSITION, {
        isNop: true,
      });

      assert.true(model.elements.get(transition).isNop);

      const restored = FmcModel.fromJSON(model.toJSON());
      assert.true(restored.elements.get(transition).isNop);
    });
  });

  module('legacy JSON migration (pre-rename autosaves/files)', function () {
    test('an old "storage" element and AccessEdge.storage load as a location', function (assert) {
      const restored = FmcModel.fromJSON({
        elements: {
          a: { type: 'agent', label: 'A', parent: null, dashed: false },
          s: { type: 'storage', label: 'S', parent: null, dashed: false },
        },
        accesses: [{ agent: 'a', kind: 'read', storage: 's' }],
      });

      assert.strictEqual(restored.elements.get('s').type, ElementType.LOCATION);
      assert.strictEqual(restored.accesses[0].location, 's');
      assert.false('storage' in restored.accesses[0]);
    });

    test('a singular legacy Element.parent becomes a one-item parents array', function (assert) {
      const restored = FmcModel.fromJSON({
        elements: {
          p: { type: 'agent', label: 'P', parent: null, dashed: false },
          c: { type: 'agent', label: 'C', parent: 'p', dashed: false },
        },
        accesses: [],
      });

      assert.deepEqual([...restored.elements.get('c').parents], ['p']);
    });

    test('a legacy Channel becomes a location element with access edges, shown in views that had it positioned', function (assert) {
      const restored = FmcModel.fromJSON({
        elements: {
          a: { type: 'agent', label: 'A', parent: null, dashed: false },
          b: { type: 'agent', label: 'B', parent: null, dashed: false },
        },
        accesses: [],
        channels: [
          {
            id: 'ch1',
            source: 'a',
            target: 'b',
            directed: true,
            place: { label: null, shorthand: false },
          },
        ],
        views: {
          v: {
            name: 'v',
            diagramType: 'block',
            included: ['a', 'b'],
            boxes: {
              a: { x: 0, y: 0, width: 120, height: 60 },
              b: { x: 300, y: 0, width: 120, height: 60 },
            },
            channelPlaces: { ch1: { x: 150, y: 20 } },
          },
        },
      });

      const place = restored.elements.get('ch1');
      assert.strictEqual(place.type, ElementType.LOCATION);
      assert.deepEqual(place.channel, { shorthand: false });
      assert.deepEqual(
        restored.accesses.map((edge) => [edge.agent, edge.kind, edge.location]),
        [
          ['a', 'write', 'ch1'],
          ['b', 'read', 'ch1'],
        ],
      );
      const view = restored.views.get('v');
      assert.true(view.included.includes('ch1'));
      assert.strictEqual(view.boxes.get('ch1').x, 150);
      assert.strictEqual(view.boxes.get('ch1').y, 20);
    });

    test('a current-schema export round-trips unchanged (migration is a no-op)', function (assert) {
      const model = new FmcModel();
      const agent = model.addElement(ElementType.AGENT, { label: 'A' });
      const location = model.addElement(ElementType.LOCATION, { label: 'L' });
      model.addAccess(agent, 'read', location);

      const restored = FmcModel.fromJSON(model.toJSON());

      assert.strictEqual(restored.elements.get(location).type, 'location');
      assert.strictEqual(restored.accesses[0].location, location);
    });
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
