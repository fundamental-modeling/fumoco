// This file is part of Fumoco.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Holger Peters -- see the LICENSE file.

import Component from '@glimmer/component';
import { action } from '@ember/object';
import { service } from '@ember/service';
import { on } from '@ember/modifier';
import { fn } from '@ember/helper';
import { modifier } from 'ember-modifier';
import { swapBoxAxes } from 'fumoco/components/canvas-view';
import {
  BOX_FILLS,
  FmcModelError,
  formatDate,
  isGlyphType,
} from 'fumoco/utils/fmc-model';

export default class PropertiesPanel extends Component {
  @service modelStore;
  @service selection;

  get selectedElement() {
    const id = this.selection.selectedIds.at(-1);
    return id ? this.modelStore.model.elements.get(id) : null;
  }

  // Views loaded from a file saved before this metadata existed have
  // `null` timestamps -- shown as "-" rather than a fabricated date.
  get viewCreatedAt() {
    return formatDate(this.modelStore.activeView?.createdAt);
  }

  get viewUpdatedAt() {
    return formatDate(this.modelStore.activeView?.updatedAt);
  }

  get selectedAccess() {
    const id = this.selection.selectedEdgeId;
    if (!id) return null;
    return this.modelStore.model.accesses.find((a) => a.id === id) ?? null;
  }

  get selectedAccessAgent() {
    return this.modelStore.model.elements.get(this.selectedAccess?.agent);
  }

  get selectedAccessLocation() {
    return this.modelStore.model.elements.get(this.selectedAccess?.location);
  }

  // Every access edge touching the selected element (as either endpoint --
  // an agent's writes/reads and a location's incoming accesses both count),
  // labeled with the *other* endpoint and which way it points, so a box's
  // connections are readable at a glance without switching to the canvas.
  get incidentAccesses() {
    const element = this.selectedElement;
    if (!element) return [];
    const model = this.modelStore.model;
    return model.accesses
      .filter((a) => a.agent === element.id || a.location === element.id)
      .map((access) => {
        const isAgentEnd = access.agent === element.id;
        const otherId = isAgentEnd ? access.location : access.agent;
        const other = model.elements.get(otherId);
        return {
          access,
          otherLabel: other?.label ?? `(unnamed ${other?.type ?? 'element'})`,
          // From the selected element's point of view: an agent "reads"/
          // "writes"/"modifies" its location; a location is the target of
          // those same verbs from its agent's point of view -- same kind,
          // just described from whichever end is selected.
          description: isAgentEnd ? `${access.kind} →` : `← ${access.kind}`,
        };
      });
  }

  // Every other element is offered as a possible container -- the model's
  // own cycle/self-containment checks (surfaced via an alert) are the
  // actual guard, rather than trying to duplicate that logic here just to
  // pre-filter the list.
  get availableContainers() {
    const element = this.selectedElement;
    if (!element) return [];
    return [...this.modelStore.model.elements.values()].filter(
      (candidate) =>
        candidate.id !== element.id && !element.parents.includes(candidate.id),
    );
  }

  get parentElements() {
    const element = this.selectedElement;
    return element ? this.modelStore.model.parentsOf(element.id) : [];
  }

  // Dashed (structure variance) is a plain-storage-box convention -- a
  // channel place drawn as a dashed circle isn't a real FMC combination.
  get showsDashedOption() {
    const element = this.selectedElement;
    return element?.type === 'location' && !element.channel;
  }

  get showsTokensOption() {
    return this.selectedElement?.type === 'place';
  }

  get showsStartOption() {
    return this.selectedElement?.type === 'place';
  }

  // A relation's ER arcs, each with its entity set -- ticking "1" marks
  // that entity set as the relation's functional ("1") side, drawn as
  // the arrow inside the relation box.
  get relationArcs() {
    const element = this.selectedElement;
    if (element?.type !== 'relation') return [];
    const model = this.modelStore.model;
    return model.arcs
      .filter((arc) => arc.source === element.id || arc.target === element.id)
      .map((arc) => {
        const other = model.elements.get(
          arc.source === element.id ? arc.target : arc.source,
        );
        return {
          arc,
          otherLabel: other?.label || '(unnamed)',
          one: arc.cardinality === 'one',
        };
      });
  }

