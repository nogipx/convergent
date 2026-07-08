// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'crdt.dart';
import 'dot_set.dart';
import 'hlc.dart';
import 'pruneable.dart';

/// Side of the parent character a [Sequence] entry is attached to.
///
/// Concurrent insertions at the same parent on different sides
/// always order LEFT before the parent, then RIGHT. Same-side
/// concurrents tiebreak by [Hlc.compareTo] of the inserted child's
/// id.
enum SequenceSide { left, right }

/// One entry in a [Sequence] — a character of a Fugue-style position
/// tree.
///
/// Identity is the [id] (a unique [Hlc] dot). [parent] points to the
/// character this one was inserted next to; `null` means a root of
/// the tree (multiple roots are allowed and sorted by id). [side]
/// places this entry to the LEFT or RIGHT of [parent].
///
/// [tombstoned] tracks deletion. A tombstoned entry keeps its
/// position metadata (id, parent, side) because descendants whose
/// positions depend on it must still resolve correctly. Tombstoned
/// entries are simply hidden from the user-visible [Sequence.values]
/// traversal.
class SeqEntry<T> {
  const SeqEntry({
    required this.id,
    required this.parent,
    required this.side,
    required this.value,
    this.tombstoned = false,
  });

  final Hlc id;
  final Hlc? parent;
  final SequenceSide side;
  final T value;
  final bool tombstoned;

  SeqEntry<T> withTombstone(bool t) => t == tombstoned
      ? this
      : SeqEntry<T>(
          id: id,
          parent: parent,
          side: side,
          value: value,
          tombstoned: t,
        );

  @override
  bool operator ==(Object other) =>
      other is SeqEntry<T> &&
      id == other.id &&
      parent == other.parent &&
      side == other.side &&
      value == other.value &&
      tombstoned == other.tombstoned;

  @override
  int get hashCode => Object.hash(id, parent, side, value, tombstoned);

  @override
  String toString() =>
      'SeqEntry($value@$id ${tombstoned ? "✗" : "✓"} '
      'parent=$parent side=${side.name})';
}

/// One operation in a [Sequence.applyOps] batch.
///
/// Use [SeqOp.insert] for inserts and [SeqOp.removeAt] for removes.
/// Ops are applied in list order; later ops see the index space
/// produced by earlier ones in the same batch.
sealed class SeqOp<T> {
  const SeqOp();

  /// Insert [value] at logical index [at]. The dot for the new entry
  /// is minted from the `nextHlc` callback at apply time, so callers
  /// don't need to allocate clocks ahead of the batch.
  const factory SeqOp.insert(int at, T value) = SeqOpInsert<T>;

  /// Remove the live entry at logical index [at].
  const factory SeqOp.removeAt(int at) = SeqOpRemove<T>;
}

class SeqOpInsert<T> extends SeqOp<T> {
  const SeqOpInsert(this.at, this.value);
  final int at;
  final T value;
}

class SeqOpRemove<T> extends SeqOp<T> {
  const SeqOpRemove(this.at);
  final int at;
}

