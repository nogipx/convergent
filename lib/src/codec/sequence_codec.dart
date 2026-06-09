// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../hlc.dart';
import '../sequence.dart';
import 'codec.dart';
import 'hlc_codec.dart';

/// Codec for [Sequence] with two supported wire formats.
///
/// **v3 (default, emitted by [encode])** — compact array form with a
/// per-blob node-id dictionary. Most of v1's bytes were duplicated
/// long device-id strings repeated in every `id` and `parent` field;
/// v3 interns them into a single table and references by integer
/// index. On text-seeded files (every entry shares the
/// shared seed node id) this cuts blob size 5–10×.
///
/// ```json
/// {
///   "v": 3,
///   "n": ["device-A", "device-B"],          // node-id dictionary
///   "c": [
///     [idMs, idCnt, idIdx,
///      parentMs|null, parentCnt|null, parentIdx|null,
///      side(0=l, 1=r),
///      <encoded value>,
///      1 (optional, present only when tombstoned)],
///     ...
///   ]
/// }
/// ```
///
/// **v1 (legacy, accepted by [decode])** — older nested-object form
/// from when the codec used [kCrdtCodecVersion]'s envelope helper.
/// Kept so blobs persisted by pre-v3 clients still load cleanly:
///
/// ```json
/// {
///   "v": 1,
///   "chars": [
///     {"id":"ms-c-node","parent":"…"|null,"side":"l"|"r",
///      "value":<T>,"tomb":true?},
///     ...
///   ]
/// }
/// ```
///
/// Both forms preserve the full Δ-state: id, parent linkage, side,
/// value, and tombstone bit per entry. The receiver always rebuilds
/// the same position tree regardless of which form was used to ship.
class SequenceCodec<T> implements Codec<Sequence<T>> {
  const SequenceCodec(this._element);

  final Codec<T> _element;
  static const _hlc = HlcCodec();

  /// Format version emitted by [encode]. Bumped when the wire shape
  /// changes; [decode] still accepts every previously-shipped version.
  static const int formatVersion = 3;

  @override
  Object? encode(Sequence<T> value) {
    final entries = value.entries.values;
    // Build the node-id dictionary in observation order (deterministic
    // for the same input). Both the entry's own dot and its parent
    // contribute, since either can introduce a new node.
    final nodeIdx = <String, int>{};
    final nodes = <String>[];
    int internNode(String n) {
      var i = nodeIdx[n];
      if (i != null) return i;
      i = nodes.length;
      nodes.add(n);
      nodeIdx[n] = i;
      return i;
    }

    final rows = <List<Object?>>[];
    for (final e in entries) {
      final row = <Object?>[e.id.millis, e.id.counter, internNode(e.id.nodeId)];
      final p = e.parent;
      if (p != null) {
        row
          ..add(p.millis)
          ..add(p.counter)
          ..add(internNode(p.nodeId));
      } else {
        row
          ..add(null)
          ..add(null)
          ..add(null);
      }
      row
        ..add(e.side == SequenceSide.left ? 0 : 1)
        ..add(_element.encode(e.value));
      if (e.tombstoned) row.add(1);
      rows.add(row);
    }
    return <String, Object?>{'v': formatVersion, 'n': nodes, 'c': rows};
  }

  @override
  Sequence<T> decode(Object? json) {
    if (json is! Map) {
      throw FormatException('Expected JSON object, got ${json.runtimeType}');
    }
    final v = json['v'];
    if (v == 3) return _decodeV3(json);
    if (v == 1) return _decodeV1(json);
    throw FormatException(
      'Unsupported Sequence codec version: $v (supported: 1, 3)',
    );
  }

  Sequence<T> _decodeV3(Map<dynamic, dynamic> env) {
    final nodes = (env['n'] as List).cast<String>();
    final rows = env['c'] as List;
    final entries = <Hlc, SeqEntry<T>>{};
    for (final row in rows) {
      final r = row as List;
      final id = Hlc(
        (r[0] as num).toInt(),
        (r[1] as num).toInt(),
        nodes[(r[2] as num).toInt()],
      );
      Hlc? parent;
      if (r[3] != null) {
        parent = Hlc(
          (r[3] as num).toInt(),
          (r[4] as num).toInt(),
          nodes[(r[5] as num).toInt()],
        );
      }
      final side = (r[6] as num).toInt() == 0
          ? SequenceSide.left
          : SequenceSide.right;
      final value = _element.decode(r[7]);
      final tomb = r.length > 8 && r[8] == 1;
      entries[id] = SeqEntry<T>(
        id: id,
        parent: parent,
        side: side,
        value: value,
        tombstoned: tomb,
      );
    }
    return Sequence<T>.fromRaw(entries);
  }

  Sequence<T> _decodeV1(Map<dynamic, dynamic> env) {
    final raw = env['chars'] as List;
    final entries = <Hlc, SeqEntry<T>>{};
    for (final r in raw) {
      final m = r as Map;
      final id = _hlc.decode(m['id']);
      final parentRaw = m['parent'];
      final parent = parentRaw == null ? null : _hlc.decode(parentRaw);
      final side = (m['side'] as String) == 'l'
          ? SequenceSide.left
          : SequenceSide.right;
      final value = _element.decode(m['value']);
      final tomb = (m['tomb'] as bool?) ?? false;
      entries[id] = SeqEntry<T>(
        id: id,
        parent: parent,
        side: side,
        value: value,
        tombstoned: tomb,
      );
    }
    return Sequence<T>.fromRaw(entries);
  }
}
