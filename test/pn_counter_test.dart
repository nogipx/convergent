// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:convergent/convergent.dart';
import 'package:test/test.dart';

void main() {
  final a = Hlc(0, 0, 'A');
  final b = Hlc(0, 0, 'B');

  group('PnCounter', () {
    test('empty value is 0', () {
      expect(PnCounter.empty().value, 0);
    });

    test('increment and decrement', () {
      final c = PnCounter.empty().increment(a, 5).decrement(a, 2);
      expect(c.value, 3);
    });

    test('per-replica state is independent', () {
      final x = PnCounter.empty().increment(a, 10);
      final y = PnCounter.empty().increment(b, 7);
      expect(x.join(y).value, 17);
    });

    test('join takes per-replica max — duplicates do not double-count', () {
      final once = PnCounter.empty().increment(a, 5);
      final twice = once.increment(a, 0); // no-op, but new instance
      // Joining the SAME counter twice must not change value.
      expect(once.join(once).value, 5);
      expect(once.join(twice).value, 5);
    });

    test('commutative + associative', () {
      final c1 = PnCounter.empty().increment(a, 3);
      final c2 = PnCounter.empty().increment(b, 4);
      final c3 = PnCounter.empty().decrement(a, 1);
      expect(c1.join(c2), c2.join(c1));
      expect(c1.join(c2).join(c3), c1.join(c2.join(c3)));
    });

    test('decrement of 0 is no-op', () {
      final c = PnCounter.empty().increment(a, 5);
      expect(c.decrement(a, 0), c);
    });

    test('two successive delta-increments both count (join into state)', () {
      final a = Hlc(1, 0, 'A');
      var s = PnCounter.empty();
      final d1 = s.deltaIncrement(a, 1);
      s = s.join(d1);
      final d2 = s.deltaIncrement(a, 1);
      s = s.join(d2);
      expect(s.value, 2); // static-delta code yields 1
    });

    test('Mutator + PnCounter: local state equals what peers reconstruct', () {
      final a = Hlc(1, 0, 'A');
      final alice = Mutator<PnCounter>(initial: PnCounter.empty());
      alice.applyLocal(alice.state.deltaIncrement(a, 1));
      alice.applyLocal(alice.state.deltaIncrement(a, 1));
      final bob = PnCounter.empty().join(alice.flushDelta());
      expect(alice.state.value, 2);
      expect(bob.value, alice.state.value);
    });
  });
}
