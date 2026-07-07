// Delta-state properties: applyOps returns a δ-fragment such that
// base.join(δ) reconstructs the applied state, δs compose, and merges are
// associative across three replicas.
import 'dart:math';

import 'package:convergent/fugue.dart';
import 'package:test/test.dart';

List<FugueOp<String>> randomOps(Random rng, int len0, int count) {
  final ops = <FugueOp<String>>[];
  var len = len0;
  for (var i = 0; i < count; i++) {
    if (len > 0 && rng.nextDouble() < 0.3) {
      ops.add(FugueOp.removeAt(rng.nextInt(len)));
      len--;
    } else {
      ops.add(FugueOp.insert(
        len == 0 ? 0 : rng.nextInt(len + 1),
        String.fromCharCode(0x61 + rng.nextInt(26)),
      ));
      len++;
    }
  }
  return ops;
}

Fugue<String> seeded(String text, LamportClock clk) {
  final f = Fugue<String>();
  for (final ch in text.split('')) {
    f.insert(f.length, ch, clk.tick());
  }
  return f;
}

void main() {
  group('Fugue — delta-state', () {
    test('base.join(delta) reconstructs the applied state', () {
      final sclk = LamportClock('S');
      final base = seeded('hello', sclk);

      final g = base.clone();
      final clk = LamportClock('A')..observeAll(base.dots);
      final delta = g.applyOps(const [
        FugueOp.insert(0, 'X'),
        FugueOp.removeAt(2),
        FugueOp.insert(5, 'Y'),
      ], clk);

      // A peer holding only `base` applies just the shipped delta.
      final peer = base.join(delta);
      expect(peer.values, g.values);
    });

    test('delta reconstructs applied state (fuzz)', () {
      for (var seed = 0; seed < 200; seed++) {
        final rng = Random(seed);
        final base = seeded(
          String.fromCharCodes(
            List.generate(rng.nextInt(6), (_) => 0x61 + rng.nextInt(26)),
          ),
          LamportClock('S'),
        );
        final g = base.clone();
        final clk = LamportClock('A')..observeAll(base.dots);
        final delta = g.applyOps(randomOps(rng, g.length, 20), clk);

        expect(base.join(delta).values, g.values, reason: 'seed=$seed');
        // Idempotent re-delivery.
        expect(base.join(delta).join(delta).values, g.values);
      }
    });

    test('deltas compose (deltaCompose == join of fragments)', () {
      for (var seed = 0; seed < 150; seed++) {
        final rng = Random(seed);
        final base = seeded('abcde', LamportClock('S'));
        final g = base.clone();
        final clk = LamportClock('A')..observeAll(base.dots);

        final d1 = g.applyOps(randomOps(rng, g.length, 8), clk);
        final d2 = g.applyOps(randomOps(rng, g.length, 8), clk);
        final composed = d1.deltaCompose(d2);

        expect(base.join(composed).values, g.values, reason: 'seed=$seed');
      }
    });
  });

  group('Fugue — state-based join laws', () {
    test('three-replica associativity + commutativity (fuzz)', () {
      for (var seed = 0; seed < 120; seed++) {
        final base = seeded('base', LamportClock('S'));

        Fugue<String> replica(String id, int salt) {
          final f = base.clone();
          final clk = LamportClock(id)..observeAll(base.dots);
          f.applyOps(randomOps(Random(seed * 31 + salt), f.length, 12), clk);
          return f;
        }

        final a = replica('A', 1);
        final b = replica('B', 2);
        final c = replica('C', 3);

        final left = a.join(b).join(c);
        final right = a.join(b.join(c));
        final perm = c.join(a).join(b);

        expect(left.values, right.values, reason: 'assoc seed=$seed');
        expect(left.values, perm.values, reason: 'commut seed=$seed');
        // Idempotent.
        expect(left.join(a).values, left.values);
      }
    });
  });
}
