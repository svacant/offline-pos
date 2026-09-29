import type { OfflineStatus } from '@stripe/stripe-terminal-react-native';

export type OfflineLimits = {
  /** Largest single payment accepted while offline (minor units). */
  maxTransactionAmount: number;
  /** Largest total of stored, not yet forwarded payments (minor units). */
  maxStoredAmount: number;
};

export type NetworkStatus = 'online' | 'offline' | 'unknown';

export type OfflineSnapshot = {
  networkStatus: NetworkStatus;
  /** Payments stored on the device/reader waiting to be forwarded to Stripe. */
  storedCount: number;
  /** Total of stored payments in the POS currency (minor units). */
  storedAmount: number;
};

export const EMPTY_SNAPSHOT: OfflineSnapshot = { networkStatus: 'unknown', storedCount: 0, storedAmount: 0 };

/**
 * Collapses the SDK offline status into what the POS needs. Mobile readers
 * store offline payments in the SDK, smart readers on the reader itself, so
 * both are summed. The SDK side drives the network status because that is
 * the link the app uses to reach Stripe.
 */
export function summarizeOfflineStatus(status: OfflineStatus, currency: string): OfflineSnapshot {
  const key = currency.toLowerCase();
  const sources = [status.sdk, status.reader].filter((s): s is NonNullable<typeof s> => Boolean(s));
  const amountFor = (amounts: Record<string, number>) =>
    Object.entries(amounts).reduce((sum, [cur, value]) => (cur.toLowerCase() === key ? sum + value : sum), 0);

  return {
    networkStatus: status.sdk?.networkStatus ?? 'unknown',
    storedCount: sources.reduce((sum, s) => sum + s.offlinePaymentsCount, 0),
    storedAmount: sources.reduce((sum, s) => sum + amountFor(s.offlinePaymentAmountsByCurrency ?? {}), 0),
  };
}

export type OfflineDecision =
  | { allowed: true; offlineBehavior: 'prefer_online' }
  | { allowed: false; reason: 'over_transaction_limit' | 'over_stored_limit' };

/**
 * Decides whether a charge may be attempted. Payments always use
 * `prefer_online`: online when Stripe is reachable, stored on the device
 * otherwise. When the network is not confirmed online the merchant's
 * offline risk limits apply, because a stored payment is only authorised
 * once it is forwarded and may be declined then.
 */
export function decideOffline(amount: number, snapshot: OfflineSnapshot, limits: OfflineLimits): OfflineDecision {
  if (snapshot.networkStatus !== 'online') {
    if (amount > limits.maxTransactionAmount) {
      return { allowed: false, reason: 'over_transaction_limit' };
    }
    if (snapshot.storedAmount + amount > limits.maxStoredAmount) {
      return { allowed: false, reason: 'over_stored_limit' };
    }
  }
  return { allowed: true, offlineBehavior: 'prefer_online' };
}
