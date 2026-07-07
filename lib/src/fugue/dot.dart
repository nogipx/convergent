// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Side of a parent a Fugue tree node attaches to.
enum Side {
  /// Ordered before the parent in the in-order traversal.
  left,

  /// Ordered after the parent in the in-order traversal.
  right,
}

/// A logical (Lamport-style) identifier for one element of a Fugue list.
///
/// Unlike an HLC, a dot carries **no wall-clock component**: [counter] is a
/// pure per-replica logical clock. That is what lets a run of
/// contiguously-typed characters share consecutive counters and collapse
/// into a single block — the RGASplit / Yjs "waypoint" optimisation the
/// optimised Fugue relies on. An HLC's millisecond field changes on almost
/// every keystroke (~100 ms apart), which would reset the counter and split
/// every character into its own block, defeating the optimisation.
///
/// The total order is `(counter, replica)`. Fugue only requires *some*
/// agreed total order over dots to tie-break same-side siblings (paper §4,
/// "the exact construction of IDs and their order is not important"), so
/// this choice is not semantically load-bearing beyond being consistent.
class Dot implements Comparable<Dot> {
  /// Creates a dot with logical [counter] and author [replica].
  const Dot(this.counter, this.replica);

  /// Per-replica logical clock value. Strictly positive for real elements;
  /// `0` is reserved (see [Dot.origin]).
  final int counter;

  /// Stable identifier of the replica that minted this dot.
  final String replica;

  /// The virtual origin ("root") that every top-level element hangs off.
  /// Never stored as a real element; used only as a parent sentinel.
  static const Dot origin = Dot(0, '');

  /// Whether this is the [origin] sentinel.
  bool get isOrigin => counter == 0 && replica.isEmpty;

  @override
  int compareTo(Dot other) {
    final c = counter.compareTo(other.counter);
    return c != 0 ? c : replica.compareTo(other.replica);
  }

  /// Whether this dot orders before [other].
  bool operator <(Dot other) => compareTo(other) < 0;

  /// Whether this dot orders after [other].
  bool operator >(Dot other) => compareTo(other) > 0;

  /// Whether this dot orders at or before [other].
  bool operator <=(Dot other) => compareTo(other) <= 0;

  /// Whether this dot orders at or after [other].
  bool operator >=(Dot other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is Dot && counter == other.counter && replica == other.replica;

  @override
  int get hashCode => Object.hash(counter, replica);

  @override
  String toString() => isOrigin ? 'origin' : '$counter@$replica';
}

/// A per-replica Lamport clock that mints [Dot]s for local edits.
///
/// [observe] folds a counter seen on incoming content into the local clock
/// so that the next minted dot strictly dominates it. This gives, for free,
/// the "local edits causally dominate observed content" property that a
/// separate HLC-witness step had to enforce out-of-band: an edit authored
/// against pulled content always sorts after that content.
class LamportClock {
  /// Creates a clock for [replica], optionally resuming from a prior counter.
  LamportClock(this.replica, [this._counter = 0]);

  /// Stable identifier of this replica; stamped into every minted [Dot].
  final String replica;
  int _counter;

  /// Current high-water mark. The next [tick] returns `value + 1`.
  int get value => _counter;

  /// Mint the next dot for a local event.
  Dot tick() => Dot(++_counter, replica);

  /// Raise the clock so future dots dominate an observed [counter]
  /// (Lamport receive rule).
  void observe(int counter) {
    if (counter > _counter) _counter = counter;
  }

  /// Convenience: observe every dot of an existing element set.
  void observeAll(Iterable<Dot> dots) {
    for (final d in dots) {
      if (d.counter > _counter) _counter = d.counter;
    }
  }
}
