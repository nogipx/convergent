// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'crdt.dart';
import 'hlc.dart';

/// PN-Counter (Positive-Negative counter).
///
/// Holds an integer that supports `increment` and `decrement`. Two
/// per-replica G-Counters track the total inc and dec from each
/// replica; the value is `sum(inc[r]) - sum(dec[r])`.
///
/// `join` takes the per-replica max of both halves — every replica
/// only ever advances each counter monotonically, so the max is the
/// converged truth.
///
/// **Classification.** Classical state-based CvRDT (Shapiro et al.
/// 2011, §3.1) that trivially admits Δ-state shipping: a delta is
/// just the single-replica entry that changed, and joining it
/// against the full state is identical to joining two full states.
///
/// Identity per replica is the [Hlc.nodeId] passed to `increment`
/// / `decrement`. Different replicas MUST use distinct node ids
/// (the same invariant the rest of this package relies on).
class PnCounter implements Crdt<PnCounter> {
  /// nodeId -> (positive, negative)
  final Map<String, (int, int)> _state;

  const PnCounter._(this._state);

  PnCounter.empty() : _state = const {};

  /// Reconstructs a counter from the per-replica `(positive, negative)`
  /// state. Used by codecs and tests.
  factory PnCounter.fromRaw(Map<String, (int, int)> state) =>
      PnCounter._(Map.unmodifiable(state));

  /// Immutable view of `nodeId -> (positive, negative)`. Used by
  /// codecs and introspection.
  Map<String, (int, int)> get state => _state;

  int get value => _state.values.fold(0, (sum, e) => sum + e.$1 - e.$2);

  PnCounter increment(Hlc by, [int delta = 1]) =>
      _bump(by.nodeId, positive: delta);

  PnCounter decrement(Hlc by, [int delta = 1]) =>
      _bump(by.nodeId, negative: delta);

  PnCounter _bump(String nodeId, {int positive = 0, int negative = 0}) {
    assert(
      positive >= 0 && negative >= 0,
      'PN-Counter deltas must be non-negative; use the opposite operation to decrease.',
    );
    if (positive == 0 && negative == 0) return this;
    final cur = _state[nodeId] ?? (0, 0);
    return PnCounter._(
      Map.unmodifiable({
        ..._state,
        nodeId: (cur.$1 + positive, cur.$2 + negative),
      }),
    );
  }

  /// Δ-state delta for a local increment: carries this replica's
  /// POST-increment `(positive, negative)` pair, so that joining it into
  /// any state that already reflects this replica's history is a proper
  /// join-inflation (join is per-entry max).
  ///
  /// A raw `{node: (delta, 0)}` fragment is NOT an inflation — two
  /// successive raw increments both carry `(1, 0)` and max-merge to `1`,
  /// silently dropping one. Snapshotting the post-increment total makes
  /// repeated in-replica composition (and `Mutator.applyLocal`, which does
  /// `state.join(delta)`) accumulate correctly under max.
  PnCounter deltaIncrement(Hlc by, [int delta = 1]) {
    assert(
      delta >= 0,
      'PN-Counter deltas must be non-negative; use the opposite operation to decrease.',
    );
    final cur = _state[by.nodeId] ?? (0, 0);
    return PnCounter._(Map.unmodifiable({by.nodeId: (cur.$1 + delta, cur.$2)}));
  }

  /// Δ-state delta for a local decrement: carries this replica's
  /// POST-decrement `(positive, negative)` pair. See [deltaIncrement] for
  /// why the post-mutation snapshot (not the raw amount) is the
  /// join-inflation fragment.
  PnCounter deltaDecrement(Hlc by, [int delta = 1]) {
    assert(
      delta >= 0,
      'PN-Counter deltas must be non-negative; use the opposite operation to decrease.',
    );
    final cur = _state[by.nodeId] ?? (0, 0);
    return PnCounter._(Map.unmodifiable({by.nodeId: (cur.$1, cur.$2 + delta)}));
  }

  @override
  PnCounter get empty => PnCounter.empty();

  @override
  PnCounter join(PnCounter other) {
    final keys = {..._state.keys, ...other._state.keys};
    final merged = <String, (int, int)>{};
    for (final k in keys) {
      final a = _state[k] ?? (0, 0);
      final b = other._state[k] ?? (0, 0);
      merged[k] = (a.$1 > b.$1 ? a.$1 : b.$1, a.$2 > b.$2 ? a.$2 : b.$2);
    }
    return PnCounter._(Map.unmodifiable(merged));
  }

  /// In-replica composition coincides with [join]. Each [deltaIncrement] /
  /// [deltaDecrement] fragment already carries the replica's POST-mutation
  /// per-replica total, so two fragments compose by per-entry MAX — the
  /// later (larger) total subsumes the earlier. Summing them, as an earlier
  /// version did with raw increments, double-counts the shared history that
  /// is baked into both post-mutation snapshots.
  @override
  PnCounter deltaCompose(PnCounter other) => join(other);

  @override
  bool operator ==(Object other) {
    if (other is! PnCounter) return false;
    if (_state.length != other._state.length) return false;
    for (final entry in _state.entries) {
      final there = other._state[entry.key];
      if (there == null || there != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    var h = 0;
    for (final entry in _state.entries) {
      h ^= Object.hash(entry.key, entry.value.$1, entry.value.$2);
    }
    return h;
  }

  @override
  String toString() => 'PnCounter($value, replicas=${_state.length})';
}
