import Component from '@glimmer/component';
import { tracked } from '@glimmer/tracking';
import { action } from '@ember/object';
import { service } from '@ember/service';
import { on } from '@ember/modifier';
import { modifier } from 'ember-modifier';

const focusOnInsert = modifier((element) => element.focus());

export default class ViewRow extends Component {
  @service modelStore;

  @tracked isEditing = false;
  @tracked draftName = '';

  get isActive() {
    return this.args.view.id === this.modelStore.activeViewId;
  }

  @action
  select() {
    this.modelStore.activeViewId = this.args.view.id;
  }

  @action
  startEditing(event) {
    event.stopPropagation();
    this.draftName = this.args.view.name;
    this.isEditing = true;
  }

  @action
  updateDraft(event) {
    this.draftName = event.target.value;
  }

  @action
  commitEditing() {
    if (!this.isEditing) return;
    this.isEditing = false;
    const name = this.draftName.trim();
    this.modelStore.mutate(() => {
      this.args.view.name = name || this.args.view.name;
    });
  }

  @action
  handleEditKeydown(event) {
    if (event.key === 'Enter') {
      event.target.blur();
    } else if (event.key === 'Escape') {
      this.isEditing = false;
    }
  }

  @action
  deleteView(event) {
    event.stopPropagation();
    this.args.onDelete(this.args.view.id);
  }

  <template>
    <li>
      {{#if this.isEditing}}
        <input
          class="model-tree-node-rename"
          aria-label="Rename view"
          value={{this.draftName}}
          {{focusOnInsert}}
          {{on "input" this.updateDraft}}
          {{on "keydown" this.handleEditKeydown}}
          {{on "blur" this.commitEditing}}
        />
      {{else}}
        <button
          type="button"
          class="model-tree-node-label {{if this.isActive 'is-selected'}}"
          {{on "click" this.select}}
          {{on "dblclick" this.startEditing}}
        >
          {{@view.name}}
        </button>
        <button
          type="button"
          class="model-tree-node-rename-btn"
          title="Rename"
          {{on "click" this.startEditing}}
        >&#9998;</button>
        <button
          type="button"
          class="model-tree-node-delete"
          {{on "click" this.deleteView}}
        >&times;</button>
      {{/if}}
    </li>
  </template>
}
