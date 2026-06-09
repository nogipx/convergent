// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'hlc.dart';

/// Explicit set of observed `Hlc` dots — the Almeida 2018 §3.4
/// causal context for an Observed-Remove Set.
///
/// Unlike `CausalContext` (which summarises observations as a
/// `Map<NodeId, max(Hlc)>`), a `DotSet` records **every** dot the
/// replica has ever observed as an explicit member. This is the
/// representation required for correct Δ-state OR-Set semantics:
///
/// - Two locally-produced delta-adds from the same node compose by
///   union (`{a} ∪ {c} = {a, c}`), preserving both dots, instead of
///   collapsing to the max-watermark `{node: max(a, c)}`.
/// - Cross-replica join can decide "the other side has observed dot
///   `d` but doesn't list it in their `dots` → they removed it" by
///   exact membership, with no risk of over-domination from same-node
///   monotonicity.
///
/// Memory grows as O(unique dots ever added). Pruning of dots that
/// have been observed by every replica (causal stability) is left to
/// the Phase B tombstone-GC API.
class DotSet {
  final Set<Hlc> _dots;

  const DotSet._(this._dots);
  const DotSet.empty() : _dots = const {};

  factory DotSet.from(Iterable<Hlc> dots) =>
      DotSet._(Set.unmodifiable(dots.toSet()));

  /// Read-only view of the dot membership. Order is not stable.
  Set<Hlc> get dots => _dots;

  bool get isEmpty => _dots.isEmpty;
  int get length => _dots.length;

  /// Returns a new context that additionally observes [dot].
  DotSet add(Hlc dot) {
    if (_dots.contains(dot)) return this;
    return DotSet._(Set.unmodifiable({..._dots, dot}));
  }

  /// Set union of the two contexts.
  DotSet union(DotSet other) =>
      DotSet._(Set.unmodifiable({..._dots, ...other._dots}));

  /// Exact membership — true iff `dot` was explicitly observed.
  bool contains(Hlc dot) => _dots.contains(dot);

  /// `true` iff this set is a (non-strict) superset of [other].
  bool dominates(DotSet other) => other._dots.every(_dots.contains);

  @override
  bool operator ==(Object other) =>
      other is DotSet &&
      _dots.length == other._dots.length &&
      _dots.containsAll(other._dots);

  @override
  int get hashCode => Object.hashAllUnordered(_dots);

  @override
  String toString() => 'DotSet($_dots)';

  /// Compact wire string: `hlc1;hlc2;hlc3` (each packed via
  /// [Hlc.pack]). Empty set packs to the empty string.
  String pack() {
    if (_dots.isEmpty) return '';
    return _dots.map((d) => d.pack()).join(';');
  }

  /// Unpacks the format produced by [pack]. Tolerates the empty
  /// string.
  static DotSet unpack(String s) {
    if (s.isEmpty) return const DotSet.empty();
    return DotSet._(Set.unmodifiable(s.split(';').map(Hlc.unpack).toSet()));
  }
}
