// Ordered selection: which element ids are selected on the current canvas,
// in the order they were picked. Order matters because "same width/height"
// copies from the *last*-selected box -- plain Set-based selection can't
// answer "which one was last."
import Service from '@ember/service';
import { TrackedArray } from 'tracked-built-ins';

export default class SelectionService extends Service {
  selectedIds = new TrackedArray();

  get lastId() {
    return this.selectedIds.at(-1) ?? null;
  }

  isSelected(id) {
    return this.selectedIds.includes(id);
  }

  select(id) {
    this.selectedIds.length = 0;
    this.selectedIds.push(id);
  }

  toggle(id) {
    const index = this.selectedIds.indexOf(id);
    if (index === -1) {
      this.selectedIds.push(id);
    } else {
      this.selectedIds.splice(index, 1);
    }
  }

  clear() {
    this.selectedIds.length = 0;
  }
}
