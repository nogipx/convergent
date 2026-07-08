## 0.6.0

Correctness fixes from the 0.5.0 audit, plus removal of the legacy
`Sequence` list CRDT. Two **breaking** changes: `Sequence` is gone (use
`Fugue`), and `PnCounter` delta producers move from static to instance
methods.

### Removed

- **`Sequence<T>`, `SeqEntry`, `SeqOp`, and `SequenceCodec` are removed.**
  `Fugue` supersedes them on every axis (correct non-interleaving, O(log N)
  locate, position API, batched `applyOps`, ~2 vs ~618 bytes/char), and its
  only distinguishing trait — sharing the library's HLC causal context /
  `DotSet` pruning — is a convenience achievable with `Fugue` + an
  application-level `Hlc` stamp, not a requirement. Maintaining a second list
  CRDT (a proven bug source) had no offsetting real-world use case.
  Migration: use `Fugue<T>` from `package:convergent/fugue.dart`.

### Added

- **`Fugue.orphanBlockCount`** — a diagnostic getter counting blocks whose
  parent element is absent: either deltas delivered ahead of their parent
  (transient, heals on merge) or children of pruned blocks (permanent —
  indicates a violated prune barrier). Non-empty after a full sync means
  investigate. O(N), allocation-free, uncached.

### Changed (breaking)

- **`PnCounter.deltaIncrement` / `deltaDecrement` are now instance methods**
  and carry this replica's **post-mutation total** `(positive, negative)`,
  not the raw amount. A Δ-state delta must be a join-inflation of the
  post-mutation state; the old static `{node: (n, 0)}` fragment was not one.
  Because cross-replica `join` is per-entry max, two successive raw
  increments max-merged and silently dropped one
  (`empty.join(deltaIncrement(a,1)).join(deltaIncrement(a,1))` gave 1, not
  2), and since `Mutator.applyLocal` does `state.join(delta)`, the local
  replica diverged from peers that received the (correctly summed) flushed
  accumulator. `PnCounter.deltaCompose` now delegates to `join` — post-total
  fragments compose by max, so the previous sum-based override would
  double-count. Migration: replace `PnCounter.deltaIncrement(hlc, n)` with
  `counter.deltaIncrement(hlc, n)`, producing each delta against the counter
  state it applies to.

### Changed

- **Canonical encoding.** `Fugue.encode` and `Fugue.rawBlocks` (hence
  `FugueTextBinaryCodec`) now emit blocks in start-dot order instead of
  map-iteration order. The decoded value is unchanged, but the same converged
  state serialises to byte-identical output on every replica — so a snapshot
  has a stable content hash, enabling dedup and O(1) "are we in sync?"
  handshakes. Cost is proportional to block count (coalesced runs keep it
  low), at encode only.

### Documentation

- **README Fugue property claim corrected.** "Non-interleaving (Theorem 1)"
  was miscited — Theorem 1 is the strong list specification. Now stated as
  strong list spec (Theorem 1) plus forward non-interleaving (§5). README
  front-matter version synced to `0.6.0` (was `0.3.x`).

- **`Fugue.prune` barrier requirement.** The doc now spells out the full
  caller invariant: because a tombstone still anchors positions and
  `rightOrigin` walks the tombstone-inclusive traversal, `stable` must also
  guarantee that every delta parented on the pruned blocks' tombstones has
  been delivered everywhere, and prune must be applied with the same
  `stable` set on all replicas. Violating it leaves permanently unreachable
  blocks (detectable via `orphanBlockCount`) and breaks convergence.

### Fixed

- **`LwwRegister` broke join idempotency / identity.** `join` collapsed
  concurrent survivors to the single winner (the 0.4.1 anti-bloat change) but
  `set` did not, so a state produced by two blind `set`s (non-dominating
  contexts) held ≥2 inner values while `join` reduced them to one — making it
  not a join fixpoint: `a.join(a) != a` and `a.join(empty) != a` (the
  observable `.value` stayed correct, but the advertised semilattice `==`
  laws were violated, affecting any `==`-based change detection). `set` now
  collapses too, so the register is single-valued on every path.

