# convergent

Convergent Replicated Data Types for Dart.

Self-contained, dependency-free primitives — registers, sets, counters,
maps, and list / text CRDTs (**`Fugue`** and `Sequence`) — together with
the supporting clock and causal-context machinery. Every type implements a shared
`Crdt<Self>` interface with three operations:

- `join` — cross-replica merge; commutative, associative, idempotent.
- `empty` — identity element of the join-semilattice (the bottom).
- `deltaCompose` — in-replica composition of two locally-produced
  Δ-state fragments before shipping; defaults to `join` for most
  types.

Replicas converge under any delivery order, with arbitrary
duplicates, with no central coordinator.

**Form.** State-based / Δ-state. `MvRegister`, `LwwRegister`, `OrSet`
and `Sequence` follow the Δ-state formulation of Almeida, Shapiro,
Baquero (JPDC 2018), embedding the causal context directly in the
state so that `join` is a pure 2-argument function with no
out-of-band delivery guarantees. `GSet` and `PnCounter` are classical
CvRDTs (Shapiro et al. 2011) that trivially admit Δ-state shipping —
any subset of their state is a valid delta. Nothing in this package
is operation-based: there is no notion of "broadcasting an op" and
no causal-delivery requirement on the transport.

Version: `0.3.x` (pre-stable; minor versions may break API).
License: MIT.

---

## Contents

