// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dot_set.dart';

/// Tombstone GC interface — drop causally-stable dots from a CRDT's
/// context.
///
/// **Why.** Δ-state CRDTs with an explicit dot-set causal context
/// (notably [OrSet]) keep every observed dot forever. As writes and
/// removes pile up, the context grows linearly with history.
///
/// **Causal stability** (Almeida 2018 §5; Bauwens & Boix 2023). Once
/// *every* replica has observed dot `d` AND `d` is no longer
/// referenced by any live entry in the state, no future operation
/// can change the meaning of `d` — neither as a survivor nor as an
/// emergent tombstone. The dot is safe to drop from the context
/// without affecting convergence.
///
/// **What [prune] does.** Given a [DotSet] [stable] describing dots
/// known to have been observed by every replica, returns a smaller
/// equivalent state with those stable dots that are NOT in the live
/// dot-store removed from the context. Live entries (and dots they
/// reference) are always preserved.
///
/// **Watermark computation is out of scope.** Computing the stable
/// dot-set is an application-level distributed-systems problem —
/// some options:
///
/// - **Epoch / round protocol**: every replica periodically reports
///   the highest contiguous dot it has observed; the meet is stable.
/// - **All-have-acked watermark**: each replica reports `lastSeenDot`
///   per peer; the per-replica minimum across peers is stable.
/// - **Server-mediated**: a central coordinator tracks consumer
///   cursors and broadcasts the meet.
///
/// The library exposes the pruning operation; the caller decides
/// when and what to prune.
abstract interface class Pruneable<Self> {
  /// Returns an equivalent state with [stable] dots dropped from the
  /// causal context, **except** those still referenced by a live
  /// entry in the state.
  ///
  /// Caller invariant: every replica must have observed every dot in
  /// [stable] AND no future write may reference a dot in [stable]
  /// from an ancestral state. If this invariant is violated,
  /// convergence is no longer guaranteed across the pruned and
  /// unpruned replicas.
  Self prune(DotSet stable);
}
