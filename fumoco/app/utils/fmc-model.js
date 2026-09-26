// Fumoco's in-memory model: a JS port of attic/src/fmc/model.py's shape,
// normalized to reference elements by a stable `id` (from crypto.randomUUID)
// instead of Python's direct object references, and made reactive with
// tracked-built-ins so Ember components re-render on mutation.
//
// Milestone A scope only: agents/human_agents/storage, access edges,
// channels (incl. reqres). Petri/ER element types are added in
// Milestones B/C without changing this shape's spirit -- see the plan.

import { tracked } from '@glimmer/tracking';
import { TrackedArray, TrackedMap } from 'tracked-built-ins';

export class FmcModelError extends Error {}

export const ElementType = Object.freeze({
  AGENT: 'agent',
  HUMAN_AGENT: 'human_agent',
  STORAGE: 'storage',
});

export class Element {
  id;
  type;
  @tracked label;
  // Many-to-many containment: an element can be nested inside more than
  // one container at once (e.g. a shared resource nested under two
  // different composites) -- not a strict tree, so this is a list, not a
  // single `parent`.
  parents = new TrackedArray();
  @tracked dashed = false; // storage only -- structure variance

  constructor(id, type, { label = null, parents = [], dashed = false } = {}) {
    this.id = id;
    this.type = type;
    this.label = label;
    for (const parentId of parents) this.parents.push(parentId);
    this.dashed = dashed;
  }
}

// Access edges and channels are recreated wholesale (not field-mutated) on
// edit, so plain objects -- held in a TrackedArray -- are enough: pushing/
// splicing the array is what's reactive, not any one edge's fields.
export function makeAccessEdge(agentId, kind, storageId) {
  return { agent: agentId, kind, storage: storageId };
}

function makeId() {
  return crypto.randomUUID();
}

export function makeChannel(sourceId, targetId, directed, place = {}) {
  return {
    id: makeId(),
    source: sourceId,
    target: targetId,
    directed,
    place: { label: place.label ?? null, shorthand: place.shorthand ?? false },
  };
}

export class View {
  id;
  @tracked name;
  @tracked diagramType;
  included = new TrackedArray(); // element ids shown in this view
  boxes = new TrackedMap(); // element id -> { x, y, width, height }
  // channel id -> { x, y }, overriding the auto-computed midpoint when the
  // user has dragged that channel's place circle to a custom spot.
  channelPlaces = new TrackedMap();
  // Whether/under-which-parent an element is *displayed* nested in this
  // view -- independent of Element.parents (the world-model fact).
  // element id -> parentId (display nested under that parent, which must
  // be one of its actual model parents) | null (explicitly displayed
  // un-nested, even though the model still says it's contained somewhere).
  // No entry at all means "use the default": nested under the first
  // model parent that's also present in this view, if any. Dragging an
  // element out of its container's box only ever writes `null` here --
  // it never touches Element.parents (see canvas-view.gjs).
  nestedUnder = new TrackedMap();

  constructor(id, name, diagramType = 'block') {
    this.id = id;
    this.name = name;
    this.diagramType = diagramType;
  }
}

export class FmcModel {
  elements = new TrackedMap(); // id -> Element
  accesses = new TrackedArray(); // AccessEdge[]
  channels = new TrackedArray(); // Channel[]
  views = new TrackedMap(); // id -> View

  // ---- elements & containment ----

  addElement(type, opts = {}) {
    const id = makeId();
    this.elements.set(id, new Element(id, type, opts));
    return id;
  }

  removeElement(id) {
    for (const element of this.elements.values()) {
      const index = element.parents.indexOf(id);
      if (index !== -1) element.parents.splice(index, 1);
    }
    this.elements.delete(id);
    for (const [viewId, view] of this.views) {
      void viewId;
      const index = view.included.indexOf(id);
      if (index !== -1) view.included.splice(index, 1);
      view.boxes.delete(id);
      view.nestedUnder.delete(id);
      // `id` may also have been *someone else's* display parent in this
      // view -- that display choice is now meaningless.
      for (const [childId, parentId] of view.nestedUnder) {
        if (parentId === id) view.nestedUnder.delete(childId);
      }
    }
    this._removeInPlace(
      this.accesses,
      (a) => a.agent === id || a.storage === id,
    );
    const removedChannelIds = this.channels
      .filter((c) => c.source === id || c.target === id)
      .map((c) => c.id);
    this._removeInPlace(
      this.channels,
      (c) => c.source === id || c.target === id,
    );
    for (const view of this.views.values()) {
      for (const channelId of removedChannelIds)
        view.channelPlaces.delete(channelId);
    }
  }

  _removeInPlace(trackedArray, matches) {
    for (let i = trackedArray.length - 1; i >= 0; i--) {
      if (matches(trackedArray[i])) trackedArray.splice(i, 1);
    }
  }

  childrenOf(id) {
    return [...this.elements.values()].filter((element) =>
      element.parents.includes(id),
    );
  }

  parentsOf(id) {
    return (
      this.elements
        .get(id)
        ?.parents.map((parentId) => this.elements.get(parentId)) ?? []
    );
  }