**Causal machinery:**
- `Hlc` — Hybrid Logical Clock.
- `CausalContext` — `Map<NodeId, max(Hlc)>` watermark vector clock
  (used by `MvRegister`'s writer contexts).
- `DotSet` — `Set<Hlc>` with explicit dot membership (used by
  `OrSet` and `Sequence`'s implicit context; the canonical Almeida
  2018 §3.4 representation).

**Common interfaces:**
- `Crdt<Self extends Crdt<Self>>` — `join` + `empty` + `deltaCompose`.
- `Pruneable<Self>` — `prune(DotSet stable)` for tombstone GC via
  causal stability.

**CRDT primitives:**
- `MvRegister<T>` — multi-value register (Δ-state, embedded
  contexts).
- `LwwRegister<T>` — single-value register, total order by `Hlc`.
- `GSet<T>` — grow-only set.
- `OrSet<T>` — observed-remove set; add wins on concurrent
  add/remove.
- `PnCounter` — positive/negative counter, per-replica G-Counters.
- `CrdtMap<K, V extends Crdt<V>>` — per-key join over nested CRDTs.
- `Fugue<T>` — optimised list / text CRDT; run-length ("waypoint")
  Fugue in `package:convergent/fugue.dart`. **Recommended** for
  lists / text.
- `Sequence<T>` — ordered Δ-state Fugue list / text CRDT (HLC-based;
  superseded by `Fugue` for new code).

**Δ-state shipping:**
- `Mutator<C>` — per-replica delta accumulator. Tracks current
  state and pending local delta; ships only what changed.

**Serialisation:**
- `Codec<T>` interface + primitive codecs + per-type CRDT codecs
  (JSON, format-versioned via `"v": 1`).

No transport, no persistence. Every CRDT is a pure value with
public state.

---

## `Hlc`

`(millis, counter, nodeId)`. Total order via `compareTo`: lexicographic
on `(millis, counter, nodeId)`. Survives bounded clock skew: `receive`
caps a remote `millis` above local wall time by `maxSkewMs` to prevent
a misbehaving peer from poisoning the local clock.

```dart
class Hlc implements Comparable<Hlc> {
  final int millis;
  final int counter;
  final String nodeId;

  Hlc increment(int wallMs);                              // local event
  Hlc receive(Hlc remote, int wallMs, {int? maxSkewMs});  // remote event
}
```

`nodeId` must be unique per replica.

Reference: Kulkarni et al., *Logical Physical Clocks and Consistent
Snapshots in Globally Distributed Databases*, Buffalo TR 2014-04.

---

## `CausalContext`

`Map<NodeId, Hlc>` — the latest `Hlc` observed from each replica. This
is the classical **vector clock** (Mattern 1988, Fidge 1988) with `Hlc`
in place of an integer counter.

```dart
class CausalContext {
  CausalContext advance(Hlc hlc);                   // record one event
  CausalContext merge(CausalContext other);         // pointwise max
  bool contains(Hlc hlc);                            // has the context seen this event?
  bool dominates(CausalContext other);              // ⊒ relation
}
```

`a.dominates(b) == true` iff every entry in `b` is ≤ the corresponding
entry in `a`. Used by Δ-state `join` to determine which `TaggedValue`s
have been causally superseded.

---

## `DotSet`

```dart
class DotSet {
  DotSet add(Hlc dot);
  DotSet union(DotSet other);
  bool contains(Hlc dot);
  bool dominates(DotSet other);
  Set<Hlc> get dots;
}
```

Explicit set of observed `Hlc` dots. Unlike `CausalContext`, which
summarises observations as a max watermark per node, `DotSet`
records every dot individually. This is the representation that
Almeida 2018 §3.4 requires for correct Δ-state OR-Set / Sequence
delta composition — the watermark form collapses sibling same-node
dots into `max(h1, h2)`, which would erroneously cross-tombstone
legitimate concurrent same-node entries.

Memory grows as O(unique dots ever added); see `Pruneable` for
bounded-memory steady state via causal stability GC.

---

## `Crdt<Self extends Crdt<Self>>`

```dart
abstract interface class Crdt<Self extends Crdt<Self>> {
  Self join(Self other);
  Self get empty;
  Self deltaCompose(Self other);
}
```

F-bounded so generic containers (notably `CrdtMap`) can require their
value type to expose all three returning the same type.

- `join` — **cross-replica** merge. Must be:
  - **Commutative:** `a.join(b) == b.join(a)`.
  - **Associative:** `a.join(b.join(c)) == a.join(b).join(c)`.
  - **Idempotent:** `a.join(a) == a`.
- `empty` — identity element. `a.join(empty) == a` for every `a`.
- `deltaCompose` — **in-replica** composition of two
  locally-produced Δ-state fragments before shipping. For every type
  in this package it coincides with `join`; the hook exists for a
  hypothetical type whose cross-replica join filters (tombstone
  semantics, max-reduction) in a way that would be wrong when
  accumulating one replica's own successive deltas. `Mutator` uses
  `deltaCompose` for its pending-delta accumulator.

These properties give the convergence guarantee independent of the
network or message-passing semantics.

---

## `Pruneable<Self>` — Tombstone GC

```dart
abstract interface class Pruneable<Self> {
  Self prune(DotSet stable);
}
```

Δ-state CRDTs with explicit dot-set contexts (`OrSet`, `Sequence`)
keep every observed dot forever; without pruning, the context
grows linearly with history. **Causal stability** (Almeida 2018
§5): once every replica has observed dot `d` AND `d` is not
referenced by any live entry, dropping `d` from the context is
safe — convergence is preserved.

`prune(stable)` drops every dot in `stable` from the context
**except** those still referenced by a live entry (live dots
must stay so future joins recognise them as already observed).

Computing the stable dot-set is an application-level
distributed-systems problem. Documented patterns:

- **Epoch / round protocol** — every replica reports its highest
  contiguous observed dot; the meet is stable.
- **All-have-acked watermark** — each replica reports
  `lastSeenDot` per peer; the per-replica minimum across peers
  is stable.
- **Server-mediated cursor** — a central coordinator tracks
  consumer cursors and broadcasts the meet.

---

## `MvRegister<T>` — Multi-Value Register

Stores a set of `TaggedValue<T>` where

```dart
class TaggedValue<T> {
  final T value;
  final Hlc hlc;
  final CausalContext context;  // writer-observed state at write time
}
```

`TaggedValue` identity is `(value, hlc)`; `context` is metadata for
dominance and is excluded from equality (required for idempotency).

```dart
class MvRegister<T> implements Crdt<MvRegister<T>> {
  MvRegister<T> set(T value, Hlc hlc, CausalContext writerContext);
  MvRegister<T> join(MvRegister<T> other);

  Set<TaggedValue<T>> get values;
  T? get singleValue;       // null when empty OR when conflict
  bool get hasConflict;     // |values| > 1
}
```

**Join algorithm (Δ-state, doc §4.2):**

```
U  = self.values ∪ other.values
S  = { v ∈ U | ∀ w ∈ U: w.hlc = v.hlc  ∨  ¬ w.context.contains(v.hlc) }
result = MvRegister(S)
```

Each `TaggedValue` carries its writer's `CausalContext`, so dominance
can be computed from the union alone — no externally-tracked state.

**Transitive-context invariant.** Because dominance is judged per-value
via the embedded context, `join` is only associative when each stored
context is *transitively closed*: a write that supersedes value `w` must
carry a context that covers not just `w`'s hlc but every value `w` itself
superseded. `set` guarantees this by absorbing the context of every value
it supersedes. `deltaSet` cannot see those values, so **the caller must
supply a `writerContext` that already dominates the contexts of all
superseded values** — maintaining a device-level context by merging the
embedded contexts of every value ever observed satisfies this; advancing
a context only by observed value hlcs does not.

Reference: Almeida, Shapiro, Baquero, *Delta State Replicated Data
Types*, JPDC 2018, §4.

---

## `LwwRegister<T>` — Last-Writer-Wins Register

Wraps `MvRegister<T>`. `value` returns the `TaggedValue<T>` with the
maximum `Hlc` under `Hlc.compareTo`. Determinism is guaranteed because
`Hlc.compareTo` is a total order including `nodeId` as final tiebreaker.

```dart
class LwwRegister<T> implements Crdt<LwwRegister<T>> {
  LwwRegister<T> set(T value, Hlc hlc, CausalContext context);
  LwwRegister<T> join(LwwRegister<T> other);

  T? get value;
  Hlc? get hlc;
  bool get isEmpty;
}
```

Concurrent writes are still stored internally; only the externally
observed `value` is single-valued.

---

## `GSet<T>` — Grow-Only Set

```dart
class GSet<T> implements Crdt<GSet<T>> {
  GSet<T> add(T value);
  GSet<T> join(GSet<T> other);    // set union

  Set<T> get values;
  int get size;
  bool contains(T value);
}
```

`join` is unconditional set union; commutativity / associativity /
idempotency follow from set-theory and require no timestamps.
Classical CvRDT (Shapiro et al. 2011, §3.3); any subset of the state
is a valid Δ-state delta.

---

## `OrSet<T>` — Observed-Remove Set

Δ-state formulation per Almeida, Shapiro, Baquero (JPDC 2018, §3.4).

State:

```
dots     : Set<Dot<T>>     // live (value, hlc) pairs
context  : DotSet           // every dot the replica has ever observed
```

`Dot<T>` is a public `(value, hlc)` pair, parallel to `TaggedValue`
in `MvRegister`. `DotSet` is the explicit dot-set representation
(see above).

`contains(x)` iff some `(x, _)` is present in `dots`.

```dart
class OrSet<T> implements Crdt<OrSet<T>>, Pruneable<OrSet<T>> {
  OrSet<T> add(T value, Hlc dot);    // caller-minted unique dot
  OrSet<T> remove(T value);          // drops local dots only

  // Δ-state delta producers.
  static OrSet<T> deltaAdd<T>(T value, Hlc dot);
  OrSet<T> deltaRemoveOf(T value);

  Set<T> get values;
  bool contains(T value);
  DotSet get context;                // introspection
}
```

- `add(x, hlc)` adds `(x, hlc)` to `dots` and adds `hlc` to
  `context`.
- `remove(x)` drops every `(x, _)` from `dots`. **Does not touch
  `context`** — the context still reflects every dot observed.
- `join` keeps `(x, hlc)` from one side iff the other side has the
  same dot, *or* its context does not yet contain `hlc`. A dot
  present on one side but absent from the other side, whose context
  contains it, is treated as removed by that side.

**Tombstones are emergent**, not stored: they are exactly the dots
covered by the context but missing from `dots`. There is no
tombstone set to grow or GC.

**Add-wins semantics:** `add` mints a fresh `hlc` that no concurrent
remover's context covers, so the new dot survives the join.

Caller invariant: every `add` must be passed a unique fresh `Hlc`
per call across all replicas.

---

## `PnCounter` — Positive/Negative Counter

State: `Map<NodeId, (int positive, int negative)>`.

```dart
class PnCounter implements Crdt<PnCounter> {
  PnCounter increment(Hlc by, [int delta = 1]);
  PnCounter decrement(Hlc by, [int delta = 1]);
  PnCounter join(PnCounter other);   // per-key max of both halves

  // Δ-state delta producers — carry this replica's POST-mutation total.
  PnCounter deltaIncrement(Hlc by, [int delta = 1]);
  PnCounter deltaDecrement(Hlc by, [int delta = 1]);

  int get value;                      // Σ positive − Σ negative
}
```

`delta` must be non-negative (use the opposite operation to decrease).

Per-replica halves only ever grow, so per-key `max` is the correct
join. Idempotent on duplicate delivery: the same `(nodeId, positive,
negative)` triple gives the same max. Classical CvRDT (Shapiro et
al. 2011, §3.1).

A Δ-state delta must be a **join-inflation** of the post-mutation
state, so `deltaIncrement` / `deltaDecrement` are **instance methods**
that carry this replica's post-mutation total `(positive, negative)` —
not the raw amount. A raw `{node: (n, 0)}` fragment is not an
inflation: two of them max-merge and one is silently dropped (and
`Mutator.applyLocal`, which does `state.join(delta)`, would then
diverge from a peer that received the summed accumulator). Because
each fragment is a post-total, in-replica `deltaCompose` coincides
with `join`.

---

## `CrdtMap<K, V extends Crdt<V>>` — Map of CRDTs

```dart
class CrdtMap<K, V extends Crdt<V>> implements Crdt<CrdtMap<K, V>> {
  CrdtMap<K, V> put(K key, V value);   // joins with existing value
  CrdtMap<K, V> join(CrdtMap<K, V> other);

  V? operator [](K key);
  Iterable<K> get keys;
  Iterable<V> get values;
}
```

`put` joins the incoming value with any existing entry — never blindly
overwrites. `join` walks the union of keys and joins entries pairwise.

Keys are monotonic: a key, once present, is never removed by `join`.
Combine with `OrSet<K>` to support deletion.

---

## `Fugue<T>` — Optimised list / text CRDT

`package:convergent/fugue.dart`. A run-length ("waypoint") implementation
of the full Fugue algorithm from *The Art of the Fugue: Minimizing
Interleaving in Collaborative Text Editing* (Weidner & Kleppmann, IEEE TPDS
2025). Prefer it over `Sequence` for new code: a contiguously-typed run is
stored as a single block instead of one node per character (~2 bytes/char
through the binary codec, vs ~618 for one-node-per-char), while remaining a
faithful **state-based** CRDT (the paper's own reformulation of the
algorithm).

Identity is a **logical `Dot(counter, replica)`**, not an `Hlc` — a logical
counter is what lets a run share consecutive counters and coalesce into one
block. `LamportClock` mints dots; `observe` folds observed counters in so a
fresh edit causally dominates the content it edits (no separate skew-witness
step needed).

```dart
final clk = LamportClock(deviceId);
final f = Fugue<String>();

// Index-based edits.
f.insert(0, 'h', clk.tick());
final delta = f.applyOps([FugueOp.insert(1, 'i')], clk); // batch → δ to ship

// Position-based edits — stable cursors that survive concurrent edits and
// the anchor element's own deletion.
final pos = f.positionAt(0);
f.insertAfter(pos, '!', clk.tick());

// Merge / serialise.
final merged = f.join(other);                          // semilattice join
final bytes  = const FugueTextBinaryCodec().encode(f); // compact bytes
```

- **Non-interleaving** (the paper's Theorem 1): concurrent runs at the same
  position never interleave — each stays a contiguous block.
- **State-based + delta**: `join` is commutative / associative / idempotent;
  `applyOps` returns a δ-fragment such that `base.join(δ)` reconstructs the
  applied state.
- **Pruning**: `prune(Set<Dot> stable)` drops fully-tombstoned, causally
  stable, anchorless blocks (block-granular).
- **Codecs**: `FugueCodec<T>(Codec<T>)` (JSON) and `FugueTextBinaryCodec`
  (replica-id interning + LEB128 varints + one packed UTF-8 string per run;
  ~2 bytes/char, encode/decode ~2 ms for a 20k-char doc).

Because `Fugue` runs a **separate logical clock**, it does not share the
library's HLC causal context or `DotSet` pruning — that is the one reason
`Sequence` is retained.

---

## `Sequence<T>` — Ordered Δ-state CRDT (Fugue)

> **Superseded by `Fugue` (above) for new code.** `Sequence` is retained for
> HLC-integrated use — it shares the library's causal context and `DotSet`
> pruning, whereas `Fugue` runs a separate logical clock.

Position tree of `SeqEntry<T>` keyed by `Hlc` dots. Derived from
Weidner, Gentle, Kleppmann, *Fugue: A Basis for Elegant CRDTs*
(PaPoC 2023) via Almeida 2018's op-based → state-based
transformation. The first Dart Fugue we are aware of, and the
only one in pure Δ-state form (no causal-delivery requirement
on the transport).

State:

```
chars : Map<Hlc, SeqEntry<T>>     // all observed entries (live + tombstoned)
```

Each entry carries `id`, `parent`, `side` (`LEFT`/`RIGHT`),
`value`, and a `tombstoned` flag. Tombstoned entries are kept
because their position is still required to resolve their
descendants; they are hidden from the user-visible read.

```dart
class Sequence<T> implements Crdt<Sequence<T>>, Pruneable<Sequence<T>> {
  // Full-state mutators.
  Sequence<T> insertAt(int index, T value, Hlc dot);
  Sequence<T> removeAt(int index);

  // Δ-state delta producers.
  Sequence<T>  deltaInsertAt(int index, T value, Hlc dot);
  Sequence<T>? deltaRemoveAt(int index);

  List<T> get values;
  int get length;
  T? operator [](int index);
}
```

**Insert rule** (Fugue Algorithm 1):

- Index `0` on a non-empty list → LEFT child of the leftmost
  visible entry.
- Index `n` (append) → RIGHT child of the rightmost visible entry.
- Index `i` in the middle:
  - If the left neighbour at `i-1` has no right-side children
    observed, insert as RIGHT child of the left neighbour.
  - Otherwise insert as LEFT child of the right neighbour at `i`.

**Read**: in-order DFS — LEFT children sorted by id, then the
parent (when not tombstoned), then RIGHT children sorted by id.
Roots (`parent == null`) traverse in id order.

**Join**: per-id union with tombstone OR-merge. Every observed
dot lives in `chars`, so the same explicit-context argument that
makes `OrSet` correct also makes `Sequence` correct;
`deltaCompose` simply delegates to `join`.

**Pruning**: drops tombstoned entries whose ids are in `stable`
AND have no live descendants. Live entries are never dropped
(their position metadata anchors their children).

Text editing is a special case — `Sequence<int>` (codepoints) or
`Sequence<String>` (graphemes). Concurrent insertions interleave
deterministically via the side-and-id ordering.

---

## `Mutator<C>` — Δ-state delta accumulator

```dart
class Mutator<C extends Crdt<C>> {
  Mutator({required C initial});

  C get state;             // current full state
  C get pendingDelta;      // accumulated local delta since last flush
  bool get hasPendingDelta;

  void applyLocal(C delta);     // joins into state AND accumulator
  void applyRemote(C delta);    // joins into state only
  C    flushDelta();            // returns accumulator + resets to empty
  void discardPendingDelta();   // clears accumulator without shipping
}
```

The typical loop:

```dart
final mut = Mutator<OrSet<String>>(initial: OrSet<String>.empty());

mut.applyLocal(OrSet.deltaAdd('hello', clock.tick()));
mut.applyLocal(OrSet.deltaAdd('world', clock.tick()));

// Ship just what changed:
final wire = codec.encode(mut.flushDelta());
transport.send(wire);

// On the peer:
final remote = codec.decode(payload);
peerMutator.applyRemote(remote);
```

`Mutator` does no IO, no timing, no transport. Correctness
follows directly from the semilattice properties of `Crdt.join`
and the in-replica composition properties of
`Crdt.deltaCompose`.

---

## Composition

Application records can embed multiple CRDTs and gain a free `join`:

```dart
class TodoItem implements Crdt<TodoItem> {
  final LwwRegister<String> title;
  final LwwRegister<bool>   done;
  final OrSet<String>       tags;

  TodoItem({required this.title, required this.done, required this.tags});

  @override
  TodoItem get empty => TodoItem(
    title: LwwRegister<String>.empty(),
    done:  LwwRegister<bool>.empty(),
    tags:  OrSet<String>.empty(),
  );

  @override
  TodoItem join(TodoItem other) => TodoItem(
    title: title.join(other.title),
    done:  done.join(other.done),
    tags:  tags.join(other.tags),
  );

  @override
  TodoItem deltaCompose(TodoItem other) => TodoItem(
    title: title.deltaCompose(other.title),
    done:  done.deltaCompose(other.done),
    tags:  tags.deltaCompose(other.tags),
  );
}

final todos = CrdtMap<TodoId, TodoItem>.empty();
```

Each field carries its own conflict policy; commutativity /
associativity / idempotency are preserved by structural composition.

---

## Serialisation

Every type ships with a JSON codec via the shared `Codec<T>` interface:

```dart
abstract interface class Codec<T> {
  Object? encode(T value);
  T decode(Object? json);
}
```

Codecs are pure values, format-versioned (every Map-shaped encoding
carries `"v": 1`), and round-trip through `dart:convert.jsonEncode`
/ `jsonDecode`.

```dart
const codec = OrSetCodec<String>(StringCodec());

final s = OrSet<String>.empty()
    .add('hello', Hlc(1, 0, 'A'))
    .add('world', Hlc(2, 0, 'A'));

final json = codec.encode(s);                // Object?  (a Map<String, Object?>)
final wire = jsonEncode(json);               // String  — persist or send
final restored = codec.decode(jsonDecode(wire));
// restored == s
```

Primitive codecs are provided for the common payload types:
`StringCodec`, `IntCodec`, `DoubleCodec`, `BoolCodec`, `JsonCodec<T>`
(identity, for already-JSON-compatible values).

Nesting composes naturally:

```dart
const reactionsCodec = CrdtMapCodec<String, PnCounter>(
  keyCodec: StringCodec(),
  valueCodec: PnCounterCodec(),
);

const todoCodec = CrdtMapCodec<String, GSet<String>>(
  keyCodec: StringCodec(),
  valueCodec: GSetCodec<String>(StringCodec()),
);
```

Codec table:

| Codec | Type | Encoded shape |
|---|---|---|
| `HlcCodec` | `Hlc` | `"millis-counter-nodeId"` |
| `CausalContextCodec` | `CausalContext` | `"nodeA=hlcA;nodeB=hlcB"` |
| `DotSetCodec` | `DotSet` | `"hlc1;hlc2;hlc3"` |
| `MvRegisterCodec<T>(Codec<T>)` | `MvRegister<T>` | `{v, values:[{value, hlc, ctx}…]}` |
| `LwwRegisterCodec<T>(Codec<T>)` | `LwwRegister<T>` | same as `MvRegisterCodec` |
| `GSetCodec<T>(Codec<T>)` | `GSet<T>` | `{v, values:[…]}` |
| `OrSetCodec<T>(Codec<T>)` | `OrSet<T>` | `{v, dots:[{value, hlc}…], ctx}` |
| `PnCounterCodec` | `PnCounter` | `{v, state:{nodeId:[pos,neg]…}}` |
| `CrdtMapCodec<K, V>(Codec<K>, Codec<V>)` | `CrdtMap<K, V>` | `{v, entries:[[k, v]…]}` |
| `SequenceCodec<T>(Codec<T>)` | `Sequence<T>` | `{v, chars:[{id, parent, side, value, tomb?}…]}` |

---

## Out of scope

- **Tree CRDTs with move semantics** (Kleppmann's Movable Tree). A
  parent-pointer tree can be approximated with
  `CrdtMap<NodeId, LwwRegister<NodeId?>>` + `OrSet<NodeId>` for
  membership; Kleppmann-style concurrent-move arbitration is not
  provided.
- **Binary wire format** — JSON only; binary codecs (CBOR /
  protobuf) can be plugged in via the same `Codec<T>` interface.
- **Transport** and **persistence** — every type is a pure value;
  ship and store via whatever channel suits the host application.
- **Watermark protocol** for `Pruneable.prune` — the API surfaces
  the pruning operation; computing the stable dot-set is the
  caller's distributed-systems problem.

These may be added in future minor versions if scope demands.

---

## References

- Shapiro, Preguiça, Baquero, Zawirski. *Conflict-free Replicated Data
  Types.* INRIA RR-7687, 2011.
- Almeida, Shapiro, Baquero. *Delta State Replicated Data Types.* JPDC,
  2018.
- Weidner, Gentle, Kleppmann. *Fugue: A Basis for Elegant CRDTs.*
  PaPoC, 2023.
- Kulkarni, Demirbas, Madappa, Avva, Leone. *Logical Physical Clocks
  and Consistent Snapshots in Globally Distributed Databases.* Buffalo
  TR 2014-04.
- Mattern. *Virtual Time and Global States of Distributed Systems.*
  1988.
- Fidge. *Timestamps in Message-Passing Systems That Preserve the
  Partial Ordering.* 1988.