- **`MvRegister.join` non-associativity without a transitive-context
  invariant.** Dominance is judged per-value via each writer's embedded
  `CausalContext`. If a write superseded value `w` but its context did not
  transitively cover the values `w` itself superseded, join order could
  change the survivor set. `set` now folds the context (and hlc) of every
  value it supersedes into the stored context, making it transitively closed
  by construction. `deltaSet` cannot see superseded values — its caller
  invariant (the supplied context must already dominate all superseded
  values' contexts) is now documented on the method and in the README.

- **`Fugue` had no value `==` / `hashCode`.** It fell back to identity
  equality, so `Mutator<Fugue>.hasPendingDelta` (which tests the accumulator
  against `state.empty`, two distinct instances) was always `true` — any code
  gating sends on it shipped empty deltas forever — and `CrdtMap<K, Fugue>`
  compared by identity, inconsistent with every HLC-based type. Added
  structural equality over the Δ-state (blocks by start dot; placement, run
  values, and tombstone set), so `join` is value-idempotent and converged
  replicas compare equal.

- **`FugueTextBinaryCodec` element-count check.** The per-block element
  count was decoded and discarded. A block whose values were not all single
  Unicode scalars (e.g. a multi-rune emoji grapheme cluster) rune-split into
  a different length on decode, silently shifting every later element's dot.
  Decode now compares the recovered rune count to the stored count and
  throws `FormatException` on mismatch.

- **`Fugue.insert` duplicate-dot hardening.** A local insert with an
  already-used dot (a replica restarted without seeding its clock from
  `Fugue.dots`, or two devices sharing a replica id) overwrote a block while
  the stale block object stayed referenced from the children index —
  corrupted traversal, silent data loss. `_index` now asserts (checked mode)
  when a dot already indexes a block. The assert cannot fire on legitimate
  paths (merge only indexes behind a `mine == null` check; codecs build fresh
  instances). README documents the clock-seeding ritual for restart.

### Tests

- Fugue δ-fragment **delivery-order** property test: fragments delivered
  out of order, duplicated, and permuted must converge to the full-state
  join, with a deterministic child-before-parent case asserting the child
  is hidden (`orphanBlockCount > 0`) until its parent arrives.

## 0.5.0

New `Fugue` list CRDT — the optimised, academically-faithful implementation
of Fugue from *The Art of the Fugue: Minimizing Interleaving in Collaborative
Text Editing* (Weidner & Kleppmann, IEEE TPDS 2025) — plus correctness fixes
to `Sequence`.

### Added

- **`package:convergent/fugue.dart` — `Fugue<T>`**: a run-length ("waypoint")
  implementation of Fugue Algorithm 1. A contiguously-typed run is stored as a
  single block instead of one node per element (~2 bytes/char with the binary
  codec, vs ~618 for one-node-per-char), yet it is a faithful **state-based**
  CRDT — the paper's own reformulation of the algorithm. `join` is a validated
  join-semilattice (commutative / associative / idempotent), and behaviour is
  fuzzed against a literal Algorithm-1 oracle across 900+ concurrent
  merge scenarios and checked against the paper's worked examples
  (Figures 1, 4 and 6).
  - **Identity**: `Dot(counter, replica)` + `LamportClock` — a logical counter,
    not an HLC, which is what lets a run share consecutive counters and
    coalesce. `LamportClock.observe` gives edits causal dominance over observed
    content for free.
  - **Non-interleaving** (the paper's §5 forward property; Theorem 1 is the
    strong list specification): concurrent runs at the same position never
    interleave; guarded by a direct fuzz.
  - **Delta-state**: `applyOps(ops, clock)` applies a batch locally and returns
    a δ-fragment such that `base.join(δ)` reconstructs the state.
  - **Pruning**: `prune(Set<Dot> stable)` drops fully-tombstoned, causally
    stable, anchorless blocks (block-granular; iterative).
  - **Codecs**: `FugueCodec<T>(Codec<T>)` (JSON) and `FugueTextBinaryCodec`
    (compact bytes — replica-id interning + LEB128 varints + one packed UTF-8
    string per run; ~2 bytes/char, encode/decode ~2 ms for a 20k-char doc).
  - **Position API** (stable cursors): `positionAt` / `indexOf` / `valueAt` /
    `isLive` + `insertAfter(anchor)` / `deleteDot` operate on stable `Dot`
    positions that survive concurrent edits and the anchored element's own
    deletion — what an editor uses to pin cursors, selections and comments.

### Fixed

- **`Sequence` insert resolution.** The middle-insert rule used "does the left
  neighbour have any right child" as a proxy for Fugue's ancestor test. That
  misfired when the neighbour's right subtree was fully tombstoned, misplacing
  the insert — and, on the per-op path, interleaving concurrent runs — whenever
  the new dot sorted before that neighbour. Now decided by true ancestry (a
  bidirectional parent-chain walk); misprojection is eliminated across all id
  orderings, and the two mutation paths share one resolver.
- **`Sequence.prune` stack overflow.** The recursive live-descendant check
  overflowed the stack on a deep right-chain (a linearly-typed document past
  ~10k characters) — on the main-isolate GC path. Replaced with a single
  iterative post-order pass; also collapses the old O(N·depth) re-traversal to
  O(N).

### Changed

- `Sequence` is documented as **superseded by `Fugue`** for new code. It is
  retained for HLC-integrated use (shared causal context, `DotSet` pruning),
  since `Fugue` runs a separate logical (Lamport) clock.

## 0.4.1

`LwwRegister.join` now collapses to the single winning value instead of
carrying the underlying `MvRegister`'s concurrent survivors. For an LWW
register the winner (highest HLC) is the only meaningful result, so keeping
the losers was pure bloat: under node-id churn each writer added a
`TaggedValue` with its own growing context, accumulating O(N²) and producing
multi-MB register states in the field. The collapse folds every survivor's
HLC + context into the winner's context so the losers are dominated and never
resurface on a later join. Still a valid semilattice op (commutative,
associative, idempotent); the register now stays O(1) per leaf.

## 0.4.0

Performance overhaul of `Sequence`. Production trigger: a 23k-entry
text-reconcile on dart2js (Obsidian plugin) was hanging the UI for
77+ seconds. After this release the same workload runs in ~100ms — a
~800× speedup at the diff-apply step, end-to-end O(N + K) where K is
the size of the batch and N is the entry-map size.

### Changed

- `Sequence._chars` migrated from `IMap` (fast_immutable_collections)
  to a native `Map<Hlc, SeqEntry<T>>` treated as immutable by
  convention. The previous backing store advertised HAMT semantics
  but was implemented as a chained delta on top of a base `Map`
  with periodic auto-flush — its `add` was O(1) amortised but every
  `values`/`entries` iteration walked the delta chain via
  `Iterable.followedBy`, which on dart2js is a major const-factor
  loss against V8's native hash table. The migration trades the
  (unused in our access pattern) structural sharing for raw
  iteration throughput. Benchmarks: dart2js iteration 17× faster,
  build N=100k from 149s → 27ms, batch-join K=1000 from 3.1s → 19ms.
- `Sequence.entries` now returns `Map<Hlc, SeqEntry<T>>` instead of
  `IMap<Hlc, SeqEntry<T>>`. The map is the live internal storage and
  must not be mutated by callers. Methods used by codecs and tests
  (`.length`, `.values`, `.keys`, `.containsKey`, `.entries`) are
  preserved by both types, so most call sites are unaffected.
- `package:fast_immutable_collections` is no longer a dependency.

### Added

- `Sequence.applyOps(List<SeqOp<T>>, Hlc Function() nextHlc)` — batch
  mutation entry point. One `Map.of` copy + one mutable working
  visible list + a precomputed `hasRightChild` set turn what was K
  independent `O(N log N)` mutations into a single `O(N + K)` batch.
  Use for any multi-op write path: text-diff reconcile, bulk apply
  of a remote delta, codec-side replay.
- `SeqOp<T>` sealed class with `SeqOp.insert(int at, T value)` and
  `SeqOp.removeAt(int at)` constructors. Ops are interpreted in
  list order against the evolving visible projection — `insert(3,
  …)` followed by `removeAt(2)` resolves the remove against the
  post-insert indexing.
- Memoisation of `Sequence._visible()`. Every getter that walks
  visible order (`values`, `length`, `[]`, `_resolveInsertion`,
  `_findLastVisible`, `_findFirstVisible`) now shares a single
  cached list per Sequence instance. Repeated `.values` reads on
  the same instance drop from `O(N log N)` per call to `O(1)`.

### Migration

- Switch any per-op write loop on a large `Sequence` to `applyOps`.
  The per-op API (`insertAt` / `removeAt` / `append` / `prepend`)
  still works for single mutations, but on a `Map`-backed Sequence
  each one is `O(N)` (the entry map is cloned) — calling them
  thousands of times in a row hits the same kind of quadratic blow-
  up that `IMap.add` had via auto-flush.
- If you relied on `Sequence.entries` returning an `IMap` (e.g. to
  pass it to a function typed against `IMap`), wrap it with `.lock`
  at the call site or change the receiver's type to `Map`.

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
