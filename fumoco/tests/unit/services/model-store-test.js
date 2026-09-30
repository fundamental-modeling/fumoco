import { module, test } from 'qunit';
import { setupTest } from 'fumoco/tests/helpers';
import { ElementType, FmcModel } from 'fumoco/utils/fmc-model';

module('Unit | Service | model-store (undo/redo)', function (hooks) {
  setupTest(hooks);

  hooks.beforeEach(function () {
    this.store = this.owner.lookup('service:model-store');
    this.store.model = new FmcModel();
    this.store.undoStack = [];
    this.store.redoStack = [];
    this.store.undoCoalesceMs = -1; // every mutation its own step
  });

  test('undo restores the state before a change, redo reapplies it', function (assert) {
    const id = this.store.mutate((m) =>
      m.addElement(ElementType.AGENT, { label: 'A' }),
    );
    this.store.mutate(() => {
      this.store.model.elements.get(id).label = 'B';
    });

    this.store.undo();
    assert.strictEqual(this.store.model.elements.get(id).label, 'A');
    this.store.undo();
    assert.false(this.store.model.elements.has(id));
    assert.false(this.store.canUndo);

    this.store.redo();
    this.store.redo();
    assert.strictEqual(this.store.model.elements.get(id).label, 'B');
    assert.false(this.store.canRedo);
  });

  test('a new change after undo clears redo', function (assert) {
    this.store.mutate((m) => m.addElement(ElementType.AGENT));
    this.store.undo();
    assert.true(this.store.canRedo);
    this.store.mutate((m) => m.addElement(ElementType.LOCATION));
    assert.false(this.store.canRedo);
  });

  test('changes in quick succession are one undo step', function (assert) {
    this.store.undoCoalesceMs = 10000;
    this.store.mutate((m) => m.addElement(ElementType.AGENT));
    this.store.mutate((m) => m.addElement(ElementType.AGENT));
    this.store.undo();
    assert.strictEqual(this.store.model.elements.size, 0);
  });
});
