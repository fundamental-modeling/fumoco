import Component from '@glimmer/component';
import { action } from '@ember/object';
import { service } from '@ember/service';
import { on } from '@ember/modifier';
import { fn } from '@ember/helper';
import eq from 'fumoco/helpers/eq';
import { ConnectorKind, connectorRule } from 'fumoco/services/connector-tool';

const BUTTONS = [
  { kind: ConnectorKind.READ, label: 'Read' },
  { kind: ConnectorKind.WRITE, label: 'Write' },
  { kind: ConnectorKind.MODIFY, label: 'Modify' },
  { kind: ConnectorKind.CHANNEL_DIRECTED, label: 'Channel →' },
  { kind: ConnectorKind.CHANNEL_BIDIRECTIONAL, label: 'Channel ↔' },
  { kind: ConnectorKind.REQRES_LONG, label: 'Req/Res' },
  { kind: ConnectorKind.REQRES_SHORTHAND, label: 'Req/Res (short)' },
];

export default class ConnectorToolbar extends Component {
  @service connectorTool;

  buttons = BUTTONS;

  @action
  toggle(kind) {
    this.connectorTool.arm(kind);
  }

  get hint() {
    const kind = this.connectorTool.kind;
    if (!kind) return null;
    const rule = connectorRule(kind);
    return this.connectorTool.pendingSourceId
      ? `Click the ${rule.targetLabel}…`
      : `Click the ${rule.sourceLabel}…`;
  }

  <template>
    <div class="connector-toolbar">
      {{#each this.buttons as |option|}}
        <button
          type="button"
          class="{{if (eq this.connectorTool.kind option.kind) 'is-armed'}}"
          {{on "click" (fn this.toggle option.kind)}}
        >
          {{option.label}}
        </button>
      {{/each}}
      {{#if this.hint}}
        <span class="connector-toolbar-hint">{{this.hint}}</span>
      {{/if}}
    </div>
  </template>
}
