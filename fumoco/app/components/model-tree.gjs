import Component from '@glimmer/component';
import { action } from '@ember/object';
import { service } from '@ember/service';
import { on } from '@ember/modifier';
import ModelTreeNode from 'fumoco/components/model-tree-node';
import ViewRow from 'fumoco/components/view-row';
import { ElementType } from 'fumoco/utils/fmc-model';

export default class ModelTree extends Component {
  @service modelStore;

  get rootElements() {
    return [...this.modelStore.model.elements.values()].filter(
      (element) => element.parent === null,
    );
  }

  get views() {
    return [...this.modelStore.model.views.values()];
  }

  @action
  addAgent() {
    this.modelStore.mutate((model) =>
      model.addElement(ElementType.AGENT, { label: 'New agent' }),
    );
  }

  @action
  addHumanAgent() {
    this.modelStore.mutate((model) =>
      model.addElement(ElementType.HUMAN_AGENT, { label: 'New human agent' }),
    );
  }

  @action
  addStorage() {
    this.modelStore.mutate((model) =>
      model.addElement(ElementType.STORAGE, { label: 'New storage' }),
    );
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
        <div class="model-tree-toolbar">
          <button type="button" {{on "click" this.addAgent}}>+ Agent</button>
          <button type="button" {{on "click" this.addHumanAgent}}>+ Human agent</button>
          <button type="button" {{on "click" this.addStorage}}>+ Storage</button>
        </div>
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
