// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Two-replica convergence demo.
//
// Builds the same logical todo list on two devices in parallel —
// each one offline, each one making different edits. After both have
// made all their changes, we exchange state in both directions and
// show that the final result is identical regardless of merge order.
//
// Run with: `dart run example/convergent_example.dart`.

// ignore_for_file: avoid_print

import 'package:convergent/convergent.dart';

void main() {
  // -------------------------------------------------------------------------
  // Replica setup
  // -------------------------------------------------------------------------
  // Each replica has a unique nodeId — required so HLCs can be totally
  // ordered (and so PnCounter halves stay independent).
  //
  // To make this demo deterministic we anchor Bob's clock at t=1000
  // and Alice's at t=2000. The real world uses `Hlc.now(nodeId)` and
  // `Hlc.receive(remote, ...)` on every incoming event.
  final clockB = Clock('bob', startMillis: 1000);
  final clockA = Clock('alice', startMillis: 2000);

  // -------------------------------------------------------------------------
  // Replica A's edits (offline, on their laptop)
  // -------------------------------------------------------------------------
  var todoA = TodoList.empty()
      .upsert('1', _newItem('Buy milk', clockA))
      .upsert('2', _newItem('Read paper', clockA))
      .complete('1', clockA);

  // Alice renames item 2 a moment later.
  todoA = todoA.rename('2', 'Read CRDT paper', clockA);

  // -------------------------------------------------------------------------
  // Replica B's edits (offline, on their phone)
  // -------------------------------------------------------------------------
  var todoB = TodoList.empty()
      .upsert('1', _newItem('Buy milk', clockB))
      .upsert('3', _newItem('Call mom', clockB))
      .tag('1', 'errand', clockB)
      .tag('3', 'family', clockB);

  // -------------------------------------------------------------------------
  // Sync (in both directions, twice — convergence holds anyway)
  // -------------------------------------------------------------------------
  final mergedAB = todoA.join(todoB);
  final mergedBA = todoB.join(todoA);
  final mergedTwice = mergedAB.join(mergedBA); // idempotency check

  print('--- Replica A after sync ---');
  _print(mergedAB);

  print('\n--- Replica B after sync (reverse order) ---');
  _print(mergedBA);

  print('\n--- Joined twice (idempotency) ---');
  _print(mergedTwice);

  print('\nConverged? ${mergedAB == mergedBA && mergedAB == mergedTwice}');
}

// ---------------------------------------------------------------------------
// A small offline-first todo list built entirely out of `convergent`
// primitives.
//
// Each item is a record of three CRDTs:
//   - `LwwRegister<String>` — the title, silent last-writer-wins.
//   - `LwwRegister<bool>`   — the completion flag.
//   - `OrSet<String>`       — tags, add-wins on concurrent add/remove.
//
// The list itself is a `CrdtMap<String, TodoItem>`.
// ---------------------------------------------------------------------------

class TodoItem implements Crdt<TodoItem> {
  TodoItem({required this.title, required this.done, required this.tags});

  final LwwRegister<String> title;
  final LwwRegister<bool> done;
  final OrSet<String> tags;

  @override
  TodoItem get empty => TodoItem(
    title: LwwRegister<String>.empty(),
    done: LwwRegister<bool>.empty(),
    tags: OrSet<String>.empty(),
  );

  @override
  TodoItem join(TodoItem other) => TodoItem(
    title: title.join(other.title),
    done: done.join(other.done),
    tags: tags.join(other.tags),
  );

  @override
  TodoItem deltaCompose(TodoItem other) => TodoItem(
    title: title.deltaCompose(other.title),
    done: done.deltaCompose(other.done),
    tags: tags.deltaCompose(other.tags),
  );

  @override
  bool operator ==(Object other) =>
      other is TodoItem &&
      title == other.title &&
      done == other.done &&
      tags == other.tags;

  @override
  int get hashCode => Object.hash(title, done, tags);
}

class TodoList implements Crdt<TodoList> {
  TodoList._(this._items);

  TodoList.empty() : _items = CrdtMap<String, TodoItem>.empty();

  final CrdtMap<String, TodoItem> _items;

  Iterable<MapEntry<String, TodoItem>> get entries =>
      _items.keys.map((k) => MapEntry(k, _items[k]!));

  TodoList upsert(String id, TodoItem item) => TodoList._(_items.put(id, item));

  TodoList rename(String id, String newTitle, Clock clock) {
    final cur = _items[id];
    if (cur == null) return this;
    return upsert(
      id,
      TodoItem(
        title: cur.title.set(
          newTitle,
          clock.tick(),
          const CausalContext.empty(),
        ),
        done: cur.done,
        tags: cur.tags,
      ),
    );
  }

  TodoList complete(String id, Clock clock) {
    final cur = _items[id];
    if (cur == null) return this;
    return upsert(
      id,
      TodoItem(
        title: cur.title,
        done: cur.done.set(true, clock.tick(), const CausalContext.empty()),
        tags: cur.tags,
      ),
    );
  }

  TodoList tag(String id, String tag, Clock clock) {
    final cur = _items[id];
    if (cur == null) return this;
    return upsert(
      id,
      TodoItem(
        title: cur.title,
        done: cur.done,
        tags: cur.tags.add(tag, clock.tick()),
      ),
    );
  }

  @override
  TodoList get empty => TodoList._(_items.empty);

  @override
  TodoList join(TodoList other) => TodoList._(_items.join(other._items));

  @override
  TodoList deltaCompose(TodoList other) =>
      TodoList._(_items.deltaCompose(other._items));

  @override
  bool operator ==(Object other) => other is TodoList && _items == other._items;

  @override
  int get hashCode => _items.hashCode;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Minimal monotonic HLC clock per replica. Real apps would persist the
/// last `Hlc` and use `Hlc.receive` to advance on every received event;
/// this demo just calls `Hlc.now` and tracks counter locally.
class Clock {
  Clock(this.nodeId, {int? startMillis})
    : _last = Hlc(
        startMillis ?? DateTime.now().millisecondsSinceEpoch,
        0,
        nodeId,
      );

  final String nodeId;
  Hlc _last;

  /// Advances the logical counter; keeps `millis` anchored so the demo
  /// is deterministic. A real-world clock would pass
  /// `DateTime.now().millisecondsSinceEpoch` here.
  Hlc tick() {
    _last = Hlc(_last.millis, _last.counter + 1, nodeId);
    return _last;
  }
}

TodoItem _newItem(String title, Clock clock) => TodoItem(
  title: LwwRegister.single(title, clock.tick()),
  done: LwwRegister.single(false, clock.tick()),
  tags: OrSet<String>.empty(),
);

void _print(TodoList list) {
  for (final entry in list.entries) {
    final item = entry.value;
    final mark = (item.done.value ?? false) ? '✓' : '·';
    final tagsStr = item.tags.values.isEmpty
        ? ''
        : ' [${item.tags.values.join(", ")}]';
    print('  $mark ${entry.key}  ${item.title.value}$tagsStr');
  }
}
