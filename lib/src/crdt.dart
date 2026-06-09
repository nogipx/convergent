// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Common interface for every CRDT in this package.
///
/// **Required operations:**
///
/// - [join] — the semilattice cross-replica merge. Commutative,
///   associative, idempotent. Two replicas that observe the same
///   set of states (in any order) converge to the same value.
/// - [empty] — identity element of the join-semilattice (the
///   bottom). `a.join(empty) == a` for every `a`. Used as the seed
///   for delta accumulators and as the "nothing to ship" sentinel.
/// - [deltaCompose] — combines two **locally-produced** Δ-state
///   fragments from the same replica before shipping. For most
///   types this coincides with [join]; only types whose
///   cross-replica join applies tombstone-style filtering or
///   max-reduction (notably `OrSet` and `PnCounter`) override.
///
/// `Self extends Crdt<Self>` is F-bounded polymorphism: it lets
/// generic containers (notably `CrdtMap<K, V>`) require their value
/// type to expose `join`/`empty`/`deltaCompose` returning the same
/// type, not a supertype.
abstract interface class Crdt<Self extends Crdt<Self>> {
  /// Cross-replica merge. Must be commutative, associative,
  /// idempotent.
  Self join(Self other);

  /// Identity element of the join-semilattice.
  /// `a.join(empty) == a` for every `a`.
  Self get empty;

  /// Composes two locally-produced Δ-state fragments. For most
  /// CRDT types this coincides with [join]. Override when the
  /// cross-replica join applies filters (tombstone semantics, max
  /// reduction) that would be wrong for in-replica delta
  /// accumulation.
  Self deltaCompose(Self other);
}
