// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Test-only oracle: a naive, obviously-correct transcription of Fugue
// Algorithm 1 (Weidner & Kleppmann, "The Art of the Fugue", TPDS 2025).
//
// Correctness over speed — O(N) scans everywhere, direct from the
// pseudocode — so it can be trusted as the reference that the optimised
// block implementation is fuzzed against. NOT shipped.
import 'package:convergent/src/fugue/dot.dart';

class _RefNode<T> {
  _RefNode(this.value, this.parent, this.side, {this.deleted = false});
  final T value;
  final Dot parent; // Dot.origin for top-level nodes
  final Side side;
  bool deleted;
}

/// Literal Fugue Algorithm 1 as a state-based CRDT: local [insert]/[delete]
/// generate and apply a node; [merge] is a per-id union with tombstone
/// OR-merge (position metadata is identical across replicas that observed
/// the node).
class RefFugue<T> {
  final Map<Dot, _RefNode<T>> _nodes = {};

  /// Ids of every node (live + tombstoned) — for clock seeding in tests.
  Iterable<Dot> get ids => _nodes.keys;

  RefFugue<T> clone() {
    final c = RefFugue<T>();
    for (final e in _nodes.entries) {
      final n = e.value;
      c._nodes[e.key] = _RefNode(n.value, n.parent, n.side, deleted: n.deleted);
    }
    return c;
  }

  List<T> values() {
    final out = <T>[];
    _walk(Dot.origin, emit: false, onValue: out.add, onId: null);
    return out;
  }

  List<Dot> _visibleIds() {
    final out = <Dot>[];
    _walk(Dot.origin, emit: false, onValue: null, onId: out.add);
    return out;
  }

  int get length => _visibleIds().length;

  // In-order DFS: left children (by id), self (if live), right children.
  void _walk(
    Dot nodeId, {
    required bool emit,
    void Function(T)? onValue,
    void Function(Dot)? onId,
  }) {
    final left = <Dot>[];
    final right = <Dot>[];
    for (final e in _nodes.entries) {
      if (e.value.parent == nodeId) {
        (e.value.side == Side.left ? left : right).add(e.key);
      }
    }
    left.sort();
    right.sort();
    for (final c in left) {
      _walk(c, emit: true, onValue: onValue, onId: onId);
    }
    if (emit) {
      final n = _nodes[nodeId]!;
      if (!n.deleted) {
        onValue?.call(n.value);
        onId?.call(nodeId);
      }
    }
    for (final c in right) {
      _walk(c, emit: true, onValue: onValue, onId: onId);
    }
  }

  bool _hasRightChild(Dot parent) {
    for (final n in _nodes.values) {
      if (n.parent == parent && n.side == Side.right) return true;
    }
    return false;
  }

  // rightOrigin(x) = the node right after x in the FULL traversal (tombstones
  // included) = leftmost node of x's right subtree = leftmost-descendant of
  // x's smallest-id right child.
  Dot _rightOrigin(Dot x) {
    Dot? smallestChild(Dot parent, Side side) {
      Dot? best;
      for (final e in _nodes.entries) {
        final n = e.value;
        if (n.parent == parent && n.side == side) {
          if (best == null || e.key < best) best = e.key;
        }
      }
      return best;
    }

    var cur = smallestChild(x, Side.right)!;
    while (true) {
      final lc = smallestChild(cur, Side.left);
      if (lc == null) return cur;
      cur = lc;
    }
  }

  /// insert(i, x) — Algorithm 1 lines 21–28.
  void insert(int i, T value, Dot dot) {
    final vis = _visibleIds();
    final ii = i < 0 ? 0 : (i > vis.length ? vis.length : i);
    final leftOrigin = ii == 0 ? Dot.origin : vis[ii - 1];
    if (!_hasRightChild(leftOrigin)) {
      // right child of leftOrigin
      _nodes[dot] = _RefNode(value, leftOrigin, Side.right);
    } else {
      // left child of rightOrigin
      _nodes[dot] = _RefNode(value, _rightOrigin(leftOrigin), Side.left);
    }
  }

  /// delete(i) — Algorithm 1 lines 39–44 (tombstone).
  void delete(int i) {
    final vis = _visibleIds();
    if (i < 0 || i >= vis.length) return;
    _nodes[vis[i]]!.deleted = true;
  }

  void merge(RefFugue<T> other) {
    for (final e in other._nodes.entries) {
      final mine = _nodes[e.key];
      final n = e.value;
      if (mine == null) {
        _nodes[e.key] = _RefNode(n.value, n.parent, n.side, deleted: n.deleted);
      } else if (n.deleted && !mine.deleted) {
        mine.deleted = true;
      }
    }
  }
}
