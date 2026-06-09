// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:convergent/convergent.dart';
import 'package:test/test.dart';

void main() {
  group('LwwRegister', () {
    test('empty register has null value', () {
      expect(LwwRegister<int>.empty().value, isNull);
      expect(LwwRegister<int>.empty().isEmpty, isTrue);
    });

    test('single value is returned', () {
      final r = LwwRegister.single(42, Hlc(100, 0, 'A'));
      expect(r.value, 42);
      expect(r.hlc, Hlc(100, 0, 'A'));
    });

    test('concurrent writes resolve by highest HLC', () {
      final a = LwwRegister<String>.empty().set(
        'a',
        Hlc(100, 0, 'A'),
        const CausalContext.empty(),
      );
      final b = LwwRegister<String>.empty().set(
        'b',
        Hlc(100, 0, 'B'),
        const CausalContext.empty(),
      );
      // Same millis+counter — nodeId 'B' > 'A' lexicographically.
      expect(a.join(b).value, 'b');
      expect(b.join(a).value, 'b');
    });

    test('later write wins by wall time', () {
      final a = LwwRegister<int>.empty().set(
        1,
        Hlc(100, 0, 'A'),
        const CausalContext.empty(),
      );
      final b = a.set(
        2,
        Hlc(200, 0, 'A'),
        const CausalContext.empty().advance(Hlc(100, 0, 'A')),
      );
      expect(b.value, 2);
    });

    test('commutative + idempotent', () {
      final a = LwwRegister.single(1, Hlc(100, 0, 'A'));
      final b = LwwRegister.single(2, Hlc(150, 0, 'B'));
      expect(a.join(b), b.join(a));
      expect(a.join(a), a);
    });
  });
}
