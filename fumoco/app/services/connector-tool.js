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
});

const AGENT_TYPES = ['agent', 'human_agent'];
const STORAGE_TYPES = ['storage'];

// What each connector kind's source/target must be -- both for eligibility
// highlighting on the canvas and for the toolbar's step-by-step hint text.
// Access edges are agent->storage; channels/reqres are agent->agent.
const RULES = {
  [ConnectorKind.READ]: {
    source: AGENT_TYPES,
    target: STORAGE_TYPES,
    sourceLabel: 'agent that reads',
    targetLabel: 'storage/location being read',
  },
  [ConnectorKind.WRITE]: {
    source: AGENT_TYPES,
    target: STORAGE_TYPES,
    sourceLabel: 'agent that writes',
    targetLabel: 'storage/location being written',
  },
  [ConnectorKind.MODIFY]: {
    source: AGENT_TYPES,
    target: STORAGE_TYPES,
    sourceLabel: 'agent with modifying access',
    targetLabel: 'storage/location being modified',
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
