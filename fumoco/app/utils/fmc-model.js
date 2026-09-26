// Fumoco's in-memory model: a JS port of attic/src/fmc/model.py's shape,
// normalized to reference elements by a stable `id` (from crypto.randomUUID)
// instead of Python's direct object references, and made reactive with
// tracked-built-ins so Ember components re-render on mutation.
//
// Terminology per FMC's own notation reference (fmc-modeling.org): the
// passive system component is a "Location", with "Storage" and "Channel"
// as its two specific kinds -- not two unrelated concepts. A channel is
// NOT a distinct edge type here (unlike attic/src/fmc/model.py, where it
// was): per explicit request, a channel's "place" (the small circle) is
// an ordinary Location Element with `channel` rendering metadata set,
// connected to its agents via ordinary access edges. Direction is carried
// by which agents have read/write access to it (arrow-circle-arrow) or
// modify access (line-circle-line, no arrowheads) -- not by a `directed`
// flag on a separate concept. See addChannel/addReqRes below and
// PFLICHTENHEFT.md for the rendering side. Petri/ER element types are added
// in Milestones B/C without changing this shape's spirit -- see the plan.

import { tracked } from '@glimmer/tracking';
import { TrackedArray, TrackedMap } from 'tracked-built-ins';

export class FmcModelError extends Error {}

