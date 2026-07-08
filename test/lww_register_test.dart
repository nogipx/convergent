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

    test('join collapses concurrent values — no node-churn bloat', () {
      // Many distinct nodes each writing concurrently (empty context, so none
      // dominates the others) — the classic node-churn accumulation that bloats
      // a field-map state to megabytes. The register must stay a single value.
      var reg = LwwRegister<int>.empty();
      for (var i = 0; i < 200; i++) {
        reg = reg.join(
          LwwRegister.deltaSet(
            i,
            Hlc(1000 + i, 0, 'node$i'),
            const CausalContext.empty(),
          ),
        );
      }
      expect(reg.inner.values.length, 1, reason: 'must collapse to one value');
      expect(reg.value, 199, reason: 'winner is the highest-HLC write');
    });

    test('set() collapses concurrent writes so join laws hold', () {
      // Two blind writes (empty writer context) are concurrent. Before the
      // fix, set() left both in the inner MvRegister while join() collapsed to
      // one, so a set-produced state was not a join fixpoint:
      // a.join(a) != a and a.join(empty) != a (the .value stayed correct, but
      // the advertised semilattice == laws were violated).
      final a = LwwRegister<String>.empty()
          .set('x', Hlc(100, 0, 'A'), const CausalContext.empty())
          .set('y', Hlc(50, 0, 'B'), const CausalContext.empty());

      expect(a.inner.values.length, 1, reason: 'single-value invariant');
      expect(a.value, 'x', reason: 'winner is the highest HLC');
      expect(a.join(a), a, reason: 'idempotency');
      expect(a.join(a.empty), a, reason: 'identity');
      expect(a.empty.join(a), a, reason: 'identity (mirror)');
    });

    test('collapsed loser never resurfaces on a later join', () {
      final winner = LwwRegister.deltaSet(
        2,
        Hlc(200, 0, 'B'),
        const CausalContext.empty(),
      );
      final loser = LwwRegister.deltaSet(
        1,
        Hlc(100, 0, 'A'),
        const CausalContext.empty(),
      );
      final collapsed = winner.join(loser); // -> single value 2, ctx covers A
      // Re-joining the loser must not re-add it (its HLC is dominated).
      final again = collapsed.join(loser);
      expect(again.inner.values.length, 1);
      expect(again.value, 2);
    });
  });
}
