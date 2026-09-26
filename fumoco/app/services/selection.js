// Ordered selection: which element ids are selected on the current canvas,
// in the order they were picked. Order matters because "same width/height"
// copies from the *last*-selected box -- plain Set-based selection can't
// answer "which one was last."
//
// An access edge (arrow) is selected separately, via `selectedEdgeId` --
// elements and an edge are mutually exclusive selection modes (the
// properties panel shows one or the other), so selecting either kind
// clears the other.
import Service from '@ember/service';
import { tracked } from '@glimmer/tracking';
import { TrackedArray } from 'tracked-built-ins';

export default class SelectionService extends Service {
  selectedIds = new TrackedArray();
  @tracked selectedEdgeId = null;

  get lastId() {
    return this.selectedIds.at(-1) ?? null;
  }

  isSelected(id) {
    return this.selectedIds.includes(id);
  }

  select(id) {
    this.selectedEdgeId = null;
    this.selectedIds.length = 0;
    this.selectedIds.push(id);
  }

  toggle(id) {
    this.selectedEdgeId = null;
    const index = this.selectedIds.indexOf(id);
    if (index === -1) {
      this.selectedIds.push(id);
    } else {
      this.selectedIds.splice(index, 1);
    }
  }

  selectEdge(id) {
    this.selectedIds.length = 0;
    this.selectedEdgeId = id;
  }

  clear() {
    this.selectedIds.length = 0;
    this.selectedEdgeId = null;
  }
}
