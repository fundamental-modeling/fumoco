import Component from '@glimmer/component';
import { action } from '@ember/object';
import { service } from '@ember/service';
import { on } from '@ember/modifier';
import Icon from 'fumoco/components/icon';
import StretchHorizontal from '@lucide/icons/icons/stretch-horizontal';
import StretchVertical from '@lucide/icons/icons/stretch-vertical';
import SquareEqual from '@lucide/icons/icons/square-equal';
import AlignHorizontalJustifyStart from '@lucide/icons/icons/align-horizontal-justify-start';
import AlignHorizontalJustifyCenter from '@lucide/icons/icons/align-horizontal-justify-center';
import AlignHorizontalJustifyEnd from '@lucide/icons/icons/align-horizontal-justify-end';
import AlignVerticalJustifyStart from '@lucide/icons/icons/align-vertical-justify-start';
import AlignVerticalJustifyCenter from '@lucide/icons/icons/align-vertical-justify-center';
import AlignVerticalJustifyEnd from '@lucide/icons/icons/align-vertical-justify-end';
import AlignHorizontalDistributeCenter from '@lucide/icons/icons/align-horizontal-distribute-center';
import AlignVerticalDistributeCenter from '@lucide/icons/icons/align-vertical-distribute-center';

export default class AlignmentToolbar extends Component {
  @service modelStore;
  @service selection;

  get view() {
    return this.modelStore.activeView;
  }

  get selectedBoxes() {
    const view = this.view;
    if (!view) return [];
    return this.selection.selectedIds
      .map((id) => ({ id, box: view.boxes.get(id) }))
      .filter((e) => e.box);
  }

  updateBoxes(updates) {
    const view = this.view;
    this.modelStore.mutate(() => {
      for (const { id, box } of updates) view.boxes.set(id, box);
    });
  }

  @action
  sameWidth() {
    this.applySameSize({ width: true });
  }

  @action
  sameHeight() {
    this.applySameSize({ height: true });
  }

  @action
  sameBoth() {
    this.applySameSize({ width: true, height: true });
  }

  applySameSize({ width, height }) {
    const entries = this.selectedBoxes;
    if (entries.length < 2) return;
    const reference = entries.at(-1).box;
    this.updateBoxes(
      entries.slice(0, -1).map(({ id, box }) => ({
        id,
        box: {
          ...box,
          ...(width ? { width: reference.width } : {}),
          ...(height ? { height: reference.height } : {}),
        },
      })),
    );
  }

  @action
  alignLeft() {
    this.applyAlign(({ minX }, box) => ({ ...box, x: minX }));
  }

  @action
  alignCenterH() {
    this.applyAlign(({ minX, maxRight }, box) => ({
      ...box,
      x: (minX + maxRight) / 2 - box.width / 2,
    }));
  }

  @action
  alignRight() {
    this.applyAlign(({ maxRight }, box) => ({
      ...box,
      x: maxRight - box.width,
    }));
  }

  @action
  alignTop() {
    this.applyAlign(({ minY }, box) => ({ ...box, y: minY }));
  }

  @action
  alignMiddleV() {
    this.applyAlign(({ minY, maxBottom }, box) => ({
      ...box,
      y: (minY + maxBottom) / 2 - box.height / 2,
    }));
  }

  @action
  alignBottom() {
    this.applyAlign(({ maxBottom }, box) => ({
      ...box,
      y: maxBottom - box.height,
    }));
  }

  applyAlign(compute) {
    const entries = this.selectedBoxes;
    if (entries.length < 2) return;
    const minX = Math.min(...entries.map((e) => e.box.x));
    const maxRight = Math.max(...entries.map((e) => e.box.x + e.box.width));
    const minY = Math.min(...entries.map((e) => e.box.y));
    const maxBottom = Math.max(...entries.map((e) => e.box.y + e.box.height));
    const extent = { minX, maxRight, minY, maxBottom };
    this.updateBoxes(
      entries.map(({ id, box }) => ({ id, box: compute(extent, box) })),
    );
  }

  @action
  distributeHorizontally() {
    this.applyDistribute('x', 'width');
  }

  @action
  distributeVertically() {
    this.applyDistribute('y', 'height');
  }

  applyDistribute(axis, sizeKey) {
    const entries = [...this.selectedBoxes].sort(
      (a, b) => a.box[axis] - b.box[axis],
    );
    if (entries.length < 3) return;
    const first = entries[0].box;
    const last = entries.at(-1).box;
    const span = last[axis] + last[sizeKey] - first[axis];
    const sumSizes = entries.reduce((total, e) => total + e.box[sizeKey], 0);
    const gap = (span - sumSizes) / (entries.length - 1);

    let cursor = first[axis];
    const updates = entries.map(({ id, box }) => {
      const updated = { ...box, [axis]: cursor };
      cursor += box[sizeKey] + gap;
      return { id, box: updated };
    });
    this.updateBoxes(updates);
  }

  <template>
    <div class="alignment-toolbar">
      <button
        type="button"
        title="Same width"
        {{on "click" this.sameWidth}}
      ><Icon @icon={{StretchHorizontal}} /></button>
      <button
        type="button"
        title="Same height"
        {{on "click" this.sameHeight}}
      ><Icon @icon={{StretchVertical}} /></button>
      <button
        type="button"
        title="Same width and height"
        {{on "click" this.sameBoth}}
      ><Icon @icon={{SquareEqual}} /></button>
      <span class="alignment-toolbar-sep"></span>
      <button
        type="button"
        title="Align left"
        {{on "click" this.alignLeft}}
      ><Icon @icon={{AlignHorizontalJustifyStart}} /></button>
      <button
        type="button"
        title="Align center"
        {{on "click" this.alignCenterH}}
      ><Icon @icon={{AlignHorizontalJustifyCenter}} /></button>
      <button
        type="button"
        title="Align right"
        {{on "click" this.alignRight}}
      ><Icon @icon={{AlignHorizontalJustifyEnd}} /></button>
      <button type="button" title="Align top" {{on "click" this.alignTop}}><Icon
          @icon={{AlignVerticalJustifyStart}}
        /></button>
      <button
        type="button"
        title="Align middle"
        {{on "click" this.alignMiddleV}}
      ><Icon @icon={{AlignVerticalJustifyCenter}} /></button>
      <button
        type="button"
        title="Align bottom"
        {{on "click" this.alignBottom}}
      ><Icon @icon={{AlignVerticalJustifyEnd}} /></button>
      <span class="alignment-toolbar-sep"></span>
      <button
        type="button"
        title="Distribute horizontally"
        {{on "click" this.distributeHorizontally}}
      ><Icon @icon={{AlignHorizontalDistributeCenter}} /></button>
      <button
        type="button"
        title="Distribute vertically"
        {{on "click" this.distributeVertically}}
      ><Icon @icon={{AlignVerticalDistributeCenter}} /></button>
    </div>
  </template>
}
