// Amounts are integers in the currency's minor unit (cents for EUR), the same
// unit Stripe uses, so no floating point ever touches money.

export type PinPadKey = '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9' | '00' | 'backspace' | 'clear';

// 999.999,99 in a two-decimal currency.
export const MAX_AMOUNT = 99_999_999;

const ZERO_DECIMAL_CURRENCIES = new Set([
  'bif', 'clp', 'djf', 'gnf', 'jpy', 'kmf', 'krw', 'mga', 'pyg', 'rwf', 'ugx', 'vnd', 'vuv', 'xaf', 'xof', 'xpf',
]);

export function minorUnitDigits(currency: string): number {
  return ZERO_DECIMAL_CURRENCIES.has(currency.toLowerCase()) ? 0 : 2;
}

/**
 * Applies a pinpad key to the current amount, cash-register style: digits
 * shift in from the right, so typing 1, 2, 5 gives 1,25.
 * Keys that would exceed `max` are ignored.
 */
export function pressKey(amount: number, key: PinPadKey, max: number = MAX_AMOUNT): number {
  switch (key) {
    case 'clear':
      return 0;
    case 'backspace':
      return Math.floor(amount / 10);
    case '00': {
      const next = amount * 100;
      return next <= max ? next : amount;
    }
    default: {
      const next = amount * 10 + Number(key);
      return next <= max ? next : amount;
    }
  }
}

export function formatAmount(amount: number, currency: string, locale = 'it-IT'): string {
  const digits = minorUnitDigits(currency);
  return new Intl.NumberFormat(locale, {
    style: 'currency',
    currency: currency.toUpperCase(),
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(amount / 10 ** digits);
}
