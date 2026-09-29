import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/src/money.dart';

int type(List<PinPadKey> keys, [int start = 0]) => keys.fold(start, pressKey);

String plain(String s) => s.replaceAll(RegExp(r'\s'), ' ');

void main() {
  group('pressKey', () {
    test('shifts digits in from the right like a cash register', () {
      expect(type([PinPadKey.d1, PinPadKey.d2, PinPadKey.d5]), 125);
      expect(type([PinPadKey.d0, PinPadKey.d0, PinPadKey.d7]), 7);
    });

    test('handles 00, backspace and clear', () {
      expect(type([PinPadKey.d5, PinPadKey.doubleZero]), 500);
      expect(type([PinPadKey.d1, PinPadKey.d2, PinPadKey.d3, PinPadKey.backspace]), 12);
      expect(type([PinPadKey.d9, PinPadKey.d9, PinPadKey.clear]), 0);
      expect(pressKey(0, PinPadKey.backspace), 0);
    });

    test('ignores keys that would exceed the maximum', () {
      expect(pressKey(maxAmount, PinPadKey.d1), maxAmount);
      expect(pressKey(1000000, PinPadKey.doubleZero), 1000000);
      expect(pressKey(12, PinPadKey.d3, max: 100), 12);
    });

    test('digit keys map to their value', () {
      for (var i = 0; i <= 9; i++) {
        expect(PinPadKey.digit(i).label, '$i');
      }
    });
  });

  group('formatAmount', () {
    test('formats minor units as euro', () {
      expect(plain(formatAmount(125, 'eur')), '1,25 €');
      expect(plain(formatAmount(1234560, 'eur')), '12.345,60 €');
      expect(plain(formatAmount(0, 'EUR')), '0,00 €');
    });

    test('knows zero-decimal currencies', () {
      expect(minorUnitDigits('jpy'), 0);
      expect(plain(formatAmount(500, 'jpy', locale: 'en_US')), '¥500');
    });
  });
}
