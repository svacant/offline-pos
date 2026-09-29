import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'ledger.dart';
import 'pos_controller.dart';

const _ledgerKey = 'pos.ledger.v1';
const _configKey = 'pos.config.v1';

// Keep the local history bounded; Stripe remains the long-term record.
const _maxLedgerEntries = 2000;

/// Persists the sales ledger and the last known backend config on the device.
class PosStorage implements PosPersistence {
  PosStorage(this._prefs);

  final SharedPreferencesAsync _prefs;

  @override
  Future<List<PosTransaction>> loadLedger() async {
    final raw = await _prefs.getString(_ledgerKey);
    if (raw == null) return [];
    try {
      return [for (final item in jsonDecode(raw) as List) PosTransaction.fromJson(item as Map<String, dynamic>)];
    } on FormatException {
      return [];
    }
  }

  @override
  Future<void> saveLedger(List<PosTransaction> ledger) async {
    // Never drop sales still waiting on Stripe, whatever their age.
    final keep = [
      for (var i = 0; i < ledger.length; i++)
        if (i < _maxLedgerEntries || ledger[i].status == TxStatus.storedOffline || ledger[i].status == TxStatus.pending)
          ledger[i],
    ];
    await _prefs.setString(_ledgerKey, jsonEncode([for (final t in keep) t.toJson()]));
  }

  @override
  Future<PosConfig?> loadConfig() async {
    final raw = await _prefs.getString(_configKey);
    if (raw == null) return null;
    try {
      return PosConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> saveConfig(PosConfig config) => _prefs.setString(_configKey, jsonEncode(config.toJson()));
}
