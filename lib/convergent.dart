// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

export 'src/crdt.dart';
export 'src/mutator.dart';
export 'src/pruneable.dart';
export 'src/hlc.dart';
export 'src/causal_context.dart';
export 'src/dot_set.dart';
export 'src/mv_register.dart';
export 'src/lww_register.dart';
export 'src/g_set.dart';
export 'src/or_set.dart';
export 'src/pn_counter.dart';
export 'src/crdt_map.dart';
export 'src/sequence.dart';

// Codecs (JSON-compatible serialisation).
export 'src/codec/codec.dart';
export 'src/codec/hlc_codec.dart';
export 'src/codec/causal_context_codec.dart';
export 'src/codec/dot_set_codec.dart';
export 'src/codec/mv_register_codec.dart';
export 'src/codec/lww_register_codec.dart';
export 'src/codec/g_set_codec.dart';
export 'src/codec/or_set_codec.dart';
export 'src/codec/pn_counter_codec.dart';
export 'src/codec/crdt_map_codec.dart';
export 'src/codec/sequence_codec.dart';
