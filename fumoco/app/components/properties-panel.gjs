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
      {{else}}
        <p class="properties-panel-empty">Nothing selected.</p>
      {{/if}}
    </div>
  </template>
}
