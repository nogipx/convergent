// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Fugue must have value-based ==/hashCode like every other CRDT in the
// package: without it, Mutator.hasPendingDelta (which compares the
// accumulator to state.empty) is always true, and CrdtMap<K, Fugue> gets
// identity equality inconsistent with Sequence.
import 'package:convergent/convergent.dart' show Mutator;
import 'package:convergent/fugue.dart';
import 'package:test/test.dart';

void main() {
  group('Fugue — value equality', () {
    test('two empty Fugues are equal and share a hashCode', () {
      final a = Fugue<String>();
      final b = Fugue<String>();
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('Mutator.hasPendingDelta is false with no local mutations', () {
      final m = Mutator<Fugue<String>>(initial: Fugue<String>());
      expect(m.hasPendingDelta, isFalse);
    });

    test('join satisfies idempotency and identity by value', () {
      final clk = LamportClock('A');
      final a = Fugue<String>()
        ..insert(0, 'a', clk.tick())
        ..insert(1, 'b', clk.tick());
      expect(a.join(a), a); // idempotency
      expect(a.join(a.empty), a); // identity
      expect(a.empty.join(a), a);
    });

    test('converged states are equal regardless of join order', () {
      final aClk = LamportClock('A');
      final bClk = LamportClock('B');
      final a = Fugue<String>()..insert(0, 'a', aClk.tick());
      final b = Fugue<String>()..insert(0, 'b', bClk.tick());
      expect(a.join(b), b.join(a));
      expect(a.join(b).hashCode, b.join(a).hashCode);
    });

    test('tombstone difference makes states unequal', () {
      final clk = LamportClock('A');
      final a = Fugue<String>()..insert(0, 'a', clk.tick());
      final b = a.clone()..delete(0);
      expect(a == b, isFalse);
    });
  });
}
