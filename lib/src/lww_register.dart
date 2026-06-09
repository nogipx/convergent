// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'causal_context.dart';
import 'crdt.dart';
import 'hlc.dart';
import 'mv_register.dart';

/// Last-Writer-Wins register.
///
/// Single-value CRDT built on top of [MvRegister]. Concurrent writes
/// are stored internally but [value] always returns the winner under a
/// deterministic total order: the [TaggedValue] with the highest
/// [Hlc]. `Hlc.compareTo` breaks ties by `nodeId`, so the choice is
/// the same on every replica.
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
  LwwRegister<T> set(T value, Hlc hlc, CausalContext context) =>
      LwwRegister._(_inner.set(value, hlc, context));

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
      LwwRegister._(_inner.join(other._inner));

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
