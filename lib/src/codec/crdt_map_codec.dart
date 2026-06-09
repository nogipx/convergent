// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../crdt_map.dart';
import '../crdt.dart';
import 'codec.dart';

/// JSON codec for [CrdtMap].
///
/// Keys are encoded via the supplied [Codec<K>] (which may produce
/// any JSON value, including non-strings), so entries are stored as a
/// list of `[encodedKey, encodedValue]` pairs rather than as a JSON
/// object:
///
/// ```json
/// {
///   "v": 1,
///   "entries": [
///     [<encoded K>, <encoded V>],
///     ...
///   ]
/// }
/// ```
class CrdtMapCodec<K, V extends Crdt<V>> implements Codec<CrdtMap<K, V>> {
  const CrdtMapCodec({required Codec<K> keyCodec, required Codec<V> valueCodec})
    : _key = keyCodec,
      _value = valueCodec;

  final Codec<K> _key;
  final Codec<V> _value;

  @override
  Object? encode(CrdtMap<K, V> value) {
    return <String, Object?>{
      'v': kCrdtCodecVersion,
      'entries': [
        for (final k in value.keys)
          [_key.encode(k), _value.encode(value[k] as V)],
      ],
    };
  }

  @override
  CrdtMap<K, V> decode(Object? json) {
    final env = readEnvelope(json, kCrdtCodecVersion);
    final raw = (env['entries'] as List).cast<List<Object?>>();
    final entries = <K, V>{
      for (final pair in raw) _key.decode(pair[0]): _value.decode(pair[1]),
    };
    return CrdtMap<K, V>.fromRaw(entries);
  }
}
