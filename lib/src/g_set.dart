// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'crdt.dart';

/// Grow-only set. Once an element is added, it stays forever.
///
/// `join` is set union — the simplest possible semilattice. No
/// timestamps, no causal context: union is unconditionally commutative
/// / associative / idempotent.
///
/// **Classification.** Classical state-based CvRDT (Shapiro et al.
/// 2011, §3.3) that trivially admits Δ-state shipping: any subset of
/// the state is itself a valid state, so a single-element `add` can
/// be shipped as `{x}` and joined identically to the full set.
///
/// Use for tags, labels, list-of-things-ever-seen, any monotonic
/// "saw event X" tracking. Need delete? Use [OrSet].
class GSet<T> implements Crdt<GSet<T>> {
  final Set<T> _values;

  const GSet._(this._values);

  GSet.empty() : _values = const {};

  GSet.from(Iterable<T> values) : _values = Set.unmodifiable(values);

  Set<T> get values => _values;
  int get size => _values.length;
  bool get isEmpty => _values.isEmpty;
  bool contains(T value) => _values.contains(value);

  GSet<T> add(T value) {
    if (_values.contains(value)) return this;
    return GSet._(Set.unmodifiable({..._values, value}));
  }

  /// Δ-state delta: a minimal GSet representing the addition of a
  /// single element. Joining the delta into a peer's GSet has the
  /// same effect as the corresponding [add] call.
  static GSet<T> deltaAdd<T>(T value) => GSet<T>.from({value});

  @override
  GSet<T> get empty => GSet<T>.empty();

  @override
  GSet<T> join(GSet<T> other) =>
      GSet._(Set.unmodifiable({..._values, ...other._values}));

  @override
  GSet<T> deltaCompose(GSet<T> other) => join(other);

  @override
  bool operator ==(Object other) =>
      other is GSet<T> &&
      _values.length == other._values.length &&
      _values.containsAll(other._values);

  @override
  int get hashCode => Object.hashAllUnordered(_values);

  @override
  String toString() => 'GSet($_values)';
}
