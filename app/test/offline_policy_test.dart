import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/src/offline_policy.dart';

const limits = OfflineLimits(maxTransactionAmount: 5000, maxStoredAmount: 20000);

void main() {
  group('OfflineSnapshot.fromBridge', () {
    test('sums SDK and reader stored payments for the POS currency only', () {
      final snapshot = OfflineSnapshot.fromBridge({
        'sdk': {
          'networkStatus': 'offline',
          'count': 2,
          'amounts': {'eur': 3000, 'usd': 999},
        },
        'reader': {
          'networkStatus': 'online',
          'count': 1,
          'amounts': {'EUR': 500},
        },
      }, 'eur');
      expect(snapshot.networkStatus, NetworkStatus.offline);
      expect(snapshot.storedCount, 3);
      expect(snapshot.storedAmount, 3500);
    });

    test('handles a missing reader and unknown network', () {
      final snapshot = OfflineSnapshot.fromBridge({
        'sdk': {'networkStatus': 'weird', 'count': 0, 'amounts': <String, int>{}},
      }, 'eur');
      expect(snapshot.networkStatus, NetworkStatus.unknown);
      expect(snapshot.storedAmount, 0);
    });
  });

  group('checkOfflineLimits', () {
    const online = OfflineSnapshot(networkStatus: NetworkStatus.online, storedCount: 0, storedAmount: 0);
    const offline = OfflineSnapshot(networkStatus: NetworkStatus.offline, storedCount: 3, storedAmount: 18000);

    test('does not apply limits while online', () {
      expect(checkOfflineLimits(1000000, online, limits), isNull);
    });

    test('caps a single offline payment', () {
      const empty = OfflineSnapshot(networkStatus: NetworkStatus.offline, storedCount: 0, storedAmount: 0);
      expect(checkOfflineLimits(5000, empty, limits), isNull);
      expect(checkOfflineLimits(5001, empty, limits), OfflineRejection.overTransactionLimit);
    });

    test('caps the total waiting to be forwarded', () {
      expect(checkOfflineLimits(2000, offline, limits), isNull);
      expect(checkOfflineLimits(2001, offline, limits), OfflineRejection.overStoredLimit);
    });

    test('treats an unknown network as offline', () {
      const unknown = OfflineSnapshot(networkStatus: NetworkStatus.unknown, storedCount: 0, storedAmount: 0);
      expect(checkOfflineLimits(6000, unknown, limits), OfflineRejection.overTransactionLimit);
    });
  });
}
