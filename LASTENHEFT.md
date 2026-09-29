# Lastenheft — Fumoco

The requirements, as user stories, in the user's own terms — this file is
the *what/why*, drawn directly from requests made in conversation. It
carries no build status; that belongs in `implementation_plan.org`, which
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
- As a modeler, I want each row's rename/delete buttons on the same line
  as its title, at the right-hand edge — not wrapped onto their own line
  wasting vertical space.
- As a modeler, I want the canvas to render text in Barlow (with its
  narrow variants configurable), matching the FMC diagrams I'm used to.
- As a modeler, I want a diagram (view) to carry a title, a creation
  date, a last-updated date, an author, and contributor fields.
- As a modeler, I want a container's label to never render smaller than
  its children's labels — this was a real complaint about the old Python
  auto-layouter too, not a new one.
- As a modeler, I want the model tree's Views section listed above
  Elements, since switching views is the thing I do most often and I
  shouldn't have to scroll past the element list to get to it.

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
  bigger than the visible area needs to actually be reachable, with
  actual visible scrollbars, not just wheel/trackpad panning.
- As a modeler, I want guide lines I can drag in from the left or top
  edge of the canvas (no tick-mark ruler needed), that other boxes then
  snap to, and that I can drag back out to remove.
- As a modeler, I want zoom in / zoom out buttons and a one-click return
  to 100%.
- As a modeler, I want box size to only ever change by selecting the box
  and dragging one of its 8 resize handles — not by any other gesture.
- As a modeler, I don't need rotation at all — boxes should stay
  axis-aligned. The rotation handle currently shown on a selected plain
  box doesn't actually do anything useful (rotation isn't persisted), so
  it should just be removed rather than made to work. (Polish item, not
  urgent.)
- As a modeler, I want selecting a container (a box showing nested
  content) to show the same 8 resize handles a plain box gets, so I can
  resize it directly too.
- As a modeler, when I drag a nested box out of its parent, I want it to
  actually end up placed outside the parent's box, not just technically
  un-nested while still overlapping it visually — it only leaves the
  parent once it's fully clear of it.
- As a modeler, I want clicking the empty canvas background (not any
  box) to show that view's own properties in the properties panel.

## Selecting and arranging multiple elements

- As a modeler, I want to multi-select boxes via shift-click, cmd/ctrl-
  click, and by dragging a selection rectangle over them.
- As a modeler, I want to select everything in a drawing with Cmd-A on a
  Mac (Ctrl-A on other keyboards), and cut/copy/paste the same way —
  Cmd/Ctrl-X/C/V — acting on the whole selection.
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
- As a modeler, I want to select an arrow and, in its properties, switch
  its access kind between read/write/modify.
- As a modeler, I want to manipulate an arrow's routing by adding and
  moving waypoints, while it stays strictly horizontal/vertical
  (rectangular) in nature — no free-angle segments.
- As a modeler, I want the properties panel to show the arrows/connections
  to and from a selected box, not just its own label/flags.
- As a modeler, I want arrows to be entities tracked in the world model,
  also visible in the left (tree) panel — not just implicit lines drawn
  between two elements.
- As a modeler, I want a read/write (modify) arrow drawable in two
  variants: a straight `<->` line, or two arrows `<-` `->` curved into a
  lens — the latter where the two boxes face each other (overlapping
  parallel sides), and the default.
- As a modeler, I don't want read + write between the same agent and
  location tracked differently from modify — modify *is* read + write, so
  adding the other direction to an existing arrow turns it into modify.

## Nesting / containment

- As a modeler, I want to nest locations and actors inside each other as
  a many-to-many relationship — not a strict tree, since the same element
  can genuinely belong inside more than one container at once.
- As a modeler, I want a way to actually establish that nesting from the
  UI (not just see it once it somehow exists) — primarily by dragging one
  box into another, on the canvas.
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

## Visualization guidance (derived from screening the FMC Visualization Guidelines and Metamodel pages, 2026-09-27)

- As a modeler, I want edges converging on the same box to merge into a
  shared trunk near that box ("edge trees") instead of drawing every leg
  separately all the way to the box, so a box with many connections stays
  legible — opt-in per box side, never automatic.
- As a modeler, I want new boxes of the same element type to default to a
  consistent size, so two boxes don't end up looking more or less
  important than each other purely because one has a longer label — and
  a way to reset a box back to that size.
- As a modeler, I want a node's line weight to read as visibly heavier
  than an edge's, so boxes and connectors stay easy to tell apart even in
  a dense diagram.
- As a modeler, I want a way to represent "N similar boxes" as one
  exemplar drawn as a stack of boxes, instead of being forced to draw
  every instance when the exact count doesn't matter.