/// Sequence CRDT — a Δ-state derivation of the Fugue list CRDT
/// (Weidner, Gentle, Kleppmann, *Fugue: A Basis for Elegant CRDTs*,
/// PaPoC 2023).
///
/// > **Superseded by `Fugue` (`package:convergent/fugue.dart`).** `Fugue` is
/// > the optimised, run-length ("waypoint") implementation of the full
/// > Algorithm 1 from *The Art of the Fugue* (TPDS 2025): a forward-typed run
/// > is one block, not one node per character (≈9 vs 618 bytes/char), and it
/// > is a state-based CRDT with a delta-producing `applyOps`. Prefer it for
/// > new code. [Sequence] is kept because it is **HLC-based** — it shares the
/// > library's HLC causal context, [DotSet] pruning, and one clock across all
/// > CRDTs — whereas `Fugue` runs a separate logical (Lamport) clock.
///
/// State is a position tree keyed by HLC dots:
///
/// ```
/// chars : Map<Hlc, SeqEntry<T>>
/// ```
///
/// Each entry is either live or tombstoned; tombstoned entries
/// remain in `chars` because their position is still required to
/// resolve their descendants. The implicit causal context is
/// `chars.keys`.
///
/// **Storage.** Backed by a native [Map] treated as immutable by
/// convention. Mutating methods build a fresh map (full O(N) copy)
/// before returning a new [Sequence]. This is fast for batch updates
/// (one copy + K mutations via [applyOps]) but pathological for
/// per-op loops on a large sequence (`seq = seq.insertAt(...)` in a
/// tight cycle becomes O(K · N)). The migration away from
/// `fast_immutable_collections` chose iteration-throughput over
/// structural sharing because rhyolite's hot paths are
/// iteration-dominant ([_visible], [_buildChildrenIndex], projection
/// to text) and our only multi-op write path ([applyOps]) is
/// explicitly batched.
///
/// **Insert rule** (Fugue, Algorithm 1):
/// - Empty sequence → new entry is a root.
/// - Index 0 with non-empty list → LEFT child of the leftmost visible
///   entry.
/// - Index `n` (append) → RIGHT child of the rightmost visible entry.
/// - Index `i` in the middle, between visible neighbours `L` (at `i-1`)
///   and `R` (at `i`):
///   - If `L` is an ancestor of `R` (i.e. `R` lives in `L`'s right
///     subtree), insert as LEFT child of `R`.
///   - Otherwise (R is an ancestor of L, or they are siblings/cousins),
///     insert as RIGHT child of `L`.
///
///   Ancestry — not "does `L` have any right child" — is what keeps the
///   placement correct when `L`'s right subtree is entirely tombstoned:
///   `L` then has a right child yet is not an ancestor of `R`.
///
/// **Read** is an in-order DFS of the position tree, ordered by
/// `(side, id)` per parent — LEFT children sorted by id, then the
/// parent itself if not tombstoned, then RIGHT children sorted by
/// id. Roots (parent==null) traverse in id order.
///
/// **Δ-state join** is per-id union of entries with tombstone
/// OR-merge. Because all observed dots live in `chars` (live or
/// tombstoned), there is no separate context to maintain — tracking
/// "observed but absent" by inspecting `chars` is sufficient, and
/// in-replica delta composition coincides with join.
///
/// **Pruning** drops tombstoned entries that:
/// 1. Are in the supplied stable [DotSet], AND
/// 2. Have no live descendants in the tree.
class Sequence<T> implements Crdt<Sequence<T>>, Pruneable<Sequence<T>> {
  /// Private storage. Treated as immutable — never mutated after
  /// construction. Cloned at every mutation boundary.
  final Map<Hlc, SeqEntry<T>> _chars;

  /// Optional pre-computed "last visible entry" hint, propagated by
  /// fast-path mutations ([append]) so subsequent appends skip the
  /// O(N) `_visible()` rebuild that would otherwise dominate cost on
  /// linear right-chains (typical typing pattern). `null` means
  /// unknown — recompute lazily.
  final SeqEntry<T>? _lastVisibleHint;

  /// Same idea as [_lastVisibleHint] but for the left edge, populated
  /// by [prepend].
  final SeqEntry<T>? _firstVisibleHint;

  /// Memoized result of [_visible]. Lazily filled on first read and
  /// shared across all accessors of the same instance ([values],
  /// [length], [], [_resolveInsertion]). Because [Sequence] is
  /// immutable, the cached list is also safe to expose as
  /// `List.unmodifiable` views.
  List<SeqEntry<T>>? _visibleCache;

  Sequence._(
    this._chars, {
    SeqEntry<T>? lastVisibleHint,
    SeqEntry<T>? firstVisibleHint,
  }) : _lastVisibleHint = lastVisibleHint,
       _firstVisibleHint = firstVisibleHint;

  Sequence.empty()
    : _chars = const {},
      _lastVisibleHint = null,
      _firstVisibleHint = null;

  /// Reconstructs a sequence from its raw entry map. Intended for
  /// codecs. The supplied map is copied — callers may mutate their
  /// reference afterwards without affecting the [Sequence].
  factory Sequence.fromRaw(Map<Hlc, SeqEntry<T>> chars) =>
      Sequence._(Map<Hlc, SeqEntry<T>>.of(chars));

