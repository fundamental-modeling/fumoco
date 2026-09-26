import { module, test } from 'qunit';
import { ElementType, FmcModel, FmcModelError } from 'fumoco/utils/fmc-model';

module('Unit | Utility | fmc-model', function () {
  test('addAccess rejects a non-agent source', function (assert) {
    const model = new FmcModel();
    const storage1 = model.addElement(ElementType.STORAGE);
    const storage2 = model.addElement(ElementType.STORAGE);
    assert.throws(
      () => model.addAccess(storage1, 'read', storage2),
      FmcModelError,
    );
  });

  test('addAccess rejects a non-storage target', function (assert) {
    const model = new FmcModel();
    const agent1 = model.addElement(ElementType.AGENT);
    const agent2 = model.addElement(ElementType.AGENT);
    assert.throws(() => model.addAccess(agent1, 'read', agent2), FmcModelError);
  });

  test('addChannel rejects a storage endpoint', function (assert) {
    const model = new FmcModel();
    const agent = model.addElement(ElementType.AGENT);
    const storage = model.addElement(ElementType.STORAGE);
    assert.throws(() => model.addChannel(agent, storage, true), FmcModelError);
  });

  test('an element cannot contain itself', function (assert) {
    const model = new FmcModel();
    const agent = model.addElement(ElementType.AGENT);
    assert.throws(() => model.setParent(agent, agent), FmcModelError);
  });

  test('containment cannot create a cycle', function (assert) {
    const model = new FmcModel();
    const a = model.addElement(ElementType.AGENT);
    const b = model.addElement(ElementType.AGENT);
    model.setParent(b, a); // a contains b
    assert.throws(() => model.setParent(a, b), FmcModelError);
  });

  test('removeElement detaches children and drops incident edges', function (assert) {
    const model = new FmcModel();
    const parent = model.addElement(ElementType.AGENT);
    const child = model.addElement(ElementType.AGENT);
    const storage = model.addElement(ElementType.STORAGE);
    model.setParent(child, parent);
    model.addAccess(parent, 'read', storage);

    model.removeElement(parent);

    assert.strictEqual(model.elements.get(child).parent, null);
    assert.strictEqual(model.accesses.length, 0);
    assert.false(model.elements.has(parent));
  });

  test('toJSON/fromJSON round-trips a model', function (assert) {
    const model = new FmcModel();
    const agent = model.addElement(ElementType.AGENT, { label: 'A' });
    const storage = model.addElement(ElementType.STORAGE, {
      label: 'S',
      dashed: true,
    });
    model.addAccess(agent, 'modify', storage);
    const viewId = model.createView('overview', 'block');
    model.views.get(viewId).included.push(agent, storage);
    model.views
      .get(viewId)
      .boxes.set(agent, { x: 0, y: 0, width: 120, height: 60 });

    const restored = FmcModel.fromJSON(model.toJSON());

    assert.strictEqual(restored.elements.get(agent).label, 'A');
    assert.true(restored.elements.get(storage).dashed);
    assert.strictEqual(restored.accesses.length, 1);
    assert.strictEqual(restored.views.get(viewId).included.length, 2);
    assert.strictEqual(restored.views.get(viewId).boxes.get(agent).width, 120);
  });

  test('channels get a stable id, and its custom place position round-trips', function (assert) {
    const model = new FmcModel();
    const a = model.addElement(ElementType.AGENT);
    const b = model.addElement(ElementType.AGENT);
    const channel = model.addChannel(a, b, true);
    assert.strictEqual(typeof channel.id, 'string');
    assert.true(channel.id.length > 0);

    const viewId = model.createView('overview', 'block');
    model.views.get(viewId).channelPlaces.set(channel.id, { x: 42, y: 7 });

    const restored = FmcModel.fromJSON(model.toJSON());
    const restoredChannel = restored.channels[0];
    assert.strictEqual(restoredChannel.id, channel.id);
    assert.deepEqual(restored.views.get(viewId).channelPlaces.get(channel.id), {
      x: 42,
      y: 7,
    });
  });

  test('removeElement drops that element channels custom place overrides too', function (assert) {
    const model = new FmcModel();
    const a = model.addElement(ElementType.AGENT);
    const b = model.addElement(ElementType.AGENT);
    const channel = model.addChannel(a, b, true);
    const viewId = model.createView('overview', 'block');
    model.views.get(viewId).channelPlaces.set(channel.id, { x: 1, y: 2 });

    model.removeElement(a);

    assert.false(model.views.get(viewId).channelPlaces.has(channel.id));
  });
});
