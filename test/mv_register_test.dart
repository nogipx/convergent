// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:math';

import 'package:convergent/convergent.dart';
import 'package:test/test.dart';

// Helpers ---------------------------------------------------------------

Hlc _hlc(int ms, int ctr, String node) => Hlc(ms, ctr, node);

TaggedValue<String> _tv(
  String value,
  Hlc hlc, {
  Map<String, Hlc> seen = const {},
}) => TaggedValue(value, hlc, context: CausalContext.from(seen));

MvRegister<String> _reg(List<TaggedValue<String>> values) =>
    MvRegister.fromValues(values.toSet());

/// Generate a deterministic-but-varied register population for property
/// tests. nodes A,B,C; some causally-related, some concurrent.
List<MvRegister<String>> _samplePopulation() {
  final hA1 = _hlc(100, 0, 'A');
  final hA2 = _hlc(200, 0, 'A');
  final hB1 = _hlc(150, 0, 'B');
  final hB2 = _hlc(250, 0, 'B');
  final hC1 = _hlc(180, 0, 'C');

  final tvA1 = _tv('a1', hA1);
  final tvA2 = _tv('a2', hA2, seen: {'A': hA1, 'B': hB1}); // dominates A1, B1
  final tvB1 = _tv('b1', hB1);
  final tvB2 = _tv(
    'b2',
    hB2,
    seen: {'B': hB1},
  ); // dominates B1, concurrent w/ A2
  final tvC1 = _tv(
    'c1',
    hC1,
    seen: {'A': hA1},
  ); // dominates A1, concurrent w/ B2, A2

  return [
    MvRegister<String>.empty(),
    _reg([tvA1]),
    _reg([tvA2]),
    _reg([tvB1]),
    _reg([tvB2]),
    _reg([tvA1, tvB1]),
    _reg([tvA2, tvB2]),
    _reg([tvA1, tvB1, tvC1]),
    _reg([tvA2, tvB2, tvC1]),
    _reg([tvA1, tvA2, tvB1, tvB2, tvC1]),
  ];
}

void main() {
  group('MvRegister Δ-state CRDT properties (doc §7)', () {
    final population = _samplePopulation();

    test('commutativity: a.join(b) == b.join(a)', () {
      for (final a in population) {
        for (final b in population) {
          expect(
            a.join(b),
            equals(b.join(a)),
            reason: 'commutativity failed for $a join $b',
          );
        }
      }
    });

    test('associativity: a.join(b).join(c) == a.join(b.join(c))', () {
      for (final a in population) {
        for (final b in population) {
          for (final c in population) {
            expect(
              a.join(b).join(c),
              equals(a.join(b.join(c))),
              reason: 'associativity failed for $a, $b, $c',
            );
          }
        }
      }
    });

    test('idempotency: a.join(a) == a', () {
      for (final a in population) {
        expect(a.join(a), equals(a), reason: 'idempotency failed for $a');
      }
    });

    test('idempotency under repetition: a.join(b).join(b) == a.join(b)', () {
      for (final a in population) {
        for (final b in population) {
          expect(
            a.join(b).join(b),
            equals(a.join(b)),
            reason: 'repeated-join idempotency failed for $a, $b',
          );
        }
      }
    });

    test('monotonicity: a.join(b) contains every survivor of a', () {
      // After join, any value from a that is NOT dominated by something in
      // (a ∪ b) must still be in the result.
      for (final a in population) {
        for (final b in population) {
          final joined = a.join(b);
          final union = {...a.values, ...b.values};
          for (final v in a.values) {
            final dominated = union.any(
              (w) => w.hlc != v.hlc && w.context.contains(v.hlc),
            );
            if (!dominated) {
              expect(
                joined.values.contains(v),
                isTrue,
                reason: 'monotonicity: $v from $a dropped after join with $b',
              );
            }
          }
        }
      }
    });

    test('causal correctness: dominated value is dropped', () {
      final hA1 = _hlc(100, 0, 'A');
      final hB1 = _hlc(150, 0, 'B');
      final a = _reg([_tv('a1', hA1)]);
      // b is a write by B that has seen A1 ⇒ dominates it.
      final b = _reg([
        _tv('b1', hB1, seen: {'A': hA1}),
      ]);

      final joined = a.join(b);
      expect(joined.values.length, equals(1));
      expect(joined.singleValue, equals('b1'));
    });

    test('causal correctness: concurrent values both kept', () {
      final hA = _hlc(100, 0, 'A');
      final hB = _hlc(110, 0, 'B');
      // Neither has seen the other.
      final a = _reg([_tv('a', hA)]);
      final b = _reg([_tv('b', hB)]);

      final joined = a.join(b);
      expect(joined.values.length, equals(2));
      expect(joined.hasConflict, isTrue);
      expect(joined.allValues.toSet(), equals({'a', 'b'}));
    });

    test('set with dominating context collapses register', () {
      final hA = _hlc(100, 0, 'A');
      final hB = _hlc(110, 0, 'B');
      final hC = _hlc(200, 0, 'C');
      final twoValue = _reg([_tv('a', hA), _tv('b', hB)]);

      // C writes having seen both A and B.
      final writerCtx = CausalContext.from({'A': hA, 'B': hB});
      final after = twoValue.set('c', hC, writerCtx);

      expect(after.values.length, equals(1));
      expect(after.singleValue, equals('c'));
    });

    test('set with non-dominating context preserves concurrent value', () {
      final hA = _hlc(100, 0, 'A');
      final hC = _hlc(200, 0, 'C');
      final twoValue = _reg([_tv('a', hA)]);

      // C writes WITHOUT having seen A.
      final after = twoValue.set('c', hC, const CausalContext.empty());

      expect(after.values.length, equals(2));
      expect(after.allValues.toSet(), equals({'a', 'c'}));
    });

    test('any delivery order yields the same register (convergence)', () {
      // Construct N independent registers and shuffle the join order. All
      // permutations must produce equal results (consequence of
      // commutativity + associativity + idempotency).
      final r = Random(0xC2D7);
      final regs = _samplePopulation();
      final permutation1 = [...regs]..shuffle(r);
      final permutation2 = [...regs]..shuffle(Random(0xBEEF));

      MvRegister<String> reduce(List<MvRegister<String>> rs) =>
          rs.reduce((acc, x) => acc.join(x));

      expect(reduce(permutation1), equals(reduce(permutation2)));
      expect(reduce(permutation1), equals(reduce(regs)));
    });
  });

  group('TaggedValue identity', () {
    test('equality ignores context (needed for idempotency)', () {
      final hlc = _hlc(100, 0, 'A');
      final a = TaggedValue('x', hlc);
      final b = TaggedValue(
        'x',
        hlc,
        context: CausalContext.from({'B': _hlc(50, 0, 'B')}),
      );
      expect(a == b, isTrue);
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}
