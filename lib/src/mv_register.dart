// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'causal_context.dart';
import 'crdt.dart';
import 'hlc.dart';

/// A single tagged value in an MV-Register.
///
/// Carries the writer's [hlc] plus the [context] the writer had seen at
/// write time. The context is what lets a pure 2-arg [MvRegister.join]
/// compute dominance without external bookkeeping (§4.1/§4.2 of the
/// Δ-state CRDT design doc).
///
/// Identity is `(value, hlc)` — [context] is metadata for dominance and
/// is intentionally excluded from equality/hash so that
/// `a.join(a) == a` holds (idempotency).
class TaggedValue<T> {
  final T value;
  final Hlc hlc;
  final CausalContext context;

  const TaggedValue(
    this.value,
    this.hlc, {
    this.context = const CausalContext.empty(),
  });

  @override
  bool operator ==(Object other) =>
      other is TaggedValue<T> && value == other.value && hlc == other.hlc;

  @override
  int get hashCode => Object.hash(value, hlc);

  @override
  String toString() => 'TaggedValue($value, $hlc, ctx=$context)';
}

/// Multi-Value Register.
///
/// Stores one value per writer. On concurrent writes, keeps ALL values
/// (the application layer resolves the conflict). On causal writes
/// (writer has seen previous value), supersedes it.
///
/// This is the core CRDT primitive. Everything else is built on top.
class MvRegister<T> implements Crdt<MvRegister<T>> {
  final Set<TaggedValue<T>> _values;

  const MvRegister._(this._values);

  /// Build from a set of TaggedValues. The set is canonicalised: any
  /// value dominated by another value's [TaggedValue.context] in the set
  /// is dropped. This preserves the invariant that a register never
  /// contains a value already superseded by another — required for
  /// `join`'s idempotency on the public surface.
  factory MvRegister.fromValues(Set<TaggedValue<T>> values) =>
      MvRegister._(_canonicalise(values));

  MvRegister.empty() : _values = {};

  static Set<TaggedValue<T>> _canonicalise<T>(Set<TaggedValue<T>> values) {
    final survivors = <TaggedValue<T>>{};
    for (final v in values) {
      var dominated = false;
      for (final w in values) {
        if (w.hlc != v.hlc && w.context.contains(v.hlc)) {
          dominated = true;
          break;
        }
      }
      if (!dominated) survivors.add(v);
    }
    return survivors;
  }

  factory MvRegister.single(T value, Hlc hlc, {CausalContext? context}) =>
      MvRegister._({
        TaggedValue(
          value,
          hlc,
          context: context ?? const CausalContext.empty(),
        ),
      });

  /// All current values. Multiple values = conflict.
  Set<TaggedValue<T>> get values => _values;

  /// True if there are concurrent values (conflict).
  bool get hasConflict => _values.length > 1;

  /// The single value if no conflict, null otherwise.
  T? get singleValue => _values.length == 1 ? _values.first.value : null;

  /// All values without tags (for application-level conflict resolution).
  List<T> get allValues => _values.map((v) => v.value).toList();

  /// Write a new value. The [writerContext] determines which existing
  /// values are superseded (causally dominated) and which are concurrent.
  ///
  /// The new TaggedValue carries [writerContext] so that subsequent pure
  /// [join]s can drop values dominated by this write.
  MvRegister<T> set(T value, Hlc hlc, CausalContext writerContext) {
    // Fold the context of every value this write supersedes into the stored
    // context. Dominance is judged per-value via the embedded context, so if
    // the new write's context named a superseded value's hlc but not the
    // (transitively) older values THAT value had itself superseded, join
    // order could change the survivor set (join is only associative when
    // dominance is transitively closed). Absorbing each superseded value's
    // context (and its hlc) makes the stored context transitively closed by
    // construction.
    var ctx = writerContext;
    final surviving = <TaggedValue<T>>{};
    for (final v in _values) {
      if (writerContext.contains(v.hlc)) {
        ctx = ctx.merge(v.context).advance(v.hlc);
      } else {
        surviving.add(v);
      }
    }
    surviving.add(TaggedValue(value, hlc, context: ctx));
    return MvRegister._(surviving);
  }

  /// Δ-state delta: a singleton register carrying the new write.
  /// Joining this into a peer's register has the same effect as
  /// calling `set(value, hlc, writerContext)` on the peer.
  ///
  /// Caller invariant: unlike [set], this cannot see the values it
  /// supersedes, so the supplied [writerContext] must already dominate the
  /// contexts of every value the write supersedes — not merely name their
  /// hlcs. Maintaining a device-level context by merging the embedded
  /// contexts of every value ever observed satisfies this; a context that
  /// only advances by observed value hlcs does not, and joining the
  /// resulting delta is no longer associative (see [set]).
  static MvRegister<T> deltaSet<T>(
    T value,
    Hlc hlc,
    CausalContext writerContext,
  ) => MvRegister<T>._({TaggedValue<T>(value, hlc, context: writerContext)});

  @override
  MvRegister<T> get empty => MvRegister<T>.empty();

  /// Δ-state CRDT join per doc §4.2.
  ///
  /// Pure 2-arg semilattice operation. Commutative, associative,
  /// idempotent. Each [TaggedValue] carries its own context, so dominance
  /// can be computed from the union alone.
  ///
  /// Algorithm:
  /// 1. U = self.values ∪ other.values
  /// 2. Drop every v ∈ U for which there exists w ∈ U with
  ///    w.hlc ≠ v.hlc and w.context.contains(v.hlc).
  /// 3. Return the remaining values.
  @override
  MvRegister<T> join(MvRegister<T> other) {
    final union = {..._values, ...other._values};
    final survivors = <TaggedValue<T>>{};
    for (final v in union) {
      var dominated = false;
      for (final w in union) {
        if (w.hlc != v.hlc && w.context.contains(v.hlc)) {
          dominated = true;
          break;
        }
      }
      if (!dominated) survivors.add(v);
    }
    return MvRegister._(survivors);
  }

  @override
  MvRegister<T> deltaCompose(MvRegister<T> other) => join(other);

  @override
  bool operator ==(Object other) {
    if (other is! MvRegister<T>) return false;
    if (_values.length != other._values.length) return false;
    return _values.containsAll(other._values);
  }

  @override
  int get hashCode => Object.hashAllUnordered(_values);

  @override
  String toString() => 'MvRegister($_values)';
}
