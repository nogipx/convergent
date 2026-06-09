// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../hlc.dart';
import 'codec.dart';

/// Encodes [Hlc] as the compact pack-string `millis-counter-nodeId`
/// produced by [Hlc.pack]. Round-trip via [Hlc.unpack].
///
/// The string form is shorter than a structured map and preserves the
/// total ordering of HLCs lexicographically when desired.
class HlcCodec implements Codec<Hlc> {
  const HlcCodec();

  @override
  Object? encode(Hlc value) => value.pack();

  @override
  Hlc decode(Object? json) => Hlc.unpack(json! as String);
}
