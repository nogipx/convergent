// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:math';

import 'package:convergent/src/fugue/dot.dart';
import 'package:convergent/src/fugue/fugue.dart';
import 'package:test/test.dart';

import 'reference.dart';

void main() {
  Fugue<String> typed(String text, LamportClock clk) {
    final f = Fugue<String>();
    for (final ch in text.split('')) {
      f.insert(f.length, ch, clk.tick());
    }
    return f;
  }

  group('Fugue — Crdt interface', () {
    test('join is commutative and idempotent on values', () {
      final aClk = LamportClock('A');
      final bClk = LamportClock('B');
      final a = typed('abc', aClk);
      final b = typed('xy', bClk);
      expect(a.join(b).values, b.join(a).values);
      expect(a.join(a).values, a.values); // idempotent
      expect(a.join(a.empty).values, a.values); // identity
    });
  });

  group('Fugue — prune', () {
    test('drops a fully-tombstoned stable leaf block', () {
      final clk = LamportClock('A');
      final f = typed('ab', clk);
      f.delete(0);
      f.delete(0);
      expect(f.values, isEmpty);
      final pruned = f.prune(f.dots.toSet());
      expect(pruned.blockCount, 0);
      expect(pruned.values, isEmpty);
    });

    test('keeps a tombstoned block that anchors a live descendant', () {
      final clk = LamportClock('A');
      final f = typed('ab', clk);
      f.insert(1, 'X', clk.tick()); // between a and b -> left child of b
      expect(f.values.join(), 'aXb');
      f.delete(0); // a
      f.delete(1); // b
      expect(f.values.join(), 'X');

      final pruned = f.prune(f.dots.toSet());
      // The "ab" block is fully tombstoned but anchors live X -> kept.
      expect(pruned.values.join(), 'X');
      expect(pruned.blockCount, f.blockCount);
    });

    test('never drops a block with a live element', () {
      final clk = LamportClock('A');
      final f = typed('abc', clk);
      final pruned = f.prune(f.dots.toSet());
      expect(pruned.values.join(), 'abc');
      expect(pruned.blockCount, 1);
    });

    test('unstable tombstones are retained', () {
      final clk = LamportClock('A');
      final f = typed('ab', clk);
      f.delete(0);
      f.delete(0);
      final pruned = f.prune(<Dot>{}); // nothing stable
      expect(pruned.blockCount, 1); // kept — not stable yet
    });

    test('prune preserves visible values (fuzz)', () {
      for (var seed = 0; seed < 80; seed++) {
        final rng = Random(seed);
        final r = RefFugue<String>();
        final f = Fugue<String>();
        final clk = LamportClock('A');
        for (var i = 0; i < 40; i++) {
          final len = f.length;
          if (len > 0 && rng.nextDouble() < 0.4) {
            final at = rng.nextInt(len);
            r.delete(at);
            f.delete(at);
          } else {
            final at = len == 0 ? 0 : rng.nextInt(len + 1);
            final v = String.fromCharCode(0x61 + rng.nextInt(26));
            final d = clk.tick();
            r.insert(at, v, d);
            f.insert(at, v, d);
          }
        }
        final pruned = f.prune(f.dots.toSet());
        expect(pruned.values, r.values(), reason: 'seed=$seed');
        // Idempotent.
        expect(pruned.prune(pruned.dots.toSet()).values, pruned.values);
      }
    });
  });
}
