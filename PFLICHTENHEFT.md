# Pflichtenheft — Fumoco

The technical/functional specification: for each user story in
`LASTENHEFT.md`, how it's actually built. `implementation_plan.org` tracks
build status per requirement; when it moves an item to `done`, that
item's "how" belongs here, and a resolved `open question` gets its answer
folded in here too.

## Architecture

- **Frontend**: Ember.js (Octane, template-tag `.gjs` components), Vite-
  based Embroider build. No backend, no ember-data — a single
  `model-store` service holds the in-memory model.
- **Canvas rendering**: Konva.js, chosen so drag/resize/hit-testing don't
  have to be hand-rolled (`Konva.Transformer` for resize handles).
- **Reactivity**: `tracked-built-ins`' `TrackedMap`/`TrackedArray`
  (backed by Ember's own `@ember/reactive/collections`) for the model's
  dynamic-keyed state (`elements`, `views`, `boxes`).
  Canvas shapes are kept in sync with two different mechanisms, not one:
  - **Structural changes** (add/remove element, switch view, add/remove
    edge) go through `syncShapes`, an `ember-modifier` function-modifier
    that auto-tracks whatever it reads and does a full teardown+rebuild
    of the shape layer when any of it changes.
  - **Interactive per-shape changes** (drag, resize) commit their new
    box/position into the tracked model
    as usual, but *also* call `refreshEdges()`/etc. directly, right in
    the same event handler — not relying on the reactive rebuild to
    happen in time, and specifically avoiding tearing down the shape
    that's mid-interaction (which would detach the Transformer from it).
- **Persistence** (Milestone A): single JSON file via the File System
  Access API, with a download/`<input type=file>` fallback; a `file-io`
  service isolates this so Milestone D can add a `vscode-file-io`
  implementation later without touching callers.

## Data model (`app/utils/fmc-model.js`)

```
FmcModel {
  elements: TrackedMap<id, Element>
  accesses: TrackedArray<AccessEdge>
  views: TrackedMap<id, View>
}

Element { id, type: "agent"|"human_agent"|"location", label, parents: id[], dashed, channel }
AccessEdge { agent, kind: "read"|"write"|"modify", location }

View {
  id, name, diagramType
  included: TrackedArray<elementId>
  boxes: TrackedMap<elementId, { x, y, width, height }>
  nestedUnder: TrackedMap<elementId, parentId | null>
}
```

Bipartite validation (`_require`) and containment cycle-checking
(`_isAncestor`) are ports of `attic/src/fmc/model.py`'s equivalents.
Ids are `crypto.randomUUID()` (native, no dependency).

Terminology per FMC's own notation reference
(https://www.fmc-modeling.org/notation_reference): "Location" is the
general term for the passive system component, with "Storage" and
"Channel" as its two specific kinds, not two unrelated concepts —
`ElementType.STORAGE`/`AccessEdge.storage` were renamed to `LOCATION`/
`location` to match. A channel is not a distinct edge type here (see
"Channels as locations" below): `Element.channel` is `null` for an
ordinary location, or `{ shorthand }` to render it as a channel place (a
small circle) instead.

## Layout (`editor.gjs` + `app/styles/app.css`)

Archi-style: a CSS grid (`.editor`, 3 columns × 2 rows) rather than nested
flexbox, since the properties panel spans only the center+canvas column
(not under the tree or palette): `model-tree` occupies column 1 across
both rows, `palette` column 3 across both rows, `editor-canvas-area`
column 2 row 1, `properties-panel` column 2 row 2. Element creation
(agent/human agent/location) and the connector-arming buttons moved from
the tree/a dedicated toolbar into `palette.gjs`; `properties-panel.gjs`
shows the last-selected element's type/label/dashed-flag (or the active
view's name if nothing is selected), editable in place.

## Visual nesting (`canvas-view.gjs`: `computeEffectiveBoxes`, `nestingDepth`)

Deliberately *not* real Konva group-nesting (child coordinates relative
to a parent group) -- that would touch drag/resize/connector/edge-routing
code throughout the file all at once, right after fixing a subtle
reactivity bug there. Instead:

- `nestingDepth(model, id, includedSet, cache)`: how many in-view
  ancestors `id` has (0 for a top-level element), counting only
  containment through parents that are themselves in the view. Exported
  and unit-tested directly (`tests/unit/components/canvas-view-test.js`)
  since it's pure and the recursion is worth pinning down.
- `computeEffectiveBoxes(model, view)`: for every included id, its
  rendered box is either its own stored `view.boxes` entry, or — if it
  has at least one child also in the view — a bounding box around those
  children's *effective* boxes plus `NESTING_PADDING` (30px) on every
  side (the "auto-fit" box), *unless* its own stored `view.boxes` entry
  (set by a manual resize -- see below) still fully contains that auto-fit
  box (`boxContains`), in which case the manual box wins instead. Computed
  deepest-first (via `nestingDepth`, descending) so a grandparent's fit
  sees its already-fit parent. Also exported/tested.
- `syncShapes` builds shapes in *ascending* depth order (outermost first)
  so containers draw behind their content, and passes the same
  `effectiveBoxes` map into `buildEdges` so edge endpoints agree with
  what's actually on screen (not stale `view.boxes` positions).
- A container gets the same 8 resize handles a plain box does (no more
  `fumocoNested`-based exclusion in `attachTransformer`): a shared
  `transformend` handler (leaf and container alike) commits
  `{x, y, width, height}` straight into `view.boxes`, which
  `computeEffectiveBoxes` then either honors (if still big enough for the
  current children) or silently falls back away from (same "invalid
  action is just ignored" precedent as an invalid drag-nest) -- no error,
  no separate "detach from auto-fit" mode to manage. Its label still
  moves to the top-left corner (small, gray) instead of centered.
- Dragging a container (`buildShape`'s `nested` branch) moves every
  currently *displayed*-nested descendant along with it by the same
  delta: `collectDescendantNodes` walks `buildDisplayChildIndex`
  recursively (children, grandchildren, ...) collecting each one's live
  Konva node and starting position; `dragmove` repositions all of them by
  the live delta for immediate visual feedback, `dragend` commits each
  one's shifted absolute box into `view.boxes`. If the container itself
  has a manual-resize box in `view.boxes` (see above), that entry is
  shifted by the same delta too, right alongside its children, so a
  resized-then-dragged container doesn't snap back to its pre-drag
  position on the next render; a container with no manual box (still
  purely auto-fit) has nothing there to shift.
- A container's fill stays plain white, same as any other box -- a muted
  default fill tied purely to "is this a container" was tried and
  reverted; a box's fill only changes when the user explicitly sets it
  (not built yet), not automatically based on its role.
- Every node strokes at `NODE_STROKE_WIDTH` (3, or `NODE_STROKE_WIDTH_SELECTED`
  4 when selected) while every edge stays at `strokeWidth: 2`, so a node's
  outline reads visibly heavier than an edge's (Visualization Guidelines'
  "line weight of edges and nodes").

### World-model containment vs. per-view display (`View.nestedUnder`)

`Element.parents` is the world-model fact, shared by every view.
Whether an element is *displayed* nested inside a parent is a separate,
per-view choice: `View.nestedUnder` (`elementId -> parentId | null`,
`TrackedMap`). No entry means "default to the first model parent also
present in this view"; `displayParentOf(model, view, id, includedSet)` is
the one place this resolution happens, and `nestingDepth`/
`computeEffectiveBoxes`/`buildDisplayChildIndex` all go through it rather
than reading `Element.parents` directly, so the model/view distinction
can't drift out of sync between them.

Dragging a plain (non-container) element (`buildShape`'s non-nested
branch) runs `updateContainmentAfterDrag` after committing its new box:
- If its new center lands inside some *other* element's box (the
  smallest one, if several overlap, excluding its current display
  parent) — `addContainment` (world model) *and* `view.nestedUnder.set`
  to that parent (this view's display). Establishing containment always
  does both, whether triggered by a drag or by the properties panel's
  "add to container" dropdown (same two calls, same order).
- Else, if it's no longer inside the box of the parent it was
  *displayed* nested under — `view.nestedUnder.set(elementId, null)`
  only. `Element.parents` (and every other view's display, and the tree)
  is untouched. Dragging out is explicitly *not* the same action as the
  properties panel's "remove from container" (×), which does call
  `removeContainment` on the model.
- `FmcModelError` from a rejected `addContainment` (e.g. a would-be
  cycle) is caught and silently ignored — an incidental drag-over
  shouldn't pop an alert the way an explicit connector action does.

`FmcModel.removeContainment` and `removeElement` both sweep every view's
`nestedUnder` for entries that referenced the now-gone relationship/
element and delete them, so a view can never keep "displaying" a
containment that no longer exists at the model level.

**Known v1 limitation**: an element with two parents both present in the
same view still renders once (at whichever one `nestedUnder`/the default
resolves to), rather than once per container. Fixing this needs the
instance-based view schema below (each occurrence gets its own id and
box).

## Connectors (`connector-tool` service + `palette` + `canvas-view`)

- `connectorRule(kind)` (in `connector-tool.js`) is the single source of
  truth for each connector kind's required source/target element types
  and its step-by-step hint text — both the palette's hint and the
  canvas's eligibility-dimming read from it, so they can't drift apart.
- Picking a kind arms it; the first canvas click on an eligible element
  sets it as the pending source (dimming non-eligible elements via
  `syncConnectorEligibility`); the second click on an eligible target
  creates the edge. `FmcModelError` (bipartite violations) surfaces as a
  native `alert`.
- Edge routing (`orthogonalPath`) is a single-bend rectilinear path
  (straight segment if the boxes already share an axis, otherwise one
  right-angle bend) — no obstacle avoidance yet (see
  `attic/src/fmc/render.py`'s `_orthogonal_path` for the fancier
  candidate-scoring version, not ported).
- Corners are rounded via a custom `Konva.Shape` using native canvas
  `arcTo` (`Konva.Arrow` doesn't support this) plus hand-drawn triangle
  arrowheads.
- A channel's place is an ordinary `Location` element (see "Channels as
  locations" below), so it's freely draggable and positioned like any
  other box — no separate `channelPlaces` map or dedicated drag handling.

## Access edges as entities; arrow selection, kind editing, routing waypoints

An `AccessEdge` now carries its own `id` (`makeAccessEdge`), not just its
`agent`/`kind`/`location` fields — it's an addressable entity like an
`Element`, not just an implicit line between two of them:
- `FmcModel.updateAccessKind(id, kind)`: splices in a new edge object with
  the same id/endpoints and a different kind (edges are recreated
  wholesale on edit, same as everywhere else — see `makeAccessEdge`'s
  comment).
- `FmcModel.removeAccess(id)`: removes one specific edge (vs. deleting an
  element, which already swept every edge touching it); also sweeps any
  view's `edgeWaypoints` entry for that id.
- `fromJSON` assigns a fresh id to any access edge that doesn't already
  have one (`{ id: makeId(), ...access }`), so a pre-this-feature
  autosave/file still loads without every edge silently losing its
  identity.

`View.edgeWaypoints: TrackedMap<edgeId, TrackedArray<{x, y}>>` holds a
per-view list of user-added routing points for an edge, always stored in
agent-to-location order regardless of which way the edge visually draws
(`drawAccessEdge` reverses them for a `read` edge, which draws
location-to-agent). Routing is a per-view display choice, same spirit as
`nestedUnder` — not a model-level fact.

Rendering (`canvas-view.gjs`): a waypoint is represented as a zero-size
"point box" (`pointBox`), letting `orthogonalPath` route to/from/between
them exactly like it already routes between two real element boxes, with
no separate point-to-point geometry needed. `buildRoutedPath` chains
`orthogonalPath` across every consecutive anchor pair (agent box, each
waypoint in display order, location box), dropping each segment's
duplicate leading point.

Interaction, all on `addRoutedEdge`'s main path shape (the arrowhead
triangles stay `listening: false`, purely decorative):
- `hitStrokeWidth: 16` makes a 2px stroke practically clickable.
- Click selects the edge (`selection.selectEdge`, mutually exclusive with
  element selection — see `selection.js`); the selected edge's stroke
  turns blue via `refreshEdgeStyling`, mirroring a selected node's border.
- Double-click inserts a waypoint at the click position
  (`insertWaypoint`), positioned among any existing waypoints by
  `nearestWaypointInsertIndex` — whichever straight segment (agent center
  → each waypoint in order → location center) the click point is closest
  to, via ordinary point-to-segment distance. This approximates against
  anchor *centers* rather than the actual rendered rounded/orthogonal
  path — close enough to feel natural without reproducing the rendering
  geometry just to pick an insertion index.
- `syncEdgeHandles` draws a small draggable `Konva.Circle` (radius 7, a
  bit bigger than its visual dot for an easier grab target) at each of
  the selected edge's waypoints (rebuilt from scratch on every
  selection/edit, same as the shape layer — there are never more than a
  handful); dragging one live-updates its point (and calls `refreshEdges`
  for immediate visual feedback, uncommitted until `dragend`, same
  live/commit split as every other drag in this file); double-clicking a
  handle removes that waypoint (`removeWaypoint`).
- `syncEdgeSelection` (the modifier driving the above) defers its
  `refreshEdgeStyling`/`syncEdgeHandles` calls into a queued microtask
  rather than calling them synchronously in its own body — same fix, and
  same reason, as `syncShapes`' deferred styling calls (see "Draw order /
  z-index" above): `syncEdgeHandles` reads `view.edgeWaypoints`, and
  calling it synchronously would make *this modifier* depend on that
  array too. Since a handle's own `dragmove` live-writes into that same
  array (for the immediate-feedback line redraw), every pixel of a drag
  would re-fire this modifier and destroy-and-recreate the very handle
  Konva was mid-drag on — which is exactly why dragging a waypoint handle
  (and, transitively, double-clicking one right after) didn't work.
- A known rendering wart: two waypoints that happen to be exactly
  horizontally/vertically aligned still get an unnecessary small jog
  instead of a dead-straight segment, since `orthogonalPath`'s "already
  share an axis" check needs a nonzero-width overlap, which two
  zero-size point-boxes can never produce even when equal on one axis.
  No crash, just a minor visual imperfection — not worth special-casing
  for v1.

The properties panel (`properties-panel.gjs`) shows a selected edge's
endpoints (read-only) and a `kind` `<select>` bound to
`updateAccessKind`, plus a delete button; when an *element* is selected
instead, it lists every access edge touching it (either end) via
`incidentAccesses`, each row clickable to select that edge and a `×`
button to delete it directly.

The model tree (`model-tree.gjs` + new `arrow-row.gjs`) lists every
`FmcModel.accesses` entry under a new "Arrows" section, same tree level
as "Elements"/"Views" (access edges are world-model entities, not
per-view artifacts). Clicking one selects it and pulls both endpoints
into the active view if either isn't already shown there — same "make it
visible" convenience `ModelTreeNode.selectElement` already does for a
lone element.

## Model validation (`FmcModel.validate`, `model-tree.gjs`)

Checks the well-formedness conditions that only make sense on a
*finished* diagram -- currently just the two Access-arity laws from
`spec/index.html` (a channel needs ≥2 accessing agents, a storage needs
≥1) -- run on demand rather than enforced eagerly. This is deliberately
different from the bipartite and acyclic-containment rules, which reject
the mutation outright (`FmcModelError`, surfaced as an `alert`) since
those really can't be temporarily true mid-edit without corrupting the
graph; arity is a completeness property an in-progress diagram is
allowed to violate (an unconnected storage or a half-wired channel is a
normal intermediate state, not a bug).

`FmcModel.validate()` returns `{ elementId, message }[]` by scanning
every `location` element's distinct accessing-agent count against
whichever arity law applies (`element.channel` set or not). The model
tree's "Validate model" toolbar button (`model-tree.gjs`) runs it into a
`@tracked validationIssues` (`null` = never run, so the panel stays
hidden; `[]` = run and clean, so it explicitly says so — a plain
`{{#if this.validationIssues}}` can't tell those two states apart since
Ember templates treat an empty array as falsy too, hence the separate
`hasValidated` getter) and renders the results in a small dismissible
panel, each issue clickable to `selection.select` the offending element.

## Draw order / z-index (`canvas-view.gjs`: `buildDrawOrder`)

`syncShapes` used to add shapes to the Konva layer in "every depth-0
element, then every depth-1 element, then every depth-2 element, ..."
order (a global sort by `nestingDepth`). That had a real bug: since a
later-added Konva node draws on top, it meant *every* deeply-nested
descendant of some container drew above *every* unrelated top-level
element -- including a brand new, entirely unrelated box just added from
the palette, which could render underneath existing nested content it
had no relationship to at all.

`buildDrawOrder(model, view)` replaces that global sort with a DFS over
`view.included`: visit each top-level element (no displayed parent) in
`view.included` order, and immediately recurse into its own displayed
children before moving to the next top-level element. This keeps the one
ordering constraint FMC nesting actually requires (a container draws
behind its own children) while giving two *unrelated* elements exactly
the z-order their relative position in `view.included` implies -- and
since every "add this element to the view" call site (`palette.gjs`,
`model-tree-node.gjs`, `arrow-row.gjs`) pushes to the *end* of
`view.included`, a freshly-added element's whole (single-node) subtree
is always visited dead last, i.e. always on top.

## Box placement (`utils/box-layout.js`: `nextFreeBoxPosition`)

Every "place this newly-added-or-selected element into the active view"
call site used to duplicate the same `40 + 20 * (view.boxes.size % 10)`
cascading-offset formula -- which, being a `% 10`, silently starts
reusing (and therefore overlapping) earlier positions once an 11th
element is placed. `nextFreeBoxPosition(view, width, height)` centralizes
this: it walks the same outward diagonal cascade but keeps stepping past
any offset that would overlap a box already in `view.boxes`, rather than
wrapping back to the start on a fixed schedule. Bounded at 200 attempts,
falling back to just past the last one tried, so a pathological diagram
can't hang the UI.

## Canvas viewport (pan)

Wheel/trackpad scroll pans by translating `stage.x()`/`stage.y()`
directly (shift+wheel swaps the axis, for single-axis input devices).
No zoom yet, just panning. This meant `getPointerPosition()` (raw
container-pixel coordinates, unaffected by the stage's own pan offset)
was no longer safe to use for anything compared against shape positions
(which live in the stage's *local*/world coordinate space) — the marquee
selection's start/move handlers switched to
`getRelativePointerPosition()`, which converts through the stage's
current transform. Everything else (drag/resize/`dragBoundFunc`/snap
guides) was already safe: Konva reports a dragged node's position
relative to its immediate parent (the shape layer), not the stage, so
panning the stage never affected it.

## Containment (`Element.parents`)

Many-to-many, not a single `parent`: `Element.parents` is a `TrackedArray`
of container ids. `FmcModel.addContainment(parentId, childId)`/
`removeContainment` replace the old `setParent`; `_isAncestor` is now a
graph search (DFS/BFS over all parent links, not one chain) so cycles are
still blocked even through an indirect ancestor. `childrenOf(id)` filters
by `element.parents.includes(id)`. The model tree renders an element once
under *each* of its parents (and at the root only if it has none) --
`ModelTreeNode`'s existing recursive `childrenOf` call already does this
for free, no changes needed there.

**Not yet built**: any UI to actually create a containment relationship
(no drag-onto-container, no tree action), and the canvas-side consequence
of many-to-many containment -- drawing an element nested inside each of
its containers when more than one is in the same view. That's the same
underlying mechanism as the "multiple occurrences per view" item below,
now resolved: draw once per occurrence, not once per element id.

## Planned: view instances (multiple occurrences per view + visual nesting)

Not started. Current `View.included: elementId[]` / `boxes: Map<elementId,
Box>` assume exactly one box per element id per view -- this needs to
become `View.instances: Map<instanceId, { elementId, containerInstanceId,
box }>` (an instance id distinct from the element id) so:
- the same element can have more than one box in one view (e.g. nested
  under two different container instances, or just placed twice to avoid
  line crossings);
- an edge can be told to draw to (or be hidden from) one specific
  occurrence, per the Lastenheft item on removable per-instance edges.

This touches `canvas-view.gjs` throughout (shape building keys off
element id everywhere currently: drag/resize commit, connector
click-to-id, `nodesById`, selection) -- deliberately scoped as its own
pass rather than folded into the containment-model change above.

## Channels as locations (`fmc-model.js`, `canvas-view.gjs`)

Done. `Channel { id, source, target, directed, place }` as a distinct
edge type is gone; a channel's place is an ordinary `Location` `Element`
with `channel: { shorthand }` set, connected to its agents via ordinary
`addAccess` edges instead of a `directed` flag on a separate concept:
- `addChannel(source, target, directed)`: one location; directed gives
  source `write`/target `read` (draws arrow-circle-arrow); bidirectional
  gives both `modify` (draws line-circle-line, no arrowheads).
- `addReqRes(source, target, { shorthand })`: shorthand creates one
  bold-labeled (`"R▶"`) location with the same write/read access pattern
  as a directed channel, its glyph carrying direction instead of
  arrowheads; long form creates two locations, `REQ` (source writes/
  target reads) and `RES` (target writes/source reads).

Rendering (`canvas-view.gjs`'s `buildShape`/`drawAccessEdge`): a
`channel`-flagged location gets a near-circular `cornerRadius` (a squashed
`Konva.Rect`, not a dedicated `Konva.Circle`, to reuse all the existing
shape-generic code — drag, resize, label, selection — for free);
`drawAccessEdge` branches on `locationElement.channel` to pick
arrow-circle-arrow vs. line-circle-line and whether to suppress
arrowheads for `shorthand`. `FmcModel.channels`/the old `drawChannel`
method/`View.channelPlaces` are all gone — this was a real reduction in
the number of concepts, not just a relabeling.

`placeChannelElementsInView` (in `canvas-view.gjs`) gives a newly-created
place a default 28x28 box at the midpoint between source and target
(down from an initial 50x50, which read as too large next to a typical
120x60 agent/location box); it's an ordinary `view.boxes` entry
afterward, resizable via the same 8 handles as anything else.

## Removed: automatic box-to-box smart guides

Tried, then explicitly disabled (`showSnapGuides` and its `dragmove`
listener deleted from `canvas-view.gjs`): with more than a few boxes on a
view, a guide line flashing on every nearby-box alignment was too
invasive. Grid snap (`dragBoundFunc`/`snapToGrid`) is unaffected and still
active. The `implementation_plan.org` "draggable ruler guide lines" item
is the intended replacement — a guide you drag in deliberately, not one
the canvas throws up automatically.

## Process note

Commit after each coherent chunk of work (a feature, a bug fix), not just
at phase boundaries — this was missed for a while during Milestone A's
Phase 2–6 work and should not repeat.
