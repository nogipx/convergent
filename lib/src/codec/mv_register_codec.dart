// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../mv_register.dart';
import 'causal_context_codec.dart';
import 'codec.dart';
import 'hlc_codec.dart';

/// JSON codec for [MvRegister].
///
/// Encoded form:
/// ```json
/// {
///   "v": 1,
///   "values": [
///     { "value": <encoded T>, "hlc": "ms-c-node", "ctx": "..." },
///     ...
///   ]
/// }
/// ```
///
/// Every internally-tracked [TaggedValue] is preserved so that
/// concurrent edits survive a round-trip.
class MvRegisterCodec<T> implements Codec<MvRegister<T>> {
  const MvRegisterCodec(this._payload);

  final Codec<T> _payload;
  static const _hlc = HlcCodec();
  static const _ctx = CausalContextCodec();

  @override
  Object? encode(MvRegister<T> value) {
    return <String, Object?>{
      'v': kCrdtCodecVersion,
      'values': [
        for (final tv in value.values)
          <String, Object?>{
            'value': _payload.encode(tv.value),
            'hlc': _hlc.encode(tv.hlc),
            'ctx': _ctx.encode(tv.context),
          },
      ],
    };
  }

  @override
  MvRegister<T> decode(Object? json) {
    final env = readEnvelope(json, kCrdtCodecVersion);
    final raw = (env['values'] as List).cast<Map<String, Object?>>();
    final values = <TaggedValue<T>>{};
    for (final e in raw) {
      values.add(
        TaggedValue<T>(
          _payload.decode(e['value']),
          _hlc.decode(e['hlc']),
          context: _ctx.decode(e['ctx']),
        ),
      );
    }
    return MvRegister<T>.fromValues(values);
  }
}
