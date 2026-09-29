function intFromEnv(env, name, fallback) {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  const value = Number.parseInt(raw, 10);
  if (!Number.isFinite(value) || value < 0) {
    throw new Error(`${name} must be a non-negative integer (minor units), got "${raw}"`);
  }
  return value;
}

/**
 * Reads the server configuration from environment variables.
 * Amounts are in minor units (e.g. cents).
 */
export function loadConfig(env = process.env) {
  const required = ['STRIPE_SECRET_KEY', 'POS_API_KEY'];
  const missing = required.filter((name) => !env[name]);
  if (missing.length > 0) {
    throw new Error(`Missing required environment variables: ${missing.join(', ')}`);
  }

  return {
    port: intFromEnv(env, 'PORT', 8080),
    stripeSecretKey: env.STRIPE_SECRET_KEY,
    webhookSecret: env.STRIPE_WEBHOOK_SECRET || null,
    posApiKey: env.POS_API_KEY,
    locationId: env.STRIPE_LOCATION_ID || null,
    currency: (env.POS_CURRENCY || 'eur').toLowerCase(),
    offline: {
      // Largest single payment accepted while offline. Offline payments are
      // authorised only when forwarded, so this caps the risk per card.
      maxTransactionAmount: intFromEnv(env, 'OFFLINE_MAX_TRANSACTION_AMOUNT', 10000),
      // Largest total of payments stored on the device waiting to be forwarded.
      maxStoredAmount: intFromEnv(env, 'OFFLINE_MAX_STORED_AMOUNT', 100000),
    },
  };
}
