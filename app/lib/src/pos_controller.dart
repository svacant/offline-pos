import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'config.dart';
import 'ledger.dart';
import 'money.dart';
import 'offline_policy.dart';
import 'terminal_bridge.dart';

/// Where the controller keeps its state between launches.
abstract interface class PosPersistence {
  Future<List<PosTransaction>> loadLedger();
  Future<void> saveLedger(List<PosTransaction> ledger);
  Future<PosConfig?> loadConfig();
  Future<void> saveConfig(PosConfig config);
}

enum ChargePhase { idle, collecting }

enum ConfigSource { defaults, cache, remote }

sealed class ChargeResult {
  const ChargeResult();
}

class ChargeSucceeded extends ChargeResult {
  const ChargeSucceeded(this.tx);
  final PosTransaction tx;
}

class ChargeFailed extends ChargeResult {
  const ChargeFailed(this.message, {this.tx});
  final String message;
  final PosTransaction? tx;
}

const _readerMessages = {
  'INSERT_CARD': 'Inserire la carta',
  'INSERT_OR_SWIPE_CARD': 'Inserire o strisciare la carta',
  'MULTIPLE_CONTACTLESS_CARDS_DETECTED': 'Più carte rilevate: avvicinarne una sola',
  'REMOVE_CARD': 'Rimuovere la carta',
  'RETRY_CARD': 'Riprovare con la carta',
  'SWIPE_CARD': 'Strisciare la carta',
  'TRY_ANOTHER_CARD': 'Provare un’altra carta',
  'TRY_ANOTHER_READ_METHOD': 'Provare un altro metodo di lettura',
  'CHECK_MOBILE_DEVICE': 'Controllare il telefono del cliente',
  'CARD_REMOVED_TOO_EARLY': 'Carta rimossa troppo presto',
  'INPUT': 'Avvicinare, inserire o strisciare la carta',
};

