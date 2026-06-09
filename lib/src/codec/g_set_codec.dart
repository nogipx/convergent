// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../g_set.dart';
import 'codec.dart';

/// JSON codec for [GSet].
///
/// Encoded form:
/// ```json
/// { "v": 1, "values": [<encoded T>, ...] }
/// ```
class GSetCodec<T> implements Codec<GSet<T>> {
  const GSetCodec(this._element);

  final Codec<T> _element;

  @override
  Object? encode(GSet<T> value) => <String, Object?>{
    'v': kCrdtCodecVersion,
    'values': value.values.map(_element.encode).toList(),
  };

  @override
  GSet<T> decode(Object? json) {
    final env = readEnvelope(json, kCrdtCodecVersion);
    final raw = (env['values'] as List).map(_element.decode);
    return GSet<T>.from(raw);
  }
}
