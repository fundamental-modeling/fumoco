import Component from '@glimmer/component';
import { action } from '@ember/object';
import { service } from '@ember/service';
import { on } from '@ember/modifier';
import ModelTreeNode from 'fumoco/components/model-tree-node';
import ViewRow from 'fumoco/components/view-row';

export default class ModelTree extends Component {
  @service modelStore;

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

  @action
  addView() {
    const id = this.modelStore.mutate((model) =>
      model.createView(`View ${this.views.length + 1}`),
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
    await this.modelStore.open();
  }

  @action
  async save() {
    await this.modelStore.save();
  }

  @action
  async saveAs() {
    await this.modelStore.saveAs();
  }

  <template>
    <div class="model-tree">
      <div class="model-tree-section">
        <div class="model-tree-toolbar">
          <button type="button" {{on "click" this.newModel}}>New</button>
          <button type="button" {{on "click" this.open}}>Open&hellip;</button>
          <button type="button" {{on "click" this.save}}>Save</button>
          <button type="button" {{on "click" this.saveAs}}>Save As&hellip;</button>
        </div>
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
        <h3>Views</h3>
        <button type="button" {{on "click" this.addView}}>+ View</button>
        <ul class="model-tree-list">
          {{#each this.views as |modelView|}}
            <ViewRow @view={{modelView}} @onDelete={{this.deleteView}} />
          {{/each}}
        </ul>
      </div>
    </div>
  </template>
}
