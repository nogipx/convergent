// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'dot.dart';
import 'fugue.dart';

/// Compact, fast binary codec for a text [Fugue] (`Fugue<String>`).
///
/// Format (all integers unsigned LEB128 varints):
///
/// ```
/// u8      version (1)
/// varint  R = replica count
/// R×      [varint len][UTF-8 replica id]        // interned dictionary
/// varint  B = block count
/// B×      varint  start replica index
///         varint  start counter
///         u8      flags: bit0 = side (0=left,1=right), bit7 = parent is origin
///         if !origin: varint parent replica index, varint parent counter
///         varint  UTF-8 byte length of the run
///         …bytes  the run's values joined as one UTF-8 string
///         varint  element count
///         varint  D = deleted-range count
///         D×      varint start, varint len
/// ```
///
/// Replica interning + varints + one packed UTF-8 string per run make this
/// several times smaller and faster than JSON, which repeats the replica id
/// in every block and stores each character as its own string.
///
/// Assumes each element is a single Unicode scalar (as produced by char-level
/// text editing): a run is joined and split by runes.
class FugueTextBinaryCodec {
  const FugueTextBinaryCodec();

  /// Encode [f] to a compact byte buffer.
  Uint8List encode(Fugue<String> f) {
    final blocks = f.rawBlocks.toList(growable: false);

    // Intern replica ids in first-seen order.
    final index = <String, int>{};
    int rid(String r) => index.putIfAbsent(r, () => index.length);
    for (final b in blocks) {
      rid(b.$1.replica); // start
      if (!b.$2.isOrigin) rid(b.$2.replica); // parent
    }
    final dict = List<String>.filled(index.length, '');
    index.forEach((r, i) => dict[i] = r);

    final out = BytesBuilder(copy: false);
    out.addByte(1);
    _varint(out, dict.length);
    for (final r in dict) {
      final b = utf8.encode(r);
      _varint(out, b.length);
      out.add(b);
    }
    _varint(out, blocks.length);
    for (final (start, parent, side, values, del) in blocks) {
      _varint(out, rid(start.replica));
      _varint(out, start.counter);
      final origin = parent.isOrigin;
      out.addByte((side == Side.right ? 1 : 0) | (origin ? 0x80 : 0));
      if (!origin) {
        _varint(out, rid(parent.replica));
        _varint(out, parent.counter);
      }
      final runBytes = utf8.encode(values.join());
      _varint(out, runBytes.length);
      out.add(runBytes);
      _varint(out, values.length);
      _varint(out, del.length ~/ 2);
      for (var i = 0; i + 1 < del.length; i += 2) {
        _varint(out, del[i]);
        _varint(out, del[i + 1]);
      }
    }
    return out.toBytes();
  }

  /// Decode a buffer produced by [encode].
  Fugue<String> decode(Uint8List bytes) {
    final r = _Reader(bytes);
    final version = r.u8();
    if (version != 1) {
      throw FormatException('Unsupported Fugue binary version: $version');
    }
    final replicaCount = r.varint();
    final dict = <String>[
      for (var i = 0; i < replicaCount; i++) utf8.decode(r.take(r.varint())),
    ];

    final blockCount = r.varint();
    final blocks = <(Dot, Dot, Side, List<String>, List<int>)>[];
    for (var i = 0; i < blockCount; i++) {
      final startReplica = dict[r.varint()];
      final startCounter = r.varint();
      final flags = r.u8();
      final side = (flags & 1) == 1 ? Side.right : Side.left;
      final origin = (flags & 0x80) != 0;
      final Dot parent;
      if (origin) {
        parent = Dot.origin;
      } else {
        final parentReplica = dict[r.varint()];
        final parentCounter = r.varint();
        parent = Dot(parentCounter, parentReplica);
      }
      final text = utf8.decode(r.take(r.varint()));
      r.varint(); // element count (elements recovered from runes)
      final values = <String>[
        for (final rune in text.runes) String.fromCharCode(rune),
      ];
      final delCount = r.varint();
      final del = <int>[for (var j = 0; j < delCount * 2; j++) r.varint()];
      blocks.add((Dot(startCounter, startReplica), parent, side, values, del));
    }
    return Fugue.fromRawBlocks<String>(blocks);
  }
}

void _varint(BytesBuilder out, int value) {
  var v = value;
  while (v >= 0x80) {
    out.addByte((v & 0x7f) | 0x80);
    v >>= 7;
  }
  out.addByte(v);
}

class _Reader {
  _Reader(this._d);
  final Uint8List _d;
  int _p = 0;

  int u8() => _d[_p++];

  int varint() {
    var shift = 0;
    var result = 0;
    while (true) {
      final byte = _d[_p++];
      result |= (byte & 0x7f) << shift;
      if (byte < 0x80) return result;
      shift += 7;
    }
  }

  Uint8List take(int n) {
    final s = Uint8List.sublistView(_d, _p, _p + n);
    _p += n;
    return s;
  }
}
