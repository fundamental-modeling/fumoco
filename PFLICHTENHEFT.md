# Pflichtenheft — Fumoco

The technical/functional specification: for each requirement in
`LASTENHEFT.md`, how it's actually built. Update this alongside that file
— a Lastenheft entry moving from `planned` to `done` should have its
"how" recorded here, and an `open question` should have its resolved
answer folded in here once decided.

## Architecture

- **Frontend**: Ember.js (Octane, template-tag `.gjs` components), Vite-
  based Embroider build. No backend, no ember-data — a single
  `model-store` service holds the in-memory model.
- **Canvas rendering**: Konva.js, chosen so drag/resize/hit-testing don't
  have to be hand-rolled (`Konva.Transformer` for resize handles).
- **Reactivity**: `tracked-built-ins`' `TrackedMap`/`TrackedArray`
  (backed by Ember's own `@ember/reactive/collections`) for the model's
  dynamic-keyed state (`elements`, `views`, `boxes`, `channelPlaces`).
  Canvas shapes are kept in sync with two different mechanisms, not one:
  - **Structural changes** (add/remove element, switch view, add/remove
    edge) go through `syncShapes`, an `ember-modifier` function-modifier
    that auto-tracks whatever it reads and does a full teardown+rebuild
    of the shape layer when any of it changes.
  - **Interactive per-shape changes** (drag, resize, dragging a channel's
    place circle) commit their new box/position into the tracked model
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
  channels: TrackedArray<Channel>
  views: TrackedMap<id, View>
}

Element { id, type: "agent"|"human_agent"|"storage", label, parent, dashed }
AccessEdge { agent, kind: "read"|"write"|"modify", storage }
Channel { id, source, target, directed, place: { label, shorthand } }

View {
  id, name, diagramType
  included: TrackedArray<elementId>
  boxes: TrackedMap<elementId, { x, y, width, height }>
  channelPlaces: TrackedMap<channelId, { x, y }>  // manual override of the
                                                    // auto-computed midpoint
}
```

Bipartite validation (`_require`) and containment cycle-checking
(`_isAncestor`) are ports of `attic/src/fmc/model.py`'s equivalents.
Ids are `crypto.randomUUID()` (native, no dependency).

## Layout (`editor.gjs` + `app/styles/app.css`)

Archi-style: a CSS grid (`.editor`, 3 columns × 2 rows) rather than nested
flexbox, since the properties panel spans only the center+canvas column
(not under the tree or palette): `model-tree` occupies column 1 across
both rows, `palette` column 3 across both rows, `editor-canvas-area`
column 2 row 1, `properties-panel` column 2 row 2. Element creation
(agent/human agent/storage) and the connector-arming buttons moved from
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
- A container currently showing its auto-fit box is not draggable/
  resizable (`buildShape`'s `nested` option sets `draggable: false` and
  is excluded from `attachTransformer`) — moving it is done by moving its
  children instead, since fighting a live auto-fit recompute with manual
  resize would be confusing. Its label moves to the top-left corner
  (small, gray) instead of centered, so it reads as a container label
  rather than competing with the nested content.

**Known v1 limitation**: an element with two parents both present in the
same view still renders once, and *both* parents' auto-fit boxes stretch
to include that single location, rather than the element being drawn
once per container. Fixing this needs the instance-based view schema
below (each occurrence gets its own id and box).

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
- A channel's place circle is `draggable`; dragging it commits an
  `{x, y}` into that view's `channelPlaces` for that channel's id. When
  set, the edge routes through it as two independent legs (source→point,
  point→target), each still rectilinear via the same `orthogonalPath`
  fed a zero-size "point box."

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

## Planned: channel places as locations

Not started. `Channel { id, source, target, directed, place }` as a
distinct edge type goes away; a channel's place becomes an ordinary
`Element` (type `storage`) with a rendering flag (e.g. `renderAsChannel:
true`) that draws it as a small circle instead of a rounded rect, with
direction carried by which agent has `read` vs `write` access to it
(matching FMC's arrow-circle-arrow / line-circle-line convention) rather
than a `directed` flag on a separate edge concept:
- directed channel A→B: one place-storage, A has `write`, B has `read`.
- bidirectional channel: one place-storage, both agents have `modify`.
- req/res long form: two place-storages (REQ: source writes/target
  reads; RES: target writes/source reads).
- req/res shorthand: one place-storage, same access pattern as directed,
  plus the existing bold-label/no-arrowhead rendering flags.

This removes `FmcModel.channels`/`addChannel`/`addReqRes` and the
`Channel`-specific canvas code (`drawChannel`, `channelPlaces`) in favor
of routing everything through `addAccess` plus the new rendering flag --
a real reduction in the number of concepts, not just a relabeling.

## Process note

Commit after each coherent chunk of work (a feature, a bug fix), not just
at phase boundaries — this was missed for a while during Milestone A's
Phase 2–6 work and should not repeat.
