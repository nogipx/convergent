// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'crdt.dart';
import 'dot_set.dart';
import 'hlc.dart';
import 'pruneable.dart';

/// One observed add in an [OrSet]: an element value paired with the
/// unique [Hlc] dot that minted it. Identity is `(value, hlc)`.
///
/// Analogous to `TaggedValue` in `MvRegister`, minus the embedded
/// causal context (an `OrSet` stores the context at the set level,
/// not per dot).
class Dot<T> {
  const Dot(this.value, this.hlc);

  final T value;
  final Hlc hlc;

  @override
  bool operator ==(Object other) =>
      other is Dot<T> && value == other.value && hlc == other.hlc;

  @override
  int get hashCode => Object.hash(value, hlc);

  @override
  String toString() => '($value@$hlc)';
}

/// Observed-Remove Set — Δ-state formulation per Almeida, Shapiro,
/// Baquero, *Delta State Replicated Data Types*, JPDC 2018, §3.4.
///
/// State is a pair `(dots, context)`:
///
/// - `dots` — set of `(value, hlc)` pairs that have been added and
///   not yet removed on a replica that has them.
/// - `context` — [DotSet] of every dot the replica has ever observed
///   (locally added **or** received via [join]). Explicit set, not
///   a watermark — this is what makes Δ-state delta-shipping work
///   correctly when two locally-produced deltas from the same node
///   are composed.
///
/// Tombstones are emergent — they are exactly the dots covered by
/// the context but absent from `dots`. There is no tombstone set to
/// grow or GC.
///
/// `add(x, hlc)` records a fresh dot and adds it to `context`.
/// `remove(x)` drops every local dot for `x` but does **not** touch
/// `context` — meaning "I've already seen these dots, drop them".
///
/// `join` keeps a dot from one side iff the other side either has
/// the same dot or its context has *not* yet observed the dot's
/// `hlc`. A dot present here but absent on the other side whose
/// context contains it is treated as removed by that side.
///
/// **Add-wins on concurrent add / remove:** because `add` mints a
/// fresh `hlc` that the remover's context has not yet observed, the
/// new dot survives the join.
///
/// Caller invariant: every `add` must be passed a fresh, replica-
/// unique [Hlc] (advance the per-replica HLC clock on every call).
class OrSet<T> implements Crdt<OrSet<T>>, Pruneable<OrSet<T>> {
  final Set<Dot<T>> _dots;
  final DotSet _context;

  const OrSet._(this._dots, this._context);

  OrSet.empty() : _dots = const {}, _context = const DotSet.empty();

  /// Reconstructs an OrSet from a dot store and dot-set context.
  /// Intended for codecs and state restoration — the caller is
  /// responsible for keeping `dots` and `context` consistent with
  /// the Δ-state invariant (every dot's `hlc` must be contained in
  /// `context`).
  factory OrSet.fromDots(Iterable<Dot<T>> dots, DotSet context) =>
      OrSet._(Set.unmodifiable(dots.toSet()), context);

  /// Live dot store: `(value, hlc)` pairs that have been added and
  /// not yet removed on this replica. Stable iteration order is not
  /// guaranteed.
  Iterable<Dot<T>> get dots => _dots;

  /// The replica's causal context — the explicit set of every dot
  /// it has ever observed. Exposed for introspection, codecs, and
  /// tests; app code rarely needs it directly.
  DotSet get context => _context;

  Set<T> get values => Set.unmodifiable(_dots.map((d) => d.value).toSet());

  bool get isEmpty => _dots.isEmpty;
  int get size => values.length;

  bool contains(T value) => _dots.any((d) => d.value == value);

  OrSet<T> add(T value, Hlc dot) {
    final entry = Dot(value, dot);
    if (_dots.contains(entry)) return this;
    return OrSet._(Set.unmodifiable({..._dots, entry}), _context.add(dot));
  }

  OrSet<T> remove(T value) {
    final kept = _dots.where((d) => d.value != value).toSet();
    if (kept.length == _dots.length) return this;
    return OrSet._(Set.unmodifiable(kept), _context);
  }

  /// Δ-state delta: a singleton set carrying one new `(value, dot)`
  /// observation and a one-entry context. Joining this into a peer
  /// has the same effect as calling `add(value, dot)`.
  static OrSet<T> deltaAdd<T>(T value, Hlc dot) {
    return OrSet<T>._(
      Set.unmodifiable({Dot(value, dot)}),
      const DotSet.empty().add(dot),
    );
  }

  /// Δ-state delta for a remove: a set carrying NO dots and a
  /// context containing every dot the local replica had observed
  /// for [value]. Joining this into a peer drops every same-`value`
  /// dot that the peer's context shows the local replica had
  /// already seen — exactly the observed-remove semantics expressed
  /// as a state increment.
  OrSet<T> deltaRemoveOf(T value) {
    var ctx = const DotSet.empty();
    for (final d in _dots) {
      if (d.value == value) ctx = ctx.add(d.hlc);
    }
    return OrSet<T>._(const {}, ctx);
  }

  @override
  OrSet<T> get empty => OrSet<T>.empty();

  /// Cross-replica merge.
  ///
  /// Algorithm (Almeida 2018 Algorithm 2):
  /// ```
  /// S'' = (S ∩ S') ∪ (S \ c') ∪ (S' \ c)
  /// c'' = c ∪ c'
  /// ```
  /// Equivalently: keep dot `d ∈ S` iff `d ∈ S'` or `d ∉ c'`. The
  /// explicit dot-set membership of `c'` (no watermark collapse) is
  /// what makes this also correct for in-replica delta composition,
  /// so [deltaCompose] simply delegates to [join].
  @override
  OrSet<T> join(OrSet<T> other) {
    final keptFromSelf = _dots
        .where(
          (d) => other._dots.contains(d) || !other._context.contains(d.hlc),
        )
        .toSet();
    final keptFromOther = other._dots
        .where((d) => _dots.contains(d) || !_context.contains(d.hlc))
        .toSet();
    return OrSet._(
      Set.unmodifiable({...keptFromSelf, ...keptFromOther}),
      _context.union(other._context),
    );
  }

  /// In-replica delta composition. With the explicit-dot-set context
  /// representation, composition coincides with [join] — there is no
  /// watermark collapse that would erroneously drop a sibling dot
  /// from the same node.
  @override
  OrSet<T> deltaCompose(OrSet<T> other) => join(other);

  /// Drops every dot from the context that (a) is in [stable] AND
  /// (b) is not referenced by a live entry in `dots`. Live dots
  /// (and their HLC entries in the context) are always preserved.
  ///
  /// After pruning, the OrSet's user-visible behavior is unchanged
  /// — values still present, removals still propagate. The savings
  /// are in the context's memory footprint and the wire size of
  /// future shipped states.
  ///
  /// See [Pruneable.prune] for the caller invariant on `stable`.
  @override
  OrSet<T> prune(DotSet stable) {
    final liveHlcs = _dots.map((d) => d.hlc).toSet();
    final keptContext = _context.dots
        .where((d) => !stable.contains(d) || liveHlcs.contains(d))
        .toSet();
    if (keptContext.length == _context.length) return this;
    return OrSet._(_dots, DotSet.from(keptContext));
  }

  @override
  bool operator ==(Object other) {
    if (other is! OrSet<T>) return false;
    if (_dots.length != other._dots.length) return false;
    if (!_dots.containsAll(other._dots)) return false;
    return _context == other._context;
  }

  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(_dots), _context);

  @override
  String toString() => 'OrSet($values, ctx=$_context)';
}
