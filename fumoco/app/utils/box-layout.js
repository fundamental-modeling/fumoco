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
