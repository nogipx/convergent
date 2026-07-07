// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:collection';

import 'dot.dart';

/// A run-length block ("waypoint") of consecutively-authored elements.
///
/// Element at [offset] `k` has dot `Dot(start.counter + k, start.replica)`,
/// value `values[k]`, and is (implicitly) the RIGHT child of element `k-1`.
/// Only element 0's placement is stored explicitly ([parent], [side]); the
/// rest of the run is implied. A foreign insert into the middle of a run does
/// NOT split the block — it attaches as an explicit child of the relevant
/// element dot and is interleaved with the run at traversal time.
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
  /// Blocks keyed by their start dot.
  final Map<Dot, _Block<T>> _blocks = <Dot, _Block<T>>{};

  /// Parent element dot → child blocks (both sides). This is what makes the
  /// per-element children lookup O(children) instead of O(all blocks).
  final Map<Dot, List<_Block<T>>> _children = <Dot, List<_Block<T>>>{};

  /// Per-replica `start.counter → block`, for O(log N) [_locate] of the block
  /// holding an arbitrary element dot. Blocks of one replica never overlap.
  final Map<String, SplayTreeMap<int, _Block<T>>> _byReplica =
      <String, SplayTreeMap<int, _Block<T>>>{};

  /// Memoised visible projection; nulled on every mutation.
  List<_Elem<T>>? _visibleCache;

  void _index(_Block<T> b) {
    _blocks[b.start] = b;
    (_children[b.parent] ??= <_Block<T>>[]).add(b);
    (_byReplica[b.start.replica] ??= SplayTreeMap<int, _Block<T>>())[
        b.start.counter] = b;
  }

  Fugue<T> clone() {
    final c = Fugue<T>();
    for (final b in _blocks.values) {
      final nb = _Block<T>(b.start, b.parent, b.side, List<T>.of(b.values));
      nb.deleted.addAll(b.deleted);
      c._index(nb);
    }
    return c;
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  /// Locate the block + offset holding element [d], or null. O(log N).
  (_Block<T>, int)? _locate(Dot d) {
    final tree = _byReplica[d.replica];
    if (tree == null) return null;
    final key = tree.lastKeyBefore(d.counter + 1); // greatest key <= d.counter
    if (key == null) return null;
    final b = tree[key]!;
    final off = d.counter - b.start.counter;
    return (off >= 0 && off < b.length) ? (b, off) : null;
  }

  List<_Elem<T>> _leftChildren(Dot d) {
    final kids = _children[d];
    if (kids == null) return const [];
    final out = <_Elem<T>>[];
    for (final b in kids) {
      if (b.side == Side.left) out.add(_Elem(b, 0));
    }
    out.sort((x, y) => x.dot.compareTo(y.dot));
    return out;
  }

  /// Right children of element [d]: explicit right-child blocks plus the
  /// natural continuation (next offset in [d]'s own block), merged by dot.
  List<_Elem<T>> _rightChildren(Dot d) {
    final out = <_Elem<T>>[];
    final kids = _children[d];
    if (kids != null) {
      for (final b in kids) {
        if (b.side == Side.right) out.add(_Elem(b, 0));
      }
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
    final kids = _children[d];
    if (kids != null) {
      for (final b in kids) {
        if (b.side == Side.right) return true;
      }
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
    final cached = _visibleCache;
    if (cached != null) return cached;

    final result = <_Elem<T>>[];
    final roots = <_Elem<T>>[];
    final originKids = _children[Dot.origin];
    if (originKids != null) {
      for (final b in originKids) {
        roots.add(_Elem(b, 0));
      }
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
    return _visibleCache = result;
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  List<T> get values =>
      [for (final e in _visibleElems()) e.block.values[e.offset]];

  int get length => _visibleElems().length;

  /// Insert [value] at visible index [i] with identity [dot]. Follows
  /// Algorithm 1; coalesces into an existing block when [dot] continues a run.
  ///
  /// The new element always lands at visible index [i], so the memoised
  /// projection is spliced in place rather than rebuilt: an append is O(1)
  /// amortised, a middle insert is an O(N) list shift (no re-traversal).
  void insert(int i, T value, Dot dot) {
    final vis = _visibleElems(); // === _visibleCache
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
      if (loc != null &&
          loc.$2 == loc.$1.length - 1 &&
          loc.$1.start.replica == dot.replica &&
          dot.counter == loc.$1.start.counter + loc.$1.length) {
        loc.$1.values.add(value);
        vis.insert(ii, _Elem(loc.$1, loc.$1.length - 1));
        return;
      }
    }
    final b = _Block<T>(dot, parent, side, <T>[value]);
    _index(b);
    vis.insert(ii, _Elem(b, 0));
  }

  /// Tombstone the live element at visible index [i].
  void delete(int i) {
    final vis = _visibleElems();
    if (i < 0 || i >= vis.length) return;
    final e = vis[i];
    e.block.deleted.add(e.offset);
    vis.removeAt(i);
  }

  /// Merge another replica's state: union blocks by start dot (the longer run
  /// subsumes the shorter — a block only ever grows for its author), with a
  /// tombstone OR-merge.
  void merge(Fugue<T> other) {
    for (final ob in other._blocks.values) {
      final mine = _blocks[ob.start];
      if (mine == null) {
        final nb =
            _Block<T>(ob.start, ob.parent, ob.side, List<T>.of(ob.values));
        nb.deleted.addAll(ob.deleted);
        _index(nb);
      } else {
        if (ob.length > mine.length) {
          mine.values.addAll(ob.values.sublist(mine.length));
        }
        mine.deleted.addAll(ob.deleted);
      }
    }
    _visibleCache = null;
  }

  // ---------------------------------------------------------------------------
  // Codec — one row per block (run-length): the placement metadata is stored
  // once per run, and deletions as [start, len] ranges. This is where the
  // save-size win over one-node-per-element lands.
  // ---------------------------------------------------------------------------

  /// Encode to a JSON-compatible structure. [encodeValue] maps one element
  /// value to a JSON-compatible form.
  Object encode(Object? Function(T) encodeValue) {
    final rows = <Object?>[];
    for (final b in _blocks.values) {
      rows.add(<Object?>[
        b.start.counter,
        b.start.replica,
        b.parent.counter,
        b.parent.replica,
        b.side == Side.right ? 1 : 0,
        [for (final v in b.values) encodeValue(v)],
        _encodeDeleted(b.deleted),
      ]);
    }
    return <String, Object?>{'v': 1, 'b': rows};
  }

  static List<int> _encodeDeleted(Set<int> deleted) {
    if (deleted.isEmpty) return const [];
    final sorted = deleted.toList()..sort();
    final out = <int>[];
    var start = sorted.first;
    var prev = sorted.first;
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i] == prev + 1) {
        prev = sorted[i];
        continue;
      }
      out
        ..add(start)
        ..add(prev - start + 1);
      start = sorted[i];
      prev = sorted[i];
    }
    return out
      ..add(start)
      ..add(prev - start + 1);
  }

  /// Decode a structure produced by [encode]. [decodeValue] is the inverse of
  /// the encoder passed to [encode].
  static Fugue<T> decode<T>(Object json, T Function(Object?) decodeValue) {
    final map = json as Map;
    final f = Fugue<T>();
    for (final row in map['b'] as List) {
      final r = row as List;
      final start = Dot(r[0] as int, r[1] as String);
      final parent = Dot(r[2] as int, r[3] as String);
      final side = (r[4] as int) == 1 ? Side.right : Side.left;
      final values = <T>[for (final v in r[5] as List) decodeValue(v)];
      final b = _Block<T>(start, parent, side, values);
      final del = r[6] as List;
      for (var i = 0; i + 1 < del.length; i += 2) {
        final s = del[i] as int;
        final len = del[i + 1] as int;
        for (var k = 0; k < len; k++) {
          b.deleted.add(s + k);
        }
      }
      f._index(b);
    }
    return f;
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
