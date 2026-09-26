import Component from '@glimmer/component';
import { tracked } from '@glimmer/tracking';
import { action } from '@ember/object';
import { service } from '@ember/service';
import { on } from '@ember/modifier';
import { modifier } from 'ember-modifier';

const focusOnInsert = modifier((element) => element.focus());

export default class ModelTreeNode extends Component {
  @service modelStore;
  @service selection;

  @tracked isEditing = false;
  @tracked draftLabel = '';

  get children() {
    return this.modelStore.model.childrenOf(this.args.element.id);
  }

  get isSelected() {
    return this.selection.isSelected(this.args.element.id);
  }

  get displayLabel() {
    return this.args.element.label ?? `(unnamed ${this.args.element.type})`;
  }

  @action
  selectElement() {
    this.selection.select(this.args.element.id);
    const view = this.modelStore.activeView;
    const id = this.args.element.id;
    if (view && !view.included.includes(id)) {
      this.modelStore.mutate(() => {
        const offset = 40 + 20 * (view.boxes.size % 10);
        view.included.push(id);
        view.boxes.set(id, { x: offset, y: offset, width: 120, height: 60 });
      });
    }
  }

  @action
  startEditing(event) {
    event.stopPropagation();
    this.draftLabel = this.args.element.label ?? '';
    this.isEditing = true;
  }

  @action
  updateDraft(event) {
    this.draftLabel = event.target.value;
  }

  @action
  commitEditing() {
    if (!this.isEditing) return;
    this.isEditing = false;
    const label = this.draftLabel.trim();
    this.modelStore.mutate(() => {
      this.args.element.label = label || null;
    });
  }

  @action
  handleEditKeydown(event) {
    if (event.key === 'Enter') {
      event.target.blur(); // triggers commitEditing via the blur handler
    } else if (event.key === 'Escape') {
      this.isEditing = false;
    }
  }

  @action
  deleteElement(event) {
    event.stopPropagation();
    this.modelStore.mutate((model) =>
      model.removeElement(this.args.element.id),
    );
    this.selection.clear();
  }

  <template>
    <li class="model-tree-node">
      {{#if this.isEditing}}
        <input
          class="model-tree-node-rename"
          aria-label="Rename element"
          value={{this.draftLabel}}
          {{focusOnInsert}}
          {{on "input" this.updateDraft}}
          {{on "keydown" this.handleEditKeydown}}
          {{on "blur" this.commitEditing}}
        />
      {{else}}
        <div class="model-tree-node-row">
          <button
            type="button"
            class="model-tree-node-label {{if this.isSelected 'is-selected'}}"
            {{on "click" this.selectElement}}
            {{on "dblclick" this.startEditing}}
          >
            <span class="model-tree-node-type">{{@element.type}}</span>
            {{this.displayLabel}}
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
            {{on "click" this.deleteElement}}
          >&times;</button>
        </div>
      {{/if}}
      {{#if this.children.length}}
        <ul>
          {{#each this.children as |child|}}
            <ModelTreeNode @element={{child}} />
          {{/each}}
        </ul>
      {{/if}}
    </li>
  </template>
}
