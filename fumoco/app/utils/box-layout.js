import { ElementType } from 'fumoco/utils/fmc-model';

// Default box size per element type (px; the canvas font is 15px, so
// 1em = 15). Used for new boxes and by "Reset size".
const DEFAULT_SIZES = {
  // Square, so buildShape's cornerRadius trick reads as a circle. Keeps
  // the measured place-diameter/transition-height ratio (~1.33em/2.4em).
  [ElementType.PLACE]: { width: 33, height: 33 },
  // ~1em high, 3em wide: an unnamed relation just carries its arrow.
  [ElementType.RELATION]: { width: 45, height: 15 },
  // Portrait, ~3em x 4em, holding just the stick figure (FMC stencil);
  // the name is drawn outside, above it.
  [ElementType.HUMAN_AGENT]: { width: 45, height: 60 },
  // Three dots, ~3em x 1em.
  [ElementType.ELLIPSIS]: { width: 45, height: 15 },
  // A tall, thin (but still grabbable) strip; the line runs along it.
  [ElementType.DIVIDER]: { width: 10, height: 300 },
  // A triangle glyph, not a label-sized box.
  [ElementType.PARTITION]: { width: 60, height: 50 },
};

export function defaultBoxSize(element) {
  if (element.channel) return { width: 28, height: 28 };
  // A wide, thin bar (measured: ~0.67em x 12em against a 2.4em transition).
  if (element.type === ElementType.TRANSITION && element.isNop) {
    return { width: 300, height: 17 };
  }
  return DEFAULT_SIZES[element.type] ?? { width: 120, height: 60 };
}

// Where to place a newly-added-to-a-view box so it doesn't land on top of
// one already there. Used by every "place this element in the active
// view" call site (palette, model tree, arrow rows) instead of each
// duplicating its own offset arithmetic.

function rectsOverlap(a, b) {
  return (
    a.x < b.x + b.width &&
    b.x < a.x + a.width &&
    a.y < b.y + b.height &&
    b.y < a.y + a.height
  );
}

const STEP = 30;
const MAX_ATTEMPTS = 200;

// Walks an outward diagonal cascade (same spirit as the old fixed
// 40 + 20*n offset) but keeps stepping until it finds a spot that
// doesn't overlap any box already in the view, instead of wrapping back
// to the start every 10 elements and silently overlapping from then on.
export function nextFreeBoxPosition(view, width = 120, height = 60) {
  const existing = [...view.boxes.values()];
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    const offset = 40 + STEP * attempt;
    const candidate = { x: offset, y: offset, width, height };
    if (!existing.some((box) => rectsOverlap(candidate, box))) {
      return { x: candidate.x, y: candidate.y };
    }
  }
  // Pathological case (a great many boxes already along the diagonal) --
  // fall back to just past the last attempted offset rather than looping
  // forever; an occasional overlap here is better than hanging the UI.
  const offset = 40 + STEP * MAX_ATTEMPTS;
  return { x: offset, y: offset };
}