  /// All entries (live + tombstoned), keyed by id. The returned map
  /// is the internal storage and **must not be mutated**. Stable
  /// iteration order is not guaranteed.
  Map<Hlc, SeqEntry<T>> get entries => _chars;

  /// Implicit causal context — the set of every dot observed.
  DotSet get context => DotSet.from(_chars.keys);

  /// Visible values in their resolved order.
  List<T> get values {
    final visible = _visible();
    return List<T>.unmodifiable([for (final e in visible) e.value]);
  }

  /// Visible entries in their resolved order (incl. live entries
  /// only, parent linkage intact). Exposed for traversal-aware
  /// callers; most users want [values].
  List<SeqEntry<T>> get visibleEntries =>
      List<SeqEntry<T>>.unmodifiable(_visible());

  /// Number of live (non-tombstoned) entries.
  int get length => _visible().length;

  bool get isEmpty => _visible().isEmpty;

  T? operator [](int index) {
    final v = _visible();
    if (index < 0 || index >= v.length) return null;
    return v[index].value;
  }

  // ---------------------------------------------------------------------------
  // Mutation: full-state form (returns new Sequence)
  // ---------------------------------------------------------------------------

  /// Inserts [value] at position [index], minting a fresh entry
  /// with [dot]. Returns the new sequence.
  ///
  /// O(N) — rebuilds the visible projection to resolve the parent
  /// AND copies the underlying entry map. For per-op loops on large
  /// sequences prefer [applyOps], which copies the map once for the
  /// whole batch. For the common append/prepend cases (typing at
  /// either end) [append] / [prepend] skip the projection rebuild.
  Sequence<T> insertAt(int index, T value, Hlc dot) =>
      join(deltaInsertAt(index, value, dot));

  /// Appends [value] at the visible tail. O(log N) when the cached
  /// last-visible hint is available, O(N) on the first call after
  /// a non-append mutation (cache cold).
  Sequence<T> append(T value, Hlc dot) {
    final lastVisible = _lastVisibleHint ?? _findLastVisible();
    final newEntry = SeqEntry<T>(
      id: dot,
      parent: lastVisible?.id,
      side: SequenceSide.right,
      value: value,
    );
    final next = Map<Hlc, SeqEntry<T>>.of(_chars)..[dot] = newEntry;
    return Sequence<T>._(
      next,
      lastVisibleHint: newEntry,
      // Propagate the existing head hint; only an insert into an EMPTY
      // sequence defines both edges. `_chars` is `this`'s pre-mutation map
      // (copied into `next` above), so its emptiness reflects the state
      // before this append. If we adopted `newEntry` as the head hint on a
      // non-empty sequence we would record the just-appended TAIL as the
      // first-visible entry, and a subsequent prepend would misplace.
      firstVisibleHint: _chars.isEmpty ? newEntry : _firstVisibleHint,
    );
  }

  /// Prepends [value] at the visible head. O(log N) when the cached
  /// first-visible hint is available.
  Sequence<T> prepend(T value, Hlc dot) {
    final firstVisible = _firstVisibleHint ?? _findFirstVisible();
    final newEntry = SeqEntry<T>(
      id: dot,
      parent: firstVisible?.id,
      // Empty sequence: mint a root with side=right (matches
      // [_resolveInsertion]'s empty-case so peers using insertAt(0,…)
      // and prepend produce byte-identical trees).
      side: firstVisible == null ? SequenceSide.right : SequenceSide.left,
      value: value,
    );
    final next = Map<Hlc, SeqEntry<T>>.of(_chars)..[dot] = newEntry;
    return Sequence<T>._(
      next,
      firstVisibleHint: newEntry,
      // Propagate the existing tail hint; only an insert into an EMPTY
      // sequence defines both edges (`_chars` is the pre-mutation map).
      // Adopting `newEntry` as the tail on a non-empty sequence would record
      // the just-prepended HEAD as the last-visible entry and a subsequent
      // append would misplace.
      lastVisibleHint: _chars.isEmpty ? newEntry : _lastVisibleHint,
    );
  }

  /// Tombstones the entry currently at position [index]. Returns the
  /// new sequence; if [index] is out of range, returns `this`.
  Sequence<T> removeAt(int index) {
    final delta = deltaRemoveAt(index);
    if (delta == null) return this;
    return join(delta);
  }

