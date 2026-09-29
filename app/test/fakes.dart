import 'dart:async';

import 'package:offline_pos/src/config.dart';
import 'package:offline_pos/src/ledger.dart';
import 'package:offline_pos/src/pos_controller.dart';
import 'package:offline_pos/src/terminal_bridge.dart';

class FakeTerminal implements TerminalApi {
  final controller = StreamController<TerminalEvent>.broadcast();
  Map<Object?, Object?> initialStatus = {
    'sdk': {'networkStatus': 'online', 'count': 0, 'amounts': <String, int>{}},
  };

  /// Next result of [collectPayment]: a [ChargeOutcome] or a [TerminalError].
  Object nextCharge = const ChargeOutcome(
    storedOffline: false,
    paymentIntentId: 'pi_1',
    cardBrand: 'visa',
    last4: '4242',
  );
  final charges = <Map<String, Object>>[];
  Completer<void>? holdCharge;

  /// Thrown by [initialize] when set, e.g. to simulate a platform without the bridge.
  Object? initializeError;

  void emit(TerminalEvent event) => controller.add(event);

  @override
  Stream<TerminalEvent> get events => controller.stream;

  @override
  Future<Map<Object?, Object?>> initialize(Future<String> Function() tokenProvider) async {
    if (initializeError != null) throw initializeError!;
    return initialStatus;
  }

  @override
  Future<void> discoverReaders({required ReaderLink link, required bool simulated}) async {}

  @override
  Future<void> cancelDiscovery() async {}

  @override
  Future<ReaderInfo> connectReader({
    required String serialNumber,
    required String locationId,
    required ReaderLink link,
  }) async => ReaderInfo(serialNumber: serialNumber, label: 'Simulato', simulated: true);

  @override
  Future<void> disconnectReader() async {}

  @override
  Future<ChargeOutcome> collectPayment({required int amount, required String currency, required String posTxId}) async {
    charges.add({'amount': amount, 'currency': currency, 'posTxId': posTxId});
    if (holdCharge != null) await holdCharge!.future;
    final next = nextCharge;
    if (next is TerminalError) throw next;
    return next as ChargeOutcome;
  }

  @override
  Future<void> cancelCollect() async {}

  @override
  Future<void> setSimulatedOffline(bool offline) async {}
}

class MemoryStorage implements PosPersistence {
  List<PosTransaction> saved = [];
  PosConfig? config;

  @override
  Future<List<PosTransaction>> loadLedger() async => saved;

  @override
  Future<void> saveLedger(List<PosTransaction> ledger) async => saved = ledger;

  @override
  Future<PosConfig?> loadConfig() async => config;

  @override
  Future<void> saveConfig(PosConfig config) async => this.config = config;
}
