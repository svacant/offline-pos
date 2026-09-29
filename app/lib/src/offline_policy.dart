enum NetworkStatus { online, offline, unknown }

class OfflineLimits {
  const OfflineLimits({required this.maxTransactionAmount, required this.maxStoredAmount});

  /// Largest single payment accepted while offline (minor units).
  final int maxTransactionAmount;

  /// Largest total of stored, not yet forwarded payments (minor units).
  final int maxStoredAmount;

  factory OfflineLimits.fromJson(Map<String, dynamic> json) => OfflineLimits(
    maxTransactionAmount: (json['maxTransactionAmount'] as num).toInt(),
    maxStoredAmount: (json['maxStoredAmount'] as num).toInt(),
  );

  Map<String, dynamic> toJson() => {'maxTransactionAmount': maxTransactionAmount, 'maxStoredAmount': maxStoredAmount};
}

/// What the POS needs from the SDK offline status.
class OfflineSnapshot {
  const OfflineSnapshot({required this.networkStatus, required this.storedCount, required this.storedAmount});

  static const empty = OfflineSnapshot(networkStatus: NetworkStatus.unknown, storedCount: 0, storedAmount: 0);

  final NetworkStatus networkStatus;

  /// Payments stored on the device/reader waiting to be forwarded to Stripe.
  final int storedCount;

  /// Total of stored payments in the POS currency (minor units).
  final int storedAmount;

  /// Builds a snapshot from the map sent by the native bridge:
  /// `{sdk: {networkStatus, count, amounts: {eur: 1200}}, reader: {...}}`.
  /// Mobile readers store offline payments in the SDK, smart readers on the
  /// reader, so both are summed; the SDK side drives the network status.
  factory OfflineSnapshot.fromBridge(Map<Object?, Object?> status, String currency) {
    final key = currency.toLowerCase();
    var count = 0;
    var amount = 0;
    NetworkStatus network = NetworkStatus.unknown;
    for (final side in ['sdk', 'reader']) {
      final details = status[side];
      if (details is! Map) continue;
      count += (details['count'] as num?)?.toInt() ?? 0;
      final amounts = details['amounts'];
      if (amounts is Map) {
        amounts.forEach((cur, value) {
          if (cur.toString().toLowerCase() == key && value is num) amount += value.toInt();
        });
      }
      if (side == 'sdk') network = _parseNetwork(details['networkStatus']);
    }
    return OfflineSnapshot(networkStatus: network, storedCount: count, storedAmount: amount);
  }

  static NetworkStatus _parseNetwork(Object? value) => switch (value) {
    'online' => NetworkStatus.online,
    'offline' => NetworkStatus.offline,
    _ => NetworkStatus.unknown,
  };
}

enum OfflineRejection { overTransactionLimit, overStoredLimit }

/// Returns why a charge must be refused, or null when it may proceed.
///
/// Payments always use the SDK's `prefer_online` behaviour: online when Stripe
/// is reachable, stored on the device otherwise. When the network is not
/// confirmed online the merchant's risk limits apply, because a stored payment
/// is only authorised once forwarded and may be declined then.
OfflineRejection? checkOfflineLimits(int amount, OfflineSnapshot snapshot, OfflineLimits limits) {
  if (snapshot.networkStatus == NetworkStatus.online) return null;
  if (amount > limits.maxTransactionAmount) return OfflineRejection.overTransactionLimit;
  if (snapshot.storedAmount + amount > limits.maxStoredAmount) return OfflineRejection.overStoredLimit;
  return null;
}
