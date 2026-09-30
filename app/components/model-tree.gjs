// This file is part of Fumoco.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Holger Peters -- see the LICENSE file.

import Component from '@glimmer/component';
import { tracked } from '@glimmer/tracking';
import { action } from '@ember/object';
import { service } from '@ember/service';
import { on } from '@ember/modifier';
import { fn } from '@ember/helper';
import ModelTreeNode from 'fumoco/components/model-tree-node';
import ViewRow from 'fumoco/components/view-row';
import ArrowRow from 'fumoco/components/arrow-row';
import Icon from 'fumoco/components/icon';
import FilePlus from '@lucide/icons/icons/file-plus';
import FolderOpen from '@lucide/icons/icons/folder-open';
import Save from '@lucide/icons/icons/save';
import SavePlus from '@lucide/icons/icons/save-plus';
import SquarePlus from '@lucide/icons/icons/square-plus';
import CircleCheckBig from '@lucide/icons/icons/circle-check-big';
import Undo2 from '@lucide/icons/icons/undo-2';
import Redo2 from '@lucide/icons/icons/redo-2';

export default class ModelTree extends Component {
  @service modelStore;
  @service selection;

  // null = not run yet (no panel shown); [] = run, nothing to report.
  @tracked validationIssues = null;

  get rootElements() {
    // An element with no containers is shown here at the root; one that's
    // nested somewhere is instead shown once under each of its parents
    // (many-to-many containment -- see ModelTreeNode) so it never also
    // duplicates at the root.
    return [...this.modelStore.model.elements.values()].filter(
      (element) => element.parents.length === 0,
    );
  }

  get views() {
    return [...this.modelStore.model.views.values()];
  }

  get accesses() {
    return [...this.modelStore.model.accesses];
  }

  // Distinguishes "never run" (no panel) from "run, found nothing" (panel
  // saying so) -- plain `{{#if this.validationIssues}}` can't tell those
  // apart since Ember templates treat an empty array as falsy too.
  get hasValidated() {
    return this.validationIssues !== null;
  }

  // Which diagram type the "+ View" button creates next -- block by
  // default (Milestone A), switchable to petri/er (Milestones B/C,
  // primitive support) via the adjoining select.
  @tracked newViewType = 'block';

  @action
  setNewViewType(event) {
    this.newViewType = event.target.value;
  }

  @action
  addView() {
    const id = this.modelStore.mutate((model) =>
      model.createView(`View ${this.views.length + 1}`, this.newViewType),
    );
    this.modelStore.activeViewId = id;
  }

  @action
  deleteView(id) {
    this.modelStore.mutate((model) => model.removeView(id));
    if (this.modelStore.activeViewId === id) {
      this.modelStore.activeViewId =
        this.views.find((v) => v.id !== id)?.id ?? null;
    }
  }

  @action
  async newModel() {
    this.modelStore.newModel();
  }

  @action
  async open() {
    try {
      await this.modelStore.open();
    } catch (error) {
      if (error.name === 'AbortError') return; // picker cancelled
      window.alert(`Could not open file: ${error.message}`);
    }
  }

  @action
  async save() {
    await this.modelStore.save();
  }

  @action
  async saveAs() {
    await this.modelStore.saveAs();
  }

  // Runs the well-formedness checks that only make sense on a finished
  // diagram (see FmcModel.validate's comment) on demand, rather than
  // enforcing them live like the bipartite/acyclic-containment rules.
  @action
  validate() {
    this.validationIssues = this.modelStore.model.validate();
  }

  @action
  undo() {
    this.modelStore.undo();
  }

  @action
  redo() {
    this.modelStore.redo();
  }

  @action
  dismissValidation() {
    this.validationIssues = null;
  }

  @action
  selectIssue(elementId) {
    this.selection.select(elementId);
  }

  <template>
    <div class="model-tree">
      <div class="model-tree-section">
        <div class="model-tree-toolbar">
          <button type="button" title="New" {{on "click" this.newModel}}>
            <Icon @icon={{FilePlus}} />
          </button>
          <button type="button" title="Open…" {{on "click" this.open}}>
            <Icon @icon={{FolderOpen}} />
          </button>
          <button type="button" title="Save" {{on "click" this.save}}>
            <Icon @icon={{Save}} />
          </button>
          <button type="button" title="Save As…" {{on "click" this.saveAs}}>
            <Icon @icon={{SavePlus}} />
          </button>
          <button
            type="button"
            title="Undo (⌘Z / Ctrl+Z)"
            disabled={{if this.modelStore.canUndo false true}}
            {{on "click" this.undo}}
          >
            <Icon @icon={{Undo2}} />
          </button>
          <button
            type="button"
            title="Redo (⇧⌘Z / Ctrl+Y)"
            disabled={{if this.modelStore.canRedo false true}}
            {{on "click" this.redo}}
          >
            <Icon @icon={{Redo2}} />
          </button>
          <button
            type="button"
            title="Validate model"
            {{on "click" this.validate}}
          >
            <Icon @icon={{CircleCheckBig}} />
          </button>
        </div>
        {{#if this.hasValidated}}
          <div class="model-tree-validation">
            <div class="model-tree-validation-header">
              <span>{{this.validationIssues.length}} issue(s)</span>
              <button
                type="button"
                title="Dismiss"
                {{on "click" this.dismissValidation}}
              >&times;</button>
            </div>
            {{#if this.validationIssues.length}}
              <ul>
                {{#each this.validationIssues as |issue|}}
                  <li>
                    <button
                      type="button"
                      {{on "click" (fn this.selectIssue issue.elementId)}}
                    >{{issue.message}}</button>
                  </li>
                {{/each}}
              </ul>
            {{else}}
              <p>No issues found.</p>
            {{/if}}
          </div>
        {{/if}}
      </div>

      <div class="model-tree-section">
        <h3>Views</h3>
        <select
          aria-label="New view's diagram type"
          {{on "change" this.setNewViewType}}
        >
          <option value="block">Block</option>
          <option value="petri">Petri net</option>
          <option value="er">ER</option>
        </select>
        <button type="button" title="Add view" {{on "click" this.addView}}>
          <Icon @icon={{SquarePlus}} />
        </button>
        <ul class="model-tree-list">
          {{#each this.views as |modelView|}}
            <ViewRow @view={{modelView}} @onDelete={{this.deleteView}} />
          {{/each}}
        </ul>
      </div>

      <div class="model-tree-section">
        <h3>Elements</h3>
        <ul class="model-tree-list">
          {{#each this.rootElements as |element|}}
            <ModelTreeNode @element={{element}} />
          {{/each}}
        </ul>
      </div>

      <div class="model-tree-section">
        <h3>Arrows</h3>
        <ul class="model-tree-list">
          {{#each this.accesses as |access|}}
            <ArrowRow @access={{access}} />
          {{/each}}
        </ul>
      </div>
    </div>
  </template>
}
