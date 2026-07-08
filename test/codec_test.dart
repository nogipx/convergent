// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';

import 'package:convergent/convergent.dart';
import 'package:test/test.dart';

/// Round-trips [value] through [codec], asserts equality, and also
/// proves the encoded form is real JSON by running it through
/// `dart:convert`.
T _roundTrip<T>(Codec<T> codec, T value) {
  final encoded = codec.encode(value);
  final asJsonString = jsonEncode(encoded);
  final decoded = codec.decode(jsonDecode(asJsonString));
  return decoded;
}

void main() {
  final a = Hlc(100, 0, 'alice');
  final b = Hlc(200, 0, 'bob');

  group('HlcCodec', () {
    test('round-trip', () {
      const codec = HlcCodec();
      expect(_roundTrip(codec, a), a);
      expect(_roundTrip(codec, b), b);
      expect(_roundTrip(codec, Hlc(0, 0, 'x')), Hlc(0, 0, 'x'));
    });
  });

  group('CausalContextCodec', () {
    test('empty round-trip', () {
      const codec = CausalContextCodec();
      expect(
        _roundTrip(codec, const CausalContext.empty()),
        const CausalContext.empty(),
      );
    });

    test('non-empty round-trip', () {
      const codec = CausalContextCodec();
      final ctx = const CausalContext.empty().advance(a).advance(b);
      expect(_roundTrip(codec, ctx), ctx);
    });
  });

  group('MvRegisterCodec', () {
    test('empty round-trip', () {
      final codec = MvRegisterCodec<String>(const StringCodec());
      expect(
        _roundTrip(codec, MvRegister<String>.empty()),
        MvRegister<String>.empty(),
      );
    });

    test('concurrent values round-trip', () {
      final codec = MvRegisterCodec<String>(const StringCodec());
      final r = MvRegister<String>.empty()
          .set('a', a, const CausalContext.empty())
          .set('b', b, const CausalContext.empty());
      final decoded = _roundTrip(codec, r);
      expect(decoded.values, r.values);
      expect(decoded.hasConflict, isTrue);
    });

    test('preserves embedded TaggedValue contexts', () {
      final codec = MvRegisterCodec<int>(const IntCodec());
      final ctx = const CausalContext.empty().advance(a);
      final r = MvRegister.single(42, b, context: ctx);
      final decoded = _roundTrip(codec, r);
      expect(decoded, r);
      expect(decoded.values.first.context, ctx);
    });
  });

  group('LwwRegisterCodec', () {
    test('round-trip preserves winner', () {
      final codec = LwwRegisterCodec<String>(const StringCodec());
      final r = LwwRegister.single('hello', a);
      final decoded = _roundTrip(codec, r);
      expect(decoded.value, 'hello');
      expect(decoded.hlc, a);
    });
  });

  group('GSetCodec', () {
    test('empty round-trip', () {
      const codec = GSetCodec<String>(StringCodec());
      expect(_roundTrip(codec, GSet<String>.empty()), GSet<String>.empty());
    });

    test('multi-element round-trip', () {
      const codec = GSetCodec<int>(IntCodec());
      final s = GSet<int>.from([1, 2, 3]);
      expect(_roundTrip(codec, s), s);
    });
  });

  group('OrSetCodec', () {
    test('empty round-trip', () {
      const codec = OrSetCodec<String>(StringCodec());
      expect(_roundTrip(codec, OrSet<String>.empty()), OrSet<String>.empty());
    });

    test('preserves causal context after add/remove cycles', () {
      const codec = OrSetCodec<String>(StringCodec());
      final s = OrSet<String>.empty().add('x', a).add('y', b).remove('x');
      final decoded = _roundTrip(codec, s);
      expect(decoded.values, {'y'});
      // Stale replica re-sends an old dot — must be dropped because
      // context survived the round-trip.
      final stale = OrSet<String>.empty().add('x', a);
      expect(decoded.join(stale).values, {'y'});
    });
  });

  group('PnCounterCodec', () {
    test('round-trip', () {
      const codec = PnCounterCodec();
      final c = PnCounter.empty()
          .increment(a, 5)
          .decrement(a, 1)
          .increment(b, 3);
      final decoded = _roundTrip(codec, c);
      expect(decoded.value, 7);
      expect(decoded, c);
    });
  });

  group('CrdtMapCodec', () {
    test('nested CRDTs round-trip', () {
      const codec = CrdtMapCodec<String, GSet<int>>(
        keyCodec: StringCodec(),
        valueCodec: GSetCodec<int>(IntCodec()),
      );
      final m = CrdtMap<String, GSet<int>>.empty()
          .put('a', GSet<int>.from([1, 2]))
          .put('b', GSet<int>.from([3]));
      final decoded = _roundTrip(codec, m);
      expect(decoded['a']!.values, {1, 2});
      expect(decoded['b']!.values, {3});
    });
  });
}
