// This file is part of Fumoco.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Holger Peters -- see the LICENSE file.

import { module, test } from 'qunit';
import {
  isValidOutline,
  labelArea,
  normalizeOutline,
  outlineBounds,
  outlineEntry,
  pointInOutline,
  pushSegment,
  rectInOutline,
  rectOutline,
} from 'fumoco/utils/outline';

module('Unit | Utility | outline', function () {
  const rect = rectOutline(200, 100);

  test('pushing a section of an edge in makes a notch (U shape)', function (assert) {
    // bottom edge runs (200,100) -> (0,100); push x 60..140 up by 40
    const u = pushSegment(rect, 2, 60, 140, -40);
    assert.deepEqual(u, [
      { x: 0, y: 0 },
      { x: 200, y: 0 },
      { x: 200, y: 100 },
      { x: 140, y: 100 },
      { x: 140, y: 60 },
      { x: 60, y: 60 },
      { x: 60, y: 100 },
      { x: 0, y: 100 },
    ]);
    assert.true(isValidOutline(u));
  });

  test('a section reaching a corner makes an L shape', function (assert) {
    const l = pushSegment(rect, 1, 50, 100, -80); // right edge, lower half, in
    assert.deepEqual(l, [
      { x: 0, y: 0 },
      { x: 200, y: 0 },
      { x: 200, y: 50 },
      { x: 120, y: 50 },
      { x: 120, y: 100 },
      { x: 0, y: 100 },
    ]);
    assert.deepEqual(outlineBounds(l), { x: 0, y: 0, width: 200, height: 100 });
  });

  test('a whole edge moves, its neighbours stretch', function (assert) {
    assert.deepEqual(pushSegment(rect, 1, 0, 100, 30), rectOutline(230, 100));
  });

  test('a push through the opposite side is rejected', function (assert) {
    assert.strictEqual(pushSegment(rect, 2, 60, 140, -100), null);
    assert.strictEqual(pushSegment(rect, 2, 60, 140, -120), null);
  });

  test('normalizing drops repeated and in-line vertices', function (assert) {
    assert.deepEqual(
      normalizeOutline([
        { x: 0, y: 0 },
        { x: 100, y: 0 },
        { x: 200, y: 0 },
        { x: 200, y: 100 },
        { x: 200, y: 100 },
        { x: 0, y: 100 },
      ]),
      rect,
    );
  });

  test('a connector arriving at a notch goes in to the outline', function (assert) {
    const u = pushSegment(rect, 2, 60, 140, -40);
    // from below at x=100, i.e. into the notch: meets y=60
    assert.deepEqual(outlineEntry(u, { x: 100, y: 100 }, 's'), {
      x: 100,
      y: 60,
    });
    // at x=20, beside the notch: the outline is the box side itself
    assert.deepEqual(outlineEntry(u, { x: 20, y: 100 }, 's'), {
      x: 20,
      y: 100,
    });
  });

  test('the label goes in the largest part of the shape', function (assert) {
    const u = pushSegment(rect, 2, 60, 140, -40);
    // a notch pushed up from the bottom leaves the top bar as the largest part
    assert.deepEqual(labelArea(u), { x: 0, y: 0, width: 200, height: 60 });
    assert.deepEqual(labelArea(rect), { x: 0, y: 0, width: 200, height: 100 });
  });

  test('a point in a notch is outside the shape', function (assert) {
    const u = pushSegment(rect, 2, 60, 140, -40); // notch x 60..140, y 60..100
    assert.true(pointInOutline(u, { x: 30, y: 80 }), 'in a leg');
    assert.true(pointInOutline(u, { x: 100, y: 30 }), 'in the top bar');
    assert.false(pointInOutline(u, { x: 100, y: 80 }), 'in the notch');
    assert.false(pointInOutline(u, { x: 300, y: 50 }), 'outside the box');
  });

  test('rectInOutline: inside the shape, not just its bounding box', function (assert) {
    // a U: notch x 60..140 from the top down to y 60
    const u = pushSegment(rect, 0, 60, 140, 60);
    assert.true(
      rectInOutline(u, { x: 10, y: 10, width: 40, height: 80 }),
      'left arm',
    );
    assert.true(
      rectInOutline(u, { x: 10, y: 70, width: 180, height: 20 }),
      'bottom bar',
    );
    assert.false(
      rectInOutline(u, { x: 10, y: 10, width: 180, height: 30 }),
      'spans the notch',
    );
    assert.false(
      rectInOutline(u, { x: 50, y: 50, width: 20, height: 20 }),
      'notch corner pokes in',
    );
    assert.false(
      rectInOutline(u, { x: 70, y: 10, width: 20, height: 20 }),
      'in the notch',
    );
  });
});