  @action
  toggleArcOne(arcId, event) {
    const cardinality = event.target.checked ? 'one' : null;
    this.modelStore.mutate((model) =>
      model.updateArcCardinality(arcId, cardinality),
    );
  }

  get selectedAccessLens() {
    return this.selectedAccess?.lens !== false; // lens is the default
  }

  get showsLensOption() {
    return (
      this.selectedAccess?.kind === 'modify' &&
      !this.selectedAccessLocation?.channel
    );
  }

  @action
  toggleLens(event) {
    const id = this.selectedAccess?.id;
    if (!id) return;
    this.modelStore.mutate((model) =>
      model.setAccessLens(id, event.target.checked),
    );
  }

  get isEllipsis() {
    return this.selectedElement?.type === 'ellipsis';
  }

  // Lines and swimlane dividers: which way the line runs is simply the
  // box's longer side, so picking a direction turns the box if needed.
  get isStraightGlyph() {
    return ['line', 'divider'].includes(this.selectedElement?.type);
  }

  get straightGlyphDirection() {
    const box = this.modelStore.activeView?.boxes.get(this.selectedElement?.id);
    return box && box.width > box.height ? 'horizontal' : 'vertical';
  }

  @action
  updateLineDirection(event) {
    const element = this.selectedElement;
    const view = this.modelStore.activeView;
    const box = view?.boxes.get(element?.id);
    if (!box || event.target.value === this.straightGlyphDirection) return;
    this.modelStore.mutate(() => view.boxes.set(element.id, swapBoxAxes(box)));
  }

  @action
  updateOrientation(event) {
    const element = this.selectedElement;
    if (!element) return;
    this.modelStore.mutate(() => {
      element.orientation = event.target.value || null;
    });
  }

  get isText() {
    return this.selectedElement?.type === 'text';
  }

  // Everything with a name shown in views -- not the unlabeled glyphs,
  // and not free text (its text *is* what's shown).
  get showsDisplayName() {
    return !isGlyphType(this.selectedElement?.type);
  }

  @action
  updateDisplayName(event) {
    const element = this.selectedElement;
    if (!element) return;
    this.modelStore.mutate(() => {
      element.displayName = event.target.value || null;
    });
  }

  @action
  updateAccessLabel(event) {
    const id = this.selectedAccess?.id;
    if (!id) return;
    this.modelStore.mutate((model) =>
      model.setAccessLabel(id, event.target.value),
    );
  }

  get showsNopOption() {
    return this.selectedElement?.type === 'transition';
  }

  // "N similar boxes" is block-diagram notation (agents, storages).
  get showsMultipleOption() {
    const element = this.selectedElement;
    return (
      ['agent', 'human_agent', 'location'].includes(element?.type) &&
      !element.channel
    );
  }

  // Edge trees: which sides' incoming edges merge into a shared trunk.
  get bundleSides() {
    const element = this.selectedElement;
    const view = this.modelStore.activeView;
    if (!view || !['agent', 'human_agent', 'location'].includes(element?.type))
      return [];
    const bundled = view.edgeBundles.get(element.id) ?? [];
    return [
      ['n', 'Top'],
      ['e', 'Right'],
      ['s', 'Bottom'],
      ['w', 'Left'],
    ].map(([side, label]) => ({ side, label, on: bundled.includes(side) }));
  }

  @action
  toggleBundle(side, event) {
    const element = this.selectedElement;
    const view = this.modelStore.activeView;
    if (!element || !view) return;
    const current = view.edgeBundles.get(element.id) ?? [];
    const next = event.target.checked
      ? [...current, side]
      : current.filter((s) => s !== side);
    this.modelStore.mutate(() => {
      if (next.length) view.edgeBundles.set(element.id, next);
      else view.edgeBundles.delete(element.id);
    });
  }

  get showsFillOption() {
    return (
      this.selectedElement &&
      this.selectedElement.type !== 'partition' &&
      !isGlyphType(this.selectedElement.type)
    );
  }

  get fillOptions() {
    const current = this.selectedElement?.fill ?? null;
    return [null, ...BOX_FILLS].map((color) => ({
      color,
      swatch: color ?? '#ffffff',
      label: color ? `Fill ${color}` : 'No fill (white)',
      selected: color === current,
    }));
  }

