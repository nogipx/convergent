// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:convergent/convergent.dart';
import 'package:test/test.dart';

void main() {
  group('CrdtMap with GSet values', () {
    test('empty map', () {
      expect(CrdtMap<String, GSet<int>>.empty().isEmpty, isTrue);
    });

    test('put adds a new key', () {
      final m = CrdtMap<String, GSet<int>>.empty().put(
        'a',
        GSet<int>.from([1]),
      );
      expect(m['a']!.values, {1});
    });

    test('put on existing key joins values', () {
      final m = CrdtMap<String, GSet<int>>.empty()
          .put('a', GSet<int>.from([1]))
          .put('a', GSet<int>.from([2]));
      expect(m['a']!.values, {1, 2});
    });

    test('join merges per-key', () {
      final left = CrdtMap<String, GSet<int>>.empty()
          .put('a', GSet<int>.from([1, 2]))
          .put('b', GSet<int>.from([3]));
      final right = CrdtMap<String, GSet<int>>.empty()
          .put('a', GSet<int>.from([2, 4]))
          .put('c', GSet<int>.from([5]));
      final merged = left.join(right);
      expect(merged['a']!.values, {1, 2, 4});
      expect(merged['b']!.values, {3});
      expect(merged['c']!.values, {5});
    });

    test('join is commutative + idempotent', () {
      final l = CrdtMap<String, GSet<int>>.empty().put(
        'a',
        GSet<int>.from([1]),
      );
      final r = CrdtMap<String, GSet<int>>.empty().put(
        'a',
        GSet<int>.from([2]),
      );
      expect(l.join(r), r.join(l));
      expect(l.join(l), l);
    });
  });

  group('CrdtMap with PnCounter values', () {
    final a = Hlc(0, 0, 'A');
    final b = Hlc(0, 0, 'B');

    test('two replicas, two keys, converges', () {
      final left = CrdtMap<String, PnCounter>.empty().put(
        'likes',
        PnCounter.empty().increment(a, 3),
      );
      final right = CrdtMap<String, PnCounter>.empty()
          .put('likes', PnCounter.empty().increment(b, 5))
          .put('shares', PnCounter.empty().increment(b, 1));
      final merged = left.join(right);
      expect(merged['likes']!.value, 8);
      expect(merged['shares']!.value, 1);
    });
  });
}
