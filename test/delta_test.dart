// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:convergent/convergent.dart';
import 'package:test/test.dart';

void main() {
  final a = Hlc(100, 0, 'alice');
  final b = Hlc(200, 0, 'bob');
  final c = Hlc(300, 0, 'alice');

  group('Delta producers', () {
    test('GSet.deltaAdd joins to add(x)', () {
      final full = GSet<int>.empty().add(1).add(2);
      final viaDelta = GSet<int>.empty()
          .join(GSet.deltaAdd(1))
          .join(GSet.deltaAdd(2));
      expect(viaDelta, full);
    });

    test('MvRegister.deltaSet joins to set(...)', () {
      final full = MvRegister<String>.empty().set(
        'x',
        a,
        const CausalContext.empty(),
      );
      final viaDelta = MvRegister<String>.empty().join(
        MvRegister.deltaSet('x', a, const CausalContext.empty()),
      );
      expect(viaDelta, full);
    });

    test('PnCounter delta-increment composes', () {
      // Each delta is computed from the evolving state: it carries this
      // replica's POST-mutation total (a join-inflation), so it must be
      // produced against the counter as it stands at that point.
      var s = PnCounter.empty();
      s = s.join(s.deltaIncrement(a, 5)); // A: (5, 0)
      s = s.join(s.deltaDecrement(a, 2)); // A: (5, 2)
      s = s.join(s.deltaIncrement(b, 3)); // B: (3, 0)
      expect(s.value, 6);

      // Repeated same-node +1 — the case the old amounts dodged. Both must
      // count; a raw {A:(1,0)} fragment would max-merge to 1 and drop one.
      var r = PnCounter.empty();
      r = r.join(r.deltaIncrement(a, 1));
      r = r.join(r.deltaIncrement(a, 1));
      expect(r.value, 2);
    });

    test('OrSet.deltaAdd composes', () {
      final viaDelta = OrSet<String>.empty()
          .join(OrSet.deltaAdd('hello', a))
          .join(OrSet.deltaAdd('world', b));
      expect(viaDelta.values, {'hello', 'world'});
    });

    test('OrSet delta-remove ships the tombstone as context advancement', () {
      // Alice adds, then computes a delta for the removal of 'x'.
      final alice = OrSet<String>.empty().add('x', a);
      final removeDelta = alice.deltaRemoveOf('x');
      // The delta itself has no dots — just a context covering the removed dot.
      expect(removeDelta.values, isEmpty);
      expect(removeDelta.context.contains(a), isTrue);

      // Bob has the dot. After receiving the remove-delta, his element vanishes.
      final bob = OrSet<String>.empty().add('x', a);
      expect(bob.join(removeDelta).values, isEmpty);
    });

    test('CrdtMap.deltaPut composes', () {
      final viaDelta = CrdtMap<String, PnCounter>.empty()
          .join(CrdtMap.deltaPut('a', PnCounter.empty().deltaIncrement(a, 5)))
          .join(CrdtMap.deltaPut('b', PnCounter.empty().deltaIncrement(b, 3)));
      expect(viaDelta['a']!.value, 5);
      expect(viaDelta['b']!.value, 3);
    });
  });

  group('empty (identity element)', () {
    test('GSet.empty is the join identity', () {
      final s = GSet<int>.from({1, 2, 3});
      expect(s.join(s.empty), s);
      expect(s.empty.join(s), s);
    });

    test('MvRegister.empty is the join identity', () {
      final r = MvRegister.single('x', a, context: const CausalContext.empty());
      expect(r.join(r.empty), r);
      expect(r.empty.join(r), r);
    });

    test('PnCounter.empty is the join identity', () {
      final c = PnCounter.empty().increment(a, 7);
      expect(c.join(c.empty), c);
      expect(c.empty.join(c), c);
    });
  });

  group('Mutator', () {
    test('applyLocal updates state and pending delta', () {
      final mut = Mutator<GSet<String>>(initial: GSet<String>.empty());
      mut.applyLocal(GSet.deltaAdd('hello'));
      mut.applyLocal(GSet.deltaAdd('world'));
      expect(mut.state.values, {'hello', 'world'});
      expect(mut.pendingDelta.values, {'hello', 'world'});
    });

    test('flushDelta returns accumulator and resets it', () {
      final mut = Mutator<GSet<String>>(initial: GSet<String>.empty());
      mut.applyLocal(GSet.deltaAdd('x'));
      final delta = mut.flushDelta();
      expect(delta.values, {'x'});
      expect(mut.pendingDelta.values, isEmpty);
      expect(mut.state.values, {'x'}); // state preserved
    });

    test('applyRemote does not contribute to pending delta', () {
      final mut = Mutator<GSet<String>>(initial: GSet<String>.empty());
      mut.applyRemote(GSet<String>.from({'from-peer'}));
      expect(mut.state.values, {'from-peer'});
      expect(mut.pendingDelta.values, isEmpty);
      expect(mut.hasPendingDelta, isFalse);
    });

    test('end-to-end: Alice ships delta, Bob receives, both converge', () {
      final alice = Mutator<OrSet<String>>(initial: OrSet<String>.empty());
      final bob = Mutator<OrSet<String>>(initial: OrSet<String>.empty());

      alice.applyLocal(OrSet.deltaAdd('hello', a));
      alice.applyLocal(OrSet.deltaAdd('world', c));

      // Ship just the delta.
      final wire = alice.flushDelta();
      bob.applyRemote(wire);

      expect(bob.state.values, {'hello', 'world'});
      expect(bob.hasPendingDelta, isFalse);

      // Bob makes a local change, ships it back.
      bob.applyLocal(OrSet.deltaAdd('!', b));
      alice.applyRemote(bob.flushDelta());
      expect(alice.state.values, {'hello', 'world', '!'});
    });

    test('discardPendingDelta drops accumulator without touching state', () {
      final mut = Mutator<PnCounter>(initial: PnCounter.empty());
      mut.applyLocal(mut.state.deltaIncrement(a, 5));
      mut.discardPendingDelta();
      expect(mut.state.value, 5);
      expect(mut.pendingDelta, PnCounter.empty());
    });
  });
}
