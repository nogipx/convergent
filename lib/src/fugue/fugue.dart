// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dot.dart';

/// A run-length block ("waypoint") of consecutively-authored elements.
///
/// Element at [offset] `k` has dot `Dot(start.counter + k, start.replica)`,
/// value `values[k]`, and is (implicitly) the RIGHT child of element `k-1`.
/// Only element 0's placement is stored explicitly ([parent], [side]); the
/// rest of the run is implied. Foreign inserts into the middle of a run do
/// NOT split the block — they attach as explicit children of the relevant
/// element dot and are interleaved with the run at traversal time.
class _Block<T> {
  _Block(this.start, this.parent, this.side, this.values);
  final Dot start;
  Dot parent; // element-0's parent; Dot.origin for a top-level block
  Side side; // element-0's side
  final List<T> values; // grows on append-coalesce
  final Set<int> deleted = <int>{}; // deleted offsets (tombstones)

  int get length => values.length;
  Dot dotAt(int offset) => Dot(start.counter + offset, start.replica);
}

/// One element position: a ([_Block], offset) pair.
class _Elem<T> {
  _Elem(this.block, this.offset);
  final _Block<T> block;
  final int offset;
  Dot get dot => block.dotAt(offset);
}

/// Marks "expand this element's subtree" on the traversal work stack; a bare
/// [_Elem] on the stack means "emit this element if live".
class _Expand<T> {
  _Expand(this.e);
  final _Elem<T> e;
}

/// The optimised, run-length ("waypoint") Fugue list CRDT — a faithful
/// implementation of Algorithm 1 (Weidner & Kleppmann, TPDS 2025) that stores
/// contiguously-typed runs as single blocks instead of one node per element.
///
/// Element identity is a logical [Dot] (not an HLC), so a forward-typed run
/// carries consecutive counters and collapses into one block.
class Fugue<T> {
  final Map<Dot, _Block<T>> _blocks = <Dot, _Block<T>>{};

  Fugue<T> clone() {
    final c = Fugue<T>();
    for (final b in _blocks.values) {
      final nb = _Block<T>(b.start, b.parent, b.side, List<T>.of(b.values));
      nb.deleted.addAll(b.deleted);
      c._blocks[b.start] = nb;
    }
    return c;
  }

  // ---------------------------------------------------------------------------
  // Navigation (correctness-first; O(N) scans, indexed later)
  // ---------------------------------------------------------------------------

  /// Locate the block + offset holding element [d], or null.
  (_Block<T>, int)? _locate(Dot d) {
    for (final b in _blocks.values) {
      if (b.start.replica == d.replica &&
          d.counter >= b.start.counter &&
          d.counter < b.start.counter + b.length) {
        return (b, d.counter - b.start.counter);
      }
    }
    return null;
  }

  List<_Elem<T>> _leftChildren(Dot d) {
    final out = <_Elem<T>>[];
    for (final b in _blocks.values) {
      if (b.parent == d && b.side == Side.left) out.add(_Elem(b, 0));
    }
    out.sort((x, y) => x.dot.compareTo(y.dot));
    return out;
  }

  /// Right children of element [d]: explicit right-child blocks plus the
  /// natural continuation (next offset in [d]'s own block), merged by dot.
  List<_Elem<T>> _rightChildren(Dot d) {
    final out = <_Elem<T>>[];
    for (final b in _blocks.values) {
      if (b.parent == d && b.side == Side.right) out.add(_Elem(b, 0));
    }
    if (!d.isOrigin) {
      final loc = _locate(d);
      if (loc != null && loc.$2 < loc.$1.length - 1) {
        out.add(_Elem(loc.$1, loc.$2 + 1));
      }
    }
    out.sort((x, y) => x.dot.compareTo(y.dot));
    return out;
  }

  bool _hasRightChild(Dot d) {
    if (!d.isOrigin) {
      final loc = _locate(d);
      if (loc != null && loc.$2 < loc.$1.length - 1) return true;
    }
    for (final b in _blocks.values) {
      if (b.parent == d && b.side == Side.right) return true;
    }
    return false;
  }

