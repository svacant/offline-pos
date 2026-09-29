import type { OfflineLimits } from './offline';

export type PosConfig = {
  locationId: string | null;
  currency: string;
  offline: OfflineLimits;
};

export const BACKEND_URL = (process.env.EXPO_PUBLIC_POS_BACKEND_URL ?? '').replace(/\/+$/, '');
const API_KEY = process.env.EXPO_PUBLIC_POS_API_KEY ?? '';

// Used until the backend has been reached at least once.
export const DEFAULT_CONFIG: PosConfig = {
  locationId: process.env.EXPO_PUBLIC_STRIPE_LOCATION_ID || null,
  currency: (process.env.EXPO_PUBLIC_POS_CURRENCY || 'eur').toLowerCase(),
  offline: { maxTransactionAmount: 10000, maxStoredAmount: 100000 },
};

async function backend(path: string, init?: RequestInit, timeoutMs = 8000): Promise<Response> {
  if (!BACKEND_URL) throw new Error('EXPO_PUBLIC_POS_BACKEND_URL is not set');
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(`${BACKEND_URL}${path}`, {
      ...init,
      signal: controller.signal,
      headers: { ...init?.headers, Authorization: `Bearer ${API_KEY}` },
    });
    if (!res.ok) throw new Error(`${path} returned HTTP ${res.status}`);
    return res;
  } finally {
    clearTimeout(timer);
  }
}

export async function fetchRemoteConfig(): Promise<PosConfig> {
  const res = await backend('/config');
  return (await res.json()) as PosConfig;
}

/**
 * Token provider for StripeTerminalProvider. While offline this throws; the
 * SDK then keeps working from its cached session for offline payments.
 */
export async function fetchConnectionToken(): Promise<string> {
  const res = await backend('/connection_token', { method: 'POST' });
  const { secret } = (await res.json()) as { secret: string };
  return secret;
}
