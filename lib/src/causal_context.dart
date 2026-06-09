// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'hlc.dart';

/// Tracks the latest HLC seen from each node (device).
///
/// Used to determine causality between operations:
/// - If context A contains all entries from context B, then A "dominates" B
/// - If neither dominates, the operations are concurrent
class CausalContext {
  final Map<String, Hlc> _entries;

  const CausalContext._(this._entries);
  const CausalContext.empty() : _entries = const {};

  factory CausalContext.from(Map<String, Hlc> entries) =>
      CausalContext._(Map.unmodifiable(entries));

  /// Record an event from [hlc]. Returns new context.
  CausalContext advance(Hlc hlc) {
    final current = _entries[hlc.nodeId];
    if (current != null && current >= hlc) return this;
    return CausalContext._(Map.unmodifiable({..._entries, hlc.nodeId: hlc}));
  }

  /// Merge with another context. Takes max HLC per node.
  CausalContext merge(CausalContext other) {
    final merged = Map<String, Hlc>.from(_entries);
    for (final entry in other._entries.entries) {
      final current = merged[entry.key];
      if (current == null || entry.value > current) {
        merged[entry.key] = entry.value;
      }
    }
    return CausalContext._(Map.unmodifiable(merged));
  }

  /// True if this context has seen [hlc] (or a later event from the same node).
  bool contains(Hlc hlc) {
    final current = _entries[hlc.nodeId];
    return current != null && current >= hlc;
  }

  /// True if this context dominates [other] (has seen everything other has seen).
  bool dominates(CausalContext other) {
    for (final entry in other._entries.entries) {
      final ours = _entries[entry.key];
      if (ours == null || ours < entry.value) return false;
    }
    return true;
  }

  /// True if neither context dominates the other.
  bool isConcurrentWith(CausalContext other) =>
      !dominates(other) && !other.dominates(this);

  Hlc? operator [](String nodeId) => _entries[nodeId];

  Map<String, Hlc> get entries => _entries;

  /// Pack to a compact wire string: `nodeA=hlcA;nodeB=hlcB`.
  /// Empty context packs to the empty string.
  ///
  /// `nodeId` may contain `-` (HLC uses it as field separator) but must
  /// not contain `=` or `;`. Callers are expected to use opaque ids
  /// (device UUIDs, etc.) — we do not escape.
  String pack() {
    if (_entries.isEmpty) return '';
    final parts = <String>[];
    for (final entry in _entries.entries) {
      parts.add('${entry.key}=${entry.value.pack()}');
    }
    return parts.join(';');
  }

  /// Unpack from the format produced by [pack]. Tolerates the empty string.
  static CausalContext unpack(String s) {
    if (s.isEmpty) return const CausalContext.empty();
    final map = <String, Hlc>{};
    for (final part in s.split(';')) {
      final eq = part.indexOf('=');
      if (eq < 0) throw FormatException('Invalid CausalContext entry: $part');
      map[part.substring(0, eq)] = Hlc.unpack(part.substring(eq + 1));
    }
    return CausalContext.from(map);
  }

  @override
  bool operator ==(Object other) =>
      other is CausalContext && _mapEquals(_entries, other._entries);

  @override
  int get hashCode =>
      Object.hashAll(_entries.entries.map((e) => Object.hash(e.key, e.value)));

  @override
  String toString() => 'CausalContext($_entries)';
}

bool _mapEquals(Map<String, Hlc> a, Map<String, Hlc> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
