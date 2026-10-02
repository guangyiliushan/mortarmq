# Diagram Atlas

Four pages, twelve mermaid diagrams, two ASCII timelines and eight prose tables — all views of the same system from different angles. Read them as a set, not as four separate documents.

Mermaid source is the artifact: edit the fenced block, never paste a screenshot. If a diagram and this table disagree, the diagram wins and the table is the bug.

::: warning Tables are content, not decoration
Eight of the tables below carry information that appears in **no** diagram: the Actor×Goal semantic baseline, every latency budget in the project, the CI-enforced module dependency rules, and the runtime snapshot's consistency assertions. A change that keeps the pictures but drops a table is a regression.
:::

## Behaviour

| Page | Diagrams | Answers |
|---|---|---|
| [Use cases and flows](./use-cases-and-flows.md) | 3 mermaid | Who does what (UC1–UC12) and which branch the broker takes — plus the Actor×Goal table that is the semantic source of truth |
| [Sequences](./sequences.md) | 3 mermaid | Frame-by-frame message order for publish→deliver, incremental rebalance, and lease-timeout election |

## States, timing and invariants

| Page | Diagrams | Answers |
|---|---|---|
| [States, timing and invariants](./states-timing-invariants.md) | 4 mermaid + 2 ASCII | Legal states and transitions (broker / client / delivery), the latency budgets every design must fit, and a runtime snapshot whose assertions must hold right now |

## Structure

| Page | Diagrams | Answers |
|---|---|---|
| [Structure](./structure.md) | 2 mermaid | Package-level decomposition and allowed dependency direction, then the types inside them |

## How the four pages relate

- **Use cases and flows** ↔ **Sequences** draw the *same* publish/consume link in two notations: flowchart for branch conditions and conservation, sequence for participant order. Neither is a subset of the other; each page states the other's scope in its header.
- **States, timing and invariants** holds the object snapshot rather than Structure because its payload is an invariant table (INV/CM/CB vocabulary), not a statement about type layout.
- **Structure** states dependency rules as CI-enforced import assertions; the class diagram is their type-level expression and defers to the rules table as authoritative.

## Note on diagram kinds

Mermaid has no native UML use-case, object or timing syntax, so those three are approximated with flowcharts, class-diagram instance notation and ASCII lane timelines. Where an approximation loses information, the page carries the semantic table that is the actual source of truth — read the prose, not only the picture.
