// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:convergent/convergent.dart';
import 'package:test/test.dart';

void main() {
  group('Hlc — paper Figure 5 conformance', () {
    test('Send/Local: wall ahead of l → <wall, 0>', () {
      final base = Hlc(100, 5, 'A');
      final next = base.increment(200);
      expect(next, Hlc(200, 0, 'A'));
    });

    test('Send/Local: wall equal/behind l → counter++', () {
      final base = Hlc(200, 5, 'A');
      expect(base.increment(150), Hlc(200, 6, 'A'));
      expect(base.increment(200), Hlc(200, 6, 'A'));
    });

    test('Receive: pt strictly wins → <pt, 0>', () {
      final local = Hlc(100, 3, 'A');
      final remote = Hlc(150, 7, 'B');
      final out = local.receive(remote, 300);
      expect(out, Hlc(300, 0, 'A'));
    });

    test('Receive: l == l\' == l.m → max(c, c.m) + 1', () {
      final local = Hlc(200, 3, 'A');
      final remote = Hlc(200, 7, 'B');
      final out = local.receive(remote, 100);
      expect(out, Hlc(200, 8, 'A'));
    });

    test('Receive: l\' wins → c + 1', () {
      final local = Hlc(200, 3, 'A');
      final remote = Hlc(150, 9, 'B');
      final out = local.receive(remote, 100);
      expect(out, Hlc(200, 4, 'A'));
    });

    test('Receive: l.m wins → c.m + 1', () {
      final local = Hlc(150, 9, 'A');
      final remote = Hlc(200, 3, 'B');
      final out = local.receive(remote, 100);
      expect(out, Hlc(200, 4, 'A'));
    });
  });

  group('Hlc — self-stabilization (paper §4)', () {
    test('without maxSkewMs: poisoned future remote dominates', () {
      final local = Hlc(1000, 0, 'A');
      // Remote claims it is 100 years in the future.
      final poisoned = Hlc(1000 + 100 * 365 * 86400 * 1000, 0, 'attacker');
      final out = local.receive(poisoned, 1000);
      expect(
        out.millis,
        poisoned.millis,
        reason: 'default behaviour respects paper Fig.5 — no defence',
      );
    });

    test('with maxSkewMs: poisoned future remote is clamped to wall', () {
      final local = Hlc(1000, 0, 'A');
      final poisoned = Hlc(1000 + 100 * 365 * 86400 * 1000, 0, 'attacker');
      final out = local.receive(poisoned, 1000, maxSkewMs: 5 * 60 * 1000);
      expect(
        out.millis,
        1000,
        reason: 'remote.millis > wallMs + bound → treated as wallMs',
      );
    });

    test('with maxSkewMs: remote within bound is accepted normally', () {
      final local = Hlc(1000, 0, 'A');
      // Remote is 30 seconds ahead — within 5-minute bound.
      final remote = Hlc(31000, 3, 'B');
      final out = local.receive(remote, 1000, maxSkewMs: 5 * 60 * 1000);
      expect(
        out,
        Hlc(31000, 4, 'A'),
        reason: 'within bound → normal Fig.5 behaviour',
      );
    });

    test('maxSkewMs does NOT clamp same-physical-time concurrent counters', () {
      // Both at wall=1000; remote claims same millis with higher counter.
      final local = Hlc(1000, 2, 'A');
      final remote = Hlc(1000, 9, 'B');
      final out = local.receive(remote, 1000, maxSkewMs: 5 * 60 * 1000);
      expect(out, Hlc(1000, 10, 'A'));
    });
  });
}
