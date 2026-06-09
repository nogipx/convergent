// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:convergent/convergent.dart';
import 'package:test/test.dart';

void main() {
  group('OrSet', () {
    test('add then contains', () {
      final s = OrSet<String>.empty().add('x', Hlc(1, 0, 'A'));
      expect(s.contains('x'), isTrue);
      expect(s.values, {'x'});
    });

    test('add then remove', () {
      final s = OrSet<String>.empty().add('x', Hlc(1, 0, 'A')).remove('x');
      expect(s.contains('x'), isFalse);
      expect(s.values, isEmpty);
    });

    test('remove of unseen element is no-op', () {
      final s = OrSet<String>.empty().remove('ghost');
      expect(s.isEmpty, isTrue);
    });

    test('concurrent add wins over remove (observed-remove semantics)', () {
      final base = OrSet<String>.empty().add('x', Hlc(1, 0, 'A'));
      final removed = base.remove('x'); // tombstones tag (1,0,A)
      final readded = base.add(
        'x',
        Hlc(2, 0, 'B'),
      ); // new tag, not observed by removed
      final merged = removed.join(readded);
      // The new tag was never tombstoned → element is present.
      expect(merged.contains('x'), isTrue);
    });

    test('add of same element with same tag is idempotent', () {
      final tag = Hlc(1, 0, 'A');
      final a = OrSet<String>.empty().add('x', tag);
      final b = a.add('x', tag);
      expect(a, b);
    });

    test('join commutative and idempotent', () {
      final a = OrSet<String>.empty().add('x', Hlc(1, 0, 'A'));
      final b = OrSet<String>.empty().add('y', Hlc(1, 0, 'B'));
      expect(a.join(b), b.join(a));
      expect(a.join(a), a);
    });

    // ─── Δ-state-specific invariants (Almeida et al. 2018 §3.4) ─────
    test('remove does not advance causal context', () {
      final tag = Hlc(1, 0, 'A');
      final s = OrSet<String>.empty().add('x', tag);
      final ctxBefore = s.context;
      final removed = s.remove('x');
      expect(removed.context.dominates(ctxBefore), isTrue);
      expect(ctxBefore.dominates(removed.context), isTrue);
    });

    test('removed dots vanish — no tombstone set to GC', () {
      // After 100 add/remove cycles the dot store is empty but the
      // context still covers every minted hlc. There is no separate
      // tombstone set to grow.
      var s = OrSet<int>.empty();
      for (var i = 1; i <= 100; i++) {
        s = s.add(i, Hlc(i, 0, 'A')).remove(i);
      }
      expect(s.values, isEmpty);
      // Stale replica re-sends an old dot — must be dropped because
      // our context covers it.
      final stale = OrSet<int>.empty().add(42, Hlc(42, 0, 'A'));
      expect(s.join(stale).values, isEmpty);
    });

    test('three-replica convergence — every delivery order agrees', () {
      final r1 = OrSet<String>.empty()
          .add('x', Hlc(1, 0, 'A'))
          .add('y', Hlc(2, 0, 'A'));
      final r2 = OrSet<String>.empty().add('y', Hlc(3, 0, 'B'));
      // C observed r1 then removed y; B's concurrent add of y
      // (Hlc(3,_,B)) was never seen by C so it must survive.
      final r3 = r1.remove('y');
      final order1 = r1.join(r2).join(r3);
      final order2 = r3.join(r1).join(r2);
      final order3 = r2.join(r3).join(r1);
      expect(order1.values, order2.values);
      expect(order2.values, order3.values);
      expect(order1.values, {'x', 'y'});
    });
  });
}
