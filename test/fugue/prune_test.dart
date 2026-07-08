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

    test('orphanBlockCount: transient orphan heals after parent arrives', () {
      // A authors two delta fragments: d1 is the parent content, d2 is a
      // child block anchored on an element of d1's block.
      final a = Fugue<String>();
      final clk = LamportClock('A');
      final d1 = a.applyOps(const [
        FugueOp.insert(0, 'a'),
        FugueOp.insert(1, 'b'),
      ], clk); // one coalesced block "ab"
      final d2 = a.applyOps(const [
        FugueOp.insert(1, 'X'), // between a and b -> a child block of b
      ], clk);
      expect(a.values.join(), 'aXb');

      // A fresh peer receives the CHILD fragment first: its parent element is
      // absent, so the block is a (transient) orphan and hides its value.
      var p = Fugue<String>();
      p = p.join(d2);
      expect(p.orphanBlockCount, greaterThan(0));
      expect(p.values, isEmpty);

      // The parent fragment arrives: the orphan is reattached and heals.
      p = p.join(d1);
      expect(p.orphanBlockCount, 0);
      expect(p.values, a.values);
    });

    test('violated prune barrier is detectable via orphanBlockCount', () {
      // This is the failure mode the prune barrier invariant exists to
      // prevent: pruning a tombstoned block while a delta parented on its
      // tombstone is still undelivered leaves a permanently unreachable
      // block and breaks convergence of visible values.

      // Shared base: a single block P, fully deleted and causally stable.
      final sClk = LamportClock('S');
      final base = Fugue<String>();
      base.insert(0, 'P', sClk.tick());
      final pDot = base.positionAt(0); // stable position of P (its tombstone)
      base.delete(0);
      expect(base.values, isEmpty);

      final x = base.clone();
      final y = base.clone();

      // Y anchors a child on P's tombstone (positions survive deletion).
      final yClk = LamportClock('Y')..observeAll(base.dots);
      final childDot = yClk.tick();
      y.insertAfter(pDot, 'c', childDot);
      expect(y.values, ['c']); // the tombstone still anchors the child on Y

      // The in-flight delta Y ships: just the child block (same metadata Y
      // produced — parent is P's tombstone dot).
      final delta = Fugue<String>();
      delta.insertAfter(pDot, 'c', childDot);

      // X prunes P BEFORE receiving the delta — barrier violated.
      final xPruned = x.prune(x.dots.toSet());
      expect(xPruned.blockCount, 0); // P dropped; nothing anchors it on X yet

      // X applies the in-flight delta: P's tombstone is gone, so the child is
      // permanently unreachable and X diverges from Y.
      final xAfter = xPruned.join(delta);
      expect(xAfter.orphanBlockCount, greaterThan(0));
      expect(xAfter.values, isNot(y.values));
    });
  });
}
