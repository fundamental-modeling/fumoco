import Component from '@glimmer/component';
import { action } from '@ember/object';
import { service } from '@ember/service';
import { on } from '@ember/modifier';
import eq from 'fumoco/helpers/eq';

export default class PropertiesPanel extends Component {
  @service modelStore;
  @service selection;

  get selectedElement() {
    const id = this.selection.selectedIds.at(-1);
    return id ? this.modelStore.model.elements.get(id) : null;
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
        {{#if (eq this.selectedElement.type "storage")}}
          <label class="properties-panel-field properties-panel-checkbox">
            <input
              type="checkbox"
              checked={{this.selectedElement.dashed}}
              {{on "change" this.toggleDashed}}
            />
            Dashed (structure variance)
          </label>
        {{/if}}
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
