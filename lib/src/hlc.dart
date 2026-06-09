// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Hybrid Logical Clock.
///
/// Combines wall-clock time with a logical counter to provide:
/// - Monotonically increasing timestamps even with clock drift
/// - Causal ordering (if A caused B, then A.hlc < B.hlc)
/// - Deterministic tie-breaking via [nodeId]
///
/// Based on: https://cse.buffalo.edu/tech-reports/2014-04.pdf
class Hlc implements Comparable<Hlc> {
  final int millis;
  final int counter;
  final String nodeId;

  const Hlc(this.millis, this.counter, this.nodeId);

  /// Create an HLC from the current wall clock.
  factory Hlc.now(String nodeId) =>
      Hlc(DateTime.now().millisecondsSinceEpoch, 0, nodeId);

  /// Advance the clock for a local event.
  Hlc increment(int wallMs) {
    if (wallMs > millis) {
      return Hlc(wallMs, 0, nodeId);
    }
    return Hlc(millis, counter + 1, nodeId);
  }

  /// Merge with a received remote clock.
  ///
  /// [maxSkewMs] caps how far in the future a remote `millis` is trusted.
  /// When `remote.millis > wallMs + maxSkewMs`, the remote physical-time
  /// component is treated as if it equaled `wallMs` — the node refuses
  /// to poison its own logical clock from a wildly out-of-sync (or
  /// malicious) peer. Causal ordering is still partially preserved
  /// because if `remote` was actually concurrent its embedded
  /// [CausalContext] (passed separately at the application layer) carries
  /// the dependency. Set [maxSkewMs] to `null` (default) for the paper's
  /// unbounded behaviour.
  ///
  /// See paper §4 (self-stabilizing fault-tolerance).
  Hlc receive(Hlc remote, int wallMs, {int? maxSkewMs}) {
    final effectiveRemoteMs =
        maxSkewMs != null && remote.millis > wallMs + maxSkewMs
        ? wallMs
        : remote.millis;
    final effectiveRemote = effectiveRemoteMs == remote.millis
        ? remote
        : Hlc(effectiveRemoteMs, 0, remote.nodeId);
    final r = effectiveRemote;
    final maxMs = _max3(wallMs, millis, r.millis);
    if (maxMs == wallMs && wallMs != millis && wallMs != r.millis) {
      return Hlc(maxMs, 0, nodeId);
    }
    if (maxMs == millis && millis == r.millis) {
      return Hlc(maxMs, _max2(counter, r.counter) + 1, nodeId);
    }
    if (maxMs == millis) {
      return Hlc(maxMs, counter + 1, nodeId);
    }
    return Hlc(maxMs, r.counter + 1, nodeId);
  }

  @override
  int compareTo(Hlc other) {
    final cmp = millis.compareTo(other.millis);
    if (cmp != 0) return cmp;
    final cc = counter.compareTo(other.counter);
    if (cc != 0) return cc;
    return nodeId.compareTo(other.nodeId);
  }

  bool operator <(Hlc other) => compareTo(other) < 0;
  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator <=(Hlc other) => compareTo(other) <= 0;
  bool operator >=(Hlc other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      millis == other.millis &&
      counter == other.counter &&
      nodeId == other.nodeId;

  @override
  int get hashCode => Object.hash(millis, counter, nodeId);

  @override
  String toString() => 'Hlc($millis:$counter@$nodeId)';

  /// Pack to a compact string for storage/wire: "millis-counter-nodeId"
  String pack() => '$millis-$counter-$nodeId';

  /// Unpack from compact string.
  static Hlc unpack(String s) {
    final parts = s.split('-');
    if (parts.length < 3) throw FormatException('Invalid HLC: $s');
    return Hlc(
      int.parse(parts[0]),
      int.parse(parts[1]),
      parts.sublist(2).join('-'),
    );
  }
}

int _max2(int a, int b) => a > b ? a : b;
int _max3(int a, int b, int c) => _max2(a, _max2(b, c));
