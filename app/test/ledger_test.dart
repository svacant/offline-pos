import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/src/ledger.dart';

final t0 = DateTime.utc(2026, 9, 29, 10);

PosTransaction tx(
  String id, {
  int amount = 1000,
  TxStatus status = TxStatus.succeeded,
  String currency = 'eur',
  DateTime? at,
}) => PosTransaction(
  id: id,
  amount: amount,
  currency: currency,
  createdAt: at ?? t0,
  updatedAt: at ?? t0,
  status: status,
);

void main() {
  test('adds newest first and updates in place', () {
    var ledger = addTransaction([], tx('a'));
    ledger = addTransaction(ledger, tx('b', status: TxStatus.pending));
    expect(ledger.map((t) => t.id), ['b', 'a']);

    ledger = updateTransaction(ledger, 'b', (t) => t.copyWith(status: TxStatus.storedOffline, last4: '4242'));
    expect(ledger.first.status, TxStatus.storedOffline);
    expect(ledger.first.last4, '4242');
    expect(ledger.last.status, TxStatus.succeeded);
  });

  test('copyWith can clear the error', () {
    final failed = tx('a').copyWith(error: 'boom');
    expect(failed.error, 'boom');
    expect(failed.copyWith(status: TxStatus.succeeded).error, 'boom');
    expect(failed.copyWith(clearError: true).error, isNull);
  });

  test('round-trips through JSON', () {
    final original = tx('a', status: TxStatus.storedOffline).copyWith(cardBrand: 'visa', last4: '4242', error: 'x');
    final copy = PosTransaction.fromJson(original.toJson());
    expect(copy.toJson(), original.toJson());
  });

  test('summarizes income, pending forwards and declines', () {
    final ledger = [
      tx('1', amount: 1000),
      tx('2', amount: 500, status: TxStatus.storedOffline),
      tx('3', amount: 700, status: TxStatus.declined),
      tx('4', amount: 900, status: TxStatus.canceled),
      tx('5', amount: 800, currency: 'usd'),
      tx('6', amount: 300, at: DateTime.utc(2026, 9, 28)),
    ];
    final s = summarize(ledger, 'eur', since: DateTime.utc(2026, 9, 29));
    expect([s.total, s.count, s.pendingForward, s.declined], [1500, 2, 500, 700]);
  });

  test('transaction ids are unique', () {
    final ids = {for (var i = 0; i < 1000; i++) newTransactionId(t0)};
    expect(ids.length, 1000);
  });
}
