import 'dart:math';

import 'package:convergent/fugue.dart';
import 'package:test/test.dart';

void main() {
  Fugue<String> typed(String text, LamportClock clk) {
    final f = Fugue<String>();
    for (final ch in text.split('')) {
      f.insert(f.length, ch, clk.tick());
    }
    return f;
  }

  group('Fugue — position API', () {
    test('positionAt / indexOf round-trip', () {
      final clk = LamportClock('A');
      final f = typed('abc', clk);
      for (var i = 0; i < f.length; i++) {
        expect(f.indexOf(f.positionAt(i)), i);
      }
      expect(f.indexOf(const Dot(999, 'Z')), -1);
    });

    test('a position is stable across edits elsewhere', () {
      final clk = LamportClock('A');
      final f = typed('abc', clk);
      final posB = f.positionAt(1); // the 'b'
      expect(f.valueAt(posB), 'b');

      // Insert before it — the index shifts, the position does not.
      f.insert(0, 'X', clk.tick());
      f.insert(0, 'Y', clk.tick());
      expect(f.values.join(), 'YXabc');
      expect(f.indexOf(posB), 3); // moved from 1 to 3
      expect(f.valueAt(posB), 'b'); // still the same element
    });

    test('insertAfter a TOMBSTONED anchor still lands at its position', () {
      final clk = LamportClock('A');
      final f = typed('abc', clk);
      final posB = f.positionAt(1);
      f.deleteDot(posB); // delete 'b'
      expect(f.values.join(), 'ac');
      expect(f.isLive(posB), isFalse);

      // The deleted 'b' still anchors the gap it left.
      f.insertAfter(f.positionAt(0), 'X', clk.tick()); // after 'a'
      expect(f.values.join(), 'aXc');
    });

    test('insertAfter(null) inserts at the start', () {
      final clk = LamportClock('A');
      final f = typed('abc', clk);
      f.insertAfter(null, 'Z', clk.tick());
      expect(f.values.join(), 'Zabc');
    });

    test('insertAfter == index insert for live anchors (fuzz)', () {
      for (var seed = 0; seed < 300; seed++) {
        final rng = Random(seed);
        // Build a shared base with the same dots on two clones.
        final baseClk = LamportClock('A');
        final base = <(int, String)>[]; // (dotCounter, value)
        final f0 = Fugue<String>();
        for (var i = 0; i < 6 + rng.nextInt(6); i++) {
          final at = f0.length == 0 ? 0 : rng.nextInt(f0.length + 1);
          final v = String.fromCharCode(0x61 + rng.nextInt(26));
          final d = baseClk.tick();
          f0.insert(at, v, d);
          base.add((d.counter, v));
        }

        final viaIndex = f0.clone();
        final viaAnchor = f0.clone();

        final at = f0.length == 0 ? 0 : rng.nextInt(f0.length + 1);
        final dot = baseClk.tick();
        const val = '*';

        viaIndex.insert(at, val, dot);
        final anchor = at == 0 ? null : viaAnchor.positionAt(at - 1);
        viaAnchor.insertAfter(anchor, val, dot);

        expect(viaAnchor.values, viaIndex.values, reason: 'seed=$seed at=$at');
      }
    });
  });
}
