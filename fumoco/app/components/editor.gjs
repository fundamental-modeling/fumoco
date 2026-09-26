import Component from '@glimmer/component';
import { service } from '@ember/service';
import ModelTree from 'fumoco/components/model-tree';
import CanvasView from 'fumoco/components/canvas-view';
import AlignmentToolbar from 'fumoco/components/alignment-toolbar';
import ConnectorToolbar from 'fumoco/components/connector-toolbar';

export default class Editor extends Component {
  @service modelStore;

  <template>
    <div class="editor">
      <ModelTree />
      <div class="editor-main">
        {{#if this.modelStore.activeView}}
          <AlignmentToolbar />
          <ConnectorToolbar />
          <CanvasView />
        {{else}}
          <p class="editor-empty">Create or select a view to start editing.</p>
        {{/if}}
      </div>
    </div>
  </template>
}