export const ElementType = Object.freeze({
  AGENT: 'agent',
  HUMAN_AGENT: 'human_agent',
  LOCATION: 'location',
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
  @tracked dashed = false; // location only -- structure variance
  // location only -- null for an ordinary storage box; { shorthand } to
  // render as a channel place (small circle) instead -- FMC's other kind
  // of location. `shorthand` bolds the label and suppresses arrowheads on
  // edges touching it (the label's own glyph, e.g. "R▶", carries
  // direction instead). See canvas-view.gjs.
  @tracked channel;

  constructor(
    id,
    type,
    { label = null, parents = [], dashed = false, channel = null } = {},
  ) {
    this.id = id;
    this.type = type;
    this.label = label;
    for (const parentId of parents) this.parents.push(parentId);
    this.dashed = dashed;
    this.channel = channel;
  }
}

function makeId() {
  return crypto.randomUUID();
}

// Access edges are recreated wholesale (not field-mutated) on edit, so
// plain objects -- held in a TrackedArray -- are enough: pushing/splicing
// the array is what's reactive, not any one edge's fields. `id` exists so
// an edge can be an addressable entity in its own right (selected on the
// canvas, listed in the model tree, given routing waypoints in a view)
// rather than only ever being matched by its endpoints.
export function makeAccessEdge(agentId, kind, locationId) {
  return { id: makeId(), agent: agentId, kind, location: locationId };
}

// Upgrades a pre-rename export (ElementType "storage", AccessEdge.storage,
// a singular Element.parent, FmcModel.channels, View.channelPlaces) to the
// current schema, so an old autosave/file still loads correctly instead of
// silently dropping every access edge and channel (their fields just
// wouldn't exist under the new names). A no-op on an already-current
// export -- detected per-field, not by a version flag, since none of these
// old exports carried one.
function migrateLegacyJSON(json) {
  const elements = { ...(json.elements ?? {}) };
  for (const [id, element] of Object.entries(elements)) {
    const migrated = { ...element };
    if (migrated.type === 'storage') migrated.type = ElementType.LOCATION;
    if (!migrated.parents && 'parent' in migrated) {
      migrated.parents = migrated.parent != null ? [migrated.parent] : [];
    }
    elements[id] = migrated;
  }

  const accesses = (json.accesses ?? []).map((access) => {
    if (!('storage' in access)) return access;
    const { storage, ...rest } = access;
    return { ...rest, location: storage };
  });

  // Each legacy Channel becomes an ordinary Location element wired up via
  // ordinary access edges -- the same shape addChannel/addReqRes produce.
  const legacyPlaceSources = new Map(); // placeId -> { source, target }
  for (const channel of json.channels ?? []) {
    const placeId = channel.id;
    elements[placeId] = {
      type: ElementType.LOCATION,
      label: channel.place?.label ?? null,
      parents: [],
      dashed: false,
      channel: { shorthand: !!channel.place?.shorthand },
    };
    legacyPlaceSources.set(placeId, {
      source: channel.source,
      target: channel.target,
    });
    if (channel.directed) {
      accesses.push(
        { agent: channel.source, kind: 'write', location: placeId },
        { agent: channel.target, kind: 'read', location: placeId },
      );
    } else {
      accesses.push(
        { agent: channel.source, kind: 'modify', location: placeId },
        { agent: channel.target, kind: 'modify', location: placeId },
      );
    }
  }

  const views = { ...(json.views ?? {}) };
  for (const [viewId, view] of Object.entries(views)) {
    const included = [...(view.included ?? [])];
    const boxes = { ...(view.boxes ?? {}) };
    const channelPlaces = view.channelPlaces ?? {};
    for (const [placeId, { source, target }] of legacyPlaceSources) {
      const sourceBox = boxes[source];
      const targetBox = boxes[target];
      if (!sourceBox || !targetBox) continue; // channel not shown in this view
      const override = channelPlaces[placeId];
      const size = 50;
      const box = override
        ? { x: override.x, y: override.y, width: size, height: size }
        : {
            x:
              (sourceBox.x +
                sourceBox.width / 2 +
                (targetBox.x + targetBox.width / 2)) /
                2 -
              size / 2,
            y:
              (sourceBox.y +
                sourceBox.height / 2 +
                (targetBox.y + targetBox.height / 2)) /
                2 -
              size / 2,
            width: size,
            height: size,
          };
      included.push(placeId);
      boxes[placeId] = box;
    }
    views[viewId] = { ...view, included, boxes, channelPlaces: undefined };
  }

  return { ...json, elements, accesses, views, channels: undefined };
}

export class View {
  id;
  @tracked name;
  @tracked diagramType;
  included = new TrackedArray(); // element ids shown in this view
  boxes = new TrackedMap(); // element id -> { x, y, width, height }
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
  // AccessEdge id -> TrackedArray<{x, y}>, ordered agent-to-location
  // regardless of which way the edge visually draws (see canvas-view.gjs's
  // drawAccessEdge). User-added routing waypoints an edge's rectilinear
  // path is routed through, in a view -- routing is a per-view display
  // choice, same as nestedUnder, not a model-level fact.
  edgeWaypoints = new TrackedMap();

  constructor(id, name, diagramType = 'block') {
    this.id = id;
    this.name = name;
    this.diagramType = diagramType;
  }
}

export class FmcModel {
  elements = new TrackedMap(); // id -> Element
  accesses = new TrackedArray(); // AccessEdge[]
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
    // A channel place (a location Element) that loses one of its agents
    // is just an ordinary element losing an ordinary access edge -- no
    // separate channel-cleanup needed now that a channel isn't its own
    // edge type.
    const removedEdgeIds = this.accesses
      .filter((a) => a.agent === id || a.location === id)
      .map((a) => a.id);
    this._removeInPlace(
      this.accesses,
      (a) => a.agent === id || a.location === id,
    );
    for (const view of this.views.values()) {
      for (const edgeId of removedEdgeIds) view.edgeWaypoints.delete(edgeId);
    }
  }

  removeAccess(id) {
    this._removeInPlace(this.accesses, (a) => a.id === id);
    for (const view of this.views.values()) view.edgeWaypoints.delete(id);
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

  addAccess(agentId, kind, locationId) {
    this._require(agentId, ElementType.AGENT, ElementType.HUMAN_AGENT);
    this._require(locationId, ElementType.LOCATION);
    const edge = makeAccessEdge(agentId, kind, locationId);
    this.accesses.push(edge);
    return edge;
  }

  // Access edges are recreated wholesale on edit (see makeAccessEdge's
  // comment) rather than field-mutated, so a kind change is a splice, not
  // an assignment -- that's what makes it visible to the TrackedArray.
  updateAccessKind(id, kind) {
    const index = this.accesses.findIndex((a) => a.id === id);
    if (index === -1) return;
    this.accesses.splice(index, 1, { ...this.accesses[index], kind });
  }

  // Creates the channel's place (a Location Element with `channel` render
  // metadata) and connects it to both agents via ordinary access edges --
  // directed: source writes, target reads (draws as arrow-circle-arrow);
  // bidirectional: both agents get modify access (draws as a plain
  // line-circle-line, no arrowheads -- see canvas-view.gjs). Returns the
  // new place element's id so the caller can add it to a view's boxes.
  addChannel(sourceId, targetId, directed, { label = null } = {}) {
    this._require(sourceId, ElementType.AGENT, ElementType.HUMAN_AGENT);
    this._require(targetId, ElementType.AGENT, ElementType.HUMAN_AGENT);
    const placeId = this.addElement(ElementType.LOCATION, {
      label,
      channel: { shorthand: false },
    });
    if (directed) {
      this.addAccess(sourceId, 'write', placeId);
      this.addAccess(targetId, 'read', placeId);
    } else {
      this.addAccess(sourceId, 'modify', placeId);
      this.addAccess(targetId, 'modify', placeId);
    }
    return placeId;
  }

  // shorthand: one place (source writes, target reads), labeled "R▶",
  // bold, no arrowheads -- the glyph itself carries direction. Long form:
  // two places, REQ (source writes/target reads) and RES (target writes/
  // source reads). Returns the new place element id(s).
  addReqRes(sourceId, targetId, { shorthand = false } = {}) {
    this._require(sourceId, ElementType.AGENT, ElementType.HUMAN_AGENT);
    this._require(targetId, ElementType.AGENT, ElementType.HUMAN_AGENT);
    if (shorthand) {
      const placeId = this.addElement(ElementType.LOCATION, {
        label: 'R▶',
        channel: { shorthand: true },
      });
      this.addAccess(sourceId, 'write', placeId);
      this.addAccess(targetId, 'read', placeId);
      return [placeId];
    }
    const reqId = this.addElement(ElementType.LOCATION, {
      label: 'REQ',
      channel: { shorthand: false },
    });
    this.addAccess(sourceId, 'write', reqId);
    this.addAccess(targetId, 'read', reqId);
    const resId = this.addElement(ElementType.LOCATION, {
      label: 'RES',
      channel: { shorthand: false },
    });
    this.addAccess(targetId, 'write', resId);
    this.addAccess(sourceId, 'read', resId);
    return [reqId, resId];
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
            channel: element.channel ? { ...element.channel } : null,
          },
        ]),
      ),
      accesses: [...this.accesses],
      views: Object.fromEntries(
        [...this.views].map(([id, view]) => [
          id,
          {
            name: view.name,
            diagramType: view.diagramType,
            included: [...view.included],
            boxes: Object.fromEntries(view.boxes),
            nestedUnder: Object.fromEntries(view.nestedUnder),
            edgeWaypoints: Object.fromEntries(
              [...view.edgeWaypoints].map(([edgeId, points]) => [
                edgeId,
                points.map((p) => ({ ...p })),
              ]),
            ),
          },
        ]),
      ),
    };
  }

  static fromJSON(rawJson) {
    const json = migrateLegacyJSON(rawJson);
    const model = new FmcModel();
    for (const [id, element] of Object.entries(json.elements ?? {})) {
      model.elements.set(
        id,
        new Element(id, element.type, {
          label: element.label,
          parents: element.parents ?? [],
          dashed: element.dashed,
          channel: element.channel ? { ...element.channel } : null,
        }),
      );
    }
    for (const access of json.accesses ?? []) {
      // `id: makeId()` first, then spread `access` over it, so an already-
      // current export's own id wins and only a legacy/missing one gets a
      // fresh one assigned here.
      model.accesses.push({ id: makeId(), ...access });
    }
    for (const [id, view] of Object.entries(json.views ?? {})) {
      const v = new View(id, view.name, view.diagramType);
      for (const elementId of view.included ?? []) v.included.push(elementId);
      for (const [elementId, box] of Object.entries(view.boxes ?? {}))
        v.boxes.set(elementId, { ...box });
      for (const [elementId, parentId] of Object.entries(
        view.nestedUnder ?? {},
      ))
        v.nestedUnder.set(elementId, parentId);
      for (const [edgeId, points] of Object.entries(view.edgeWaypoints ?? {})) {
        v.edgeWaypoints.set(
          edgeId,
          new TrackedArray(points.map((p) => ({ ...p }))),
        );
      }
      model.views.set(id, v);
    }
    return model;
  }
}
