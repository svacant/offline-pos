import { formatAmount, MAX_AMOUNT, pressKey, type PinPadKey } from '../amount';

const type = (keys: PinPadKey[], start = 0) => keys.reduce((amount, key) => pressKey(amount, key), start);

describe('pressKey', () => {
  it('shifts digits in from the right like a cash register', () => {
    expect(type(['1', '2', '5'])).toBe(125);
    expect(type(['0', '0', '7'])).toBe(7);
  });

  it('handles 00, backspace and clear', () => {
    expect(type(['5', '00'])).toBe(500);
    expect(type(['1', '2', '3', 'backspace'])).toBe(12);
    expect(type(['9', '9', 'clear'])).toBe(0);
    expect(pressKey(0, 'backspace')).toBe(0);
  });

  it('ignores keys that would exceed the maximum', () => {
    expect(pressKey(MAX_AMOUNT, '1')).toBe(MAX_AMOUNT);
    expect(pressKey(1_000_000, '00')).toBe(1_000_000);
    expect(pressKey(12, '3', 100)).toBe(12);
  });
});

describe('formatAmount', () => {
  const plain = (s: string) => s.replace(/\s/g, ' ');

  it('formats minor units as a currency', () => {
    expect(plain(formatAmount(125, 'eur'))).toBe('1,25 €');
    expect(plain(formatAmount(1234560, 'eur'))).toBe('12.345,60 €');
    expect(plain(formatAmount(0, 'EUR'))).toBe('0,00 €');
  });

  it('knows zero-decimal currencies', () => {
    expect(plain(formatAmount(500, 'jpy', 'en-US'))).toBe('¥500');
  });
});
