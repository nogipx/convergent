// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../or_set.dart';
import 'codec.dart';
import 'dot_set_codec.dart';
import 'hlc_codec.dart';

/// JSON codec for [OrSet].
///
/// Encoded form:
/// ```json
/// {
///   "v": 1,
///   "dots": [ { "value": <encoded T>, "hlc": "ms-c-node" }, ... ],
///   "ctx":  "hlc1;hlc2;hlc3"
/// }
/// ```
///
/// Preserves the full Δ-state of the set: the dot store plus the
/// explicit dot-set context, so emergent tombstones survive the
/// round-trip.
class OrSetCodec<T> implements Codec<OrSet<T>> {
  const OrSetCodec(this._element);

  final Codec<T> _element;
  static const _hlc = HlcCodec();
  static const _ctx = DotSetCodec();

  @override
  Object? encode(OrSet<T> value) {
    return <String, Object?>{
      'v': kCrdtCodecVersion,
      'dots': [
        for (final d in value.dots)
          <String, Object?>{
            'value': _element.encode(d.value),
            'hlc': _hlc.encode(d.hlc),
          },
      ],
      'ctx': _ctx.encode(value.context),
    };
  }

  @override
  OrSet<T> decode(Object? json) {
    final env = readEnvelope(json, kCrdtCodecVersion);
    final dotsRaw = (env['dots'] as List).cast<Map<String, Object?>>();
    final dots = <Dot<T>>[
      for (final d in dotsRaw)
        Dot<T>(_element.decode(d['value']), _hlc.decode(d['hlc'])),
    ];
    final ctx = _ctx.decode(env['ctx']);
    return OrSet<T>.fromDots(dots, ctx);
  }
}
