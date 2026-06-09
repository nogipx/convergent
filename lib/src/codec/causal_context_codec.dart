// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../causal_context.dart';
import 'codec.dart';

/// Encodes [CausalContext] using its native [CausalContext.pack]
/// string format. Round-trip via [CausalContext.unpack].
///
/// Wire form: `nodeA=hlcA;nodeB=hlcB`. Empty contexts pack to the
/// empty string.
class CausalContextCodec implements Codec<CausalContext> {
  const CausalContextCodec();

  @override
  Object? encode(CausalContext value) => value.pack();

  @override
  CausalContext decode(Object? json) => CausalContext.unpack(json! as String);
}
