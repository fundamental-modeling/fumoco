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

## Open technical questions (mirrors Lastenheft's "open question" items)

- **Multiple occurrences of one element per view**: not yet designed.
  Current `View.included`/`boxes` assume one box per element id per view.
  Supporting duplicates means each placement needs its own instance id
  (distinct from the element id), and edges need a rule for which
  instance(s) they draw to. Not started until the Lastenheft item above
  is resolved with the user.

## Process note

Commit after each coherent chunk of work (a feature, a bug fix), not just
at phase boundaries — this was missed for a while during Milestone A's
Phase 2–6 work and should not repeat.
