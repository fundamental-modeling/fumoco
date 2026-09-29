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
  have to be hand-rolled (`Konva.Transformer` for resize handles, shared
  across every shape type, `rotateEnabled: false` since boxes stay
  axis-aligned and rotation was never persisted -- exactly the 8 corner/
  edge anchors, no rotation handle).
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

## View metadata (`View` in `fmc-model.js`, properties panel)

`View` gained `createdAt`/`updatedAt` (ISO strings) and free-text
`author`/`contributors` fields, shown/editable in the properties panel
alongside the existing view-name field when nothing else is selected
(name already served as the view's own "title", so no separate title
field was needed). `FmcModel.createView` stamps both dates to "now" for
a genuinely new view; `fromJSON` defaults a legacy view's missing dates
to `null` rather than fabricating a creation time it doesn't actually
know.

`updatedAt` is bumped centrally, not by each call site: `model-store.js`'s
`mutate` (the single funnel every mutating action already goes through
for autosave) also sets `this.activeView.updatedAt = new Date().toISOString()`
after every mutation, whenever there is an active view. This is a
best-effort "last edited while this view was open", not precise
per-view dirty tracking — a mutation could touch an element shown only
in some *other* view while this one happens to be active, and it would
still bump this view's timestamp. Distinguishing that would need
tracking which view(s) a given mutation actually affects, which nothing
else in the model does either, so this trades precision for not needing
every one of the many mutation call sites to remember to stamp anything.

## Canvas font (`app.js`, `canvas-view.gjs`: `CANVAS_FONT_FAMILY`)

Canvas text renders in Barlow, matching the FMC diagrams this editor is
modeled after. Self-hosted via `@fontsource/barlow` (imported in
`app.js`, weights 400 and 700 — 700 covers a shorthand channel label's
bold glyph), not a Google Fonts CDN link, so it works offline the same
as everything else in this standalone app. Every `Konva.Text` node sets
`fontFamily: CANVAS_FONT_FAMILY` (`'Barlow, sans-serif'` — the fallback
covers both the brief window before the webfont loads and any glyph
Barlow itself doesn't have).

Canvas text is a real gotcha here: unlike DOM text, it's rasterized with
whatever font is loaded at that *exact instant* and never retroactively
re-renders once a webfont finishes loading later. Since `setupStage`'s
first draw can easily happen before Barlow has loaded on a cold page
load, every label would otherwise silently and permanently render in
the `sans-serif` fallback. Fixed with one
`document.fonts.ready.then(() => shapeLayer.batchDraw())` in
`setupStage`, guarded by `!this.isDestroyed` since that promise can
resolve after the component's already torn down (`this.stage.destroy()`
in the modifier's own cleanup) — calling `batchDraw` on an already-
destroyed layer isn't something Konva promises to handle gracefully.

Narrow-variant width configurability (e.g. offering Barlow Condensed/
Semi-Condensed as an alternative) isn't built — out of scope for this
pass, plain Barlow is what was actually asked for.

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
- Delete/Backspace with an edge selected deletes it (`deleteSelectedEdge`,
  checked ahead of the element-deletion branches in the same `keydown`
  handler) — matching the right-click menu's existing "Delete connector"
  action, which this was missing until now: clicking an edge to select it
  already worked, but neither delete key did anything with it selected,
  since the handler only ever read `selection.selectedIds` (elements).
  An edge has no view-vs-model split the way an element does (it only
  exists in the model at all), so either key removes it outright.
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

## Right-click context menu (`canvas-view.gjs`)

`@tracked contextMenu` (`{ x, y, items }` in viewport pixel coordinates,
or `null`) drives a small HTML `<ul>` overlay rendered alongside the
Konva `<div>`, not inside the canvas itself. Each interactive Konva node
type gets its own `'contextmenu'` handler (`event.evt.preventDefault()` +
`event.cancelBubble = true`) building a target-specific item list, so
there's no need for a single dispatcher walking Konva's hit hierarchy:

- A box's `group` (in `buildShape`): selects it, then rename/copy/cut/
  delete-from-view/delete-from-model (`elementMenuItems`).
- An edge's main path shape (in `addRoutedEdge`, only when `edgeId` is
  set): selects the edge, then insert-waypoint-here (using the same
  `insertWaypoint` a double-click on the line already calls) and delete-
  connector (`edgeMenuItems`).
