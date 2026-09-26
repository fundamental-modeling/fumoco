import Component from '@glimmer/component';
import { action } from '@ember/object';
import { service } from '@ember/service';
import { on } from '@ember/modifier';
import { fn } from '@ember/helper';
import { FmcModelError } from 'fumoco/utils/fmc-model';

export default class PropertiesPanel extends Component {
  @service modelStore;
  @service selection;

  get selectedElement() {
    const id = this.selection.selectedIds.at(-1);
    return id ? this.modelStore.model.elements.get(id) : null;
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
  updateViewName(event) {
    const view = this.modelStore.activeView;
    if (!view) return;
    this.modelStore.mutate(() => {
      view.name = event.target.value || view.name;
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
          Label
          <input
            type="text"
            value={{this.selectedElement.label}}
            {{on "input" this.updateLabel}}
          />
        </label>
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
      {{else}}
        <p class="properties-panel-empty">Nothing selected.</p>
      {{/if}}
    </div>
  </template>
}
