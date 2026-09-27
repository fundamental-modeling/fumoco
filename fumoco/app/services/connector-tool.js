// Which kind of edge, if any, canvas clicks should currently create instead
// of selecting. "Armed" (kind set) survives across multiple edges so the
// user can draw several of the same kind in a row; a canvas-view click on
// an element while armed sets pendingSourceId first, then creates the edge
// on the second click.
import Service from '@ember/service';
import { tracked } from '@glimmer/tracking';

export const ConnectorKind = Object.freeze({
  READ: 'read',
  WRITE: 'write',
  MODIFY: 'modify',
  CHANNEL_DIRECTED: 'channel-directed',
  CHANNEL_BIDIRECTIONAL: 'channel-bidirectional',
  REQRES_LONG: 'reqres-long',
  REQRES_SHORTHAND: 'reqres-shorthand',
  // One shared kind for both Petri net (place<->transition) and ER
  // (entity_set<->relation) arcs -- FmcModel.addArc itself enforces
  // whichever specific pair actually applies, so the tool doesn't need to
  // know which diagram type is active to arm it.
  ARC: 'arc',
});

const AGENT_TYPES = ['agent', 'human_agent'];
const LOCATION_TYPES = ['location'];
const ARC_TYPES = ['place', 'transition', 'entity_set', 'relation'];

// What each connector kind's source/target must be -- both for eligibility
// highlighting on the canvas and for the toolbar's step-by-step hint text.
// Access edges are agent->location; channels/reqres are agent->agent (a
// channel's own place is created automatically, not picked by the user --
// see FmcModel.addChannel/addReqRes).
const RULES = {
  [ConnectorKind.READ]: {
    source: AGENT_TYPES,
    target: LOCATION_TYPES,
    sourceLabel: 'agent that reads',
    targetLabel: 'location being read',
  },
  [ConnectorKind.WRITE]: {
    source: AGENT_TYPES,
    target: LOCATION_TYPES,
    sourceLabel: 'agent that writes',
    targetLabel: 'location being written',
  },
  [ConnectorKind.MODIFY]: {
    source: AGENT_TYPES,
    target: LOCATION_TYPES,
    sourceLabel: 'agent with modifying access',
    targetLabel: 'location being modified',
  },
  [ConnectorKind.CHANNEL_DIRECTED]: {
    source: AGENT_TYPES,
    target: AGENT_TYPES,
    sourceLabel: 'source agent',
    targetLabel: 'target agent',
  },
  [ConnectorKind.CHANNEL_BIDIRECTIONAL]: {
    source: AGENT_TYPES,
    target: AGENT_TYPES,
    sourceLabel: 'first agent',
    targetLabel: 'second agent',
  },
  [ConnectorKind.REQRES_LONG]: {
    source: AGENT_TYPES,
    target: AGENT_TYPES,
    sourceLabel: 'requesting agent',
    targetLabel: 'responding agent',
  },
  [ConnectorKind.REQRES_SHORTHAND]: {
    source: AGENT_TYPES,
    target: AGENT_TYPES,
    sourceLabel: 'requesting agent',
    targetLabel: 'responding agent',
  },
  [ConnectorKind.ARC]: {
    source: ARC_TYPES,
    target: ARC_TYPES,
    sourceLabel: 'first element',
    targetLabel: 'second element',
  },
};

export function connectorRule(kind) {
  return RULES[kind] ?? null;
}

export default class ConnectorToolService extends Service {
  @tracked kind = null;
  @tracked pendingSourceId = null;

  arm(kind) {
    this.kind = this.kind === kind ? null : kind;
    this.pendingSourceId = null;
  }

  disarm() {
    this.kind = null;
    this.pendingSourceId = null;
  }
}
