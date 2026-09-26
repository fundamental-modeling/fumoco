# Lastenheft — Fumoco

The requirements, as user stories, in the user's own terms — this file is
the *what/why*, drawn directly from requests made in conversation. It
carries no build status; that belongs in `implementation_plan.md`, which
tracks each of these through done/in-progress/planned/open-question.
`PFLICHTENHEFT.md` is the *how* for whatever's been built.

Update this file when a genuinely new requirement is raised, phrased as a
user story close to what was actually asked. Don't add status markers or
implementation notes here — that's the other two documents' job.

## Vision & scope

- As a modeler, I want a visual, browser-based editor for FMC diagrams —
  block diagrams first, then Petri nets, then ER/value-range diagrams —
  with manual box placement rather than an auto-layout solver, in the
  spirit of Archi for ArchiMate.
- As a modeler, I want the model to be JSON-native, not built around the
  old text DSL — I don't need `.fmc` export.
- As a modeler, I want to be able to export a finished diagram as PNG and
  as SVG.
- As a modeler, I want the app usable standalone in a browser, and later
  also embeddable as a VS Code extension, with no backend required
  either way.
- As a modeler, I want the app named Fumoco.

## Model tree, palette, properties (overall layout)

- As a modeler, I want the app laid out like Archi: a model tree on the
  left, a palette of element/connector creation tools on the right, and a
  properties panel along the bottom for editing whatever's selected.
- As a modeler, I want the model tree to list every element and every
  view, so I can navigate a model bigger than one screen.

## Placing and editing elements

- As a modeler, I want to drag elements onto a view's canvas and
  reposition them freely.
- As a modeler, I want to resize a box by dragging its handles.
- As a modeler, I want boxes to snap to a grid and align automatically
  (with visual guides) against nearby boxes while dragging.
- As a modeler, I want to rename an element or a view in place — from the
  tree, or directly on the canvas by double-clicking/double-tapping it —
  without a separate dialog taking over the screen. (Double-tap needs to
  actually be reliable, including on a trackpad's tap-to-click.)
- As a modeler, I want a clearly visible indicator (not just resize
  handles) that a box is selected, for one box and for a multi-selection
  alike.
- As a modeler, I want to remove an element from just the current view
  without deleting it from the model/tree, and separately, a way to
  delete it from the model entirely.
- As a modeler, I want a scrollable/pannable canvas viewport — a diagram
  bigger than the visible area needs to actually be reachable.

## Selecting and arranging multiple elements

- As a modeler, I want to multi-select boxes via shift-click, cmd/ctrl-
  click, and by dragging a selection rectangle over them.
- As a modeler, I want to make selected boxes the same width/height/both,
  matching whichever one I selected last.
- As a modeler, I want to align a selection (left/center/right, top/
  middle/bottom) and distribute it evenly (horizontally/vertically).

## Connectors

- As a modeler, I want to draw access edges (read/write/modify) and
  channels (directed/bidirectional/req-res, long or shorthand form)
  between elements by picking a tool and clicking source then target.
- As a modeler, I want the tool to show me which elements are valid picks
  for the connector I've armed, rather than letting me guess and hit an
  error.
- As a modeler, I want connectors routed as horizontal/vertical lines
  with rounded corners at the bends, not straight diagonal lines.
- As a modeler, I want an edge to keep following a box after I move it,
  without needing to manually refresh anything.
- As a modeler, for now, I only want connectors to appear for elements
  I've actually added to a view — not implicitly for everything related.
- As a modeler, I want to freely reposition a channel's place (the small
  circle) instead of it always sitting at the auto-computed midpoint of
  the line.
- As a modeler, I want a channel's place to actually be a location
  element in its own right, not a separate kind of thing — "channel" is a
  rendering option a location can have, and it connects to its agents via
  ordinary read/write/modify access edges.
- As a modeler, I want to be able to delete a connector, not just an
  element.

## Nesting / containment

- As a modeler, I want to nest locations and actors inside each other as
  a many-to-many relationship — not a strict tree, since the same element
  can genuinely belong inside more than one container at once.
- As a modeler, I want a way to actually establish that nesting from the
  UI (not just see it once it somehow exists).
- As a modeler, I want a container to visually show its nested content on
  the canvas, not just in the tree.
- As a modeler, I want to drag a container and have its nested content
  move with it — a container that can't be moved is a regression, not a
  feature.
- As a modeler, I want to be able to drag a nested box out of its
  container.
- As a modeler, I want to distinguish two different things: containment
  is a fact of the model (the world), shared by every view; whether an
  element is *displayed* nested inside its parent is a separate,
  per-view choice that depends on the model fact but doesn't have to
  match it everywhere. Dragging a box into another establishes the
  nesting relationship in both the model and the current view's display.
  Dragging it back out only changes this view's display — the model
  relationship (and its appearance in every other view) stays intact.
- As a modeler, I want the same element to be able to appear more than
  once across (or within) views, and to be able to remove/hide a specific
  edge's rendering near one particular occurrence without deleting the
  edge from the model.

## Beyond block diagrams

- As a modeler, I want a formal, W3C-ReSpec-based specification of FMC's
  notation — grounded in what the block-diagram editor actually
  implements — with the Petri net and ER/value-range sections drafted
  normatively before those diagram types are built, so there's something
  to implement against.
- As a modeler, I want to create Petri net places, transitions, and arcs,
  laid out manually just like block diagrams, with the place/transition
  bipartite rule enforced the same way agent/storage is today.
- As a modeler, I want to create ER entity sets and (possibly n-ary)
  relations, with arcs carrying role/cardinality labels.
- As a modeler, I want to open a Fumoco model file directly in VS Code
  and get the same editing experience as the standalone app.

## Process

- As the person paying for this, I want changes committed regularly, not
  batched up across many features at once.
- As the person paying for this, I want a Lastenheft (this file, in user-
  story form) and a Pflichtenheft (the technical how) maintained
  alongside the actual work, not written up after the fact.