  /// Applies a sequence of [ops] as a single batch. Allocates one
  /// fresh entry map and mints dots for inserts via [nextHlc]. Ops
  /// are interpreted in list order against the evolving visible
  /// projection — `SeqOp.insert(3, …)` followed by
  /// `SeqOp.removeAt(2)` resolves the remove against the post-insert
  /// indexing.
  ///
  /// **Cost.** O(N + K · N_visible) where N is the entry-map size and
  /// K is `ops.length`. Each op mutates a working `List<SeqEntry>`
  /// in-place (`removeAt`/`insert` are O(N_visible) on a list), so
  /// the batch matches the per-op cost asymptotically but pays the
  /// O(N) map copy **only once** instead of K times. For the
  /// rhyolite text-reconcile pattern (K ~ thousands, N ~ tens of
  /// thousands) this turns a multi-second drip into a single
  /// millisecond batch.
  ///
  /// Returns `this` if [ops] is empty.
  Sequence<T> applyOps(List<SeqOp<T>> ops, Hlc Function() nextHlc) {
    if (ops.isEmpty) return this;

    // Working visible list — mutated in place across all ops. Cold copy
    // of the cached visible list (so the cache on `this` stays valid
    // for any caller that still holds a reference).
    final workVisible = List<SeqEntry<T>>.of(_visible());

    // Working entry map — cloned once, mutated in place. The resolver
    // walks parent chains through this map, so entries added by earlier
    // ops in the batch inform later ops' placement decisions.
    final workChars = Map<Hlc, SeqEntry<T>>.of(_chars);

    // Track whether any op actually changed something so we can short
    // circuit on a stream of out-of-range removes.
    var changed = false;

    for (final op in ops) {
      switch (op) {
        case SeqOpInsert<T>(at: final at, value: final v):
          final (parent, side) = _resolveInsertionInListWithChars(
            workVisible,
            workChars,
            at,
          );
          final dot = nextHlc();
          final entry = SeqEntry<T>(
            id: dot,
            parent: parent,
            side: side,
            value: v,
          );
          workChars[dot] = entry;
          // Position in the visible list: clamp to bounds — matches
          // the semantics of [_resolveInsertion] which treats
          // `index < 0` as 0 and `index > len` as append.
          final pos = at < 0
              ? 0
              : (at > workVisible.length ? workVisible.length : at);
          workVisible.insert(pos, entry);
          changed = true;
        case SeqOpRemove<T>(at: final at):
          if (at < 0 || at >= workVisible.length) continue;
          final target = workVisible[at];
          final tombed = target.withTombstone(true);
          workChars[target.id] = tombed;
          workVisible.removeAt(at);
          changed = true;
      }
    }

    if (!changed) return this;
    return Sequence<T>._(workChars);
  }

  // ---------------------------------------------------------------------------
  // Mutation: Δ-state form (returns minimal delta for shipping)
  // ---------------------------------------------------------------------------

  /// Δ-state delta carrying just the new entry for an insert at
  /// [index]. The caller mints [dot] (typically `clock.tick()`).
  Sequence<T> deltaInsertAt(int index, T value, Hlc dot) {
    final (parent, side) = _resolveInsertion(index);
    final newEntry = SeqEntry<T>(
      id: dot,
      parent: parent,
      side: side,
      value: value,
    );
    return Sequence<T>._({dot: newEntry});
  }

  /// Δ-state delta carrying just a tombstoned entry for the live
  /// entry at [index]. Returns `null` when [index] is out of range.
  Sequence<T>? deltaRemoveAt(int index) {
    final v = _visible();
    if (index < 0 || index >= v.length) return null;
    final target = v[index];
    return Sequence<T>._({target.id: target.withTombstone(true)});
  }

  // ---------------------------------------------------------------------------
  // CRDT operations
  // ---------------------------------------------------------------------------

  @override
  Sequence<T> get empty => Sequence<T>.empty();