- As a modeler, I want a grouping/structuring box's fill to stay plain
  white by default, the same as any other box, and only turn muted/
  colored (from a small muted palette) when I explicitly set that myself
  — not automatically just because it happens to be a container.
- As a modeler, I want a soft nudge (not a hard limit) when a diagram
  grows past what fits a PowerPoint slide in landscape (a bit less high,
  leaving room for the diagram title), so I notice before a diagram has
  become unreadably large rather than after.

## Model validation

- As a modeler, I want a "validate model" action that checks conditions
  the editor can't (and shouldn't) enforce live while I'm still editing —
  e.g. a channel needing at least two accessing agents, a storage needing
  at least one — and lists what it finds, rather than either silently
  allowing an incomplete diagram forever or blocking me mid-edit for
  something that's only wrong if I leave it that way.

## Context menu / copy-paste

- As a modeler, I want a right-click context menu on the canvas, so
  actions like delete/copy/cut/paste don't require memorizing keyboard
  shortcuts or hunting through the properties panel.
- As a modeler, right-clicking a box should offer rename, cut, copy,
  paste, delete-from-view, and delete-from-model — the same actions
  already available elsewhere, just reachable at the point I'm looking at.
- As a modeler, right-clicking an arrow should offer inserting a waypoint
  right at that point and deleting the connector.
- As a modeler, right-clicking a waypoint on an arrow should offer
  removing just that point — a menu-driven alternative to double-clicking
  it, since deleting a routing point is exactly the kind of action that
  belongs on a context menu.
- As a modeler, right-clicking empty canvas should offer pasting,
  whenever I've copied or cut something.

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
- As a modeler, I want to draw an ER independent (orthogonal) partitioning
  of an entity set into subsets as a triangle: the partitioned (parent)
  entity set connects to the triangle's tip, and each subset connects to
  its base — distinct from the "subset" approach of nesting one entity
  set inside another.
- As a modeler, I want the lines between a relation and its entity sets
  to be undirected (not arrows); the relation box itself carries a small
  arrow pointing toward the "1" side — `->`, `<-`, or `<->` for 1:1 —
  with the arrow's line as fine as the connecting lines and nearly
  triangular tips with a slight concave dent. The cardinality is a
  property I add to a relation.
- As a modeler, I want a relation unnamed by default, and an empty
  relation about 1em high and 3em wide.
- As a modeler, I want a relation to turn 90 degrees when its entity sets
  are stacked vertically (automatically, for now).
- As a modeler, I want the circle around a reified relation to be about
  6em in diameter, growing with the relation box.
- As a modeler, I want to reify a relation into an entity set by nesting
  the relation inside it, so the reified entity set can then participate
  in further relations of its own.
- As a modeler, Petri net arcs must never look bidirectional; the
  standard flow is top-to-bottom (leaving south, arriving north), except
  for loop-back arcs to a place/transition that's beside rather than
  above/below, which should leave/arrive diagonally instead of looping
  all the way around — and a diagonal arc should actually leave from a
  place's circle, not the corner of its invisible bounding box.
- As a modeler, I want to mark a place as the net's starting place, shown
  with a small filled black circle concentric with the place, with a
  visible white gap to the place's own outline.
- As a modeler, I want a NOP (no-operation) transition -- a wide, thin,
  unlabeled bar for routing/synchronization with no real action -- and I
  don't want a new place named by default, since it's usually just an
  unnamed marking-holder.
- As a modeler, I want to open a Fumoco model file directly in VS Code
  and get the same editing experience as the standalone app.

## Export

- As a modeler, I want to export a view as PNG and as SVG.
- As a modeler, I want exports on a white background, never transparent.
- As a modeler, I want every export to carry a header with the view's
  title, author(s), created date and last-modified date (dates only, no
  time), plus "Fumoco" and its version.

## About

- As a modeler, I want a small footer in the right-hand pane showing
  "Fumoco" and its version.

## Out of scope

Dropped on 2026-09-29, kept here so they aren't re-raised by accident:

- A one-click "standard block-diagram arrangement" starting layout —
  manual layout is the premise.
- Reusable Petri-net layout stencils (sequence, case, loop, concurrency) —
  copy/paste covers it.
- Importing diagrams from the old text DSL (`examples/*.fmc`).

## Process

- As the person paying for this, I want changes committed regularly, not
  batched up across many features at once.
- As the person paying for this, I want a Lastenheft (this file, in user-
  story form) and a Pflichtenheft (the technical how) maintained
  alongside the actual work, not written up after the fact.
- As the person paying for this, I want the implementation plan kept in
  Org mode, using Org's own TODO-state keywords, not a Markdown checklist.
- As the person paying for this, I want semantic-release style version
  numbers (from 0.1.0), derived from conventional commits.
- As the person paying for this, I want the repository presentable for
  publication on GitHub.
