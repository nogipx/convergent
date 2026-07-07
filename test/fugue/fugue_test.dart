// The optimised block Fugue must be observationally identical to the
// reference oracle (literal Algorithm 1) for every op history, and must
// coalesce forward-typed runs into blocks.
import 'dart:math';

import 'package:convergent/src/fugue/dot.dart';
import 'package:convergent/src/fugue/fugue.dart';
import 'package:test/test.dart';

import 'reference.dart';

void main() {
  group('Fugue — single-replica basics', () {
    test('forward run coalesces into one block', () {
      final clk = LamportClock('A');
      final f = Fugue<String>();
      for (final ch in 'hello'.split('')) {
        f.insert(f.length, ch, clk.tick());
      }
      expect(f.values.join(), 'hello');
      expect(f.blockCount, 1, reason: 'a forward run must be one waypoint');
    });

    test('prepend reverses (each a new block)', () {
      final clk = LamportClock('A');
      final f = Fugue<String>();
      f.insert(0, 'a', clk.tick());
      f.insert(0, 'b', clk.tick());
      f.insert(0, 'c', clk.tick());
      expect(f.values.join(), 'cba');
    });

    test('mid-run insert interleaves without splitting storage', () {
      final clk = LamportClock('A');
      final f = Fugue<String>();
      for (final ch in 'hello'.split('')) {
        f.insert(f.length, ch, clk.tick());
      }
      f.insert(1, 'X', clk.tick()); // between h and e
      expect(f.values.join(), 'hXello');
    });

    test('delete tombstones but keeps successors', () {
      final clk = LamportClock('A');
      final f = Fugue<String>();
      for (final ch in 'abc'.split('')) {
        f.insert(f.length, ch, clk.tick());
      }
      f.delete(1);
      expect(f.values.join(), 'ac');
    });
  });

  // Drives an identical (op, dot) stream into both implementations.
  void ins(RefFugue<String> r, Fugue<String> f, int at, String v, Dot d) {
    r.insert(at, v, d);
    f.insert(at, v, d);
  }

  // Applies a random session to a paired (ref, block) with shared dots.
  void session({
    required Random rng,
    required RefFugue<String> r,
    required Fugue<String> f,
    required LamportClock clk,
    required int ops,
  }) {
    for (var i = 0; i < ops; i++) {
      final len = f.length;
      if (len > 0 && rng.nextDouble() < 0.3) {
        final at = rng.nextInt(len);
        r.delete(at);
        f.delete(at);
      } else {
        final at = len == 0 ? 0 : rng.nextInt(len + 1);
        ins(r, f, at, String.fromCharCode(0x61 + rng.nextInt(26)), clk.tick());
      }
    }
    expect(
      f.values,
      r.values(),
      reason: 'block vs oracle diverged mid-session',
    );
  }

  group('Fugue — matches oracle (single replica, fuzz)', () {
    test('identical to reference over 200 random sessions', () {
      for (var seed = 0; seed < 200; seed++) {
        final r = RefFugue<String>();
        final f = Fugue<String>();
        final clk = LamportClock('A');
        session(rng: Random(seed), r: r, f: f, clk: clk, ops: 40);
        expect(f.values, r.values());
      }
    });
  });

  group('Fugue — matches oracle (concurrent + merge, fuzz)', () {
    test('two replicas: block-merge == oracle-merge, both join orders', () {
      for (var seed = 0; seed < 200; seed++) {
        // Shared base.
        final rBase = RefFugue<String>();
        final fBase = Fugue<String>();
        final sClk = LamportClock('S');
        session(
          rng: Random(seed),
          r: rBase,
          f: fBase,
          clk: sClk,
          ops: 5 + Random(seed).nextInt(8),
        );

        // Replica A.
        final rA = rBase.clone();
        final fA = fBase.clone();
        final aClk = LamportClock('A')..observeAll(fBase.dots);
        session(
          rng: Random(seed * 13 + 1),
          r: rA,
          f: fA,
          clk: aClk,
          ops: 15 + Random(seed * 13 + 1).nextInt(15),
        );

        // Replica B.
        final rB = rBase.clone();
        final fB = fBase.clone();
        final bClk = LamportClock('B')..observeAll(fBase.dots);
        session(
          rng: Random(seed * 13 + 2),
          r: rB,
          f: fB,
          clk: bClk,
          ops: 15 + Random(seed * 13 + 2).nextInt(15),
        );

        // Merge both ways in each model.
        final refAB = rA.clone()..merge(rB);
        final refBA = rB.clone()..merge(rA);
        final blkAB = fA.clone()..merge(fB);
        final blkBA = fB.clone()..merge(fA);

        expect(
          refAB.values(),
          refBA.values(),
          reason: 'oracle diverges at seed=$seed',
        );
        expect(
          blkAB.values,
          blkBA.values,
          reason: 'block diverges at seed=$seed',
        );
        expect(
          blkAB.values,
          refAB.values(),
          reason: 'block != oracle at seed=$seed',
        );
      }
    });
  });
}
