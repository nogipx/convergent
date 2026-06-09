// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../pn_counter.dart';
import 'codec.dart';

/// JSON codec for [PnCounter].
///
/// Encoded form:
/// ```json
/// {
///   "v": 1,
///   "state": { "alice": [3, 1], "bob": [5, 0] }   // nodeId -> [pos, neg]
/// }
/// ```
class PnCounterCodec implements Codec<PnCounter> {
  const PnCounterCodec();

  @override
  Object? encode(PnCounter value) {
    return <String, Object?>{
      'v': kCrdtCodecVersion,
      'state': <String, Object?>{
        for (final entry in value.state.entries)
          entry.key: [entry.value.$1, entry.value.$2],
      },
    };
  }

  @override
  PnCounter decode(Object? json) {
    final env = readEnvelope(json, kCrdtCodecVersion);
    final raw = (env['state'] as Map).cast<String, Object?>();
    final state = <String, (int, int)>{
      for (final entry in raw.entries)
        entry.key: () {
          final pair = (entry.value! as List).cast<num>();
          return (pair[0].toInt(), pair[1].toInt());
        }(),
    };
    return PnCounter.fromRaw(state);
  }
}
