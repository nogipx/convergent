// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../codec/codec.dart';
import 'fugue.dart';

/// JSON codec for a [Fugue] list, matching the library's [Codec] convention.
///
/// Delegates per-element (de)serialisation to [element]; the block/run-length
/// framing is provided by [Fugue.encode] / [Fugue.decode]. One row per block,
/// so a contiguous run serialises to a single entry.
class FugueCodec<T> implements Codec<Fugue<T>> {
  /// Wraps an [element] codec for the value type [T].
  const FugueCodec(this.element);

  /// Codec for a single element value.
  final Codec<T> element;

  @override
  Object? encode(Fugue<T> value) => value.encode(element.encode);

  @override
  Fugue<T> decode(Object? json) => Fugue.decode<T>(json!, element.decode);
}
