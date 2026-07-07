// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// The optimised block-based Fugue list CRDT.
///
/// A separate entrypoint from `package:convergent/convergent.dart` because
/// Fugue uses its own logical [Dot] identity (a `(replica, counter)` pair),
/// distinct from the HLC-based dots the rest of the library uses.
library;

export 'src/codec/codec.dart' show Codec, StringCodec, IntCodec, DoubleCodec, BoolCodec, JsonCodec;
export 'src/fugue/dot.dart';
export 'src/fugue/fugue.dart';
export 'src/fugue/fugue_codec.dart';
export 'src/fugue/fugue_binary.dart';
