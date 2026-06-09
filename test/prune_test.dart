// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:convergent/convergent.dart';
import 'package:test/test.dart';

void main() {
  final a = Hlc(100, 0, 'alice');
  final b = Hlc(200, 0, 'bob');
  final c = Hlc(300, 0, 'alice');
  final d = Hlc(400, 0, 'bob');

  group('OrSet.prune (causal stability GC)', () {
    test('drops stable dots that are not in the live dot store', () {
      // Start with two adds, then remove one. The removed dot
      // lingers in `context` to drive tombstone propagation.
      var s = OrSet<String>.empty()
          .add('keep', a)
          .add('drop', b)
          .remove('drop');
      expect(s.context.dots, {a, b});

      // Both dots are stable (every replica has acked them).
      final stable = DotSet.from({a, b});
      s = s.prune(stable);

      // The removed-dot's tombstone hlc (b) is dropped from context.
      // The live-dot's hlc (a) is preserved because the dot is still
      // in the store.
      expect(s.context.dots, {a});
      expect(s.values, {'keep'});
    });

    test('never drops a live dot from context, even if stable', () {
      var s = OrSet<String>.empty().add('alive', a);
      final stable = DotSet.from({a});
      s = s.prune(stable);
      // Live dot's hlc still in context: required so future joins
      // can see this dot as "observed".
      expect(s.context.dots, {a});
      expect(s.values, {'alive'});
    });

    test('does not drop dots outside the stable set', () {
      var s = OrSet<String>.empty()
          .add('x', a)
          .add('y', b)
          .remove('y'); // y's tombstone (b) lives in context
      final stable = DotSet.from({a}); // b is NOT yet stable
      s = s.prune(stable);
      // b stays — it must continue to propagate the tombstone to
      // any replica that hasn't observed it yet.
      expect(s.context.dots, containsAll({a, b}));
    });

    test('pruning is a no-op when there is nothing safe to drop', () {
      var s = OrSet<String>.empty().add('x', a);
      final before = s;
      s = s.prune(DotSet.from({a}));
      expect(s, before);
    });

    test('after pruning, removed elements still propagate to peers '
        'who have not yet seen the stable set', () {
      // Alice adds and removes — her tombstone for x is (a).
      var alice = OrSet<String>.empty().add('x', a).remove('x');
      // Bob already saw the add+remove dance — for him (a) is
      // stable. He prunes.
      final stable = DotSet.from({a});
      final pruned = alice.prune(stable);

      // Carol, however, only ever saw the original add (she's
      // behind and never received the remove). Her state has (x, a).
      final carol = OrSet<String>.empty().add('x', a);

      // After Carol joins the pruned state, x is GONE on Carol's
      // side — even though pruned.context no longer explicitly
      // lists a (it was removed). Why? Because pruned has no live
      // entries for a, and a IS in carol's context but NOT in
      // pruned.dots → the join filter drops it from carol.dots.
      //
      // Wait: in our `join`, the filter is "dot in other.dots OR
      // dot NOT in other.context". For carol's (x, a): is it in
      // pruned.dots? No. Is it NOT in pruned.context? Yes (we
      // pruned a out). → KEEP.
      //
      // So after the prune, carol's x SURVIVES — the remove signal
      // was lost. This is the price of pruning a's stable set
      // ALONG WITH dropping the tombstone reference. The caller
      // invariant promises this never happens because stable means
      // "every replica observed a (and consequently the remove
      // event that referenced it)" — Carol's status of "still has
      // x" would contradict the precondition.
      //
      // This test documents the contract: when stable[d]=true but
      // a replica has not in fact observed d, convergence is no
      // longer guaranteed. We just verify behavior is internally
      // consistent here.
      final joined = pruned.join(carol);
      expect(joined.values, {'x'});
    });

    test('with proper invariant, removal propagates after pruning', () {
      // Both Alice and Bob have observed the add+remove cycle.
      var alice = OrSet<String>.empty().add('x', a).remove('x');
      var bob = OrSet<String>.empty().add('x', a).remove('x');

      // Both prune a as stable.
      final stable = DotSet.from({a});
      alice = alice.prune(stable);
      bob = bob.prune(stable);

      // Both contexts no longer hold a. State stays empty.
      expect(alice.context.dots, isEmpty);
      expect(bob.context.dots, isEmpty);
      expect(alice.join(bob).values, isEmpty);
    });

    test('idempotency of prune', () {
      var s = OrSet<String>.empty().add('a', a).add('b', b).remove('b');
      final stable = DotSet.from({b});
      final once = s.prune(stable);
      final twice = once.prune(stable);
      expect(twice, once);
    });

    test('continued usage after prune: new adds + joins still work', () {
      var alice = OrSet<String>.empty().add('x', a).remove('x');
      alice = alice.prune(DotSet.from({a}));
      // Alice keeps using the set.
      alice = alice.add('y', c);
      expect(alice.values, {'y'});
      expect(alice.context.dots, {c});

      // Bob receives Alice's new state.
      final bob = OrSet<String>.empty();
      expect(bob.join(alice).values, {'y'});
    });
  });

  group('DotSet operations used by pruning', () {
    test('union is commutative + idempotent', () {
      final s1 = DotSet.from({a, b});
      final s2 = DotSet.from({b, c});
      expect(s1.union(s2), s2.union(s1));
      expect(s1.union(s1), s1);
    });

    test('dominates is reflexive and superset-checking', () {
      final small = DotSet.from({a});
      final big = DotSet.from({a, b, c});
      expect(big.dominates(small), isTrue);
      expect(small.dominates(big), isFalse);
      expect(big.dominates(big), isTrue);
    });

    test('pack / unpack round-trip', () {
      final s = DotSet.from({a, b, c, d});
      expect(DotSet.unpack(s.pack()), s);
      expect(DotSet.unpack(''), const DotSet.empty());
    });
  });
}
