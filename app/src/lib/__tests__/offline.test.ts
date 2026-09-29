import { decideOffline, summarizeOfflineStatus, type OfflineSnapshot } from '../offline';

const limits = { maxTransactionAmount: 5000, maxStoredAmount: 20000 };

describe('summarizeOfflineStatus', () => {
  it('sums SDK and reader stored payments for the POS currency only', () => {
    const snapshot = summarizeOfflineStatus(
      {
        sdk: { networkStatus: 'offline', offlinePaymentsCount: 2, offlinePaymentAmountsByCurrency: { eur: 3000, usd: 999 } },
        reader: { networkStatus: 'online', offlinePaymentsCount: 1, offlinePaymentAmountsByCurrency: { EUR: 500 } },
      },
      'eur',
    );
    expect(snapshot).toEqual({ networkStatus: 'offline', storedCount: 3, storedAmount: 3500 });
  });

  it('works without reader details', () => {
    const snapshot = summarizeOfflineStatus(
      { sdk: { networkStatus: 'online', offlinePaymentsCount: 0, offlinePaymentAmountsByCurrency: {} } },
      'eur',
    );
    expect(snapshot).toEqual({ networkStatus: 'online', storedCount: 0, storedAmount: 0 });
  });
});

describe('decideOffline', () => {
  const online: OfflineSnapshot = { networkStatus: 'online', storedCount: 0, storedAmount: 0 };
  const offline: OfflineSnapshot = { networkStatus: 'offline', storedCount: 3, storedAmount: 18000 };

  it('does not apply offline limits while online', () => {
    expect(decideOffline(1_000_000, online, limits)).toEqual({ allowed: true, offlineBehavior: 'prefer_online' });
  });

  it('caps a single offline payment', () => {
    expect(decideOffline(5001, { ...offline, storedAmount: 0 }, limits)).toEqual({
      allowed: false,
      reason: 'over_transaction_limit',
    });
  });

  it('caps the total waiting to be forwarded', () => {
    expect(decideOffline(2000, offline, limits)).toEqual({ allowed: true, offlineBehavior: 'prefer_online' });
    expect(decideOffline(2001, offline, limits)).toEqual({ allowed: false, reason: 'over_stored_limit' });
  });

  it('treats an unknown network as offline', () => {
    expect(decideOffline(6000, { ...online, networkStatus: 'unknown' }, limits).allowed).toBe(false);
  });
});
