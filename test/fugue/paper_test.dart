// External validation against the worked examples in "The Art of the Fugue"
// (Weidner & Kleppmann, TPDS 2025) — independent of our Algorithm-1 oracle,
// so it catches an oracle-transcription mistake, not just self-consistency.
import 'package:convergent/fugue.dart';
import 'package:test/test.dart';

void main() {
  Fugue<String> typed(String text, LamportClock clk, [Fugue<String>? into]) {
    final f = into ?? Fugue<String>();
    for (final ch in text.split('')) {
      f.insert(f.length, ch, clk.tick());
    }
    return f;
  }

  group('Fugue — paper worked examples', () {
    // Figure 4: the insert mechanics. `a` and `b` are siblings (a before b),
    // and `a` has no right child. Insert g between them -> g is a right child
    // of a -> "a g b". Then insert h between a and g -> since g is a descendant
    // of a, h becomes a LEFT child of g -> "a h g b".
    test('Fig 4 — g right-child of a, then h left-child of g', () {
      final a = Fugue<String>()..insert(0, 'a', const Dot(1, 'A'));
      final b = Fugue<String>()..insert(0, 'b', const Dot(1, 'B'));
      final f = a.join(b); // siblings: (1,A) < (1,B) -> [a, b]
      expect(f.values, ['a', 'b']);

      final clk = LamportClock('C')..observeAll(f.dots);
      f.insert(1, 'g', clk.tick()); // between a and b
      expect(f.values, ['a', 'g', 'b'], reason: 'g right-child of a');

      f.insert(1, 'h', clk.tick()); // between a and g
      expect(f.values, ['a', 'h', 'g', 'b'], reason: 'h left-child of g');
    });

    // Figure 1: the interleaving anomaly Fugue prevents. Document "milk\n";
    // concurrently one user appends "eggs\n" and another "bread\n". A naive
    // list CRDT interleaves the two words; Fugue keeps each contiguous.
    test('Fig 1 — concurrent "eggs" / "bread" do not interleave', () {
      final base = typed('milk\n', LamportClock('S'));

      final a = typed('eggs\n', LamportClock('A')..observeAll(base.dots),
          base.clone());
      final b = typed('bread\n', LamportClock('B')..observeAll(base.dots),
          base.clone());

      final merged = a.join(b).values.join();
      expect(merged.startsWith('milk\n'), isTrue);
      // Contiguity: the whole words survive as substrings (impossible if
      // interleaved).
      expect(merged.contains('eggs'), isTrue);
      expect(merged.contains('bread'), isTrue);
      // Exactly one of the two non-interleaved orders.
      expect(
        merged == 'milk\neggs\nbread\n' || merged == 'milk\nbread\neggs\n',
        isTrue,
        reason: 'got: ${merged.replaceAll('\n', r'\n')}',
      );
    });

    // Figure 6: three replicas insert A, B, C into an empty list; replica 1
    // additionally inserts X between A and C. The paper's total order is
    // "AXBC". Derive it: A,B,C are right children of the root (sorted by id
    // A<B<C); X is a right child of A, so it is visited immediately after A.
    test('Fig 6 — merged order is AXBC', () {
      final a = Fugue<String>()..insert(0, 'A', const Dot(1, 'r1'));
      final b = Fugue<String>()..insert(0, 'B', const Dot(1, 'r2'));
      final c = Fugue<String>()..insert(0, 'C', const Dot(1, 'r3'));

      // Replica 1 has A and C, inserts X between them.
      final r1 = a.join(c); // [A, C]
      expect(r1.values, ['A', 'C']);
      r1.insert(1, 'X', const Dot(2, 'r1')); // between A and C
      expect(r1.values, ['A', 'X', 'C']);

      final merged = r1.join(b).join(c).values.join();
      expect(merged, 'AXBC');
    });
  });
}
