// This file is part of Fumoco.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Holger Peters -- see the LICENSE file.

import Component from '@glimmer/component';
import { action } from '@ember/object';
import { service } from '@ember/service';
import { on } from '@ember/modifier';
import { defaultBoxSize, nextFreeBoxPosition } from 'fumoco/utils/box-layout';

// An access edge is a world-model entity like any element, but it has no
// element-style rename/nesting of its own -- just endpoints and a kind, so
// this row is simpler than ModelTreeNode: select it (and pull its
// endpoints into the active view, same as clicking an unplaced element)
// or delete it.
export default class ArrowRow extends Component {
  @service modelStore;
  @service selection;

  get agent() {
    return this.modelStore.model.elements.get(this.args.access.agent);
  }

  get location() {
    return this.modelStore.model.elements.get(this.args.access.location);
  }

  get isSelected() {
    return this.selection.selectedEdgeId === this.args.access.id;
  }

  get displayLabel() {
    const agentLabel = this.agent?.label ?? '(unnamed)';
    const locationLabel = this.location?.label ?? '(unnamed)';
    return `${agentLabel} --${this.args.access.kind}--> ${locationLabel}`;
  }

  @action
  select() {
    this.selection.selectEdge(this.args.access.id);
    const view = this.modelStore.activeView;
    if (!view) return;
    const { agent, location } = this.args.access;
    this.modelStore.mutate(() => {
      for (const id of [agent, location]) {
        if (view.included.includes(id)) continue;
        const size = defaultBoxSize(this.modelStore.model.elements.get(id));
        const { x, y } = nextFreeBoxPosition(view, size.width, size.height);
        view.included.push(id);
        view.boxes.set(id, { x, y, ...size });
      }
    });
  }

  @action
  delete(event) {
    event.stopPropagation();
    this.modelStore.mutate((model) => model.removeAccess(this.args.access.id));
    if (this.isSelected) this.selection.clear();
  }

  <template>
    <li>
      <div class="model-tree-node-row">
        <button
          type="button"
          class="model-tree-node-label {{if this.isSelected 'is-selected'}}"
          {{on "click" this.select}}
        >
          {{this.displayLabel}}
        </button>
        <button
          type="button"
          class="model-tree-node-delete"
          {{on "click" this.delete}}
        >&times;</button>
      </div>
    </li>
  </template>
}
