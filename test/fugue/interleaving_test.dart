// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Direct non-interleaving guard on the optimised Fugue (Theorem 1). Two
// concurrent runs at the same position, with INTERLEAVED ids (both replicas
// mint from the same base counter, so their dots alternate in sort order),
// must each stay a contiguous block after merge.
import 'dart:math';

import 'package:convergent/fugue.dart';
import 'package:test/test.dart';

void main() {
  List<String> mergedRuns({
    required Fugue<String> base,
    required bool aBackward,
    required bool bBackward,
    required int at,
    required int n,
  }) {
    Fugue<String> run(String label, bool backward) {
      final f = base.clone();
      final clk = LamportClock(label)..observeAll(base.dots);
      if (backward) {
        for (var i = n - 1; i >= 0; i--) {
          f.insert(at, '$label$i', clk.tick());
        }
      } else {
        for (var i = 0; i < n; i++) {
          f.insert(at + i, '$label$i', clk.tick());
        }
      }
      return f;
    }

    final a = run('A', aBackward);
    final b = run('B', bBackward);
    return (a.clone()..merge(b)).values;
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

  test('all forward/backward combinations stay contiguous', () {
    final base = Fugue<String>();
    final s = LamportClock('S');
    base.insert(0, 'L', s.tick());
    base.insert(1, 'R', s.tick());
    for (final aB in [false, true]) {
      for (final bB in [false, true]) {
        final v = mergedRuns(
          base: base,
          aBackward: aB,
          bBackward: bB,
          at: 1,
          n: 4,
        );
        expect(violation(v, 4), isNull, reason: 'aBwd=$aB bBwd=$bB -> $v');
      }
    }
  });

  test('random bases with tombstones (fuzz)', () {
    for (var seed = 0; seed < 300; seed++) {
      final rng = Random(seed);
      final base = Fugue<String>();
      final s = LamportClock('S');
      final baseLen = 1 + rng.nextInt(5);
      for (var i = 0; i < baseLen; i++) {
        base.insert(
          base.length == 0 ? 0 : rng.nextInt(base.length + 1),
          'S$i',
          s.tick(),
        );
      }
      for (var i = 0, d = rng.nextInt(base.length); i < d; i++) {
        if (base.length == 0) break;
        base.delete(rng.nextInt(base.length));
      }
      final at = base.length == 0 ? 0 : rng.nextInt(base.length + 1);
      final n = 2 + rng.nextInt(4);
      final v = mergedRuns(
        base: base,
        aBackward: rng.nextBool(),
        bBackward: rng.nextBool(),
        at: at,
        n: n,
      );
      expect(violation(v, n), isNull, reason: 'seed=$seed at=$at n=$n -> $v');
    }
  });
}
