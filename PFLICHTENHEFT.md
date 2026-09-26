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
  side. Computed deepest-first (via `nestingDepth`, descending) so a
  grandparent's fit sees its already-fit parent. Also exported/tested.
- `syncShapes` builds shapes in *ascending* depth order (outermost first)
  so containers draw behind their content, and passes the same
  `effectiveBoxes` map into `buildEdges` so edge endpoints agree with
  what's actually on screen (not stale `view.boxes` positions).
- A container's auto-fit box is still draggable, but not resizable
  (`buildShape`'s `nested` option sets a `fumocoNested` Konva attribute,
  checked in `attachTransformer` to exclude it from resize handles --
  fighting a live auto-fit recompute with a manual resize would be
  confusing, but dragging is a real translation, not a resize). Its label
  moves to the top-left corner (small, gray) instead of centered.
- Dragging a container (`buildShape`'s `nested` branch) moves every
  currently *displayed*-nested descendant along with it by the same
  delta: `collectDescendantNodes` walks `buildDisplayChildIndex`
  recursively (children, grandchildren, ...) collecting each one's live
  Konva node and starting position; `dragmove` repositions all of them by
  the live delta for immediate visual feedback, `dragend` commits each
  one's shifted absolute box into `view.boxes`. The container's own box
  is never written (it stays auto-fit from the new child positions on
  next render).

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
