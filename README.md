# Fumoco

A visual, browser-based editor for [FMC](https://www.fmc-modeling.org/)
(Fundamental Modeling Concepts) diagrams: block diagrams, Petri nets, and
ER/value-range diagrams, with manual box placement (no auto-layout solver)
plus alignment/snapping tooling, in the spirit of Archi for ArchiMate.

The editor itself lives in `fumoco/` (Ember app) once scaffolded, with a VS
Code extension wrapper planned as a later milestone.

## `attic/`

An earlier approach: a Python text-DSL + SVG renderer with a constraint
solver (OR-Tools CP-SAT) for automatic box layout. Superseded by Fumoco's
manual-layout editor, but kept around, working and tested (`cd attic && uv
run pytest`) rather than deleted. See `attic/README.md` for its own usage.
