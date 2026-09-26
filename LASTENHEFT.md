# Lastenheft — Fumoco

Requirements as user stories, from the perspective of someone modeling FMC
diagrams. Status is tracked per story: `done`, `in progress`, `planned`
(agreed but not started), or `open question` (needs a decision before it
can be planned). This file is the *what/why*; `PFLICHTENHEFT.md` is the
*how* (technical approach, architecture decisions).

Update this file whenever a new requirement comes up in conversation or an
existing one changes status — it should always reflect the current
backlog, not a historical log (git history is the log).

## Milestone A — Block diagrams (standalone editor)

- [done] As a modeler, I want a model tree listing all agents/human
  agents/storages and all views, so I can navigate a model that's larger
  than one screen.
- [done] As a modeler, I want to create agents, human agents, and storage
  elements from the tree.
- [done] As a modeler, I want to create and switch between multiple views
  ("viewpoints") over the same model.
- [done] As a modeler, I want to drag elements onto a view's canvas and
  reposition them freely (no auto-layout).
- [done] As a modeler, I want to resize a box by dragging its corner/edge
  handles.
- [done] As a modeler, I want boxes to snap to a grid and to align
  automatically (with visual guides) against nearby boxes' edges/centers
  while dragging.
- [done] As a modeler, I want to select multiple boxes (shift-click,
  cmd/ctrl-click, or drag a rectangle over them) and see clearly which
  ones are selected.
- [done] As a modeler, I want to make selected boxes the same width/
  height/both, matching the last one I selected.
- [done] As a modeler, I want to align a selection (left/center/right,
  top/middle/bottom) and distribute it evenly (horizontally/vertically).
- [done] As a modeler, I want to rename an element or a view in place
  (from the tree, or directly on the canvas), without a separate dialog
  taking over the screen.
- [done] As a modeler, I want to draw access edges (read/write/modify)
  and channels (directed/bidirectional/req-res, long or shorthand form)
  between elements by picking a tool and clicking source then target.
- [done] As a modeler, I want the tool to show me which elements are valid
  picks for the connector I've armed (e.g. only agents as the source of a
  read access), so I don't have to guess or get a cryptic error.
- [done] As a modeler, I want edges to be routed as horizontal/vertical
  lines with rounded corners, not diagonal straight lines.
- [in progress] As a modeler, I want edges to automatically follow a box
  when I move it, without a manual "refresh" step.
- [planned] As a modeler, I want to save my model to a file and reopen it
  later, and have work-in-progress survive an accidental reload.
- [planned] As a modeler, I want to export a view as PNG and as SVG.
- [planned] As a modeler, I want to delete an edge (not just an element),
  e.g. by selecting it on the canvas.
- [open question] As a modeler, I want the same element to appear more
  than once in one view (e.g. to reduce line crossings), and I want to be
  able to hide/remove a specific edge's rendering near one occurrence
  without deleting the edge from the model. Needs a decision: should an
  edge, by default, draw to *every* occurrence of an element that's in the
  view (with a way to suppress it per-occurrence), or should creating a
  connector require picking *which* occurrence it attaches to? (Raised
  2026, not yet resolved.)

## Milestone A.5 — Formal FMC specification

- [planned] As a spec reader, I want a formal, W3C-ReSpec-based
  specification of FMC's block diagram notation (terminology, bipartite
  rules, channel notation), grounded in what Milestone A actually
  implements.
- [planned] As a spec reader, I want the Petri net and ER/value-range
  diagram sections drafted normatively *before* Milestones B/C implement
  them, so implementation has something to conform to.

## Milestone B — Petri nets

- [planned] As a modeler, I want to create places, transitions, and arcs,
  and lay them out manually just like block diagrams.
- [planned] As a modeler, I want the editor to enforce the place/
  transition bipartite rule the same way it enforces agent/storage today.

## Milestone C — ER / value-range diagrams

- [planned] As a modeler, I want to create entity sets and (possibly
  n-ary) relations, with arcs carrying role/cardinality labels.

## Milestone D — VS Code extension

- [planned] As a modeler, I want to open a Fumoco model file directly in
  VS Code and get the same editing experience as the standalone app.
