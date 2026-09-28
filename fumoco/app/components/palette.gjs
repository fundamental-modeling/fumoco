import Component from '@glimmer/component';
import { action } from '@ember/object';
import { service } from '@ember/service';
import { on } from '@ember/modifier';
import { fn } from '@ember/helper';
import eq from 'fumoco/helpers/eq';
import { ElementType } from 'fumoco/utils/fmc-model';
import { ConnectorKind, connectorRule } from 'fumoco/services/connector-tool';
import { nextFreeBoxPosition } from 'fumoco/utils/box-layout';

const BLOCK_CONNECTOR_BUTTONS = [
  { kind: ConnectorKind.READ, label: 'Read' },
  { kind: ConnectorKind.WRITE, label: 'Write' },
  { kind: ConnectorKind.MODIFY, label: 'Modify' },
  { kind: ConnectorKind.CHANNEL_DIRECTED, label: 'Channel →' },
  { kind: ConnectorKind.CHANNEL_BIDIRECTIONAL, label: 'Channel ↔' },
  { kind: ConnectorKind.REQRES_LONG, label: 'Req/Res' },
  { kind: ConnectorKind.REQRES_SHORTHAND, label: 'Req/Res (short)' },
];

const ARC_CONNECTOR_BUTTONS = [{ kind: ConnectorKind.ARC, label: 'Arc' }];

export default class Palette extends Component {
  @service modelStore;
  @service connectorTool;

  get diagramType() {
    return this.modelStore.activeView?.diagramType ?? 'block';
  }

  get connectorButtons() {
    return this.diagramType === 'block'
      ? BLOCK_CONNECTOR_BUTTONS
      : ARC_CONNECTOR_BUTTONS;
  }

  get hint() {
    const kind = this.connectorTool.kind;
    if (!kind) return null;
    const rule = connectorRule(kind);
    return this.connectorTool.pendingSourceId
      ? `Click the ${rule.targetLabel}…`
      : `Click the ${rule.sourceLabel}…`;
  }

  addElement(type, label, { width = 120, height = 60 } = {}) {
    const view = this.modelStore.activeView;
    this.modelStore.mutate((model) => {
      const id = model.addElement(type, { label });
      if (view) {
        const { x, y } = nextFreeBoxPosition(view, width, height);
        view.included.push(id);
        view.boxes.set(id, { x, y, width, height });
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
  addPlace() {
    // Square box so the channel/place circle-rendering trick in
    // buildShape (cornerRadius = half the box) reads as an actual circle
    // rather than an ellipse. Sized down from the plain 60px default to
    // keep the transition-height/place-diameter ratio from the measured
    // reference screenshot (~2.4em transition height / ~1.33em place
    // diameter) once the transition box itself went back to its original
    // 120x60 (the 200x110 transition read too large next to the label
    // text) -- 60 * (1.33/2.4) ~= 33.
    this.addElement(ElementType.PLACE, 'New place', { width: 33, height: 33 });
  }

  @action
  addTransition() {
    this.addElement(ElementType.TRANSITION, 'New transition');
  }

  @action
  addEntitySet() {
    this.addElement(ElementType.ENTITY_SET, 'New entity set');
  }

  @action
  addRelation() {
    this.addElement(ElementType.RELATION, 'New relation');
  }

  @action
  addPartition() {
    // Small and roughly square, like a place -- a triangle glyph, not a
    // label-sized box.
    this.addElement(ElementType.PARTITION, null, { width: 60, height: 50 });
  }

  @action
  toggleConnector(kind) {
    this.connectorTool.arm(kind);
  }

  <template>
    <div class="palette">
      <h3>Elements</h3>
      {{#if (eq this.diagramType "block")}}
        <button type="button" {{on "click" this.addAgent}}>Agent</button>
        <button type="button" {{on "click" this.addHumanAgent}}>Human agent</button>
        <button type="button" {{on "click" this.addLocation}}>Location</button>
      {{else if (eq this.diagramType "petri")}}
        <button type="button" {{on "click" this.addPlace}}>Place</button>
        <button
          type="button"
          {{on "click" this.addTransition}}
        >Transition</button>
      {{else if (eq this.diagramType "er")}}
        <button type="button" {{on "click" this.addEntitySet}}>Entity set</button>
        <button type="button" {{on "click" this.addRelation}}>Relation</button>
        <button
          type="button"
          {{on "click" this.addPartition}}
        >Partition</button>
      {{/if}}

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
