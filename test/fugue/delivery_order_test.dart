// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The state-based block formulation must tolerate δ-fragments delivered out
// of order, duplicated, and partitioned: orphans hide until their parent
// arrives, and a shorter run is subsumed by a longer one. This is the main
// risk class of the block formulation, so it is pinned by a property test.
import 'dart:math';

import 'package:convergent/fugue.dart';
import 'package:test/test.dart';

// A batch of random ops sized against the current visible [len0], keeping the
// simulated length valid across the batch (mirrors the delta_test generator).
List<FugueOp<String>> batchOps(Random rng, int len0, int count) {
  final ops = <FugueOp<String>>[];
  var len = len0;
  for (var i = 0; i < count; i++) {
    if (len > 0 && rng.nextDouble() < 0.3) {
      ops.add(FugueOp.removeAt(rng.nextInt(len)));
      len--;
    } else {
      ops.add(
        FugueOp.insert(
          len == 0 ? 0 : rng.nextInt(len + 1),
          String.fromCharCode(0x61 + rng.nextInt(26)),
        ),
      );
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
  group('Fugue — delivery order', () {
    test('out-of-order, duplicated, permuted δ-fragments converge (fuzz)', () {
      for (var seed = 0; seed < 150; seed++) {
        final rng = Random(seed);

        // Shared base authored by replica S.
        final base = seeded(
          String.fromCharCodes(
            List.generate(rng.nextInt(6), (_) => 0x61 + rng.nextInt(26)),
          ),
          LamportClock('S'),
        );

        // Replicas A and B each edit their own clone in several batches,
        // collecting every returned δ-fragment SEPARATELY (never composed).
        final fragments = <Fugue<String>>[];

        final a = base.clone();
        final aClk = LamportClock('A')..observeAll(base.dots);
        for (var i = 0, n = 2 + rng.nextInt(3); i < n; i++) {
          fragments.add(
            a.applyOps(batchOps(rng, a.length, 1 + rng.nextInt(5)), aClk),
          );
        }

        final b = base.clone();
        final bClk = LamportClock('B')..observeAll(base.dots);
        for (var i = 0, n = 2 + rng.nextInt(3); i < n; i++) {
          fragments.add(
            b.applyOps(batchOps(rng, b.length, 1 + rng.nextInt(5)), bClk),
          );
        }

        // Canonical result: the full-state join of both replicas.
        final canonical = a.join(b);

        // Delivery list: every fragment, each duplicated with prob 0.3.
        final delivery = <Fugue<String>>[];
        for (final f in fragments) {
          delivery.add(f);
          if (rng.nextDouble() < 0.3) delivery.add(f);
        }

        // Two peers seeded with base receive the SAME multiset of fragments
        // in two different seeded-random orders.
        Fugue<String> deliverInOrder(List<Fugue<String>> order) {
          var peer = base.clone();
          for (final f in order) {
            peer = peer.join(f);
          }
          return peer;
        }

        final peer1 = deliverInOrder(
          [...delivery]..shuffle(Random(seed * 2 + 1)),
        );
        final peer2 = deliverInOrder(
          [...delivery]..shuffle(Random(seed * 2 + 7)),
        );

        expect(
          peer1.values,
          canonical.values,
          reason: 'seed=$seed: out-of-order delivery != full-state join',
        );
        expect(
          peer2.values,
          peer1.values,
          reason: 'seed=$seed: peers diverge under different delivery order',
        );
        // No orphans survive once every fragment (incl. parents) is delivered.
        expect(peer1.orphanBlockCount, 0, reason: 'seed=$seed leftover orphan');
      }
    });

    test('a child δ-fragment before its parent is hidden, then heals', () {
      // Deterministic child-before-parent: A authors a parent block then a
      // child block anchored on one of the parent's elements.
      final a = Fugue<String>();
      final clk = LamportClock('A');
      final parent = a.applyOps(const [
        FugueOp.insert(0, 'a'),
        FugueOp.insert(1, 'b'),
      ], clk); // one coalesced block "ab"
      final child = a.applyOps(const [
        FugueOp.insert(1, 'X'), // between a and b -> a child block of b
      ], clk);
      expect(a.values.join(), 'aXb');

      // Deliver the CHILD fragment first: its parent element is absent, so the
      // block is an orphan and its value is hidden — a strictly shorter run.
      var peer = Fugue<String>();
      peer = peer.join(child);
      expect(peer.values, isEmpty);
      expect(peer.orphanBlockCount, greaterThan(0));
      expect(peer.values.length, lessThan(a.values.length));

      // The parent fragment arrives: the orphan reattaches and heals.
      peer = peer.join(parent);
      expect(peer.orphanBlockCount, 0);
      expect(peer.values, a.values);
    });
  });
}
