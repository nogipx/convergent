// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:convergent/convergent.dart';
import 'package:test/test.dart';

void main() {
  group('GSet', () {
    test('empty has size 0', () {
      expect(GSet<int>.empty().size, 0);
      expect(GSet<int>.empty().isEmpty, isTrue);
    });

    test('add stores the value', () {
      final s = GSet<int>.empty().add(1).add(2);
      expect(s.values, {1, 2});
      expect(s.contains(1), isTrue);
      expect(s.contains(3), isFalse);
    });

    test('add is idempotent', () {
      final s = GSet<int>.empty().add(1).add(1);
      expect(s.size, 1);
    });

    test('join is set union', () {
      final a = GSet<int>.from([1, 2]);
      final b = GSet<int>.from([2, 3]);
      expect(a.join(b).values, {1, 2, 3});
    });

    test('commutative, associative, idempotent', () {
      final a = GSet<int>.from([1, 2]);
      final b = GSet<int>.from([2, 3]);
      final c = GSet<int>.from([3, 4]);
      expect(a.join(b), b.join(a));
      expect(a.join(b).join(c), a.join(b.join(c)));
      expect(a.join(a), a);
    });
  });
}
