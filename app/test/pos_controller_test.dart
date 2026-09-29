import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/src/config.dart';
import 'package:offline_pos/src/ledger.dart';
import 'package:offline_pos/src/offline_policy.dart';
import 'package:offline_pos/src/pos_controller.dart';
import 'package:offline_pos/src/terminal_bridge.dart';

import 'fakes.dart';

const remoteConfig = PosConfig(
  locationId: 'tml_test',
  currency: 'eur',
  offline: OfflineLimits(maxTransactionAmount: 5000, maxStoredAmount: 8000),
);

void main() {
  late FakeTerminal terminal;
  late MemoryStorage storage;
  late PosController pos;

  Future<void> startConnected({bool configReachable = true}) async {
    pos = PosController(
      terminal: terminal,
      storage: storage,
      fetchConfig: () async => configReachable ? remoteConfig : throw Exception('offline'),
      fetchConnectionToken: () async => 'pst_test',
    );
    await pos.start();
    await pumpEventQueue();
    await pos.connect(const ReaderInfo(serialNumber: 'SIM-1'), ReaderLink.bluetooth);
  }

  void goOffline({int count = 0, int amount = 0}) {
    terminal.emit(
      OfflineStatusEvent({
        'sdk': {
          'networkStatus': 'offline',
          'count': count,
          'amounts': {'eur': amount},
        },
      }),
    );
  }

  setUp(() {
    terminal = FakeTerminal();
    storage = MemoryStorage();
  });

  test('loads the remote config and caches it for offline starts', () async {
    await startConnected();
    expect(pos.configSource, ConfigSource.remote);
    expect(pos.config.locationId, 'tml_test');
    expect(storage.config?.locationId, 'tml_test');

    final second = PosController(
      terminal: FakeTerminal(),
      storage: storage,
      fetchConfig: () async => throw Exception('no network'),
      fetchConnectionToken: () async => 'x',
    );
    await second.start();
    await pumpEventQueue();
    expect(second.configSource, ConfigSource.cache);
    expect(second.config.offline.maxStoredAmount, 8000);
  });

  test('an online payment is recorded as succeeded with the card', () async {
    await startConnected();
    final result = await pos.charge(1250);

    expect(result, isA<ChargeSucceeded>());
    final tx = pos.ledger.single;
    expect(tx.status, TxStatus.succeeded);
    expect(tx.amount, 1250);
    expect(tx.paymentIntentId, 'pi_1');
    expect(tx.last4, '4242');
    expect(terminal.charges.single['posTxId'], tx.id);
    expect(storage.saved.single.status, TxStatus.succeeded);
  });

  test('an offline payment is stored, then reconciled when forwarded', () async {
    await startConnected();
    goOffline();
    await pumpEventQueue();
    terminal.nextCharge = const ChargeOutcome(storedOffline: true, cardBrand: 'visa', last4: '0005');

    final result = await pos.charge(3000);
    expect(result, isA<ChargeSucceeded>());
    final id = pos.ledger.single.id;
    expect(pos.ledger.single.status, TxStatus.storedOffline);

    terminal.emit(PaymentForwardedEvent(posTxId: id, paymentIntentId: 'pi_fwd', status: 'succeeded'));
    await pumpEventQueue();
    expect(pos.ledger.single.status, TxStatus.succeeded);
    expect(pos.ledger.single.paymentIntentId, 'pi_fwd');
  });

  test('a forwarded payment declined by Stripe is marked declined', () async {
    await startConnected();
    goOffline();
    await pumpEventQueue();
    terminal.nextCharge = const ChargeOutcome(storedOffline: true);
    await pos.charge(1000);
    final id = pos.ledger.single.id;

    terminal.emit(PaymentForwardedEvent(posTxId: id, error: 'Your card was declined.'));
    await pumpEventQueue();
    expect(pos.ledger.single.status, TxStatus.declined);
    expect(pos.ledger.single.error, 'Your card was declined.');
    expect(summarize(pos.ledger, 'eur').declined, 1000);
  });

  test('offline limits refuse the charge before touching the reader', () async {
    await startConnected();
    goOffline(count: 1, amount: 4000);
    await pumpEventQueue();

    final overSingle = await pos.charge(5001);
    expect(overSingle, isA<ChargeFailed>());
    expect((overSingle as ChargeFailed).message, contains('50,00'));

    final overTotal = await pos.charge(4001);
    expect((overTotal as ChargeFailed).message, contains('80,00'));

    expect(terminal.charges, isEmpty);
    expect(pos.ledger, isEmpty);
  });

  test('cancel and decline errors map to ledger statuses', () async {
    await startConnected();
    terminal.nextCharge = const TerminalError('CANCELED', 'Canceled');
    final canceled = await pos.charge(100);
    expect((canceled as ChargeFailed).message, 'Pagamento annullato');
    expect(pos.ledger.first.status, TxStatus.canceled);

    terminal.nextCharge = const TerminalError('DECLINED_BY_STRIPE_API', 'Card declined', declined: true);
    await pos.charge(200);
    expect(pos.ledger.first.status, TxStatus.declined);

    terminal.nextCharge = const TerminalError('READER_BUSY', 'Busy');
    await pos.charge(300);
    expect(pos.ledger.first.status, TxStatus.failed);
  });

  test('refuses to charge without a reader or twice at once', () async {
    pos = PosController(
      terminal: terminal,
      storage: storage,
      fetchConfig: () async => remoteConfig,
      fetchConnectionToken: () async => 'x',
    );
    await pos.start();
    expect(await pos.charge(100), isA<ChargeFailed>());

    await pos.connect(const ReaderInfo(serialNumber: 'SIM-1'), ReaderLink.bluetooth);
    terminal.holdCharge = Completer<void>();
    final first = pos.charge(100);
    expect(pos.phase, ChargePhase.collecting);
    expect(pos.ledger.first.status, TxStatus.pending);
    expect(await pos.charge(100), isA<ChargeFailed>());
    terminal.holdCharge!.complete();
    expect(await first, isA<ChargeSucceeded>());
    expect(pos.phase, ChargePhase.idle);
  });

  test('connect needs a location', () async {
    pos = PosController(
      terminal: terminal,
      storage: storage,
      fetchConfig: () async => throw Exception('offline'),
      fetchConnectionToken: () async => 'x',
    );
    await pos.start();
    final error = await pos.connect(const ReaderInfo(serialNumber: 'SIM-1'), ReaderLink.bluetooth);
    expect(error, contains('Location'));
    expect(pos.connectedReader, isNull);
  });

  test('start survives a platform without the native bridge', () async {
    terminal.initializeError = MissingPluginException('initialize');
    pos = PosController(
      terminal: terminal,
      storage: storage,
      fetchConfig: () async => remoteConfig,
      fetchConnectionToken: () async => 'x',
    );
    await pos.start();
    expect(pos.ready, isTrue);
    expect(pos.initError, contains('Android'));
  });

  test('start reports missing permissions', () async {
    pos = PosController(
      terminal: terminal,
      storage: storage,
      fetchConfig: () async => remoteConfig,
      fetchConnectionToken: () async => 'x',
    );
    await pos.start(missingPermissions: true);
    expect(pos.initError, contains('Permessi'));
  });
}
