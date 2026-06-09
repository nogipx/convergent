// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'crdt.dart';

/// A map of CRDTs: each value is itself a CRDT, joined per-key on
/// merge.
///
/// `V extends Crdt<V>` (F-bounded) — any Δ-state CRDT from this
/// package (`MvRegister`, `LwwRegister`, `GSet`, `OrSet`, `PnCounter`,
/// or a nested `CrdtMap`) qualifies. The Δ-state constraint lets
/// `CrdtMap` itself produce single-key deltas (see [deltaPut]).
///
/// Keys are not CRDTs and never disappear: adding a key on one
/// replica means it exists on every replica that observes that delta.
/// To delete keys, store an `OrSet<K>` alongside (or wrap values in
/// `OrSet`/`LwwRegister<V?>` patterns).
class CrdtMap<K, V extends Crdt<V>> implements Crdt<CrdtMap<K, V>> {
  final Map<K, V> _entries;

  const CrdtMap._(this._entries);

  CrdtMap.empty() : _entries = const {};

  /// Reconstructs a map from a plain `Map<K, V>`. Used by codecs and
  /// tests. Unlike [put], does not join — the caller is responsible
  /// for any prior consolidation.
  factory CrdtMap.fromRaw(Map<K, V> entries) =>
      CrdtMap._(Map.unmodifiable(entries));

  Iterable<K> get keys => _entries.keys;
  Iterable<V> get values => _entries.values;
  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;
  bool containsKey(K key) => _entries.containsKey(key);

  V? operator [](K key) => _entries[key];

  /// Put a value at [key]. If a value already exists, joins the
  /// existing and incoming CRDTs — never blindly overwrites.
  CrdtMap<K, V> put(K key, V value) {
    final existing = _entries[key];
    final merged = existing == null ? value : existing.join(value);
    return CrdtMap._(Map.unmodifiable({..._entries, key: merged}));
  }

  /// Δ-state delta: a singleton map binding one key to a value
  /// (typically itself a delta produced by the value type's
  /// `delta*` factory).
  static CrdtMap<K, V> deltaPut<K, V extends Crdt<V>>(K key, V value) =>
      CrdtMap<K, V>._(Map.unmodifiable({key: value}));

  @override
  CrdtMap<K, V> get empty => CrdtMap<K, V>.empty();

  @override
  CrdtMap<K, V> join(CrdtMap<K, V> other) {
    final allKeys = {..._entries.keys, ...other._entries.keys};
    final merged = <K, V>{};
    for (final k in allKeys) {
      final a = _entries[k];
      final b = other._entries[k];
      if (a == null) {
        merged[k] = b!;
      } else if (b == null) {
        merged[k] = a;
      } else {
        merged[k] = a.join(b);
      }
    }
    return CrdtMap._(Map.unmodifiable(merged));
  }

  /// Per-key [Crdt.deltaCompose] — the right thing whenever the
  /// value type's own composition differs from its `join` (so e.g.
  /// nested `OrSet` or `PnCounter` values compose correctly).
  @override
  CrdtMap<K, V> deltaCompose(CrdtMap<K, V> other) {
    final allKeys = {..._entries.keys, ...other._entries.keys};
    final merged = <K, V>{};
    for (final k in allKeys) {
      final a = _entries[k];
      final b = other._entries[k];
      if (a == null) {
        merged[k] = b!;
      } else if (b == null) {
        merged[k] = a;
      } else {
        merged[k] = a.deltaCompose(b);
      }
    }
    return CrdtMap._(Map.unmodifiable(merged));
  }

  @override
  bool operator ==(Object other) {
    if (other is! CrdtMap<K, V>) return false;
    if (_entries.length != other._entries.length) return false;
    for (final entry in _entries.entries) {
      final there = other._entries[entry.key];
      if (there == null || there != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    var h = 0;
    for (final entry in _entries.entries) {
      h ^= Object.hash(entry.key, entry.value);
    }
    return h;
  }

  @override
  String toString() => 'CrdtMap($_entries)';
}
