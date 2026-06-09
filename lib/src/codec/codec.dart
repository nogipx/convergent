// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// A reversible encoder for a value of type [T] to / from a
/// JSON-compatible representation.
///
/// `Object?` covers any value accepted by `dart:convert.JsonCodec`:
/// `null`, `bool`, `int`, `double`, `String`, `List<Object?>`, or
/// `Map<String, Object?>`. The actual concrete type returned by
/// [encode] depends on the implementation; CRDT codecs always return
/// a `Map<String, Object?>` while primitive codecs return primitives.
///
/// Codecs are pure values: no state, no side effects, safe to share
/// across isolates.
abstract interface class Codec<T> {
  Object? encode(T value);
  T decode(Object? json);
}

// ---------------------------------------------------------------------------
// Primitive codecs
// ---------------------------------------------------------------------------

/// String passthrough.
class StringCodec implements Codec<String> {
  const StringCodec();
  @override
  Object? encode(String value) => value;
  @override
  String decode(Object? json) => json! as String;
}

/// `int` passthrough.
class IntCodec implements Codec<int> {
  const IntCodec();
  @override
  Object? encode(int value) => value;
  @override
  int decode(Object? json) => (json! as num).toInt();
}

/// `double` passthrough. Accepts any JSON number on decode so that
/// `4` and `4.0` are interchangeable on the wire.
class DoubleCodec implements Codec<double> {
  const DoubleCodec();
  @override
  Object? encode(double value) => value;
  @override
  double decode(Object? json) => (json! as num).toDouble();
}

/// `bool` passthrough.
class BoolCodec implements Codec<bool> {
  const BoolCodec();
  @override
  Object? encode(bool value) => value;
  @override
  bool decode(Object? json) => json! as bool;
}

/// Identity codec for any value that is already JSON-compatible
/// (Maps, Lists, primitives). Useful when [T] is itself a JSON
/// payload, or when the caller has already converted [T] to / from
/// JSON outside this layer.
class JsonCodec<T> implements Codec<T> {
  const JsonCodec();
  @override
  Object? encode(T value) => value;
  @override
  T decode(Object? json) => json as T;
}

// ---------------------------------------------------------------------------
// Format versioning helpers — used by every CRDT codec
// ---------------------------------------------------------------------------

/// Wire-format version embedded in every Map-shaped CRDT encoding.
/// Bumped only on incompatible schema changes.
const int kCrdtCodecVersion = 1;

/// Reads and validates the `v` field of a CRDT JSON envelope.
/// Throws [FormatException] if the value is missing or mismatched.
Map<String, Object?> readEnvelope(Object? json, int expectedVersion) {
  if (json is! Map<String, Object?>) {
    throw FormatException('Expected JSON object, got ${json.runtimeType}');
  }
  final v = json['v'];
  if (v != expectedVersion) {
    throw FormatException(
      'Unsupported codec version: expected $expectedVersion, got $v',
    );
  }
  return json;
}