  @action
  toggleMultiple(event) {
    const element = this.selectedElement;
    if (!element) return;
    this.modelStore.mutate(() => {
      element.multiple = event.target.checked;
    });
  }

  @action
  setFill(color) {
    const element = this.selectedElement;
    if (!element) return;
    this.modelStore.mutate(() => {
      element.fill = color;
    });
  }

  // Swatch buttons get their color imperatively (no inline style
  // attribute -- ember-template-lint's no-inline-styles).
  swatchColor = modifier((element, [color]) => {
    element.style.background = color;
  });

  @action
  updateLabel(event) {
    const element = this.selectedElement;
    if (!element) return;
    this.modelStore.mutate(() => {
      element.label = event.target.value || null;
    });
  }

  @action
  toggleDashed(event) {
    const element = this.selectedElement;
    if (!element) return;
    this.modelStore.mutate(() => {
      element.dashed = event.target.checked;
    });
  }

  @action
  updateTokens(event) {
    const element = this.selectedElement;
    if (!element) return;
    const tokens = Math.max(0, parseInt(event.target.value, 10) || 0);
    this.modelStore.mutate(() => {
      element.tokens = tokens;
    });
  }

  @action
  toggleStart(event) {
    const element = this.selectedElement;
    if (!element) return;
    this.modelStore.mutate(() => {
      element.isStart = event.target.checked;
    });
  }

  @action
  toggleNop(event) {
    const element = this.selectedElement;
    if (!element) return;
    this.modelStore.mutate(() => {
      element.isNop = event.target.checked;
    });
  }

  @action
  addToContainer(event) {
    const containerId = event.target.value;
    const element = this.selectedElement;
    if (!containerId || !element) return;
    try {
      this.modelStore.mutate((model) => {
        model.addContainment(containerId, element.id);
        // Establishing containment here also chooses to display it
        // nested in the active view, matching the canvas's drag-to-nest
        // gesture -- both are "establish the relationship" actions, so
        // both do the model *and* the view part of it.
        this.modelStore.activeView?.nestedUnder.set(element.id, containerId);
      });
    } catch (error) {
      if (!(error instanceof FmcModelError)) throw error;
      window.alert(error.message);
    }
    event.target.value = '';
  }

  @action
  removeFromContainer(parentId) {
    const element = this.selectedElement;
    if (!element) return;
    this.modelStore.mutate((model) =>
      model.removeContainment(parentId, element.id),
    );
  }

  @action
  selectAccess(id) {
    this.selection.selectEdge(id);
  }

  @action
  updateAccessKind(event) {
    const access = this.selectedAccess;
    if (!access) return;
    this.modelStore.mutate((model) =>
      model.updateAccessKind(access.id, event.target.value),
    );
  }

  @action
  deleteAccess(id) {
    this.modelStore.mutate((model) => model.removeAccess(id));
    if (this.selection.selectedEdgeId === id) this.selection.clear();
  }

  @action
  updateViewName(event) {
    const view = this.modelStore.activeView;
    if (!view) return;
    this.modelStore.mutate(() => {
      view.name = event.target.value || view.name;
    });
  }

  @action
  updateViewDisplayName(event) {
    const view = this.modelStore.activeView;
    if (!view) return;
    this.modelStore.mutate(() => {
      view.displayName = event.target.value || null;
    });
  }

  @action
  updateViewAuthor(event) {
    const view = this.modelStore.activeView;
    if (!view) return;
    this.modelStore.mutate(() => {
      view.author = event.target.value || null;
    });
  }

  @action
  updateViewContributors(event) {
    const view = this.modelStore.activeView;
    if (!view) return;
    this.modelStore.mutate(() => {
      view.contributors = event.target.value || null;
    });
  }

