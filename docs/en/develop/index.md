# Develop

For people changing the code: how the modules are wired, how the test pyramid runs, and what performance claims are allowed to look like.

Contributor workflow (branch model, commit format, CLA, PR checklist) lives in [CONTRIBUTING.md](https://github.com/guangyiliushan/mortarmq/blob/main/CONTRIBUTING.md) at the repository root, because GitHub renders it in the pull-request sidebar.

## In this chapter

| Page | What it gives you |
|---|---|
| [Testing](./testing.md) | The pyramid — unit, golden, property, simulation, model checking, upgrade matrix — plus the reproduction discipline |
| [Benchmarks](./benchmarks.md) | The benchmark matrix, the noise-control protocol, and the rules for drawing conclusions |

## Planned pages

- **Module boundaries and extension points** — how to add a new op, a new metric or a new config key without breaking the allowlists
- **Storage internals** — segment format, sparse index, checkpoint replay

## Related chapters

- Package layout and dependency rules: [Architecture](../concepts/architecture.md)
- The diagrams behind the design: [Diagram atlas](../concepts/diagrams/index.md)
