// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'crdt.dart';

/// Per-replica accumulator for Δ-state CRDT mutations.
///
/// Wraps a single CRDT instance and the pending delta produced since
/// the last [flushDelta]. The typical loop is:
///
/// ```dart
/// final mut = Mutator(initial: OrSet<String>.empty());
/// mut.applyLocal(OrSet.deltaAdd('hello', clock.tick()));
/// mut.applyLocal(OrSet.deltaAdd('world', clock.tick()));
///
/// // Ship just what we changed:
/// final delta = mut.flushDelta();
/// transport.send(codec.encode(delta));
///
/// // On the peer:
/// final remote = codec.decode(payload);
/// peerMutator.applyRemote(remote);
/// ```
///
/// The class is a thin bookkeeping helper — it does no IO, no
/// timing, no transport. Correctness follows directly from the
/// semilattice properties of [Crdt.join]: any [applyLocal] or
/// [applyRemote] is a join of the input into [_state]; the
/// accumulator just remembers the local-only joins so the caller can
/// ship them later.
class Mutator<C extends Crdt<C>> {
  Mutator({required C initial})
    : _state = initial,
      _accumulator = initial.empty;

  C _state;
  C _accumulator;

  /// Current full state after every applied join.
  C get state => _state;

  /// Pending delta accumulated since the last [flushDelta]. Reading
  /// this does not reset the accumulator.
  C get pendingDelta => _accumulator;

  /// `true` iff [_accumulator] equals the empty element — i.e. no
  /// local mutations to ship.
  bool get hasPendingDelta => _accumulator != _state.empty;

  /// Apply a locally-produced delta (typically from a `delta*`
  /// factory on the CRDT type). The delta is joined into the state
  /// **and** into the pending accumulator so it ships on the next
  /// [flushDelta].
  void applyLocal(C delta) {
    _state = _state.join(delta);
    _accumulator = _accumulator.deltaCompose(delta);
  }

  /// Apply a delta received from a peer. Joined into [_state] but
  /// NOT into the accumulator — we don't re-ship what we received.
  void applyRemote(C remoteDelta) {
    _state = _state.join(remoteDelta);
  }

  /// Returns the accumulated local delta and resets the accumulator
  /// to the empty element. Subsequent local mutations start a fresh
  /// batch.
  C flushDelta() {
    final result = _accumulator;
    _accumulator = _state.empty;
    return result;
  }

  /// Resets the accumulator without consuming the pending delta —
  /// useful when shipping fails and the caller wants to retry from
  /// the existing accumulator. Equivalent to "drop unshipped delta".
  void discardPendingDelta() {
    _accumulator = _state.empty;
  }
}