- A waypoint handle (in `syncEdgeHandles`): just remove-this-point
  (`handleMenuItems`), reusing `removeWaypoint` -- a menu-driven
  alternative to double-clicking the handle, for discoverability.
- The stage itself, only when `event.target === this.stage` (every
  more-specific handler above already `cancelBubble`d): paste, shown only
  when `clipboard` is non-empty (`backgroundMenuItems`).

Copy/cut/paste (`copyElement`/`cutElement`/`pasteClipboard`) work off a
single `@tracked clipboard` holding just an element's own
type/label/dashed/channel -- deliberately not its id, containment, or
access edges, so a paste always creates an independent element rather
than something that reads as an alias of the original. Cut is copy +
`removeElement`. Paste creates a fresh element, adds it to the active
view centered on the right-click point, and selects it.

The menu closes on Escape (checked first in the existing `keydown`
handler), a click anywhere outside `.canvas-context-menu` (a dedicated
window `click` listener, safe from racing a right-click's own menu-open
since a right-click never fires a plain DOM `click` event), or running an
item (`runMenuItem` wraps every action to also clear `contextMenu`
afterward). Positioned via a small `positionContextMenu` element modifier
that sets `element.style.left/top` directly, rather than a template
`style="..."` attribute -- `ember-template-lint`'s `no-inline-styles`
rule disallows the latter.

`this.stage.on('mousedown', ...)` (marquee-select) now also checks
`event.evt.button !== 0` first, so a right-click opening a context menu
can't also kick off a marquee-selection drag underneath it.

## Petri nets and ER diagrams (primitive support)

Milestones B and C, deliberately minimal ("primitive support is okay for
now"): four new `ElementType`s (`PLACE`/`TRANSITION` for Petri nets,
`ENTITY_SET`/`RELATION` for ER) and one new generic edge concept,
`FmcModel.arcs`, rather than one bespoke edge type per diagram type.

- `isRoundedElementType(type)` (`fmc-model.js`) generalizes the angular/
  rounded bipartite distinction across all three diagram types --
  `LOCATION`/`PLACE`/`ENTITY_SET` are rounded, everything else (agent,
  transition, relation) is angular -- so `canvas-view.gjs`'s `buildShape`
  only needs one shared branch instead of duplicating the channel-circle
  trick per diagram type. An entity set specifically reuses that same
  `cornerRadius = min(width, height) / 2` formula (not the plain
  location's smaller fixed 12px rounding): for a square box that's a
  circle, for a wider-than-tall box it's a stadium/pill shape (two
  half-circles joined by a straight-sided rectangle), visually
  distinguishing an entity set from an ordinary location at a glance.
- `FmcModel.addArc(sourceId, targetId, weight = 1)`: one method handling
  both a Petri arc and an ER arc, since both are "a directed edge between
  the two bipartite kinds of one diagram type, with no read/write/modify
  distinction." Validates against *both* valid type pairs
  (place<->transition, entity_set<->relation) rather than needing the
  caller to know which diagram type it's in; throws `FmcModelError` on
  anything else, same as every other bipartite check. `removeArc(id)` and
  `removeElement`'s arc-sweep are equally generic.