  addContainment(parentId, childId) {
    if (childId === parentId) {
      throw new FmcModelError(`${childId} cannot contain itself`);
    }
    this._require(parentId, null); // just existence, containment allows any type mix
    this._require(childId, null);
    if (this._isAncestor(childId, parentId)) {
      throw new FmcModelError(
        `containing ${childId} in ${parentId} would create a cycle`,
      );
    }
    const child = this.elements.get(childId);
    if (!child.parents.includes(parentId)) child.parents.push(parentId);
  }

  removeContainment(parentId, childId) {
    const child = this.elements.get(childId);
    const index = child?.parents.indexOf(parentId) ?? -1;
    if (index !== -1) child.parents.splice(index, 1);
    // A view that was displaying childId nested under exactly this parent
    // can no longer do so -- the relationship it was showing no longer
    // exists. Falls back to this view's default (another remaining model
    // parent, if any, else un-nested) rather than lying about a
    // containment that's gone.
    for (const view of this.views.values()) {
      if (view.nestedUnder.get(childId) === parentId) {
        view.nestedUnder.delete(childId);
      }
    }
  }

  // Is `candidateId` reachable by walking *any* combination of parent
  // links starting from `id`? (Not just one chain -- many-to-many
  // containment means `id` can have several parents, each with their own
  // several parents, so this is a graph search, not a linear walk.)
  _isAncestor(candidateId, id) {
    const seen = new Set();
    const stack = [...(this.elements.get(id)?.parents ?? [])];
    while (stack.length) {
      const current = stack.pop();
      if (current === candidateId) return true;
      if (seen.has(current)) continue;
      seen.add(current);
      for (const parentId of this.elements.get(current)?.parents ?? []) {
        stack.push(parentId);
      }
    }
    return false;
  }

  // ---- bipartite edges ----

  addAccess(agentId, kind, storageId) {
    this._require(agentId, ElementType.AGENT, ElementType.HUMAN_AGENT);
    this._require(storageId, ElementType.STORAGE);
    const edge = makeAccessEdge(agentId, kind, storageId);
    this.accesses.push(edge);
    return edge;
  }

  addChannel(sourceId, targetId, directed) {
    this._require(sourceId, ElementType.AGENT, ElementType.HUMAN_AGENT);
    this._require(targetId, ElementType.AGENT, ElementType.HUMAN_AGENT);
    const channel = makeChannel(sourceId, targetId, directed);
    this.channels.push(channel);
    return channel;
  }

  addReqRes(sourceId, targetId, { shorthand = false } = {}) {
    if (shorthand) {
      const channel = this.addChannel(sourceId, targetId, true);
      channel.place.label = 'R▶';
      channel.place.shorthand = true;
      return [channel];
    }
    const request = this.addChannel(sourceId, targetId, true);
    request.place.label = 'REQ';
    const response = this.addChannel(targetId, sourceId, true);
    response.place.label = 'RES';
    return [request, response];
  }

  _require(id, ...expectedTypes) {
    const element = this.elements.get(id);
    if (!element) {
      throw new FmcModelError(`unknown element: ${id}`);
    }
    if (
      expectedTypes.length &&
      expectedTypes[0] !== null &&
      !expectedTypes.includes(element.type)
    ) {
      throw new FmcModelError(
        `bipartite violation: ${id} is a ${element.type}, expected one of ${expectedTypes.join(', ')}`,
      );
    }
    return element;
  }

  // ---- views ----

  createView(name, diagramType = 'block') {
    const id = makeId();
    this.views.set(id, new View(id, name, diagramType));
    return id;
  }

  removeView(id) {
    this.views.delete(id);
  }

  // ---- serialization ----

  toJSON() {
    return {
      elements: Object.fromEntries(
        [...this.elements].map(([id, element]) => [
          id,
          {
            type: element.type,
            label: element.label,
            parents: [...element.parents],
            dashed: element.dashed,
          },
        ]),
      ),
      accesses: [...this.accesses],
      channels: [...this.channels],
      views: Object.fromEntries(
        [...this.views].map(([id, view]) => [
          id,
          {
            name: view.name,
            diagramType: view.diagramType,
            included: [...view.included],
            boxes: Object.fromEntries(view.boxes),
            channelPlaces: Object.fromEntries(view.channelPlaces),
            nestedUnder: Object.fromEntries(view.nestedUnder),
          },
        ]),
      ),
    };
  }

  static fromJSON(json) {
    const model = new FmcModel();
    for (const [id, element] of Object.entries(json.elements ?? {})) {
      model.elements.set(
        id,
        new Element(id, element.type, {
          label: element.label,
          parents: element.parents ?? [],
          dashed: element.dashed,
        }),
      );
    }
    for (const access of json.accesses ?? []) {
      model.accesses.push({ ...access });
    }
    for (const channel of json.channels ?? []) {
      model.channels.push({
        ...channel,
        id: channel.id ?? makeId(),
        place: { ...channel.place },
      });
    }
    for (const [id, view] of Object.entries(json.views ?? {})) {
      const v = new View(id, view.name, view.diagramType);
      for (const elementId of view.included ?? []) v.included.push(elementId);
      for (const [elementId, box] of Object.entries(view.boxes ?? {}))
        v.boxes.set(elementId, { ...box });
      for (const [channelId, place] of Object.entries(view.channelPlaces ?? {}))
        v.channelPlaces.set(channelId, { ...place });
      for (const [elementId, parentId] of Object.entries(
        view.nestedUnder ?? {},
      ))
        v.nestedUnder.set(elementId, parentId);
      model.views.set(id, v);
    }
    return model;
  }
}