  /// Per-id union with tombstone OR-merge.
  ///
  /// Position metadata (parent, side, value) is identical on every
  /// replica that has seen the entry, so taking either side is
  /// fine. The tombstone bit is OR'd: once any replica tombstones
  /// an entry, every replica that observes either side sees it as
  /// tombstoned (observed-remove semantics).
  @override
  Sequence<T> join(Sequence<T> other) {
    if (other._chars.isEmpty) return this;
    if (_chars.isEmpty) return other;

    // Iterate over the smaller side and fold into a copy of the
    // larger, so we pay one O(|large|) copy plus O(|small|) lookups
    // and conditional writes.
    final (small, large) = _chars.length <= other._chars.length
        ? (_chars, other._chars)
        : (other._chars, _chars);
    final merged = Map<Hlc, SeqEntry<T>>.of(large);
    var changed = false;
    for (final entry in small.entries) {
      final id = entry.key;
      final mine = entry.value;
      final theirs = merged[id];
      if (theirs == null) {
        merged[id] = mine;
        changed = true;
        continue;
      }
      // Both sides have it. Position metadata is identical across replicas
      // that observed the entry — the insert derives (parent, side, value)
      // deterministically from the position, so the only way they can differ
      // is a dot minted twice with different metadata (the same misuse the
      // Fugue duplicate-dot guard catches). Taking one side silently would
      // lock the divergence in and break commutativity; assert instead.
      assert(
        mine.parent == theirs.parent &&
            mine.side == theirs.side &&
            mine.value == theirs.value,
        'Divergent metadata for dot $id: a dot was minted twice with '
        'different (parent, side, value). Never reuse an Hlc across inserts.',
      );
      // OR-merge the tombstone bit.
      final tomb = mine.tombstoned || theirs.tombstoned;
      if (tomb == theirs.tombstoned) continue;
      merged[id] = theirs.withTombstone(tomb);
      changed = true;
    }
    if (!changed && identical(large, _chars)) return this;
    return Sequence<T>._(merged);
  }

  /// In-replica composition coincides with [join] because every
  /// observed dot is explicitly tracked in `_chars` — there is no
  /// watermark collapse that would erroneously cross-tombstone
  /// sibling dots from the same node.
  @override
  Sequence<T> deltaCompose(Sequence<T> other) => join(other);

  /// Drop tombstoned entries whose ids are in [stable] AND have no
  /// surviving descendants. Live entries are never dropped (their
  /// position metadata is required for traversal). Tombstones with
  /// at least one live descendant are kept so the descendants
  /// continue to resolve their position correctly.
  @override
  Sequence<T> prune(DotSet stable) {
    final childrenIndex = _buildChildrenIndex();

    // Precompute the set of ids that have a live (non-tombstoned) strict
    // descendant. Single iterative pass — a linearly-typed document is a
    // right-chain as deep as it is long, and the previous recursive
    // hasLiveDescendant overflowed the stack past ~10k entries (the same
    // reason [_visible] is iterative). This also collapses the old
    // O(N · depth) re-traversal to O(N).
    final hasLiveDescendant = _idsWithLiveDescendant(childrenIndex);

    // First pass: collect ids to drop. If none, return this unchanged
    // (avoids a Map.of copy when prune is a no-op, which is the common
    // case for sequences without ready-to-drop tombstones).
    final toDrop = <Hlc>[];
    for (final entry in _chars.entries) {
      final e = entry.value;
      if (!e.tombstoned) continue;
      if (!stable.contains(entry.key)) continue;
      if (hasLiveDescendant.contains(entry.key)) continue;
      toDrop.add(entry.key);
    }
    if (toDrop.isEmpty) return this;
    final kept = Map<Hlc, SeqEntry<T>>.of(_chars);
    for (final id in toDrop) {
      kept.remove(id);
    }
    return Sequence<T>._(kept);
  }

