import Component from '@glimmer/component';
import { action } from '@ember/object';
import { service } from '@ember/service';
import { on } from '@ember/modifier';
import { fn } from '@ember/helper';
import eq from 'fumoco/helpers/eq';
import { ElementType } from 'fumoco/utils/fmc-model';
import { ConnectorKind, connectorRule } from 'fumoco/services/connector-tool';
import { nextFreeBoxPosition } from 'fumoco/utils/box-layout';

const CONNECTOR_BUTTONS = [
  { kind: ConnectorKind.READ, label: 'Read' },
  { kind: ConnectorKind.WRITE, label: 'Write' },
  { kind: ConnectorKind.MODIFY, label: 'Modify' },
  { kind: ConnectorKind.CHANNEL_DIRECTED, label: 'Channel →' },
  { kind: ConnectorKind.CHANNEL_BIDIRECTIONAL, label: 'Channel ↔' },
  { kind: ConnectorKind.REQRES_LONG, label: 'Req/Res' },
  { kind: ConnectorKind.REQRES_SHORTHAND, label: 'Req/Res (short)' },
];

export default class Palette extends Component {
  @service modelStore;
  @service connectorTool;

  connectorButtons = CONNECTOR_BUTTONS;

  get hint() {
    const kind = this.connectorTool.kind;
    if (!kind) return null;
    const rule = connectorRule(kind);
    return this.connectorTool.pendingSourceId
      ? `Click the ${rule.targetLabel}…`
      : `Click the ${rule.sourceLabel}…`;
  }

  addElement(type, label) {
    const view = this.modelStore.activeView;
    this.modelStore.mutate((model) => {
      const id = model.addElement(type, { label });
      if (view) {
        const { x, y } = nextFreeBoxPosition(view);
        view.included.push(id);
        view.boxes.set(id, { x, y, width: 120, height: 60 });
      }
    });
  }

  @action
  addAgent() {
    this.addElement(ElementType.AGENT, 'New agent');
  }

  @action
  addHumanAgent() {
    this.addElement(ElementType.HUMAN_AGENT, 'New human agent');
  }

  @action
  addLocation() {
    this.addElement(ElementType.LOCATION, 'New location');
  }

  @action
  toggleConnector(kind) {
    this.connectorTool.arm(kind);
  }

  <template>
    <div class="palette">
      <h3>Elements</h3>
      <button type="button" {{on "click" this.addAgent}}>Agent</button>
      <button type="button" {{on "click" this.addHumanAgent}}>Human agent</button>
      <button type="button" {{on "click" this.addLocation}}>Location</button>

      <h3>Connectors</h3>
      {{#each this.connectorButtons as |option|}}
        <button
          type="button"
          class="{{if (eq this.connectorTool.kind option.kind) 'is-armed'}}"
          {{on "click" (fn this.toggleConnector option.kind)}}
        >
          {{option.label}}
        </button>
      {{/each}}
      {{#if this.hint}}
        <p class="palette-hint">{{this.hint}}</p>
      {{/if}}
    </div>
  </template>
}
