// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../lww_register.dart';
import 'codec.dart';
import 'mv_register_codec.dart';

/// JSON codec for [LwwRegister].
///
/// Encoded form is identical to [MvRegisterCodec] — `LwwRegister` is
/// a thin wrapper that picks the winning [TaggedValue] from an inner
/// `MvRegister<T>`. Internally-tracked concurrent writes survive a
/// round-trip; the externally observable `value` stays the same.
class LwwRegisterCodec<T> implements Codec<LwwRegister<T>> {
  LwwRegisterCodec(Codec<T> payload) : _inner = MvRegisterCodec<T>(payload);

  final MvRegisterCodec<T> _inner;

  @override
  Object? encode(LwwRegister<T> value) => _inner.encode(value.inner);

  @override
  LwwRegister<T> decode(Object? json) =>
      LwwRegister<T>.fromInner(_inner.decode(json));
}
