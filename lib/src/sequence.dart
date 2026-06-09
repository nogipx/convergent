// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:fast_immutable_collections/fast_immutable_collections.dart';

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

/// Sequence CRDT — a Δ-state derivation of the Fugue list CRDT
/// (Weidner, Gentle, Kleppmann, *Fugue: A Basis for Elegant CRDTs*,
/// PaPoC 2023).
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
/// **Insert rule** (Fugue, Algorithm 1):
/// - Empty sequence → new entry is a root.
/// - Index 0 with non-empty list → LEFT child of the leftmost visible
///   entry.
/// - Index `n` (append) → RIGHT child of the rightmost visible entry.
/// - Index `i` in the middle:
///   - If the left neighbour at `i-1` has no right-side children
///     observed, insert as RIGHT child of the left neighbour.
///   - Otherwise insert as LEFT child of the right neighbour at `i`.
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
  /// Backed by a HAMT-based persistent map (`fast_immutable_collections`).
  /// `add`/`remove` are O(log₃₂ N) with structural sharing, so producing
  /// a new [Sequence] after an insert/remove no longer copies the whole
  /// entry table — append/prepend stay logarithmic regardless of size.
  final IMap<Hlc, SeqEntry<T>> _chars;

  /// Optional pre-computed "last visible entry" hint, propagated by
  /// fast-path mutations ([append]) so subsequent appends skip the
  /// O(N) `_visible()` rebuild that would otherwise dominate cost on
  /// linear right-chains (typical typing pattern). `null` means
  /// unknown — recompute lazily.
  final SeqEntry<T>? _lastVisibleHint;

  /// Same idea as [_lastVisibleHint] but for the left edge, populated
  /// by [prepend].
  final SeqEntry<T>? _firstVisibleHint;

  const Sequence._(
    this._chars, {
    SeqEntry<T>? lastVisibleHint,
    SeqEntry<T>? firstVisibleHint,
  }) : _lastVisibleHint = lastVisibleHint,
       _firstVisibleHint = firstVisibleHint;

  Sequence.empty()
    : _chars = <Hlc, SeqEntry<T>>{}.lock,
      _lastVisibleHint = null,
      _firstVisibleHint = null;

  /// Reconstructs a sequence from its raw entry map. Intended for
  /// codecs.
  factory Sequence.fromRaw(Map<Hlc, SeqEntry<T>> chars) =>
      Sequence._(IMap<Hlc, SeqEntry<T>>(chars));

  /// All entries (live + tombstoned), keyed by id. Stable iteration
  /// order is not guaranteed.
  IMap<Hlc, SeqEntry<T>> get entries => _chars;

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
  /// O(N) — rebuilds the visible projection to resolve the parent.
  /// For the common append/prepend cases (typing at either end of a
  /// document) prefer [append] / [prepend], which skip the rebuild
  /// and run in O(log N) when the corresponding edge hint is warm.
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
    return Sequence<T>._(
      _chars.add(dot, newEntry),
      lastVisibleHint: newEntry,
      // Prepend hint is invalidated only when prepending onto an empty
      // sequence — appending into a sequence with an existing first
      // visible doesn't change the head.
      firstVisibleHint: _firstVisibleHint ?? newEntry,
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
    return Sequence<T>._(
      _chars.add(dot, newEntry),
      firstVisibleHint: newEntry,
      lastVisibleHint: _lastVisibleHint ?? newEntry,
    );
  }

  /// Tombstones the entry currently at position [index]. Returns the
  /// new sequence; if [index] is out of range, returns `this`.
  Sequence<T> removeAt(int index) {
    final delta = deltaRemoveAt(index);
    if (delta == null) return this;
    return join(delta);
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
    return Sequence<T>._(<Hlc, SeqEntry<T>>{dot: newEntry}.lock);
  }

  /// Δ-state delta carrying just a tombstoned entry for the live
  /// entry at [index]. Returns `null` when [index] is out of range.
  Sequence<T>? deltaRemoveAt(int index) {
    final v = _visible();
    if (index < 0 || index >= v.length) return null;
    final target = v[index];
    return Sequence<T>._(
      <Hlc, SeqEntry<T>>{target.id: target.withTombstone(true)}.lock,
    );
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
    // Iterate over the smaller side and fold into the larger, so we
    // pay O(min(|this|, |other|) · log(max)) instead of touching every
    // id when one delta is tiny — the common case for δ-state inserts.
    final (small, large) = _chars.length <= other._chars.length
        ? (_chars, other._chars)
        : (other._chars, _chars);
    var merged = large;
    for (final entry in small.entries) {
      final id = entry.key;
      final mine = entry.value;
      final theirs = merged[id];
      if (theirs == null) {
        merged = merged.add(id, mine);
        continue;
      }
      // Both sides have it. OR-merge tombstone bit. Position metadata
      // is identical across replicas that have observed the entry.
      final tomb = mine.tombstoned || theirs.tombstoned;
      if (tomb == theirs.tombstoned) continue;
      merged = merged.add(id, theirs.withTombstone(tomb));
    }
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

    bool hasLiveDescendant(Hlc id) {
      final children = childrenIndex[id];
      if (children == null) return false;
      for (final c in children) {
        if (!c.tombstoned) return true;
        if (hasLiveDescendant(c.id)) return true;
      }
      return false;
    }

    // Build the kept set by removing only what should be dropped — most
    // pruning passes touch a small fraction of entries, so we save
    // re-allocating the whole map in that case.
    var kept = _chars;
    for (final entry in _chars.entries) {
      final e = entry.value;
      if (!e.tombstoned) continue;
      if (!stable.contains(entry.key)) continue;
      if (hasLiveDescendant(entry.key)) continue;
      kept = kept.remove(entry.key);
    }
    if (identical(kept, _chars)) return this;
    return Sequence<T>._(kept);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Resolves `(parent, side)` for an insertion at logical [index]
  /// against the current visible sequence.
  (Hlc?, SequenceSide) _resolveInsertion(int index) {
    final v = _visible();
    if (v.isEmpty) return (null, SequenceSide.right);
    if (index <= 0) {
      return (v.first.id, SequenceSide.left);
    }
    if (index >= v.length) {
      return (v.last.id, SequenceSide.right);
    }
    final leftNeighbour = v[index - 1];
    final rightNeighbour = v[index];
    final hasRightChildren = _hasObservedChildren(
      leftNeighbour.id,
      SequenceSide.right,
    );
    if (!hasRightChildren) {
      return (leftNeighbour.id, SequenceSide.right);
    }
    return (rightNeighbour.id, SequenceSide.left);
  }

  bool _hasObservedChildren(Hlc parentId, SequenceSide side) {
    for (final e in _chars.values) {
      if (e.parent == parentId && e.side == side) return true;
    }
    return false;
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
  /// tree.
  ///
  /// Iterative implementation: long right-chains (typing at the tail
  /// of a single document) build trees thousands of levels deep, and
  /// recursion would blow Dart's stack at ~5k–10k entries. The
  /// iterative form uses an explicit work stack and handles arbitrary
  /// depth.
  List<SeqEntry<T>> _visible() {
    if (_chars.isEmpty) return const [];
    final childrenIndex = _buildChildrenIndex();
    final result = <SeqEntry<T>>[];
    final roots = _chars.values.where((e) => e.parent == null).toList()
      ..sort((a, b) => a.id.compareTo(b.id));

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
    return result;
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
    return _chars.equalItemsToIMap(other._chars);
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
