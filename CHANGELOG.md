## 0.3.0

Three-phase upgrade aligning the package with the published Δ-state
CRDT theory and closing the headline gap with comparable Dart
libraries (collaborative text editing).

### Added

#### Delta extraction & Mutator

- `Crdt<Self>` gains two members on top of `join`:
  - `empty` — identity element of the join-semilattice.
  - `deltaCompose` — combines two locally-produced Δ-state
    fragments from the same replica before shipping. Defaults
    to `join` for most types; `PnCounter` overrides to sum
    per-replica halves instead of taking max.
- Per-type Δ-state delta producers: `GSet.deltaAdd`,
  `MvRegister.deltaSet`, `LwwRegister.deltaSet`, `OrSet.deltaAdd`
  / `deltaRemoveOf`, `PnCounter.deltaIncrement` /
  `deltaDecrement`, `CrdtMap.deltaPut`.
- `Mutator<C>` — per-replica delta accumulator. `applyLocal`
  joins into the live state AND `deltaCompose`s into the
  pending delta; `applyRemote` joins into state only.
  `flushDelta` returns and resets the accumulator.

#### Tombstone GC

- `Pruneable<Self>` interface with a single method
  `prune(DotSet stable)`. The caller supplies the dot-set every
  replica is known to have observed; pruning drops those dots
  from the context except where they are still referenced by a
  live entry. Documented protocol patterns for computing
  `stable` (epoch round, all-have-acked watermark,
  server-mediated cursor) live in the type's doc comment.
- `OrSet` and `Sequence` both implement `Pruneable`.

#### Sequence CRDT (Fugue, Δ-state)

- `Sequence<T>` — ordered Δ-state CRDT, the first Dart Fugue
  implementation we are aware of. Derived from Weidner, Gentle,
  Kleppmann, *Fugue: A Basis for Elegant CRDTs* (PaPoC 2023)
  via Almeida 2018's op-based → state-based transformation.
  Position tree of `SeqEntry<T>` keyed by `Hlc` dots; in-order
  DFS read; Fugue insert rule; tombstone OR-merge on `join`.
  Public API: `insertAt` / `removeAt` (full-state) and
  `deltaInsertAt` / `deltaRemoveAt` (Δ-state delta producers).
- `SequenceCodec<T>` — JSON codec for `Sequence`.

#### DotSet (explicit causal context)

- New public type `DotSet` — `Set<Hlc>` with explicit membership,
  union, dominance, `pack` / `unpack`. Now the causal-context
  representation used by `OrSet` and `Sequence`.

### Changed

- `OrSet`'s causal context migrated from the watermark
  `CausalContext` (`Map<NodeId, max(Hlc)>`) to the explicit
  `DotSet` (`Set<Hlc>`). Reason: the watermark form collapsed
  two sibling dots from the same node into `max(h1, h2)`, which
  caused legitimate concurrent same-node adds to be
  erroneously dropped during in-replica delta composition. The
  explicit dot-set is the canonical Almeida 2018 §3.4
  representation; with it, `deltaCompose` coincides with `join`
  and Mutator-based delta-shipping for `OrSet` is now correct.
- `MvRegister` keeps `CausalContext` — for the writer-context
  watermark semantics on each `TaggedValue`, that is the right
  representation.
- `OrSet.causalContext` getter renamed to `OrSet.context` and
  returns a `DotSet`. The wire format on `OrSetCodec` changes
  accordingly (semicolon-separated packed HLCs instead of the
  watermark `nodeA=hlcA;...` form).
- `OrSet.fromDots` now takes a `DotSet` instead of a
  `CausalContext`.

### Memory trade-off

`OrSet`'s context now grows as O(unique dots ever observed)
instead of O(devices) — this is the price of mathematical
correctness for delta composition. `Pruneable.prune` exists
precisely to bound that growth once causal stability is
achieved.

### Tests

113 total in the package (up from 65), all green. New coverage
includes Δ-state delta producer round-trips, `Mutator`
end-to-end (Alice ships sequential same-node deltas, Bob
converges), `Pruneable.prune` invariants, full Sequence
semantics (insert / remove / concurrent edits / convergence /
add-wins / Mutator end-to-end / pruning with live-descendant
preservation), and codec round-trips for the new types.

## 0.2.0

### Added

- JSON codecs for every type, via a shared `Codec<T>` interface:
  `HlcCodec`, `CausalContextCodec`, `MvRegisterCodec<T>`,
  `LwwRegisterCodec<T>`, `GSetCodec<T>`, `OrSetCodec<T>`,
  `PnCounterCodec`, `CrdtMapCodec<K, V>`. Primitive payload codecs:
  `StringCodec`, `IntCodec`, `DoubleCodec`, `BoolCodec`,
  `JsonCodec<T>`. Format-versioned (`"v": 1`) and round-trips
  through `dart:convert`.
- New public type `Dot<T>` in `or_set.dart` — `(value, hlc)` pair,
  parallel to `TaggedValue<T>` in `MvRegister`. Lets callers and
  codecs reconstruct an `OrSet` from its raw dot store without
  juggling tuples or sentinel values.
- Minimal raw factories / accessors for codec implementations and
  state reconstruction: `OrSet.fromDots(Iterable<Dot<T>>, CausalContext)`
  / `dots`, `LwwRegister.fromInner` / `inner`,
  `PnCounter.fromRaw` / `state`, `CrdtMap.fromRaw`.

### Changed

- `OrSet<T>` rebuilt on the Δ-state dot-store formulation per Almeida
  et al. 2018, §3.4. State is now `(Set<(value, hlc)> dots,
  CausalContext context)`; tombstones are emergent — a removed dot
  is one covered by the context but absent from `dots`. The previous
  monotonically-growing `removed` set is gone. Public API
  (`add(value, dot)`, `remove(value)`, `join`) is unchanged; new
  `causalContext` accessor for introspection.
- `GSet` and `PnCounter` docstrings clarified as classical CvRDTs
  (Shapiro et al. 2011) that trivially admit Δ-state shipping —
  noted alongside the Δ-state formulation used by `MvRegister` /
  `LwwRegister` / `OrSet`.

## 0.1.0

Initial pre-stable release.

- `Crdt<Self extends Crdt<Self>>` — common semilattice interface.
- `Hlc` — Hybrid Logical Clock with bounded-skew `receive`.
- `CausalContext` — vector clock over `Hlc`.
- `MvRegister<T>` — Δ-state multi-value register with embedded
  per-`TaggedValue` causal contexts; pure 2-argument `join`.
- `LwwRegister<T>` — single-value register, winner by total `Hlc`
  order.
- `GSet<T>` — grow-only set.
- `OrSet<T>` — observed-remove set with add-wins semantics.
- `PnCounter` — positive/negative counter, per-replica G-Counters.
- `CrdtMap<K, V extends Crdt<V>>` — per-key join over nested CRDTs.

49 tests covering convergence, commutativity, idempotency, and
nested composition.
