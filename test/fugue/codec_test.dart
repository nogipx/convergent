// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Round-trips through the run-length codec, and shows the coalescing win:
// a typed-and-edited document encodes to a handful of block rows, not one
// row per character.
import 'dart:convert';
import 'dart:math';

import 'package:convergent/src/codec/codec.dart';
import 'package:convergent/src/fugue/dot.dart';
import 'package:convergent/src/fugue/fugue.dart';
import 'package:convergent/src/fugue/fugue_codec.dart';
import 'package:test/test.dart';

import 'reference.dart';

// Encode → JSON string → decode, exercising the full wire path.
Fugue<String> roundtrip(Fugue<String> f) {
  final json = jsonDecode(jsonEncode(f.encode((s) => s))) as Object;
  return Fugue.decode<String>(json, (o) => o as String);
}

void main() {
  group('Fugue codec', () {
    test('round-trips values, tombstones and block structure', () {
      final clk = LamportClock('A');
      final f = Fugue<String>();
      for (final ch in 'hello world'.split('')) {
        f.insert(f.length, ch, clk.tick());
      }
      f.delete(5); // the space
      f.insert(0, 'X', clk.tick());

      final back = roundtrip(f);
      expect(back.values, f.values);
      expect(back.blockCount, f.blockCount);
      expect(back.length, f.length);
    });

    test('a 10k typed run encodes to a single block row', () {
      final clk = LamportClock('A');
      final f = Fugue<String>();
      for (var i = 0; i < 10000; i++) {
        f.insert(f.length, String.fromCharCode(0x61 + (i % 26)), clk.tick());
      }
      final json = f.encode((s) => s) as Map;
      expect(
        (json['b'] as List).length,
        1,
        reason: '10k-char run must serialise as one waypoint',
      );

      final back = roundtrip(f);
      expect(back.length, 10000);
      expect(back.values, f.values);
    });

    test('deleted ranges round-trip (RLE)', () {
      final clk = LamportClock('A');
      final f = Fugue<String>();
      for (var i = 0; i < 20; i++) {
        f.insert(f.length, '$i;', clk.tick());
      }
      // Peel a contiguous middle band by repeatedly deleting the same index.
      for (var i = 0; i < 5; i++) {
        f.delete(7);
      }
      expect(roundtrip(f).values, f.values);
    });

    test('decode(encode(x)) == x over random states (fuzz)', () {
      for (var seed = 0; seed < 60; seed++) {
        final rng = Random(seed);
        final r = RefFugue<String>();
        final f = Fugue<String>();
        final clk = LamportClock('A');
        for (var i = 0; i < 30; i++) {
          final len = f.length;
          if (len > 0 && rng.nextDouble() < 0.3) {
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
        expect(roundtrip(f).values, r.values(), reason: 'seed=$seed');
      }
    });

    test('encode row order is canonical across join order', () {
      final a = Fugue<String>()..insert(0, 'a', LamportClock('A').tick());
      final b = Fugue<String>()..insert(0, 'b', LamportClock('B').tick());
      final xy = a.join(b);
      final yx = b.join(a);
      expect(xy.values, yx.values);
      expect(jsonEncode(xy.encode((s) => s)), jsonEncode(yx.encode((s) => s)));
    });

    test('FugueCodec<T>(Codec<T>) round-trips via the element codec', () {
      const codec = FugueCodec<String>(StringCodec());
      final clk = LamportClock('A');
      final f = Fugue<String>();
      for (final ch in 'the quick brown fox'.split('')) {
        f.insert(f.length, ch, clk.tick());
      }
      f.delete(3);
      final json = jsonDecode(jsonEncode(codec.encode(f))) as Object;
      final back = codec.decode(json);
      expect(back.values, f.values);
    });
  });
}
