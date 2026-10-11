# Gap triage: which proposed cases await tests and which await code

The edge-coverage report closed with five proposed cases (G1-G5) for the
six model edges that carry no code-level test. This note triages each
one: is the rule already implemented and only missing its case, or does
the implementation itself stand behind a face that does not exist yet.
The layer each rule belongs to is decided here as well, since one of
the proposed placements (a decode guard for G2) turns out to be the
wrong layer once the registry classes are read side by side.

Rule sources: the wire tables' field-semantics notes (items 1, 4, 5, 7)
and the registered code table in `openspec/specs/protocol/tables.md`,
cited below by note number; the requirement scenarios in
`openspec/specs/protocol/spec.md`; the decision records those notes
name.

## Verdicts

### G1 -- SUB admission (model edges E10, E11)

- Rules: field-semantics note 5 (a SUB never implicitly DECLAREs; a
  missing topic answers 0x0008 UNKNOWN_TOPIC; the partition field is
  fixed at 0xFFFF in v0) plus the actionable-text anchor in the code
  table ("DECLARE first or fix the name").
- Implemented today: the wire shape only -- the codec pins the 0xFFFF
  partition, the credit fields decode, and the routing face of 0x0008
  has its own path (a route request on an undeclared topic).
- Not implemented: the admission decision itself -- no face accepts a
  SUB, checks the declared set, subscribes on presence, or answers
  0x0008 on absence.
- Verdict: **true gap (implementation missing)**. The proposed case
  lands with whoever builds the SUB admission face (the consumer and
  coordinator domain; the coordinator assigns ownership).

### G2 -- malformed producer combination (E13, E16)

- Rules: field-semantics note 1 (producer id zero with a positive
  sequence is refused with 0x0013 PRODUCER_SEQ_INVALID; the
  zero/zero pair is allowed as non-idempotent production).
- Layer decision: **not the decode guard**. The code table classes the
  two outcomes apart: MALFORMED_PAYLOAD is "close the connection",
  PRODUCER_SEQ_INVALID is "no close; fix the client". A decode-layer
  guard would answer a fatal malformed verdict where the registry
  demands a non-fatal, actionable ERR -- the codec stays shape-only
  (the decode entry keeps its own note that semantic checks live in
  later subsystems). The rule lands on the publish admission face as
  an ERR response, the shape the state machine model gives it.
- Not implemented: no admission face reads the producer fields
  together; 0x0013 is registry-pinned only. The decode-guard
  placement offered during the coverage report is withdrawn on this
  evidence.
- Verdict: **true gap (implementation missing)**, on the publish
  admission face (the producer-semantics domain; the coordinator
  assigns ownership).

### G3 -- producer idempotent window (E14, E15)

- Rules: field-semantics note 1 continued -- sequences deduplicate in
  a window keyed by (topic_id, partition, producer_id), and the PUB
  success result carries its deduplicated flag; the neighbouring
  codes 0x0010-0x0012 cover the wider sequence family.
- Implemented today: the fields travel (codec round-trips, the
  dead-letter envelope carries producer identity onward) and the
  delivery ledger has its own exactly-once cases -- that is a
  different mechanism and does not cover this window rule.
- Not implemented: the window itself -- no accept/deduplicate decision
  exists behind a publish path.
- Verdict: **true gap (implementation missing)**, same face as G2.

### G4 -- notice acknowledgement idempotence (E20)

- Rules: field-semantics note 4 (every NOTICE carries a notice id; the
  CONTROL_ACK echoes it back unchanged, so out-of-order confirmations
  stay attributable) and the ack result codes in the op table.
- Implemented today (awaiting tests where noted): notice generation
  with monotone ids lives in the group coordinator, and its tests
  exercise join and leave sequences that replay the same assignment --
  the generation half of the edge family is real code.
- Not implemented: the ack face -- nothing consumes a CONTROL_ACK,
  checks the echoed id, applies the result code, or makes a second ack
  a no-op.
- Verdict: **split** -- the generation half is implemented and its
  coverage is the coordinator's replay cases; the ack-idempotence
  half is a **true gap (implementation missing)** on the notice
  processing face (the consumer and coordinator domain).

### G5 -- orderly close (E21)

- Rules: the connection lifecycle rule the model checks as
  no-frame-after-close: once closed, the connection serves nothing
  more. (The fatal and timeout closes are separate edges and are
  tested.)
- Implemented today: the transport primitive (`close` on the
  connection trait, documented never to fail) and the establishment
  story (a stream that ends before CONNECT is an unfinished
  establishment; wire errors close).
- Not implemented as a tested face: the post-established serving loop
  that stops serving after an orderly close -- no case drives
  established traffic, closes, and asserts silence afterwards.
- Verdict: **true gap (implementation missing)** at the connection
  serving loop (the coordinator assigns ownership; it is the face
  that wires frames to handlers).

## The two piles

| Proposed case | Await tests (implemented) | Await code (true gap) |
| --- | --- | --- |
| G1 SUB admission | | the admission decision (wire shape is done) |
| G2 producer combination | | the admission ERR path (decode guard withdrawn) |
| G3 producer window | | the window accept/deduplicate path |
| G4 notice ack idempotence | generation half (ids, replay cases) | the CONTROL_ACK processing half |
| G5 orderly close | transport close primitive, establishment story | the post-established serving loop case |

## Cross-domain dispatch list

None of the five landing spots sits in the codec domain; each needs
its own face first and its case with it:

- G1 and G4 (ack half): consumer and coordinator domain -- the SUB
  admission and notice-ack faces.
- G2 and G3: producer semantics domain -- the publish admission face
  and its window.
- G5: the connection serving loop, whoever wires frames to handlers.

Until each face lands, the corresponding rule stays visible in the
edge-coverage report rather than claimed by a test.
