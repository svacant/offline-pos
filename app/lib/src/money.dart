import 'package:intl/intl.dart';

// Amounts are integers in the currency's minor unit (cents for EUR), the same
// unit Stripe uses, so no floating point ever touches money.

enum PinPadKey {
  d0('0'),
  d1('1'),
  d2('2'),
  d3('3'),
  d4('4'),
  d5('5'),
  d6('6'),
  d7('7'),
  d8('8'),
  d9('9'),
  doubleZero('00'),
  backspace('⌫'),
  clear('C');

  const PinPadKey(this.label);
  final String label;

  static PinPadKey digit(int value) => PinPadKey.values[value];
}

/// 999.999,99 in a two-decimal currency.
const int maxAmount = 99999999;

const _zeroDecimalCurrencies = {
  'bif', 'clp', 'djf', 'gnf', 'jpy', 'kmf', 'krw', 'mga', 'pyg', 'rwf', 'ugx', 'vnd', 'vuv', 'xaf', 'xof', 'xpf', //
};

int minorUnitDigits(String currency) => _zeroDecimalCurrencies.contains(currency.toLowerCase()) ? 0 : 2;

/// Applies a pinpad key cash-register style: digits shift in from the right,
/// so typing 1, 2, 5 gives 1,25. Keys that would exceed [max] are ignored.
int pressKey(int amount, PinPadKey key, {int max = maxAmount}) {
  switch (key) {
    case PinPadKey.clear:
      return 0;
    case PinPadKey.backspace:
      return amount ~/ 10;
    case PinPadKey.doubleZero:
      final next = amount * 100;
      return next <= max ? next : amount;
    default:
      final next = amount * 10 + key.index;
      return next <= max ? next : amount;
  }
}

String formatAmount(int amount, String currency, {String locale = 'it_IT'}) {
  final digits = minorUnitDigits(currency);
  final format = NumberFormat.simpleCurrency(locale: locale, name: currency.toUpperCase(), decimalDigits: digits);
  return format.format(digits == 0 ? amount : amount / 100);
}
