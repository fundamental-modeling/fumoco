import { module, test } from 'qunit';
import { defaultBoxSize, nextFreeBoxPosition } from 'fumoco/utils/box-layout';
import { ElementType } from 'fumoco/utils/fmc-model';

module('Unit | Utility | box-layout', function () {
  test('places the first box at the base offset', function (assert) {
    const view = { boxes: new Map() };

    const { x, y } = nextFreeBoxPosition(view);

    assert.strictEqual(x, 40);
    assert.strictEqual(y, 40);
  });

  test('does not overlap a box already at the base offset', function (assert) {
    const view = {
      boxes: new Map([['existing', { x: 40, y: 40, width: 120, height: 60 }]]),
    };

    const position = nextFreeBoxPosition(view, 120, 60);

    const overlaps =
      position.x < 40 + 120 &&
      40 < position.x + 120 &&
      position.y < 40 + 60 &&
      40 < position.y + 60;
    assert.false(overlaps);
  });

  test('keeps stepping past many existing boxes instead of wrapping back to an occupied spot', function (assert) {
    // Simulate 15 elements already placed along the old fixed 10-slot
    // cascade -- the old `40 + 20 * (size % 10)` formula would repeat
    // offset 40 again here and collide with the very first box.
    const boxes = new Map();
    for (let i = 0; i < 15; i++) {
      const offset = 40 + 20 * (i % 10);
      boxes.set(`el${i}`, { x: offset, y: offset, width: 120, height: 60 });
    }
    const view = { boxes };

    const position = nextFreeBoxPosition(view, 120, 60);

    for (const box of boxes.values()) {
      const overlaps =
        position.x < box.x + box.width &&
        box.x < position.x + 120 &&
        position.y < box.y + box.height &&
        box.y < position.y + 60;
      assert.false(overlaps, `should not overlap box at (${box.x}, ${box.y})`);
    }
  });

  test('defaultBoxSize: relation ~1em x 3em, NOP bar, channel, fallback', function (assert) {
    assert.deepEqual(defaultBoxSize({ type: ElementType.RELATION }), {
      width: 45,
      height: 15,
    });
    assert.deepEqual(
      defaultBoxSize({ type: ElementType.TRANSITION, isNop: true }),
      { width: 300, height: 17 },
    );
    assert.deepEqual(
      defaultBoxSize({ type: ElementType.LOCATION, channel: {} }),
      { width: 28, height: 28 },
    );
    assert.deepEqual(defaultBoxSize({ type: ElementType.AGENT }), {
      width: 120,
      height: 60,
    });
  });
});
