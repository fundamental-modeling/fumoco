import Component from '@glimmer/component';
import { service } from '@ember/service';
import ModelTree from 'fumoco/components/model-tree';
import CanvasView from 'fumoco/components/canvas-view';
import AlignmentToolbar from 'fumoco/components/alignment-toolbar';
import Palette from 'fumoco/components/palette';
import PropertiesPanel from 'fumoco/components/properties-panel';

// Archi-style layout: model tree left, palette right, properties bottom
// (spanning under the canvas), canvas filling the remaining center.
export default class Editor extends Component {
  @service modelStore;

  <template>
    <div class="editor">
      <ModelTree />
      <div class="editor-canvas-area">
        {{#if this.modelStore.activeView}}
          <AlignmentToolbar />
          <CanvasView />
        {{else}}
          <p class="editor-empty">Create or select a view to start editing.</p>
        {{/if}}
      </div>
      <Palette />
      <PropertiesPanel />
    </div>
  </template>
}
