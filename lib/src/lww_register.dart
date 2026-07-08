// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'causal_context.dart';
import 'crdt.dart';
import 'hlc.dart';
import 'mv_register.dart';

/// Last-Writer-Wins register.
///
/// Single-value CRDT built on top of [MvRegister]. On concurrent writes it
/// keeps the winner under a deterministic total order — the [TaggedValue]
/// with the highest [Hlc] (`Hlc.compareTo` breaks ties by `nodeId`, so the
/// choice is the same on every replica) — and folds the losers' HLCs and
/// contexts into the winner's context. Both [set] and [join] collapse this
/// way, so the register is always single-valued and every reachable state is
/// a join fixpoint (`a.join(a) == a`).
///
/// Use this when conflicts are best resolved silently (configuration,
/// feature flags, presence) rather than surfaced to the user.
class LwwRegister<T> implements Crdt<LwwRegister<T>> {
  final MvRegister<T> _inner;

  const LwwRegister._(this._inner);

  LwwRegister.empty() : _inner = MvRegister.empty();

  factory LwwRegister.single(T value, Hlc hlc, {CausalContext? context}) =>
      LwwRegister._(MvRegister.single(value, hlc, context: context));

  /// Wraps an existing [MvRegister]. Used by codecs.
  factory LwwRegister.fromInner(MvRegister<T> inner) => LwwRegister._(inner);

  /// The underlying [MvRegister]. Exposed for codecs and advanced
  /// callers that need every internally-tracked [TaggedValue]
  /// (e.g. tracing). Day-to-day code should use [value] / [hlc].
  MvRegister<T> get inner => _inner;

  /// The winning value, or `null` when the register is empty. On
  /// concurrent writes, picks the [TaggedValue] with the highest HLC.
  T? get value {
    if (_inner.values.isEmpty) return null;
    return _winner().value;
  }

  /// The HLC of the winning value, or `null` when empty.
  Hlc? get hlc => _inner.values.isEmpty ? null : _winner().hlc;

  /// `true` when no write has ever been applied.
  bool get isEmpty => _inner.values.isEmpty;

  /// Write a new value at [hlc] with the writer-observed [context].
  ///
  /// Collapses concurrent survivors to the single winner (see [join]) so the
  /// register keeps its single-value invariant on every path. Without this,
  /// two blind writes (non-dominating contexts) would leave the inner
  /// [MvRegister] multi-valued while [join] collapses it — making a
  /// set-produced state not a join fixpoint (`a.join(a) != a`).
  LwwRegister<T> set(T value, Hlc hlc, CausalContext context) =>
      _collapse(_inner.set(value, hlc, context));

  /// Δ-state delta: a singleton register carrying the new write.
  static LwwRegister<T> deltaSet<T>(
    T value,
    Hlc hlc,
    CausalContext writerContext,
  ) => LwwRegister<T>.fromInner(MvRegister.deltaSet(value, hlc, writerContext));

  @override
  LwwRegister<T> get empty => LwwRegister<T>.empty();

  @override
  LwwRegister<T> join(LwwRegister<T> other) =>
      _collapse(_inner.join(other._inner));

  /// Collapse an inner [MvRegister] to the single highest-HLC value.
  ///
  /// LWW semantics: the result is the single highest-HLC value, so the
  /// concurrent survivors the underlying [MvRegister] keeps are redundant.
  /// Retaining them accumulates one [TaggedValue] — each with its own growing
  /// context — per writer node, which bloats without bound under node churn
  /// (the cause of multi-MB field-map states). Collapse to the winner and fold
  /// every survivor's HLC + context into its context so the losers are
  /// dominated and never resurface on a later join. Still a valid semilattice
  /// op: the winner is the global HLC-max and the context is the union, so
  /// join stays commutative, associative and idempotent — and, applied on
  /// [set] too, `a.join(a) == a` holds for every reachable state.
  static LwwRegister<T> _collapse<T>(MvRegister<T> joined) {
    final values = joined.values;
    if (values.length <= 1) return LwwRegister._(joined);
    var winner = values.first;
    var context = const CausalContext.empty();
    for (final v in values) {
      if (v.hlc > winner.hlc) winner = v;
      context = context.merge(v.context).advance(v.hlc);
    }
    return LwwRegister._(
      MvRegister.single(winner.value, winner.hlc, context: context),
    );
  }

  @override
  LwwRegister<T> deltaCompose(LwwRegister<T> other) => join(other);

  TaggedValue<T> _winner() {
    var best = _inner.values.first;
    for (final v in _inner.values) {
      if (v.hlc > best.hlc) best = v;
    }
    return best;
  }

  @override
  bool operator ==(Object other) =>
      other is LwwRegister<T> && _inner == other._inner;

  @override
  int get hashCode => _inner.hashCode;

  @override
  String toString() => 'LwwRegister(${value ?? '∅'})';
}
