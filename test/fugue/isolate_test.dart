// True-concurrent convergence: each replica runs in its own isolate, edits
// with a real Lamport clock, and ships its state as JSON across the SendPort
// (full codec round-trip). The main isolate merges and checks that all join
// orders converge.
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:convergent/fugue.dart';
import 'package:test/test.dart';

const _codec = FugueCodec<String>(StringCodec());

List<FugueOp<String>> _randomOps(Random rng, int len0, int count) {
  final ops = <FugueOp<String>>[];
  var len = len0;
  for (var i = 0; i < count; i++) {
    if (len > 0 && rng.nextDouble() < 0.3) {
      ops.add(FugueOp.removeAt(rng.nextInt(len)));
      len--;
    } else {
      ops.add(FugueOp.insert(
        len == 0 ? 0 : rng.nextInt(len + 1),
        String.fromCharCode(0x61 + rng.nextInt(26)),
      ));
      len++;
    }
  }
  return ops;
}

// Runs inside a worker isolate: decode base, edit, ship state back as JSON.
String _worker(Map<String, Object?> spec) {
  final base = _codec.decode(jsonDecode(spec['base']! as String));
  final clk = LamportClock(spec['replica']! as String)..observeAll(base.dots);
  base.applyOps(
    _randomOps(Random(spec['seed']! as int), base.length, spec['ops']! as int),
    clk,
  );
  return jsonEncode(_codec.encode(base));
}

void main() {
  test('replicas in separate isolates converge under any join order', () async {
    for (var trial = 0; trial < 40; trial++) {
      // Shared base built on the main isolate.
      final base = Fugue<String>();
      final sClk = LamportClock('S');
      final baseRng = Random(trial);
      for (final op in _randomOps(baseRng, 0, 4 + baseRng.nextInt(6))) {
        switch (op) {
          case FugueInsert<String>(:final at, :final value):
            base.insert(at, value, sClk.tick());
          case FugueRemoveAt<String>(:final at):
            base.delete(at);
        }
      }
      final baseJson = jsonEncode(_codec.encode(base));

      // Three replicas edit concurrently, each in its own isolate.
      final labels = ['A', 'B', 'C'];
      final results = await Future.wait([
        for (var i = 0; i < labels.length; i++)
          Isolate.run(() => _worker({
                'base': baseJson,
                'replica': labels[i],
                'seed': trial * 17 + i,
                'ops': 12,
              })),
      ]);

      final replicas = [for (final r in results) _codec.decode(jsonDecode(r))];

      // Merge in two different orders; both must converge.
      final m1 = replicas[0].join(replicas[1]).join(replicas[2]);
      final m2 = replicas[2].join(replicas[0]).join(replicas[1]);
      expect(m1.values, m2.values, reason: 'diverges at trial=$trial');
    }
  });
}