  /// Ids of every entry that has at least one live (non-tombstoned)
  /// strict descendant, computed in a single iterative post-order walk of
  /// the forest so it never recurses on deep right-chains.
  ///
  /// Roots are entries with no parent OR whose parent is absent from
  /// [_chars] (orphans); every entry hangs off exactly one such root, so
  /// the walk visits each once. Children are computed before their parent
  /// (post-order), so `subtreeHasLive[child.id]` — true when the child or
  /// any of its descendants is live — is available when the parent is
  /// resolved. An entry joins the result when any child's subtree is live.
  Set<Hlc> _idsWithLiveDescendant(Map<Hlc, List<SeqEntry<T>>> childrenIndex) {
    final result = <Hlc>{};
    final subtreeHasLive = <Hlc, bool>{};

    // Work stack: _ExpandFrame(node) == "push children, then compute
    // this node after them"; a bare SeqEntry == "compute this node".
    final stack = <Object>[];
    for (final e in _chars.values) {
      final p = e.parent;
      if (p == null || !_chars.containsKey(p)) {
        stack.add(_ExpandFrame<T>(e));
      }
    }

    while (stack.isNotEmpty) {
      final item = stack.removeLast();
      if (item is _ExpandFrame<T>) {
        final node = item.node;
        stack.add(node); // compute-after-children marker
        final children = childrenIndex[node.id];
        if (children != null) {
          for (final c in children) {
            stack.add(_ExpandFrame<T>(c));
          }
        }
      } else {
        final node = item as SeqEntry<T>;
        final children = childrenIndex[node.id];
        var liveDesc = false;
        if (children != null) {
          for (final c in children) {
            if (subtreeHasLive[c.id] == true) {
              liveDesc = true;
              break;
            }
          }
        }
        if (liveDesc) result.add(node.id);
        subtreeHasLive[node.id] = liveDesc || !node.tombstoned;
      }
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Resolves `(parent, side)` for an insertion at logical [index]
  /// against the current visible sequence.
  (Hlc?, SequenceSide) _resolveInsertion(int index) =>
      _resolveInsertionInList(_visible(), index);

  /// Same as [_resolveInsertion] but operates on an externally supplied
  /// visible list, resolving ancestry against `this._chars`. Suitable for
  /// single-op mutation paths.
  (Hlc?, SequenceSide) _resolveInsertionInList(
    List<SeqEntry<T>> v,
    int index,
  ) => _resolveInsertionInListWithChars(v, _chars, index);

  /// Resolves `(parent, side)` for an insertion at visible [index] against
  /// the supplied visible list [v], walking parent chains through [chars]
  /// to decide the neighbour ancestry. [applyOps] passes its mutating
  /// working map so entries added by earlier ops in the same batch are
  /// seen; single-op paths pass `this._chars`.
  (Hlc?, SequenceSide) _resolveInsertionInListWithChars(
    List<SeqEntry<T>> v,
    Map<Hlc, SeqEntry<T>> chars,
    int index,
  ) {
    if (v.isEmpty) return (null, SequenceSide.right);
    if (index <= 0) {
      return (v.first.id, SequenceSide.left);
    }
    if (index >= v.length) {
      return (v.last.id, SequenceSide.right);
    }
    final leftNeighbour = v[index - 1];
    final rightNeighbour = v[index];
    // Between two adjacent visible characters exactly one of three
    // structural relations holds: the left is an ancestor of the right,
    // the right is an ancestor of the left, or they are siblings/cousins
    // under a shared ancestor. Fugue descends the RIGHT neighbour's left
    // side only when the left is an ancestor of the right; otherwise it
    // attaches to the LEFT neighbour's right side (which correctly covers
    // both the right-ancestor-of-left and the sibling cases). Decide by
    // walking both parent chains upward in lockstep — the descendant
    // reaches its ancestor first; if neither does, they are siblings.
    //
    // Using true ancestry, rather than "does the left neighbour have any
    // right child", is what stays correct when the left neighbour's right
    // subtree is fully tombstoned: it then has a right child but is NOT an
    // ancestor of the (visible) right neighbour, and the old predicate
    // misrouted the insert to the far side of the left neighbour.
    final lId = leftNeighbour.id;
    final rId = rightNeighbour.id;
    Hlc? upL = leftNeighbour.parent;
    Hlc? upR = rightNeighbour.parent;
    while (upL != null || upR != null) {
      if (upR == lId) return (rId, SequenceSide.left); // left ⊐ right
      if (upL == rId) return (lId, SequenceSide.right); // right ⊐ left
      if (upL != null) upL = chars[upL]?.parent;
      if (upR != null) upR = chars[upR]?.parent;
    }
    return (lId, SequenceSide.right); // siblings/cousins → attach to left
  }

  /// Iteratively walks the rightmost path of the position tree to find
  /// the last live entry. Cheaper than [_visible] when callers only
  /// need the tail (e.g. [append] cache-miss recovery).
  ///
  /// Worst case is O(N) when the tree is a degenerate right-chain, but
  /// the hint cached on the returned [Sequence] keeps subsequent
  /// appends amortised O(log N). When the tree contains tombstones we
  /// fall back to scanning [_visible] so we don't miss a live entry
  /// hidden inside a tombstoned subtree.
  SeqEntry<T>? _findLastVisible() {
    if (_chars.isEmpty) return null;
    final v = _visible();
    return v.isEmpty ? null : v.last;
  }

  SeqEntry<T>? _findFirstVisible() {
    if (_chars.isEmpty) return null;
    final v = _visible();
    return v.isEmpty ? null : v.first;
  }

  /// Materialises the visible list via in-order DFS of the position
  /// tree. Memoized — every getter that reads visible order shares the
  /// same cached list for the lifetime of this [Sequence] instance.
  ///
  /// Iterative implementation: long right-chains (typing at the tail
  /// of a single document) build trees thousands of levels deep, and
  /// recursion would blow Dart's stack at ~5k–10k entries. The
  /// iterative form uses an explicit work stack and handles arbitrary
  /// depth.
  List<SeqEntry<T>> _visible() {
    final cached = _visibleCache;
    if (cached != null) return cached;
    if (_chars.isEmpty) return _visibleCache = const [];

    final childrenIndex = _buildChildrenIndex();
    final result = <SeqEntry<T>>[];
    final roots = <SeqEntry<T>>[];
    for (final e in _chars.values) {
      if (e.parent == null) roots.add(e);
    }
    roots.sort((a, b) => a.id.compareTo(b.id));

    // Each work item is either:
    //  - SeqEntry<T> directly → "visit this node (emit if live)"
    //  - _ExpandFrame(node)   → "expand this node's subtree (push
    //    right children, self-visit, left children, in that order
    //    so popping yields left → self → right)"
    final stack = <Object>[];
    for (var i = roots.length - 1; i >= 0; i--) {
      stack.add(_ExpandFrame<T>(roots[i]));
    }

    while (stack.isNotEmpty) {
      final item = stack.removeLast();
      if (item is SeqEntry<T>) {
        if (!item.tombstoned) result.add(item);
        continue;
      }
      final node = (item as _ExpandFrame<T>).node;
      final children = childrenIndex[node.id];
      if (children == null) {
        if (!node.tombstoned) result.add(node);
        continue;
      }
      // Split + sort once. Right children pushed first → popped last.
      final left = <SeqEntry<T>>[];
      final right = <SeqEntry<T>>[];
      for (final c in children) {
        (c.side == SequenceSide.left ? left : right).add(c);
      }
      left.sort((a, b) => a.id.compareTo(b.id));
      right.sort((a, b) => a.id.compareTo(b.id));

      for (var i = right.length - 1; i >= 0; i--) {
        stack.add(_ExpandFrame<T>(right[i]));
      }
      stack.add(node); // visit-self after left, before right
      for (var i = left.length - 1; i >= 0; i--) {
        stack.add(_ExpandFrame<T>(left[i]));
      }
    }
    return _visibleCache = result;
  }

  /// Build a parent.id → children list index. O(N) once per call.
  Map<Hlc, List<SeqEntry<T>>> _buildChildrenIndex() {
    final index = <Hlc, List<SeqEntry<T>>>{};
    for (final e in _chars.values) {
      final p = e.parent;
      if (p == null) continue;
      (index[p] ??= []).add(e);
    }
    return index;
  }

  @override
  bool operator ==(Object other) {
    if (other is! Sequence<T>) return false;
    if (_chars.length != other._chars.length) return false;
    for (final entry in _chars.entries) {
      if (other._chars[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    var h = 0;
    for (final entry in _chars.entries) {
      h ^= Object.hash(entry.key, entry.value);
    }
    return h;
  }

  @override
  String toString() => 'Sequence($values)';
}

/// Marker used by the iterative DFS in [Sequence._visible] to flag a
/// node whose subtree hasn't been expanded yet. Plain [SeqEntry] on the
/// work stack means "already expanded, just emit if live".
class _ExpandFrame<T> {
  const _ExpandFrame(this.node);
  final SeqEntry<T> node;
}
