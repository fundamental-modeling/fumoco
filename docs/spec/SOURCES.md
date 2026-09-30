# Spec sources — shortlist from `ext/www.fmc-modeling.org`

`ext/` is a full recursive mirror of fmc-modeling.org (~78MB: HTML pages,
PDFs, images, mailing-list archives, book excerpts). This is the shortlist
of files actually screened and used as background reading for `spec/index.html`.
Everything in `spec/` is our own original writeup, in our own words and
structure — it summarizes and paraphrases these sources, it does not copy
their text, tables, or figures. Cite this document, not the mirror, when
asking "why does the spec say X."

## Primary sources (screened in full, HTML text extracted via pandoc)

- `notation_reference.html` (+ PDF twin at
  `download/notation_reference/FMC-Notation_Reference.pdf`) — the core
  normative content: per-diagram-type basic elements, common structures,
  and advanced constructs for block diagrams, Petri nets, and ER diagrams.
  This is the single most load-bearing source for `spec/index.html`'s
  normative sections.
- `metamodel.html` (+ PDF twins `FMC-Metamodel.pdf` and
  `FMC-Metamodel_Explained.pdf`) — the underlying entity/relation model
  behind all three diagram types: compositional structure (agents,
  locations, channels vs. storages), value range structure (values,
  structured vs. unstructured), dynamic structure (operations, access
  kinds, events, causal ordering), and how the three diagram types each
  project a different slice of this one model. Source for the spec's
  Terminology & Conformance section.
- `visualization_guidelines.html` (+ PDF twin
  `download/visualization_guidelines/FMC-VisualizationGuidelines.pdf`) —
  general diagram-layout guidance (edge routing, node arrangement,
  labeling, color use, diagram size) plus FMC-specific guidance per
  diagram type and a set of named standard layouts (block diagram
  standard arrangement, client-server pattern, Petri net sequence/case/
  loop/concurrency constructs). Source for both the spec's informative
  Visualization Guidance appendix and the new Lastenheft entries below.

## Secondary sources (skimmed for gaps/cross-checks)

- `quick-intro.html` — a single worked example (travel agency) across all
  three diagram types; useful as a sanity check that the spec's normative
  rules actually produce a consistent example, not used as a primary
  source of rules.
- `glossary.html` — single-term definitions (structure variance,
  reification, orthogonal partitioning, environment, ...); used to
  cross-check terminology already covered by `notation_reference.html`
  and `metamodel.html` rather than as an independent source.
- `fmc_stencils.html`, `fmc-and-uml.html`, `fmc-and-tam.html` — tool/
  ecosystem pages, not notation content; screened and set aside, not used.
- `download/notation_reference/Reference_Sheet-*.pdf` (Block Diagram, ER
  Diagram, Petri Net ×2) — single-page visual cheat sheets; same content
  as `notation_reference.html` in denser form, kept as a cross-check, not
  read separately since the HTML version is already the fuller text.

## Explicitly not used

Everything else in `ext/` (research papers, the two full book excerpts in
`fmcbook/`, `redbook/`, `peterbook/`, `sapbook/`, the mailing-list
archive, project pages, consortium/company pages, `images/*` themselves).
These are either not notation-defining, too large relative to their
marginal contribution, or reproduce book-length copyrighted text that
has no place being mirrored into our own spec anyway.