/// Ties together the Stripe Terminal bridge, the local ledger and the backend
/// config. The UI only talks to this class.
class PosController extends ChangeNotifier {
  PosController({
    required this._terminal,
    required this._storage,
    required this._fetchConfig,
    required this._fetchConnectionToken,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final TerminalApi _terminal;
  final PosPersistence _storage;
  final Future<PosConfig> Function() _fetchConfig;
  final Future<String> Function() _fetchConnectionToken;
  final DateTime Function() _clock;
  StreamSubscription<TerminalEvent>? _subscription;

  bool ready = false;
  String? initError;
  PosConfig config = PosConfig.defaults;
  ConfigSource configSource = ConfigSource.defaults;
  OfflineSnapshot offline = OfflineSnapshot.empty;
  List<PosTransaction> ledger = const [];
  ReaderInfo? connectedReader;
  List<ReaderInfo> discoveredReaders = const [];
  bool discovering = false;
  String? readerMessage;
  ChargePhase phase = ChargePhase.idle;

  /// Restores local state first so the POS is usable without network, then
  /// initialises the SDK and tries to refresh the config.
  Future<void> start({bool missingPermissions = false}) async {
    ledger = await _storage.loadLedger();
    final cached = await _storage.loadConfig();
    if (cached != null) {
      config = cached;
      configSource = ConfigSource.cache;
    }
    notifyListeners();

    // Listen before initialising, so no event from the SDK is missed.
    _subscription = _terminal.events.listen(_onEvent);
    try {
      final status = await _terminal.initialize(_fetchConnectionToken);
      offline = OfflineSnapshot.fromBridge(status, config.currency);
      if (missingPermissions) {
        initError = 'Permessi posizione/Bluetooth negati: abilitali nelle impostazioni per usare il lettore.';
      }
    } on TerminalError catch (e) {
      initError = 'Stripe Terminal non inizializzato: ${e.message}';
    } on MissingPluginException {
      // The native bridge exists only on Android (see README).
      initError = 'Stripe Terminal non disponibile su questa piattaforma: usa Android.';
    }
    ready = true;
    notifyListeners();
    unawaited(refreshConfig());
  }

  Future<void> refreshConfig() async {
    try {
      final remote = await _fetchConfig();
      config = PosConfig(
        locationId: remote.locationId ?? PosConfig.defaults.locationId,
        currency: remote.currency,
        offline: remote.offline,
        livemode: remote.livemode,
      );
      configSource = ConfigSource.remote;
      await _storage.saveConfig(config);
      notifyListeners();
    } catch (e) {
      debugPrint('Uso la configurazione in cache: $e');
    }
  }

  void _setLedger(List<PosTransaction> next) {
    ledger = next;
    notifyListeners();
    unawaited(_storage.saveLedger(next));
  }

  void _updateTx(String id, PosTransaction Function(PosTransaction) update) {
    _setLedger(updateTransaction(ledger, id, (t) => update(t).copyWith(updatedAt: _clock())));
  }

  PosTransaction _tx(String id) => ledger.firstWhere((t) => t.id == id);

  void _onEvent(TerminalEvent event) {
    switch (event) {
      case OfflineStatusEvent(:final status):
        offline = OfflineSnapshot.fromBridge(status, config.currency);
      case PaymentForwardedEvent():
        _onForwarded(event);
        return;
      case ForwardingFailureEvent(:final error):
        debugPrint('Inoltro pagamenti offline non riuscito: $error');
        return;
      case ReadersEvent(:final readers):
        discoveredReaders = readers;
      case DiscoveryFinishedEvent():
        discovering = false;
      case ConnectionStatusEvent():
        break;
      case ReaderMessageEvent(:final message):
        readerMessage = _readerMessages[message] ?? message;
      case DisconnectedEvent():
        connectedReader = null;
    }
    notifyListeners();
  }

  void _onForwarded(PaymentForwardedEvent event) {
    final id = event.posTxId;
    if (id == null || !ledger.any((t) => t.id == id)) return;
    if (event.error != null) {
      _updateTx(
        id,
        (t) => t.copyWith(status: TxStatus.declined, error: event.error, paymentIntentId: event.paymentIntentId),
      );
    } else if (event.status == 'succeeded') {
      _updateTx(
        id,
        (t) => t.copyWith(status: TxStatus.succeeded, paymentIntentId: event.paymentIntentId, clearError: true),
      );
    } else if (event.status == 'requires_payment_method' || event.status == 'canceled') {
      _updateTx(id, (t) => t.copyWith(status: TxStatus.declined, paymentIntentId: event.paymentIntentId));
    } else {
      _updateTx(id, (t) => t.copyWith(paymentIntentId: event.paymentIntentId));
    }
  }

  Future<ChargeResult> charge(int amount) async {
    if (connectedReader == null) return const ChargeFailed('Nessun lettore collegato');
    if (amount <= 0) return const ChargeFailed('Importo non valido');
    if (phase != ChargePhase.idle) return const ChargeFailed('Pagamento già in corso');

    final currency = config.currency;
    final limits = config.offline;
    switch (checkOfflineLimits(amount, offline, limits)) {
      case OfflineRejection.overTransactionLimit:
        return ChargeFailed(
          'Offline sono accettati importi fino a ${formatAmount(limits.maxTransactionAmount, currency)}',
        );
      case OfflineRejection.overStoredLimit:
        return ChargeFailed(
          'Limite di pagamenti offline in attesa raggiunto (${formatAmount(limits.maxStoredAmount, currency)})',
        );
      case null:
        break;
    }

    final now = _clock();
    final id = newTransactionId(now);
    _setLedger(
      addTransaction(
        ledger,
        PosTransaction(
          id: id,
          amount: amount,
          currency: currency,
          createdAt: now,
          updatedAt: now,
          status: TxStatus.pending,
        ),
      ),
    );
    phase = ChargePhase.collecting;
    notifyListeners();

    try {
      final outcome = await _terminal.collectPayment(amount: amount, currency: currency, posTxId: id);
      _updateTx(
        id,
        (t) => t.copyWith(
          status: outcome.storedOffline ? TxStatus.storedOffline : TxStatus.succeeded,
          paymentIntentId: outcome.paymentIntentId,
          cardBrand: outcome.cardBrand,
          last4: outcome.last4,
          clearError: true,
        ),
      );
      return ChargeSucceeded(_tx(id));
    } on TerminalError catch (e) {
      final status = e.canceled ? TxStatus.canceled : (e.declined ? TxStatus.declined : TxStatus.failed);
      _updateTx(id, (t) => t.copyWith(status: status, error: e.message));
      return ChargeFailed(e.canceled ? 'Pagamento annullato' : e.message, tx: _tx(id));
    } finally {
      phase = ChargePhase.idle;
      readerMessage = null;
      notifyListeners();
    }
  }

  /// Asks the reader to stop waiting for the card. [charge] then completes
  /// with a canceled result.
  Future<void> cancelCharge() async {
    try {
      await _terminal.cancelCollect();
    } on TerminalError catch (e) {
      debugPrint('Annullamento non riuscito: ${e.message}');
    }
  }

  /// Returns an error message, or null on success.
  Future<String?> discover(ReaderLink link, {required bool simulated}) async {
    discovering = true;
    discoveredReaders = const [];
    notifyListeners();
    try {
      await _terminal.discoverReaders(link: link, simulated: simulated);
      return null;
    } on TerminalError catch (e) {
      discovering = false;
      notifyListeners();
      return e.message;
    }
  }

  Future<void> cancelDiscovery() async {
    try {
      await _terminal.cancelDiscovery();
    } on TerminalError catch (e) {
      debugPrint('Stop ricerca non riuscito: ${e.message}');
    }
    discovering = false;
    notifyListeners();
  }

  Future<String?> connect(ReaderInfo reader, ReaderLink link) async {
    final locationId = config.locationId;
    if (locationId == null) return 'Location Stripe non configurata (STRIPE_LOCATION_ID sul server)';
    try {
      connectedReader = await _terminal.connectReader(
        serialNumber: reader.serialNumber,
        locationId: locationId,
        link: link,
      );
      discovering = false;
      notifyListeners();
      return null;
    } on TerminalError catch (e) {
      return e.message;
    }
  }

  Future<String?> disconnect() async {
    try {
      await _terminal.disconnectReader();
    } on TerminalError catch (e) {
      return e.message;
    }
    connectedReader = null;
    notifyListeners();
    return null;
  }

  Future<String?> simulateOffline(bool value) async {
    try {
      await _terminal.setSimulatedOffline(value);
      return null;
    } on TerminalError catch (e) {
      return e.message;
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
