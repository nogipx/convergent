// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../dot_set.dart';
import 'codec.dart';

/// Encodes a [DotSet] via its native [DotSet.pack] / [DotSet.unpack]
/// string form. Wire form is `hlc1;hlc2;hlc3`, empty set packs to
/// the empty string.
class DotSetCodec implements Codec<DotSet> {
  const DotSetCodec();

  @override
  Object? encode(DotSet value) => value.pack();

  @override
  DotSet decode(Object? json) => DotSet.unpack(json! as String);
}