  <template>
    <div class="properties-panel">
      {{#if this.selectedElement}}
        <div class="properties-panel-row">
          <span
            class="properties-panel-type"
          >{{this.selectedElement.type}}</span>
        </div>
        <label class="properties-panel-field">
          {{#if this.isText}}
            Text
            <textarea
              rows="4"
              value={{this.selectedElement.label}}
              {{on "input" this.updateLabel}}
            ></textarea>
          {{else}}
            Name
            <input
              type="text"
              value={{this.selectedElement.label}}
              {{on "input" this.updateLabel}}
            />
          {{/if}}
        </label>
        {{#if this.isEllipsis}}
          <label class="properties-panel-field">
            Direction
            <select
              value={{this.selectedElement.orientation}}
              {{on "change" this.updateOrientation}}
            >
              <option value="">By shape</option>
              <option value="horizontal">Horizontal …</option>
              <option value="vertical">Vertical ⋮</option>
              <option value="diagonal-down">Diagonal ⋱</option>
              <option value="diagonal-up">Diagonal ⋰</option>
            </select>
          </label>
        {{/if}}
        {{#if this.isStraightGlyph}}
          <label class="properties-panel-field">
            Direction
            <select
              value={{this.straightGlyphDirection}}
              {{on "change" this.updateLineDirection}}
            >
              <option value="horizontal">Horizontal ─</option>
              <option value="vertical">Vertical │</option>
            </select>
          </label>
        {{/if}}
        {{#if this.showsDisplayName}}
          <label class="properties-panel-field">
            Display name
            <input
              type="text"
              placeholder="(the name)"
              value={{this.selectedElement.displayName}}
              {{on "input" this.updateDisplayName}}
            />
          </label>
        {{/if}}
        {{#if this.showsDashedOption}}
          <label class="properties-panel-field properties-panel-checkbox">
            <input
              type="checkbox"
              checked={{this.selectedElement.dashed}}
              {{on "change" this.toggleDashed}}
            />
            Dashed (structure variance)
          </label>
        {{/if}}
        {{#if this.showsTokensOption}}
          <label class="properties-panel-field">
            Tokens (marking)
            <input
              type="number"
              min="0"
              value={{this.selectedElement.tokens}}
              {{on "input" this.updateTokens}}
            />
          </label>
        {{/if}}
        {{#if this.showsStartOption}}
          <label class="properties-panel-field properties-panel-checkbox">
            <input
              type="checkbox"
              checked={{this.selectedElement.isStart}}
              {{on "change" this.toggleStart}}
            />
            Start place
          </label>
        {{/if}}
        {{#if this.showsNopOption}}
          <label class="properties-panel-field properties-panel-checkbox">
            <input
              type="checkbox"
              checked={{this.selectedElement.isNop}}
              {{on "change" this.toggleNop}}
            />
            NOP transition
          </label>
        {{/if}}
        {{#if this.showsMultipleOption}}
          <label class="properties-panel-field properties-panel-checkbox">
            <input
              type="checkbox"
              checked={{this.selectedElement.multiple}}
              {{on "change" this.toggleMultiple}}
            />
            Multiple instances (stacked)
          </label>
        {{/if}}
        {{#if this.bundleSides.length}}
          <div class="properties-panel-field">
            <span class="properties-panel-subhead">Merge edges into a trunk</span>
            <div class="properties-panel-swatches">
              {{#each this.bundleSides as |entry|}}
                <label class="properties-panel-checkbox">
                  <input
                    type="checkbox"
                    checked={{entry.on}}
                    {{on "change" (fn this.toggleBundle entry.side)}}
                  />
                  {{entry.label}}
                </label>
              {{/each}}
            </div>
          </div>
        {{/if}}
        {{#if this.showsFillOption}}
          <div class="properties-panel-field">
            <span class="properties-panel-subhead">Fill</span>
            <div class="properties-panel-swatches">
              {{#each this.fillOptions as |option|}}
                <button
                  type="button"
                  class="properties-panel-swatch
                    {{if option.selected 'is-selected'}}"
                  title={{option.label}}
                  aria-label={{option.label}}
                  aria-pressed={{if option.selected "true" "false"}}
                  {{this.swatchColor option.swatch}}
                  {{on "click" (fn this.setFill option.color)}}
                ></button>
              {{/each}}
            </div>
          </div>
        {{/if}}
        {{#if this.relationArcs.length}}
          <div class="properties-panel-field">
            <span class="properties-panel-subhead">Cardinality ("1" side)</span>
            {{#each this.relationArcs as |entry|}}
              <label class="properties-panel-checkbox">
                <input
                  type="checkbox"
                  checked={{entry.one}}
                  {{on "change" (fn this.toggleArcOne entry.arc.id)}}
                />
                {{entry.otherLabel}}
              </label>
            {{/each}}
          </div>
        {{/if}}
        <div class="properties-panel-field">
          <span class="properties-panel-subhead">Contained in</span>
          {{#if this.parentElements.length}}
            <ul class="properties-panel-parents">
              {{#each this.parentElements as |parent|}}
                <li>
                  <span>{{parent.label}}
                    <span
                      class="properties-panel-type-inline"
                    >({{parent.type}})</span></span>
                  <button
                    type="button"
                    {{on "click" (fn this.removeFromContainer parent.id)}}
                  >&times;</button>
                </li>
              {{/each}}
            </ul>
          {{else}}
            <p class="properties-panel-empty">Not nested in anything.</p>
          {{/if}}
          <select
            aria-label="Add to container"
            {{on "change" this.addToContainer}}
          >
            <option value="">Add to container&hellip;</option>
            {{#each this.availableContainers as |candidate|}}
              <option value={{candidate.id}}>{{candidate.label}}
                ({{candidate.type}})</option>
            {{/each}}
          </select>
        </div>
        <div class="properties-panel-field">
          <span class="properties-panel-subhead">Connections</span>
          {{#if this.incidentAccesses.length}}
            <ul class="properties-panel-parents">
              {{#each this.incidentAccesses as |entry|}}
                <li>
                  <button
                    type="button"
                    class="properties-panel-access-row"
                    {{on "click" (fn this.selectAccess entry.access.id)}}
                  >{{entry.description}}
                    {{entry.otherLabel}}</button>
                  <button
                    type="button"
                    {{on "click" (fn this.deleteAccess entry.access.id)}}
                  >&times;</button>
                </li>
              {{/each}}
            </ul>
          {{else}}
            <p class="properties-panel-empty">No connections.</p>
          {{/if}}
        </div>
      {{else if this.selectedAccess}}
        <div class="properties-panel-row">
          <span class="properties-panel-type">connector</span>
        </div>
        <p class="properties-panel-access-endpoints">
          {{this.selectedAccessAgent.label}}
          &rarr;
          {{this.selectedAccessLocation.label}}
        </p>
        <label class="properties-panel-field">
          Kind
          <select
            value={{this.selectedAccess.kind}}
            {{on "change" this.updateAccessKind}}
          >
            <option value="read">read</option>
            <option value="write">write</option>
            <option value="modify">modify</option>
          </select>
        </label>
        <label class="properties-panel-field">
          Annotation
          <input
            type="text"
            value={{this.selectedAccess.label}}
            {{on "input" this.updateAccessLabel}}
          />
        </label>
        {{#if this.showsLensOption}}
          <label class="properties-panel-field properties-panel-checkbox">
            <input
              type="checkbox"
              checked={{this.selectedAccessLens}}
              {{on "change" this.toggleLens}}
            />
            Two curved arrows (lens) where the boxes face each other
          </label>
        {{/if}}
        <button
          type="button"
          {{on "click" (fn this.deleteAccess this.selectedAccess.id)}}
        >Delete connector</button>
      {{else if this.modelStore.activeView}}
        <div class="properties-panel-row">
          <span class="properties-panel-type">view</span>
        </div>
        <label class="properties-panel-field">
          Name
          <input
            type="text"
            value={{this.modelStore.activeView.name}}
            {{on "input" this.updateViewName}}
          />
        </label>
        <label class="properties-panel-field">
          Display name
          <input
            type="text"
            placeholder="(the name)"
            value={{this.modelStore.activeView.displayName}}
            {{on "input" this.updateViewDisplayName}}
          />
        </label>
        <label class="properties-panel-field">
          Author
          <input
            type="text"
            value={{this.modelStore.activeView.author}}
            {{on "input" this.updateViewAuthor}}
          />
        </label>
        <label class="properties-panel-field">
          Contributors
          <input
            type="text"
            value={{this.modelStore.activeView.contributors}}
            {{on "input" this.updateViewContributors}}
          />
        </label>
        <div class="properties-panel-field">
          <span class="properties-panel-subhead">Created</span>
          <span>{{this.viewCreatedAt}}</span>
        </div>
        <div class="properties-panel-field">
          <span class="properties-panel-subhead">Last edited</span>
          <span>{{this.viewUpdatedAt}}</span>
        </div>
      {{else}}
        <p class="properties-panel-empty">Nothing selected.</p>
      {{/if}}
    </div>
  </template>
}
