// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT
//
// Quick end-to-end timing of Sequence.applyOps on workloads that mirror
// rhyolite's text-reconcile. The production hang was N=23k entries with
// a few hundred diff ops, hitting ~77s on dart2js. This bench confirms
// the post-migration envelope.

import 'package:convergent/convergent.dart';

void main() {
  var counter = 0;
  Hlc dot() {
    counter += 1;
    return Hlc(1000, counter, 'A');
  }

  var s = Sequence<String>.empty();
  final sw1 = Stopwatch()..start();
  for (var i = 0; i < 23000; i++) {
    s = s.append(String.fromCharCode(0x61 + (i % 26)), dot());
  }
  sw1.stop();
  print('build 23k via append: ${sw1.elapsedMilliseconds}ms');

  final ops = <SeqOp<String>>[];
  for (var i = 0; i < 500; i++) {
    ops.add(SeqOp.insert(11000 + i, 'X'));
  }
  final sw2 = Stopwatch()..start();
  final result = s.applyOps(ops, dot);
  sw2.stop();
  print(
    'applyOps K=500 on N=23k: ${sw2.elapsedMilliseconds}ms (size=${result.length})',
  );

  final ops2 = <SeqOp<String>>[];
  for (var i = 0; i < 1000; i++) {
    ops2.add(SeqOp.insert(5000 + i * 2, 'Y'));
    ops2.add(SeqOp.removeAt(5000 + i * 2 + 1));
  }
  final sw3 = Stopwatch()..start();
  final r2 = s.applyOps(ops2, dot);
  sw3.stop();
  print(
    'applyOps K=2000 mixed on N=23k: ${sw3.elapsedMilliseconds}ms (size=${r2.length})',
  );
}