- `Element.tokens` (place-only, default 0, same "only meaningful for one
  type" spirit as `dashed`/`channel`) holds a place's marking. No firing
  rule, no capacity, no multi-token/infinite-capacity place styling --
  just a settable count, editable via the properties panel's `showsTokensOption`
  field and rendered inline with the label (`"label (n)"`) in
  `buildShape` rather than as per-token dots, which stop being legible
  past a handful.
- `canvas-view.gjs`'s `buildArcs`/`drawArc` mirror `buildEdges`/
  `drawAccessEdge` structurally but are much simpler: a single directed
  leg, an optional weight label when `weight !== 1`, and a `contextmenu`
  handler offering only "Delete arc" -- no selection state, no waypoints,
  no kind-switching. This is the actual "primitive" cut: Milestone A's
  full connector treatment (`selection.selectedEdgeId`, `edgeWaypoints`,
  the properties panel's connector section) was deliberately not ported
  to arcs in this pass. Routing differs by diagram type, chosen in
  `buildArcs` from the source element's type:
  - A **Petri arc** (place<->transition) uses `verticalArcPath`, not
    `orthogonalPath`: FMC's standard Petri net flow is top-to-bottom, so
    in the common case it exits the source's bottom-center and enters the
    target's top-center perpendicular to that edge, regardless of their
    exact relative x-position. This also fixes a real bug for free -- two
    opposite-direction arcs between the same pair used to route
    identically (just traversed in reverse), so they'd draw as one
    perfectly overlapping line with an arrowhead at each end, reading as
    a single bidirectional edge, which a Petri arc must never be; fixed
    ports make forward and reverse arcs take visibly different paths
    instead. When the target's top is at or below the source's bottom, a
    circular end (a place) has exactly one valid attachment point on that
    side -- its own pole (center-x), the actual "top"/"bottom" of the
    circle, not just anywhere along its bounding box's flat edge -- and
    can't shift to line up with the other end; a rectangular end (a
    transition) can attach anywhere along its flat edge, so it's free to
    shift and meet the other end's x with a single straight vertical
    line, *if* that lands safely inside its own edge (inboard of each
    corner by `EDGE_CORNER_RADIUS`, the same radius every bend in this
    path already rounds to, so a "straight" line never reads as clipping
    the corner). When both ends are rectangular, the source's own center
    is preferred as the line's x. Only when even that doesn't fit does it
    fall back to each end's own center and a horizontal leg at their
    midpoint (already guaranteed clear of both boxes, since it sits below
    the source's bottom and above the target's top by construction).

    When the target *isn't* below the source, two distinct shapes apply,
    chosen by the actual gap between the boxes' x-ranges, not merely
    whether they overlap:

    If that gap is narrower than `ARC_DIAGONAL_STUB` -- including
    overlapping ranges (a reversed-direction arc along a shared column,
    not really "beside", just running against the usual top-to-bottom
    flow) *and* disjoint-but-touching ranges (two boxes pushed flush
    against each other, a real traced case: a place's right edge exactly
    meeting a transition's left edge) -- a short diagonal corner-cut
    can't stay clear of both boxes: the stub's fixed reach isn't enough
    to clear the far box's near edge, so it would land *inside* that box
    and the connecting segment would cut straight through it. This falls
    back to the original plain-ports shape that predates the diagonal
    work entirely: down from the source, out to a lane west of both
    boxes, up past the target, and in -- still leaving south and
    arriving north.

    Only once the gap is at least `ARC_DIAGONAL_STUB` wide (genuinely
    beside with room for the stub to actually clear -- e.g. a self-loop's
    return arc to a transition left or right of its place), the arc
    leaves/arrives via a short 45° diagonal stub (`ARC_DIAGONAL_STUB`,
    28px -- comfortably longer than `EDGE_CORNER_RADIUS` so canvas
    `arcTo` has room to render the same corner radius here as everywhere
    else, since `arcTo` shrinks the radius it draws when the adjacent
    segment is too short to fit it) right at the shape's own boundary,
    but **only at the circular end**. A Petri arc is always
    place<->transition (the bipartite rule), so exactly one endpoint is a
    place; the transition endpoint always keeps the same plain
    south(if source)/north(if target) center port the forward case above
    already uses, since a rectangle's edge midpoint is already a clean
    perpendicular attachment with no need for a corner cut. For the place
    (drawn as a circle via `buildShape`'s `cornerRadius` trick), the
    diagonal stub's anchor is the actual point on the circle at that 45°
    angle (`diagonalBoundaryPoint`), not the invisible bounding box's
    corner, which sits outside the circle.

    The place's diagonal side (top corner when it's this arc's source,
    bottom corner when it's the target) always matches the transition's
    plain port for the same role (a transition-as-target already enters
    north/top; a transition-as-source already exits south/bottom), so
    both ends of any one arc land on the same side -- above both boxes,
    or below both -- letting a single shared lane connect them safely
    (their x-ranges are disjoint here, so the vertical legs down to that
    lane can't cross the other box). A reciprocal arc swaps source and
    target, which swaps which end is the place and therefore swaps
    top<->bottom too, so a loop-back pair can never land on the same
    corner/port and never traces the same line.

    This went through several iterations before landing here: an early
    version made both ends leave/arrive via a top corner (reasoning the
    transit lane sits above both boxes, so a bottom entry would loop
    underneath the target) -- but that reintroduced the exact
    bidirectional-overlap bug this mechanism exists to prevent, since the
    corner formula only depended on which side the *other* box was on,
    not on which arc was being drawn. A second attempt fixed the overlap
    (source always top, target always bottom) with a route fully
    enclosing both boxes, but a traced example showed it attached the arc
    to a corner on *both* ends when only the circular one should ever get
    diagonal treatment.

    A further precision bug in that fix, also caught by tracing an actual
    example by hand: the transition end was given its own short vertical
    "bend" via `ARC_ROUTE_MARGIN` (20px) too, and the shared lane was the
    min/max of *both* bends -- but that margin almost never lined up
    exactly with the diagonal stub's own height (`ARC_DIAGONAL_STUB`,
    28px, measured from a different anchor point), leaving a
    near-zero-length leftover segment between the two. Visually that read
    as the diagonal overshooting into a spurious, nearly invisible
    vertical hop before snapping back to horizontal instead of a clean
    45°-to-horizontal bend, and the degenerate segment gave canvas
    `arcTo` an undefined direction to round against at the *next* corner
    too, so a turn several segments later rendered as a sharp point
    instead of curved. Fixed by dropping the straight end's own bend
    entirely: since only the circular end ever needs a detour, the lane
    is simply that diagonal stub's own height (`circularBend.y`), nudged
    further out only if the straight box's own edge would otherwise stick
    past it (`circularBendClears`), and the straight end connects to that
    lane with a single plain segment, no bend of its own -- 4 points in
    the common case (diagonal stub, bend onto the lane, bend into the
    straight port) instead of 6, or 5 when `circularBendClears` is false
    (see the fifth bug below, which needed an extra point here too).

    A second bug turned up in the *forward* case's plumb-line shortcut,
    caught the same way (tracing a hand-provided example, "Reg test 3"):
    the first version applied it unconditionally, so when the target was
    a place, the line's x came from the source's own center regardless
    of the place's actual pole -- landing the arrow somewhere on the
    place's flat bounding-box edge instead of the true top/bottom of its
    circle, which doesn't read as "arriving at the circle" at all, corner
    margin or not. Fixed by making a circular end's own center
    non-negotiable and only ever letting a rectangular end's attachment
    point shift to meet the other side: `fixedX` is the circular end's
    center when either end is circular (or the source's center when
    neither is), and only the *other*, rectangular box (`flexBox`) is
    checked for whether that x fits inside it.

    A third bug turned up in the loop-back branch's "genuinely beside"
    shape, caught the same way ("Reg test 4"): the shape assumed the
    diagonal stub's fixed 28px reach was always enough to clear the far
    box's near edge -- true with a comfortable horizontal gap, but not
    when the two boxes are pushed flush against each other (zero gap,
    disjoint x-ranges but touching). Fixed by replacing the old boolean
    "do the x-ranges overlap" check with an actual gap measurement
    (`xGap`), and only taking the diagonal shape when that gap is at
    least `ARC_DIAGONAL_STUB` wide; anything narrower -- overlapping or
    merely touching -- falls back to the safe west-lane wraparound.

    A fourth bug: even with a sufficient `xGap`, the diagonal shape could
    still cut through the straight box if the two boxes' vertical offset
    was large enough that the stub's fixed reach fell well short of the
    lane height ("Reg test 5") -- jumping straight from the stub to the
    lane point was then a genuinely diagonal segment (not axis-aligned),
    slicing through the straight box's near corner on the way. Fixed by
    inserting one more point at the stub's own x when
    `!circularBendClears`, keeping every segment axis-aligned; that x is
    provably always clear of the straight box given the `xGap >=
    ARC_DIAGONAL_STUB` gate already in place (the stub can reach at most
    `ARC_DIAGONAL_STUB - circularBox's own radius * (1 - cos 45°)` past
    the circular box's own edge, strictly less than `ARC_DIAGONAL_STUB`
    itself), so the extra vertical leg down/up to the lane never enters
    it.

    A fifth bug, this time in the west-lane wraparound branch itself, was
    caught by a systematic swept regression test added at the user's
    request after the fourth and fifth reports in a row (many
    place/transition placements, both arc directions, asserting no
    crossing in any of them, run at both a coarse grid in the test suite
    and a much finer one standalone) rather than waiting for the next
    one-off report. That branch's clearance margins were each measured
    off only the *nearer* box's own edge (`exit.y + ARC_ROUTE_MARGIN` for
    the bottom lane, `enter.y - ARC_ROUTE_MARGIN` for the top lane) --
    correct back when this branch was only reached for a target cleanly
    above the source, but broken once the `xGap` fix (bug three) also
    routed merely-touching x-ranges through it, where the two boxes can
    overlap substantially in y. Fixed by measuring both lane heights
    against *both* boxes (`Math.max(sourceBottom, targetBottom) +
    ARC_ROUTE_MARGIN` and `Math.min(sourceBox.y, targetBox.y) -
    ARC_ROUTE_MARGIN`), the same "clear of both, not just the nearer one"
    principle the diagonal branch already relies on.
  - An **ER arc** (entity_set<->relation) keeps using `orthogonalPath` --
    an ER diagram has no fixed reading direction (see `spec/index.html`'s
    ER section), so the shortest-route logic that access edges already
    use is the right fit, not a forced vertical flow. `orthogonalPath` is
    also what block-diagram access edges and channels route through, so
    it's the actual routing function for the block-diagram side of the
    app as well as ER, despite living in this Petri-net-heavy section of
    the file.

**Swept regression tests** (`tests/unit/components/canvas-view-test.js`):
after the five Petri-routing bugs above were each found by a one-off
hand-traced example, the user asked for a standing guard instead of
waiting for the next report, plus "any other sweeping tests" including
for block diagrams. Three exist now:
  - `verticalArcPath` swept across many place/transition *positions*
    (the guard that caught bug five above).
  - `verticalArcPath` swept across many place/transition *sizes* too
    (tiny places, very wide/narrow transitions) -- came back clean, a
    standing guard against the diagonal stub's fixed margins
    (`ARC_DIAGONAL_STUB` vs. `EDGE_CORNER_RADIUS`) breaking at extreme
    proportions, not a fix for a found bug.
  - `orthogonalPath` swept across many placements and sizes -- this
    function (block-diagram access/channel edges and ER arcs) had zero
    prior test coverage of any kind before this. Also came back clean.
    `orthogonalPath` is now `export`ed (it wasn't previously) purely so
    the test can call it directly, the same reason `verticalArcPath`
    already was.

Each sweep excludes placements where the two boxes' bounding boxes
already overlap (not a real diagram layout, and not a property either
function claims to handle) and checks, for every remaining placement,
that no segment of the returned path crosses into either box's interior
(touching a boundary at an endpoint is fine; entering past it isn't). Grid
density is kept modest in-suite (the full run happens in a real browser
via testem, where too many assertions in one test risks the runner's own
timeout) -- a finer standalone sweep (plain Node, no browser) is what
actually found bug five and confirmed zero crossings at higher
resolution afterward; see `implementation_plan.org`'s entry for this
section for the exact counts.
- `connector-tool.js`'s new `ConnectorKind.ARC` covers both diagram
  types' arcs with one rule (`source`/`target` both accept
  place/transition/entity_set/relation) -- the specific pairing is
  `addArc`'s job, not the tool's.
- `palette.gjs` now branches its Elements section on
  `modelStore.activeView.diagramType` (block/petri/er) and swaps its
  Connectors section between the existing block-diagram buttons and a
  single "Arc" button. A new place defaults to a 60x60 (square) box so
  the existing channel-circle rendering trick (`cornerRadius` = half the
  box) reads as an actual circle.
- `model-tree.gjs`'s "+ View" gained an adjoining `<select>` for the new
  view's diagram type (block/petri/er), read by `addView` and passed to
  `FmcModel.createView`.
- `Element.isStart` (place-only, default `false`) marks a Petri net's
  starting place, toggled via the properties panel. `buildShape` draws a
  small filled black `Konva.Circle` concentric with the place when set,
  with a visible white gap to the place's own outline -- independent of
  `tokens` (a place can hold a nonzero marking without being where the
  net's flow is considered to begin). Sized as `Math.min(box.width,
  box.height) * 0.47` for the inner circle's diameter, so it scales with
  the place rather than a fixed pixel value -- the ratio comes from a
  measured reference screenshot (place diameter ~1.33em, filled inner
  circle ~0.6-0.67em, i.e. ~0.45-0.5x). An earlier version instead drew a
  short, unconnected stub arrow pointing into the place's left side; that
  wasn't FMC's actual convention and was replaced outright, not kept
  alongside the correct marker.
- Default place/transition size ratio: the same reference screenshot
  also measured a transition box at ~2.4em tall, ~4.5em wide against a
  ~1.33em place diameter. A first attempt kept the place at its existing
  60px and scaled the transition up (~200x110) to match, but that read
  too large relative to the label text. Inverted instead: `addTransition`
  no longer passes an explicit box at all (back to `addElement`'s plain
  120x60 default, its original size), and `addPlace` was sized *down* to
  `60 * (1.33/2.4) ~= 33` (33x33, was 60x60) to keep the same ratio
  against that. The isStart inner-circle sizing (`0.47 *
  Math.min(box.width, box.height)`) is already relative to the place's
  own size, so it scales down automatically with no separate change.
  `addPlace` also now creates a place with `null` label instead of "New
  place", matching `addPartition`'s already-unlabeled default -- a place
  is usually just an unnamed marking-holder.
- `Element.isNop` (transition-only, default `false`) marks a NOP
  (no-operation) transition -- one with no real action, used purely for
  routing/synchronization -- toggled via the properties panel's "NOP
  transition" checkbox (`showsNopOption`/`toggleNop`, mirroring
  `isStart`'s pattern). `buildShape` skips the label entirely when set
  (`isNopTransition = element.type === TRANSITION && element.isNop`) but
  keeps the ordinary white-fill/black-outline rectangle styling --
  distinguished by its proportions, not a solid fill (an initial attempt
  filled it solid black; the user corrected that a NOP bar is not
  filled). `addNopTransition` in `palette.gjs` (a dedicated button,
  shown alongside "Place"/"Transition" in a `petri` view) creates one
  pre-sized to 300x17 -- from the same reference screenshot (NOP bar
  ~0.67em tall, ~12.0em wide, against the ~2.4em/60px transition height,
  scale ~25px/em). `verticalArcPath` treats a NOP transition identically
  to any other transition for routing purposes; `isNop` only changes how
  it's drawn, not the bipartite rule or arc geometry. `palette.gjs`'s
  `addElement` helper gained an `...elementOpts` rest param (spread into
  `FmcModel.addElement`'s own opts) so `isNop: true` -- and any future
  per-element flag -- can be passed through without a bespoke parameter
  for each one.
- ER cardinality: an entity_set<->relation arc's `cardinality` field
  (`null` or `'one'`, toggled via the arc's right-click menu,
  `FmcModel.updateArcCardinality`) draws a small filled triangle a short
  distance *inside* the relation's own box (computed by extending inward
  along the arc's own final segment direction, `ARC_ROUTE_MARGIN`-scale
  inset) -- FMC's "arrow inside the relation symbol" convention for a
  1:n/1:1 relation, distinct from the main edge's own end arrowhead.
  `buildArcs` figures out which end is the relation (`relationEnd`) from
  the elements' types so `drawArc` knows which side to draw it on.
- ER independent (orthogonal) partitioning: a `PARTITION` element renders
  as an actual triangle (a `Konva.Line` with 3 points, apex at the box's
  top-center, base along its bottom edge, in `buildShape`) rather than the
  usual rounded/angular box -- the standard notation for splitting one
  entity set into subsets along an axis (`spec/index.html`'s "Orthogonal
  partitioning" section, which already defined the `part` relation
  formally but had no visual notation until now). It joins the general
  `FmcModel.arcs`/`addArc` bipartite mechanism as a third valid pair
  (`entity_set<->partition`, alongside `place<->transition` and
  `entity_set<->relation`) -- direction carries the meaning: an
  `entity_set->partition` arc is the partitioned superset, attaching at
  the apex; a `partition->entity_set` arc is one part (subset), attaching
  along the base. `drawArc`'s `isPartitionArc` flag (derived in
  `buildArcs` from either endpoint's type, same pattern as `relationEnd`)
  suppresses both the arrowhead and the weight label for these arcs -- a
  plain line, since the triangle itself already carries the meaning, not
  an arrow decoration. Created from the palette's "Partition" button in
  an `er` view; connected via the ordinary "Arc" connector, no dedicated
  connector kind needed since `ConnectorKind.ARC`'s type list already
  covers whichever pair `addArc` itself validates.

  This replaces a first, incorrect attempt at "ER is-a": a `kind:
  'inheritance'` arc connecting two entity sets directly with a hollow
  triangle *arrowhead*, modeled on UML generalization. That confused two
  distinct things -- subtyping via nesting one entity set inside another
  (the "subset" approach, already covered by ordinary containment) versus
  independent partitioning of one entity set into several (which needs
  its own triangle *node*, not a decorated line) -- so it was removed
  outright (the `kind` field, `ConnectorKind.INHERITANCE`, and the
  palette's "Inheritance (is-a)" button all deleted) rather than kept
  alongside the corrected mechanism.
- ER reification: `FmcModel.reifyRelation(relationId, { label })` creates
  a fresh entity set and nests the relation inside it via the existing
  generic containment mechanism (`addContainment` already allows any type
  mix) -- per `spec/index.html`'s Reification section, "the elements of a
  relation become the elements of a new entity set, which can then
  participate in further relations of its own." Reachable from a
  relation's right-click menu ("Reify into entity set"); `canvas-view.gjs`'s
  `reifyRelation` action also adds the new entity set to the active view
  (sized to contain the relation) and sets `view.nestedUnder` so it's
  displayed nested there immediately, not just related in the model.

**Known gaps, tracked as future work, not bugs**: no swimlanes, no
recursion elements, no standard-construct stencils
(sequence/case/loop/concurrency) for Petri nets; no role labels or n-ary
relations beyond what a generic arc already allows, for ER diagrams; no
SVG export (PNG export applies to every diagram type -- see "Export"
below); no validation extension (`FmcModel.validate` still only checks
block-diagram Access-arity laws). All explicitly out of scope for this
pass.

## Export (`canvas-view.gjs`: `exportPng`, `contentBounds`)

An "Export PNG" button overlays the canvas (`.canvas-export-toolbar`,
top-right, inside a new `.canvas-view-wrapper` -- needed because the
`.canvas-view` div itself is Konva's own stage container, and Konva
takes it over on creation, so a sibling overlay button can't live inside
it without risking being clobbered). Works for every diagram type, since
it operates on the Konva stage directly, not anything diagram-specific.

Exporting "the whole diagram" needs its own definition, since the canvas
is an infinite pannable surface with no fixed extent: `contentBounds(view)`
takes the bounding box over every box in `computeEffectiveBoxes(model,
view)` (post-nesting-fit), which is what "the diagram" actually means
here. `exportPng` then:
1. Records the stage's current position/size (to restore after).
2. Clears the `Transformer`'s selected nodes (hides resize handles for
   the export) -- restored via the existing `attachTransformer()`.
3. Repositions/resizes the stage to exactly fit `contentBounds` plus a
   margin -- this is what makes the export cover the full diagram
   regardless of what's currently scrolled into view, not just whatever
   the viewport happens to show.
4. Adds a temporary white `Konva.Rect` behind everything (the stage
   itself has no background of its own -- shapes render on
   transparency), since a transparent-background PNG isn't a usable
   deliverable.
5. Calls `stage.toDataURL({ pixelRatio: 2, mimeType: 'image/png' })`.
6. Destroys the background rect, restores the original stage position/
   size and the transformer's selection, and triggers a download via a
   throwaway `<a>` element.

All of steps 1-6 run synchronously in one call stack -- `toDataURL` never
yields -- so the temporary resize/background never actually paints to
the screen; there's no visible flash despite resizing the live stage.

**SVG export** reuses the same fit-to-content setup
(`withExportStage`), then swaps the shape layer's native 2D context for
an `svgcanvas` recording context and calls `drawScene()` once at pixel
ratio 1 -- Konva has no vector export of its own, and this keeps every
shape (custom edge `sceneFunc`s included) on a single draw path instead
of a second hand-written serializer. (`canvas2svg` was tried first but
lacks `setLineDash`, which dashed locations need.)

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
