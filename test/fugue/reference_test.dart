// Validates the reference oracle (literal Fugue Algorithm 1) so it can be
// trusted when fuzzing the optimised block implementation against it.
import 'dart:math';

import 'package:convergent/src/fugue/dot.dart';
import 'package:test/test.dart';

import 'reference.dart';

void main() {
  group('RefFugue — Lamport dot', () {
    test('total order and dominance', () {
      final clk = LamportClock('A');
      final a = clk.tick();
      final b = clk.tick();
      expect(a < b, isTrue);
      clk.observe(100);
      final c = clk.tick();
      expect(c.counter, 101);
      expect(c > b, isTrue);
      // origin sorts before every real dot.
      expect(Dot.origin < a, isTrue);
    });
  });

  group('RefFugue — single replica', () {
    test('append in order', () {
      final clk = LamportClock('A');
      final f = RefFugue<String>();
      f.insert(0, 'a', clk.tick());
      f.insert(1, 'b', clk.tick());
      f.insert(2, 'c', clk.tick());
      expect(f.values(), ['a', 'b', 'c']);
    });

    test('prepend reverses', () {
      final clk = LamportClock('A');
      final f = RefFugue<String>();
      f.insert(0, 'a', clk.tick());
      f.insert(0, 'b', clk.tick());
      f.insert(0, 'c', clk.tick());
      expect(f.values(), ['c', 'b', 'a']);
    });

    test('insert in the middle', () {
      final clk = LamportClock('A');
      final f = RefFugue<String>();
      f.insert(0, 'a', clk.tick());
      f.insert(1, 'c', clk.tick());
      f.insert(1, 'b', clk.tick());
      expect(f.values(), ['a', 'b', 'c']);
    });

    test('delete then insert at the same spot survives across the tombstone',
        () {
      final clk = LamportClock('A');
      final f = RefFugue<String>();
      f.insert(0, 'a', clk.tick());
      f.insert(1, 'b', clk.tick());
      f.insert(2, 'c', clk.tick());
      f.delete(1); // b
      expect(f.values(), ['a', 'c']);
      f.insert(1, 'B', clk.tick()); // between a and c, across the b tombstone
      expect(f.values(), ['a', 'B', 'c']);
    });
  });

  // Builds a random session of inserts/deletes on top of [base], authored by
  // [replica]. The clock observes the base first, so this replica's dots
  // dominate the base content (Lamport receive).
  RefFugue<String> randomSession({
    required Random rng,
    required RefFugue<String> base,
    required String replica,
    required int ops,
  }) {
    final f = base.clone();
    final clk = LamportClock(replica)
      ..observeAll(base.ids.map((d) => d).toList());
    for (var i = 0; i < ops; i++) {
      final del = f.length > 0 && rng.nextDouble() < 0.3;
      if (del) {
        f.delete(rng.nextInt(f.length));
      } else {
        final at = f.length == 0 ? 0 : rng.nextInt(f.length + 1);
        f.insert(at, String.fromCharCode(0x61 + rng.nextInt(26)), clk.tick());
      }
    }
    return f;
  }

  group('RefFugue — convergence (fuzz)', () {
    test('two replicas converge under either merge order', () {
      for (var seed = 0; seed < 80; seed++) {
        final rngB = Random(seed);
        final base = randomSession(
          rng: rngB,
          base: RefFugue<String>(),
          replica: 'S',
          ops: 5 + rngB.nextInt(8),
        );
        final a = randomSession(
          rng: Random(seed * 7 + 1),
          base: base,
          replica: 'A',
          ops: 15 + Random(seed * 7 + 1).nextInt(20),
        );
        final b = randomSession(
          rng: Random(seed * 7 + 2),
          base: base,
          replica: 'B',
          ops: 15 + Random(seed * 7 + 2).nextInt(20),
        );

        final ab = a.clone()..merge(b);
        final ba = b.clone()..merge(a);
        expect(ab.values(), ba.values(), reason: 'diverges at seed=$seed');
      }
    });
  });

  group('RefFugue — non-interleaving (Fugue Theorem 1)', () {
    // Two concurrent runs at the same position, with INTERLEAVED ids (both
    // replicas mint from the same base counter), must not interleave.
    List<String> merged(bool aBackward, bool bBackward, int n) {
      final base = RefFugue<String>();
      final sclk = LamportClock('S');
      base.insert(0, 'L', sclk.tick());
      base.insert(1, 'R', sclk.tick());

      RefFugue<String> run(String label, bool backward) {
        final f = base.clone();
        final clk = LamportClock(label)..observeAll(base.ids);
        if (backward) {
          for (var i = n - 1; i >= 0; i--) {
            f.insert(1, '$label$i', clk.tick());
          }
        } else {
          for (var i = 0; i < n; i++) {
            f.insert(1 + i, '$label$i', clk.tick());
          }
        }
        return f;
      }

      final a = run('A', aBackward);
      final b = run('B', bBackward);
      return (a.clone()..merge(b)).values();
    }

    String? violation(List<String> vals, int n) {
      final letters = <String>[];
      final seqs = {'A': <int>[], 'B': <int>[]};
      for (final v in vals) {
        final k = v[0];
        if (seqs.containsKey(k)) {
          letters.add(k);
          seqs[k]!.add(int.parse(v.substring(1)));
        }
      }
      var t = 0;
      for (var i = 1; i < letters.length; i++) {
        if (letters[i] != letters[i - 1]) t++;
      }
      if (t > 1) return 'INTERLEAVED ${letters.join()}';
      for (final e in seqs.entries) {
        for (var i = 0; i < n; i++) {
          if (e.value[i] != i) return '${e.key} scrambled ${e.value}';
        }
      }
      return null;
    }

    test('forward/backward run combinations stay contiguous', () {
      for (final aB in [false, true]) {
        for (final bB in [false, true]) {
          final v = merged(aB, bB, 4);
          expect(violation(v, 4), isNull,
              reason: 'aBackward=$aB bBackward=$bB -> $v');
        }
      }
    });
  });
}
