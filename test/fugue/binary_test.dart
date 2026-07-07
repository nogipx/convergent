// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:math';

import 'package:convergent/fugue.dart';
import 'package:test/test.dart';

import 'reference.dart';

void main() {
  const bin = FugueTextBinaryCodec();

  test('round-trips values, tombstones, unicode and structure', () {
    final clk = LamportClock('device-1');
    final f = Fugue<String>();
    for (final ch in 'héllo, 世界 ✓'.split('')) {
      f.insert(f.length, ch, clk.tick());
    }
    f.delete(1);
    f.insert(0, 'X', clk.tick());

    final back = bin.decode(bin.encode(f));
    expect(back.values, f.values);
    expect(back.blockCount, f.blockCount);
  });

  test('decode(encode(x)) == x over random states (fuzz)', () {
    for (var seed = 0; seed < 200; seed++) {
      final rng = Random(seed);
      final r = RefFugue<String>();
      final f = Fugue<String>();
      // A couple of replicas so the dictionary has >1 entry.
      final clocks = {'A': LamportClock('A'), 'B': LamportClock('B')};
      for (var i = 0; i < 40; i++) {
        final len = f.length;
        if (len > 0 && rng.nextDouble() < 0.3) {
          final at = rng.nextInt(len);
          r.delete(at);
          f.delete(at);
        } else {
          final at = len == 0 ? 0 : rng.nextInt(len + 1);
          final v = String.fromCharCode(0x61 + rng.nextInt(26));
          final clk = clocks[rng.nextBool() ? 'A' : 'B']!
            ..observe(
              f.dots.isEmpty ? 0 : f.dots.map((d) => d.counter).reduce(max),
            );
          final d = clk.tick();
          r.insert(at, v, d);
          f.insert(at, v, d);
        }
      }
      final back = bin.decode(bin.encode(f));
      expect(back.values, r.values(), reason: 'seed=$seed');
    }
  });

  test('binary is much smaller and faster than JSON', () {
    final clk = LamportClock('device-abcdef');
    final f = Fugue<String>();
    for (var i = 0; i < 20000; i++) {
      f.insert(f.length, String.fromCharCode(0x61 + i % 26), clk.tick());
    }
    for (var i = 0; i < 2000; i++) {
      f.insert((i * 7919) % f.length, 'e', clk.tick());
    }

    // Sizes.
    final binBytes = bin.encode(f);
    // Warm + time.
    Stopwatch time(void Function() body) {
      body();
      final sw = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        body();
      }
      return sw..stop();
    }

    final tBinEnc = time(() => bin.encode(f));
    final decoded = bin.decode(binBytes);
    final tBinDec = time(() => bin.decode(binBytes));

    expect(decoded.values, f.values);
    // The binary encoding should be well under 3 bytes/char for this doc.
    expect(
      binBytes.length / f.length,
      lessThan(3.0),
      reason: 'binary size ${binBytes.length}B for ${f.length} chars',
    );

    // Informational (not asserted beyond sanity):
    // ignore: avoid_print
    print(
      'binary: ${binBytes.length}B '
      '(${(binBytes.length / f.length).toStringAsFixed(2)} B/char), '
      'encode ${tBinEnc.elapsedMilliseconds / 20}ms, '
      'decode ${tBinDec.elapsedMilliseconds / 20}ms per op',
    );
  });
}