  /// rightOrigin(d): next node after [d] in the FULL (tombstone-inclusive)
  /// traversal = leftmost descendant of [d]'s smallest-dot right child.
  Dot _rightOrigin(Dot d) {
    var cur = _rightChildren(d).first.dot; // caller ensures d has a right child
    while (true) {
      final left = _leftChildren(cur);
      if (left.isEmpty) return cur;
      cur = left.first.dot;
    }
  }

  // ---------------------------------------------------------------------------
  // Traversal
  // ---------------------------------------------------------------------------

  List<_Elem<T>> _visibleElems() {
    final result = <_Elem<T>>[];
    final roots = <_Elem<T>>[];
    for (final b in _blocks.values) {
      if (b.parent == Dot.origin) roots.add(_Elem(b, 0));
    }
    roots.sort((x, y) => x.dot.compareTo(y.dot));

    final stack = <Object>[];
    for (var i = roots.length - 1; i >= 0; i--) {
      stack.add(_Expand<T>(roots[i]));
    }
    while (stack.isNotEmpty) {
      final item = stack.removeLast();
      if (item is _Elem<T>) {
        if (!item.block.deleted.contains(item.offset)) result.add(item);
        continue;
      }
      final e = (item as _Expand<T>).e;
      final lefts = _leftChildren(e.dot);
      final rights = _rightChildren(e.dot);
      for (var i = rights.length - 1; i >= 0; i--) {
        stack.add(_Expand<T>(rights[i]));
      }
      stack.add(e); // emit self after left children, before right
      for (var i = lefts.length - 1; i >= 0; i--) {
        stack.add(_Expand<T>(lefts[i]));
      }
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  List<T> get values =>
      [for (final e in _visibleElems()) e.block.values[e.offset]];

  int get length => _visibleElems().length;

  /// Insert [value] at visible index [i] with identity [dot]. Follows
  /// Algorithm 1; coalesces into an existing block when [dot] continues a
  /// run.
  void insert(int i, T value, Dot dot) {
    final vis = _visibleElems();
    final ii = i < 0 ? 0 : (i > vis.length ? vis.length : i);
    final leftOrigin = ii == 0 ? Dot.origin : vis[ii - 1].dot;

    final Dot parent;
    final Side side;
    if (!_hasRightChild(leftOrigin)) {
      parent = leftOrigin;
      side = Side.right;
    } else {
      parent = _rightOrigin(leftOrigin);
      side = Side.left;
    }

    // Coalesce: a right-child that continues its parent's run (same replica,
    // next counter, parent is the run's last element) extends the block.
    if (side == Side.right && !parent.isOrigin) {
      final loc = _locate(parent);
      if (loc != null) {
        final (b, off) = loc;
        if (off == b.length - 1 &&
            b.start.replica == dot.replica &&
            dot.counter == b.start.counter + b.length) {
          b.values.add(value);
          return;
        }
      }
    }
    _blocks[dot] = _Block<T>(dot, parent, side, <T>[value]);
  }

  /// Tombstone the live element at visible index [i].
  void delete(int i) {
    final vis = _visibleElems();
    if (i < 0 || i >= vis.length) return;
    vis[i].block.deleted.add(vis[i].offset);
  }

  /// Merge another replica's state: union blocks by start dot (the longer run
  /// subsumes the shorter — a block only ever grows for its author), with a
  /// tombstone OR-merge.
  void merge(Fugue<T> other) {
    for (final ob in other._blocks.values) {
      final mine = _blocks[ob.start];
      if (mine == null) {
        final nb = _Block<T>(ob.start, ob.parent, ob.side, List<T>.of(ob.values));
        nb.deleted.addAll(ob.deleted);
        _blocks[ob.start] = nb;
      } else {
        if (ob.length > mine.length) {
          mine.values.addAll(ob.values.sublist(mine.length));
        }
        mine.deleted.addAll(ob.deleted);
      }
    }
  }

  /// Number of stored blocks — for coalescing assertions in tests.
  int get blockCount => _blocks.length;

  /// Every element dot (live + tombstoned), for seeding a [LamportClock].
  Iterable<Dot> get dots sync* {
    for (final b in _blocks.values) {
      for (var k = 0; k < b.length; k++) {
        yield b.dotAt(k);
      }
    }
  }
}
