// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:math';

import 'package:convergent/convergent.dart';
import 'package:test/test.dart';

void main() {
  // Helper: per-replica monotonic HLC clock with anchored millis so
  // the tests are deterministic.
  Hlc Function() clockOf(String node, {int startMs = 1000}) {
    var last = Hlc(startMs, 0, node);
    return () {
      last = Hlc(last.millis, last.counter + 1, node);
      return last;
    };
  }

  group('Sequence — single-replica operations', () {
    test('empty sequence', () {
      final s = Sequence<int>.empty();
      expect(s.values, isEmpty);
      expect(s.length, 0);
      expect(s.isEmpty, isTrue);
      expect(s[0], isNull);
    });

    test('insertAt 0 on empty puts a single value', () {
      final clk = clockOf('A');
      final s = Sequence<int>.empty().insertAt(0, 42, clk());
      expect(s.values, [42]);
      expect(s.length, 1);
      expect(s[0], 42);
    });

    test('append in order', () {
      final clk = clockOf('A');
      var s = Sequence<String>.empty();
      s = s.insertAt(0, 'a', clk());
      s = s.insertAt(1, 'b', clk());
      s = s.insertAt(2, 'c', clk());
      expect(s.values, ['a', 'b', 'c']);
    });

    test('prepend reverses', () {
      final clk = clockOf('A');
      var s = Sequence<String>.empty();
      s = s.insertAt(0, 'a', clk());
      s = s.insertAt(0, 'b', clk());
      s = s.insertAt(0, 'c', clk());
      expect(s.values, ['c', 'b', 'a']);
    });

    test('insert in the middle', () {
      final clk = clockOf('A');
      var s = Sequence<String>.empty()
          .insertAt(0, 'a', clk())
          .insertAt(1, 'c', clk());
      expect(s.values, ['a', 'c']);
      s = s.insertAt(1, 'b', clk());
      expect(s.values, ['a', 'b', 'c']);
    });

    test('removeAt tombstones the entry but preserves successors', () {
      final clk = clockOf('A');
      var s = Sequence<String>.empty()
          .insertAt(0, 'a', clk())
          .insertAt(1, 'b', clk())
          .insertAt(2, 'c', clk());
      s = s.removeAt(1);
      expect(s.values, ['a', 'c']);
    });

    test('removeAt on out-of-range index is a no-op', () {
      final clk = clockOf('A');
      final s = Sequence<int>.empty().insertAt(0, 1, clk());
      expect(s.removeAt(7), s);
      expect(s.removeAt(-1), s);
    });

    test('reinsert at same logical position after delete', () {
      final clk = clockOf('A');
      var s = Sequence<String>.empty()
          .insertAt(0, 'a', clk())
          .insertAt(1, 'b', clk());
      s = s.removeAt(0);
      expect(s.values, ['b']);
      s = s.insertAt(0, 'a*', clk());
      expect(s.values, ['a*', 'b']);
    });
  });

  group('Sequence — concurrent edits converge', () {
    test('two replicas append independently — both appends survive', () {
      final clkA = clockOf('A', startMs: 1000);
      final clkB = clockOf('B', startMs: 2000);
      var a = Sequence<String>.empty().insertAt(0, 'a', clkA());
      var b = Sequence<String>.empty().insertAt(0, 'b', clkB());
      final m1 = a.join(b);
      final m2 = b.join(a);
      expect(m1.values, m2.values);
      // Both characters present; root-children order is by id —
      // A's hlc has smaller millis (1000<2000) so A goes first.
      expect(m1.values, ['a', 'b']);
    });

    test('idempotency: join(self, self) == self', () {
      final clk = clockOf('A');
      final s = Sequence<String>.empty()
          .insertAt(0, 'x', clk())
          .insertAt(1, 'y', clk());
      expect(s.join(s), s);
    });

    test('commutativity & associativity', () {
      final clkA = clockOf('A', startMs: 1000);
      final clkB = clockOf('B', startMs: 2000);
      final clkC = clockOf('C', startMs: 3000);
      final a = Sequence<String>.empty().insertAt(0, 'a', clkA());
      final b = Sequence<String>.empty().insertAt(0, 'b', clkB());
      final c = Sequence<String>.empty().insertAt(0, 'c', clkC());
      expect(a.join(b), b.join(a));
      expect(a.join(b).join(c), a.join(b.join(c)));
    });

    test('one replica deletes while another reads — remove propagates', () {
      final clk = clockOf('A');
      final base = Sequence<String>.empty()
          .insertAt(0, 'a', clk())
          .insertAt(1, 'b', clk());
      final aRemoves = base.removeAt(0); // tombstone the 'a'
      final bUnchanged = base; // peer never saw the remove

      final merged = aRemoves.join(bUnchanged);
      // OR semantics: once any replica tombstones, every joined
      // replica sees the entry as removed.
      expect(merged.values, ['b']);
    });

    test('concurrent add-then-delete vs add-then-add — add-wins', () {
      final clkA = clockOf('A', startMs: 1000);
      final clkB = clockOf('B', startMs: 2000);

      // Both start with 'x'.
      final initialDot = clkA();
      final base = Sequence<String>.empty().insertAt(0, 'x', initialDot);

      // A removes x.
      final aSide = base.removeAt(0);
      // B adds 'y' after x (concurrently — B never saw the remove).
      final bSide = base.insertAt(1, 'y', clkB());

      final merged = aSide.join(bSide);
      // x is tombstoned. y survives — it was inserted relative to
      // x's position, but tombstoning x doesn't remove its
      // descendants.
      expect(merged.values, ['y']);
    });
  });

  group('Sequence — Δ-state delta producers', () {
    test('deltaInsertAt joins to insertAt', () {
      final clk = clockOf('A');
      final base = Sequence<String>.empty().insertAt(0, 'a', clk());
      final dot = clk();
      final viaDelta = base.join(base.deltaInsertAt(1, 'b', dot));
      final viaFull = base.insertAt(1, 'b', dot);
      expect(viaDelta, viaFull);
    });

    test('deltaRemoveAt joins to removeAt', () {
      final clk = clockOf('A');
      final base = Sequence<String>.empty()
          .insertAt(0, 'a', clk())
          .insertAt(1, 'b', clk());
      final delta = base.deltaRemoveAt(0);
      expect(delta, isNotNull);
      expect(base.join(delta!), base.removeAt(0));
    });

    test('deltaRemoveAt on out-of-range returns null', () {
      final clk = clockOf('A');
      final s = Sequence<int>.empty().insertAt(0, 1, clk());
      expect(s.deltaRemoveAt(7), isNull);
    });

    test('Mutator end-to-end with sequential same-node deltas', () {
      final clkA = clockOf('A');
      final alice = Mutator<Sequence<String>>(
        initial: Sequence<String>.empty(),
      );
      final bob = Mutator<Sequence<String>>(initial: Sequence<String>.empty());

      alice.applyLocal(alice.state.deltaInsertAt(0, 'hello', clkA()));
      alice.applyLocal(alice.state.deltaInsertAt(1, ' ', clkA()));
      alice.applyLocal(alice.state.deltaInsertAt(2, 'world', clkA()));

      // Same-node sequential deltas: must all survive composition.
      expect(alice.state.values, ['hello', ' ', 'world']);

      // Ship just the delta.
      bob.applyRemote(alice.flushDelta());
      expect(bob.state.values, ['hello', ' ', 'world']);

      // Bob edits, ships back.
      bob.applyLocal(bob.state.deltaInsertAt(3, '!', Hlc(5000, 0, 'B')));
      alice.applyRemote(bob.flushDelta());
      expect(alice.state.values, ['hello', ' ', 'world', '!']);
    });
  });

  group('Sequence — pruning', () {
    test('drops tombstoned entries whose ids are stable + leafy', () {
      final clk = clockOf('A');
      final aDot = clk();
      final bDot = clk();
      var s = Sequence<String>.empty()
          .insertAt(0, 'a', aDot)
          .insertAt(1, 'b', bDot);
      s = s.removeAt(1); // b tombstoned, leaf
      expect(s.entries.length, 2);

      s = s.prune(DotSet.from({bDot}));
      expect(s.entries.length, 1);
      expect(s.entries.containsKey(bDot), isFalse);
      expect(s.values, ['a']);
    });

    test('keeps a tombstone with live descendants', () {
      final clk = clockOf('A');
      final aDot = clk();
      final bDot = clk();
      // b is appended after a → b becomes RIGHT child of a.
      var s = Sequence<String>.empty()
          .insertAt(0, 'a', aDot)
          .insertAt(1, 'b', bDot);
      s = s.removeAt(0); // tombstone a; b stays alive

      // a is stable, but b (a's RIGHT child) is alive → a must stay.
      s = s.prune(DotSet.from({aDot}));
      expect(s.entries.containsKey(aDot), isTrue);
      expect(s.values, ['b']);
    });

    test('never drops live entries', () {
      final clk = clockOf('A');
      final aDot = clk();
      final s = Sequence<String>.empty().insertAt(0, 'a', aDot);
      final pruned = s.prune(DotSet.from({aDot}));
      expect(pruned.entries.containsKey(aDot), isTrue);
      expect(pruned.values, ['a']);
    });

    test('prune is idempotent', () {
      final clk = clockOf('A');
      var s = Sequence<String>.empty()
          .insertAt(0, 'a', clk())
          .insertAt(1, 'b', clk())
          .removeAt(0);
      final stable = DotSet.from(s.entries.keys);
      final once = s.prune(stable);
      final twice = once.prune(stable);
      expect(twice, once);
    });

    // Builds a right-chain of [n] entries (each the RIGHT child of the
    // previous) via [Sequence.fromRaw]. Every entry is tombstoned except
    // when [liveTail] is set, in which case the last one stays live.
    // A linearly-typed note IS a right-chain this deep, so this mirrors
    // the real GC input on a large single-author file.
    Sequence<String> deepChain(int n, {required bool liveTail}) {
      final entries = <Hlc, SeqEntry<String>>{};
      Hlc? prev;
      for (var i = 0; i < n; i++) {
        final dot = Hlc(1000, i + 1, 'A');
        entries[dot] = SeqEntry<String>(
          id: dot,
          parent: prev,
          side: SequenceSide.right,
          value: 'c$i',
          tombstoned: liveTail ? i != n - 1 : true,
        );
        prev = dot;
      }
      return Sequence<String>.fromRaw(entries);
    }

    test(
      'prune keeps a deep tombstone chain with a live tail (no overflow)',
      () {
        // Regression: hasLiveDescendant recursed to full tree depth and
        // crashed with StackOverflowError past ~10k on the VM (earlier on
        // dart2js). Every tombstone here has the live tail as a descendant,
        // so none is prunable — but resolving that must not blow the stack.
        const n = 50000;
        final s = deepChain(n, liveTail: true);
        final pruned = s.prune(DotSet.from(s.entries.keys));
        expect(pruned.entries.length, n);
        expect(pruned.values, ['c${n - 1}']);
      },
    );

    test('prune drops a fully-tombstoned deep chain (no overflow)', () {
      // The drop path at depth: a wholly-deleted chain, all stable, must
      // collapse to empty via the bottom-up (iterative) descendant check.
      const n = 50000;
      final s = deepChain(n, liveTail: false);
      final pruned = s.prune(DotSet.from(s.entries.keys));
      expect(pruned.entries, isEmpty);
      expect(pruned.values, isEmpty);
    });
  });

  group('Sequence — non-interleaving (Fugue property)', () {
    // The defining reason to pick Fugue over RGA/Logoot: two runs typed
    // concurrently at the same position must NOT interleave — each stays
    // a contiguous block. This models the real sync_v3 path: a device
    // authors a whole run (the diff of a file save), and devices merge by
    // join. Nothing else in the suite guards this property — degrade
    // _resolveInsertion toward RGA and every other test still passes.
    //
    // REGRESSION-DETECTING POWER lives in the clock design below: A and B
    // share the SAME millis, so their dots INTERLEAVE in HLC order
    // (A#1 < B#1 < A#2 < B#2 < …). A correct Fugue keeps each run as one
    // subtree, so the merged order is contiguous *despite* the interleaved
    // ids. A broken resolver that flattens both runs into siblings of a
    // common parent sorts them by id and thus WEAVES them — caught as a
    // transition-count violation. If A and B instead used disjoint id
    // ranges (e.g. millis 2000 vs 3000), every A-dot would sort before
    // every B-dot and even a fully broken resolver would look contiguous —
    // the test would be green and worthless. Do NOT separate the ranges.
    Hlc Function() clockOf(String node) {
      var last = Hlc(1000, 0, node);
      return () {
        last = Hlc(last.millis, last.counter + 1, node);
        return last;
      };
    }

    // Forward run: values label0..label{n-1} left to right.
    List<SeqOp<String>> forwardRun(String label, int at, int n) => [
      for (var i = 0; i < n; i++) SeqOp.insert(at + i, '$label$i'),
    ];

    // Backward run: same visible result, but each char inserted at the
    // SAME index, pushing the previous ones right (caret-stays typing).
    List<SeqOp<String>> backwardRun(String label, int at, int n) => [
      for (var i = n - 1; i >= 0; i--) SeqOp.insert(at, '$label$i'),
    ];

    // Applies an insert-only run either as one applyOps batch (the real
    // sync path, exercising _resolveInsertionBatched) or as drip insertAt
    // calls (exercising _resolveInsertionInListWithChars). Both resolution
    // paths must uphold the property, so the fuzz runs against each.
    Sequence<String> applyRun(
      Sequence<String> base,
      List<SeqOp<String>> ops,
      Hlc Function() clk, {
      required bool viaBatch,
    }) {
      if (viaBatch) return base.applyOps(ops, clk);
      var s = base;
      for (final op in ops) {
        final ins = op as SeqOpInsert<String>;
        s = s.insertAt(ins.at, ins.value, clk());
      }
      return s;
    }

    // null == ok. Otherwise a description of the violation.
    String? violation(List<String> merged, int n) {
      final letters = <String>[];
      final seqs = {'A': <int>[], 'B': <int>[]};
      for (final v in merged) {
        final lab = v[0];
        if (seqs.containsKey(lab)) {
          letters.add(lab);
          seqs[lab]!.add(int.parse(v.substring(1)));
        }
      }
      var transitions = 0;
      for (var i = 1; i < letters.length; i++) {
        if (letters[i] != letters[i - 1]) transitions++;
      }
      if (transitions > 1) {
        return 'INTERLEAVED (${letters.join()})';
      }
      for (final e in seqs.entries) {
        if (e.value.length != n) return '${e.key}-run wrong length ${e.value}';
        for (var i = 0; i < n; i++) {
          if (e.value[i] != i) return '${e.key}-run scrambled ${e.value}';
        }
      }
      return null;
    }

    void runFuzz({required bool viaBatch}) {
      for (var seed = 0; seed < 500; seed++) {
        final rng = Random(seed);
        // Shared base with some tombstones, authored by device 'S'.
        var base = Sequence<String>.empty();
        final sClk = clockOf('S');
        final baseLen = 1 + rng.nextInt(5);
        for (var i = 0; i < baseLen; i++) {
          base = base.insertAt(
            base.length == 0 ? 0 : rng.nextInt(base.length + 1),
            'S$i',
            sClk(),
          );
        }
        for (var i = 0, d = rng.nextInt(base.length); i < d; i++) {
          if (base.length == 0) break;
          base = base.removeAt(rng.nextInt(base.length));
        }

        final at = base.length == 0 ? 0 : rng.nextInt(base.length + 1);
        final n = 2 + rng.nextInt(4);
        final aOps = rng.nextBool()
            ? forwardRun('A', at, n)
            : backwardRun('A', at, n);
        final bOps = rng.nextBool()
            ? forwardRun('B', at, n)
            : backwardRun('B', at, n);

        // A and B share millis so their ids interleave in HLC order — see
        // the group comment. Each is a concurrent run against `base`.
        final a = applyRun(base, aOps, clockOf('A'), viaBatch: viaBatch);
        final b = applyRun(base, bOps, clockOf('B'), viaBatch: viaBatch);

        final ab = a.join(b);
        final ba = b.join(a);
        expect(ab.values, ba.values, reason: 'diverges at seed=$seed');
        final v = violation(ab.values, n);
        expect(
          v,
          isNull,
          reason:
              'seed=$seed at=$at n=$n viaBatch=$viaBatch '
              'merged=${ab.values} -> $v',
        );
      }
    }

    test('two concurrent runs never interleave — applyOps batch path', () {
      runFuzz(viaBatch: true);
    });

    // Both resolution paths use the same ancestry-based resolver, so the
    // drip path upholds non-interleaving even across a tombstoned right
    // subtree with adversarially interleaved ids (previously a known bug —
    // it misrouted the run and flattened it into siblings).
    test('two concurrent runs never interleave — drip insertAt path', () {
      runFuzz(viaBatch: false);
    });

    test('applyOps splices a diff run at the requested index '
        '(realistic HLC: edits newer than base)', () {
      // sync_v3's core invariant: applyOps(diffOps).values == newText.
      // Realistic ordering — base authored OLDER (smaller millis) than the
      // edit, as sync_v3 runs it (a fresh edit's HLC dominates existing
      // content). The resolver is now correct under any ordering; this
      // guards the absolute-position invariant that the non-interleaving
      // fuzz above does not check directly.
      Hlc Function() clockAt(String node, int ms) {
        var last = Hlc(ms, 0, node);
        return () {
          last = Hlc(last.millis, last.counter + 1, node);
          return last;
        };
      }

      for (var seed = 0; seed < 500; seed++) {
        final rng = Random(seed);
        var base = Sequence<String>.empty();
        final sClk = clockAt('S', 500); // base older -> smaller ids
        final baseLen = 1 + rng.nextInt(5);
        for (var i = 0; i < baseLen; i++) {
          base = base.insertAt(
            base.length == 0 ? 0 : rng.nextInt(base.length + 1),
            'S$i',
            sClk(),
          );
        }
        for (var i = 0, d = rng.nextInt(base.length); i < d; i++) {
          if (base.length == 0) break;
          base = base.removeAt(rng.nextInt(base.length));
        }
        final at = base.length == 0 ? 0 : rng.nextInt(base.length + 1);
        final n = 2 + rng.nextInt(4);
        final ops = rng.nextBool()
            ? forwardRun('A', at, n)
            : backwardRun('A', at, n);
        final result = base.applyOps(ops, clockAt('A', 1000)); // edit newer
        final expected = [...base.values]
          ..insertAll(at, [for (var i = 0; i < n; i++) 'A$i']);
        expect(result.values, expected, reason: 'seed=$seed at=$at');
      }
    });
  });

  group('Sequence — randomized convergence (fuzz)', () {
    // Reproducible: a fixed seed deterministically generates the same
    // op sequences each run, so any failure is debuggable from the
    // seed alone. Property tested: regardless of how a session of
    // independent edits is reduced (a.join(b) vs b.join(a), or any
    // pairwise reduction), the resulting visible values are identical.
    Sequence<String> randomSession({
      required Random rng,
      required Sequence<String> base,
      required String nodeId,
      required int opCount,
      required int startMs,
    }) {
      var s = base;
      var counter = 0;
      Hlc dot() {
        counter += 1;
        return Hlc(startMs, counter, nodeId);
      }

      for (var i = 0; i < opCount; i++) {
        // 70% inserts, 30% deletes (when something is removable).
        final wantDelete = s.length > 0 && rng.nextDouble() < 0.3;
        if (wantDelete) {
          final idx = rng.nextInt(s.length);
          s = s.removeAt(idx);
        } else {
          final idx = s.length == 0 ? 0 : rng.nextInt(s.length + 1);
          final ch = String.fromCharCode(0x61 + rng.nextInt(26)); // a..z
          s = s.insertAt(idx, ch, dot());
        }
      }
      return s;
    }

    test('two-replica concurrent sessions converge under any join order', () {
      for (var seed = 1; seed <= 50; seed++) {
        final rngBase = Random(seed);
        final rngA = Random(seed * 31 + 7);
        final rngB = Random(seed * 31 + 11);

        // Shared base: a few characters seeded by replica BASE so both
        // sides observe identical initial state.
        final base = randomSession(
          rng: rngBase,
          base: Sequence<String>.empty(),
          nodeId: 'BASE',
          opCount: 5 + rngBase.nextInt(10),
          startMs: 1000,
        );

        // Independent concurrent sessions on top of the shared base.
        final a = randomSession(
          rng: rngA,
          base: base,
          nodeId: 'A',
          opCount: 20 + rngA.nextInt(30),
          startMs: 2000,
        );
        final b = randomSession(
          rng: rngB,
          base: base,
          nodeId: 'B',
          opCount: 20 + rngB.nextInt(30),
          startMs: 3000,
        );

        final mAB = a.join(b);
        final mBA = b.join(a);
        expect(mAB, mBA, reason: 'commutativity failed at seed=$seed');
        expect(
          mAB.values,
          mBA.values,
          reason: 'visible projection diverges at seed=$seed',
        );
        // Idempotency under repeated join.
        expect(
          mAB.join(a),
          mAB,
          reason: 'idempotency (re-join A) failed at seed=$seed',
        );
        expect(
          mAB.join(b),
          mAB,
          reason: 'idempotency (re-join B) failed at seed=$seed',
        );
      }
    });

    test('three-replica associativity over random sessions', () {
      for (var seed = 1; seed <= 30; seed++) {
        final rngBase = Random(seed);
        final rngA = Random(seed * 31 + 7);
        final rngB = Random(seed * 31 + 11);
        final rngC = Random(seed * 31 + 13);

        final base = randomSession(
          rng: rngBase,
          base: Sequence<String>.empty(),
          nodeId: 'BASE',
          opCount: 5,
          startMs: 1000,
        );
        final a = randomSession(
          rng: rngA,
          base: base,
          nodeId: 'A',
          opCount: 15,
          startMs: 2000,
        );
        final b = randomSession(
          rng: rngB,
          base: base,
          nodeId: 'B',
          opCount: 15,
          startMs: 3000,
        );
        final c = randomSession(
          rng: rngC,
          base: base,
          nodeId: 'C',
          opCount: 15,
          startMs: 4000,
        );

        final left = a.join(b).join(c);
        final right = a.join(b.join(c));
        expect(left, right, reason: 'associativity failed at seed=$seed');
        expect(left.values, right.values);
      }
    });
  });

  group('Sequence — fast-path equivalence', () {
    // The fast-path mutations must produce the SAME state as the
    // generic insertAt(length, ...) / insertAt(0, ...). Otherwise
    // peers using different code paths would diverge even though
    // they observed the same logical edit.
    test('append === insertAt at tail (same characters, dots)', () {
      final clk = clockOf('A');
      var slow = Sequence<String>.empty();
      var fast = Sequence<String>.empty();
      for (var i = 0; i < 200; i++) {
        final ch = 'c$i';
        final d = clk();
        slow = slow.insertAt(slow.length, ch, d);
        fast = fast.append(ch, d);
      }
      expect(fast, slow);
      expect(fast.values, slow.values);
    });

    test('prepend === insertAt(0, ...) (same characters, dots)', () {
      final clk = clockOf('A');
      var slow = Sequence<String>.empty();
      var fast = Sequence<String>.empty();
      for (var i = 0; i < 200; i++) {
        final ch = 'c$i';
        final d = clk();
        slow = slow.insertAt(0, ch, d);
        fast = fast.prepend(ch, d);
      }
      expect(fast, slow);
      expect(fast.values, slow.values);
    });

    test('mixed append + prepend converges with mirrored slow-path', () {
      final clk = clockOf('A');
      var slow = Sequence<String>.empty();
      var fast = Sequence<String>.empty();
      final rng = Random(7);
      for (var i = 0; i < 200; i++) {
        final ch = String.fromCharCode(0x61 + rng.nextInt(26));
        final d = clk();
        if (rng.nextBool()) {
          slow = slow.insertAt(slow.length, ch, d);
          fast = fast.append(ch, d);
        } else {
          slow = slow.insertAt(0, ch, d);
          fast = fast.prepend(ch, d);
        }
      }
      expect(fast, slow);
      expect(fast.values, slow.values);
    });
  });

  group('Sequence — hint fast paths', () {
    test('prepend after append on a cold-hint sequence lands at index 0', () {
      final clk = clockOf('A');
      // insertAt produces a Sequence with NULL hints — this is the cold start.
      var s = Sequence<String>.empty()
          .insertAt(0, 'a', clk())
          .insertAt(1, 'b', clk());
      s = s.append('c', clk()); // must not poison firstVisibleHint
      s = s.prepend('d', clk());
      expect(s.values, [
        'd',
        'a',
        'b',
        'c',
      ]); // buggy code yields ['a','b','d','c']
    });

    test('append after prepend on a cold-hint sequence lands at the tail', () {
      final clk = clockOf('A');
      var s = Sequence<String>.empty()
          .insertAt(0, 'a', clk())
          .insertAt(1, 'b', clk());
      s = s.prepend('z', clk()); // must not poison lastVisibleHint
      s = s.append('w', clk());
      expect(s.values, [
        'z',
        'a',
        'b',
        'w',
      ]); // buggy code yields ['z','w','a','b']
    });

    test('fast-path hints match slow path from a cold start (fuzz)', () {
      for (var seed = 0; seed < 100; seed++) {
        final rng = Random(seed);
        final clk = clockOf('A');
        // Cold start: build a base via insertAt (null hints), then random
        // append/prepend mix compared against the insertAt slow path.
        var slow = Sequence<String>.empty();
        var fast = Sequence<String>.empty();
        for (var i = 0; i < 3 + rng.nextInt(4); i++) {
          final d = clk();
          slow = slow.insertAt(slow.length, 'b$i', d);
          fast = fast.insertAt(fast.length, 'b$i', d);
        }
        for (var i = 0; i < 30; i++) {
          final d = clk();
          if (rng.nextBool()) {
            slow = slow.insertAt(slow.length, 'x$i', d);
            fast = fast.append('x$i', d);
          } else {
            slow = slow.insertAt(0, 'x$i', d);
            fast = fast.prepend('x$i', d);
          }
        }
        expect(fast.values, slow.values, reason: 'seed=$seed');
        expect(fast, slow, reason: 'seed=$seed');
      }
    });
  });

  group('Sequence — realistic-size sanity', () {
    test('10k-character session round-trips through codec', () {
      const codec = SequenceCodec<String>(StringCodec());
      final rng = Random(42);
      var s = Sequence<String>.empty();
      var counter = 0;
      Hlc dot() {
        counter += 1;
        return Hlc(1000, counter, 'A');
      }

      // 10k inserts at the tail via the O(log N) append fast-path
      // (typing-style workload). The slow `insertAt(s.length, ...)`
      // path is also tested separately at smaller scales above.
      for (var i = 0; i < 10000; i++) {
        s = s.append(String.fromCharCode(0x61 + rng.nextInt(26)), dot());
      }
      expect(s.length, 10000);

      final encoded = codec.encode(s);
      final decoded = codec.decode(encoded);
      expect(decoded.values, s.values);
      expect(decoded.entries.length, s.entries.length);

      // Sanity check: random tombstone of 5% still survives round-trip.
      for (var i = 0; i < 500; i++) {
        s = s.removeAt(rng.nextInt(s.length));
      }
      final encodedT = codec.encode(s);
      final decodedT = codec.decode(encodedT);
      expect(decodedT.values, s.values);
      expect(decodedT.entries.length, s.entries.length);
    });
  });

  group('Sequence — applyOps batch', () {
    test('empty ops list returns identical instance', () {
      final clk = clockOf('A');
      final s = Sequence<String>.empty()
          .insertAt(0, 'a', clk())
          .insertAt(1, 'b', clk());
      expect(identical(s.applyOps([], clk), s), isTrue);
    });

    test('all-out-of-range removes return identical instance', () {
      final clk = clockOf('A');
      final s = Sequence<String>.empty().insertAt(0, 'a', clk());
      final result = s.applyOps([
        const SeqOp.removeAt(5),
        const SeqOp.removeAt(-1),
      ], clk);
      expect(identical(result, s), isTrue);
    });

    test('batch of inserts at tail matches drip insertAt', () {
      final dripClk = clockOf('A');
      var drip = Sequence<String>.empty();
      for (final ch in const ['h', 'e', 'l', 'l', 'o']) {
        drip = drip.insertAt(drip.length, ch, dripClk());
      }

      final batchClk = clockOf('A');
      final batch = Sequence<String>.empty().applyOps(const [
        SeqOp.insert(0, 'h'),
        SeqOp.insert(1, 'e'),
        SeqOp.insert(2, 'l'),
        SeqOp.insert(3, 'l'),
        SeqOp.insert(4, 'o'),
      ], batchClk);

      expect(batch.values, drip.values);
      expect(batch.entries.length, drip.entries.length);
    });

    test('mixed insert + remove in one batch resolves indices in-order', () {
      final clk = clockOf('A');
      // Start with "abcd"; in one batch: insert 'X' at 2 → "abXcd",
      // then remove at 1 → "aXcd", then insert 'Y' at 4 → "aXcdY".
      var s = Sequence<String>.empty();
      for (final ch in const ['a', 'b', 'c', 'd']) {
        s = s.insertAt(s.length, ch, clk());
      }
      final result = s.applyOps(const [
        SeqOp.insert(2, 'X'),
        SeqOp.removeAt(1),
        SeqOp.insert(4, 'Y'),
      ], clk);
      expect(result.values, ['a', 'X', 'c', 'd', 'Y']);
    });

    test('batch equivalent to drip for randomized edits', () {
      // Same op script applied via drip (insertAt/removeAt) and via
      // applyOps must produce identical visible projections AND
      // identical entry counts. Tombstones may differ in order but
      // not in count.
      final rng = Random(7);
      final ops = <SeqOp<String>>[];
      var virtualLen = 0;
      for (var i = 0; i < 200; i++) {
        final wantInsert = virtualLen == 0 || rng.nextDouble() < 0.7;
        if (wantInsert) {
          final at = rng.nextInt(virtualLen + 1);
          ops.add(
            SeqOp.insert(at, String.fromCharCode(0x61 + rng.nextInt(26))),
          );
          virtualLen += 1;
        } else {
          final at = rng.nextInt(virtualLen);
          ops.add(SeqOp.removeAt(at));
          virtualLen -= 1;
        }
      }

      Hlc Function() seq(String node) {
        var c = 0;
        return () {
          c += 1;
          return Hlc(1000, c, node);
        };
      }

      var drip = Sequence<String>.empty();
      final dripClk = seq('A');
      for (final op in ops) {
        switch (op) {
          case SeqOpInsert<String>(at: final at, value: final v):
            drip = drip.insertAt(at, v, dripClk());
          case SeqOpRemove<String>(at: final at):
            drip = drip.removeAt(at);
        }
      }

      final batch = Sequence<String>.empty().applyOps(ops, seq('A'));

      expect(batch.values, drip.values);
      expect(batch.entries.length, drip.entries.length);
    });

    test('applyOps batches converge across two replicas via join', () {
      // Two replicas independently apply different batches; joining
      // both ways converges to the same Sequence.
      Hlc Function() seq(String node) {
        var c = 0;
        return () {
          c += 1;
          return Hlc(1000, c, node);
        };
      }

      final a = Sequence<String>.empty().applyOps(const [
        SeqOp.insert(0, 'a'),
        SeqOp.insert(1, 'b'),
        SeqOp.insert(2, 'c'),
      ], seq('A'));
      final b = Sequence<String>.empty().applyOps(const [
        SeqOp.insert(0, 'x'),
        SeqOp.insert(1, 'y'),
      ], seq('B'));

      final ab = a.join(b);
      final ba = b.join(a);
      expect(ab.values, ba.values);
      expect(ab, ba);
    });
  });

  group('Sequence — perf regression (was: O(K·N) drip hang)', () {
    test('applyOps with K=1000 on N=10k base completes under 2s on VM', () {
      // Pre-migration this scenario hung Obsidian for ~77s on dart2js.
      // VM is faster than dart2js by ~3-5x for this workload, but a
      // 2s budget on VM still catches the algorithmic regression that
      // mattered. The 10k seed is half the size of the file that
      // produced the original hang — enough to expose O(K·N) but fast
      // enough to keep CI cheap.
      var s = Sequence<String>.empty();
      var counter = 0;
      Hlc dot() {
        counter += 1;
        return Hlc(1000, counter, 'A');
      }

      for (var i = 0; i < 10000; i++) {
        s = s.append(String.fromCharCode(0x61 + (i % 26)), dot());
      }
      expect(s.length, 10000);

      final ops = <SeqOp<String>>[];
      for (var i = 0; i < 1000; i++) {
        ops.add(SeqOp.insert(5000 + i, 'X'));
      }

      final sw = Stopwatch()..start();
      final result = s.applyOps(ops, dot);
      sw.stop();

      expect(result.length, 11000);
      expect(
        sw.elapsedMilliseconds < 2000,
        isTrue,
        reason: 'applyOps took ${sw.elapsedMilliseconds}ms — regression?',
      );
    });

    test(
      'memoized _visible: repeated values reads on same instance are cheap',
      () {
        // Build a non-trivial sequence, then read .values many times.
        // First call computes; subsequent calls return the cached list.
        // Without memoization each call rebuilds _visible() at O(N log N).
        var s = Sequence<String>.empty();
        var counter = 0;
        Hlc dot() {
          counter += 1;
          return Hlc(1000, counter, 'A');
        }

        for (var i = 0; i < 5000; i++) {
          s = s.append(String.fromCharCode(0x61 + (i % 26)), dot());
        }
        // Warm the cache.
        final first = s.values;
        expect(first.length, 5000);

        final sw = Stopwatch()..start();
        for (var i = 0; i < 100; i++) {
          // ignore: unused_local_variable
          final v = s.values;
        }
        sw.stop();
        // 100 reads of a 5k-Sequence's projection should be trivial when
        // memoized. If we ever break the cache, this turns multi-second.
        expect(
          sw.elapsedMilliseconds < 500,
          isTrue,
          reason: '100 cached .values reads took ${sw.elapsedMilliseconds}ms',
        );
      },
    );
  });
}
