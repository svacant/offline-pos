import 'dart:convert';

import 'package:http/http.dart' as http;

import 'offline_policy.dart';

// Build-time settings, passed with --dart-define (see README).
const backendUrl = String.fromEnvironment('POS_BACKEND_URL');
const _apiKey = String.fromEnvironment('POS_API_KEY');

class PosConfig {
  const PosConfig({required this.locationId, required this.currency, required this.offline, this.livemode = false});

  final String? locationId;
  final String currency;
  final OfflineLimits offline;

  /// False when the backend uses a Stripe test key (sandbox).
  final bool livemode;

  /// Used until the backend has been reached at least once.
  static const defaults = PosConfig(
    locationId: String.fromEnvironment('STRIPE_LOCATION_ID') == ''
        ? null
        : String.fromEnvironment('STRIPE_LOCATION_ID'),
    currency: String.fromEnvironment('POS_CURRENCY', defaultValue: 'eur'),
    offline: OfflineLimits(maxTransactionAmount: 10000, maxStoredAmount: 100000),
  );

  factory PosConfig.fromJson(Map<String, dynamic> json) => PosConfig(
    locationId: json['locationId'] as String?,
    currency: (json['currency'] as String? ?? 'eur').toLowerCase(),
    offline: OfflineLimits.fromJson(json['offline'] as Map<String, dynamic>),
    livemode: json['livemode'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'locationId': locationId,
    'currency': currency,
    'offline': offline.toJson(),
    'livemode': livemode,
  };
}

/// Talks to the POS backend (server/).
class Backend {
  Backend({http.Client? client, this.baseUrl = backendUrl, this.apiKey = _apiKey}) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final String apiKey;

  Future<Map<String, dynamic>> _call(String method, String path) async {
    if (baseUrl.isEmpty) throw StateError('POS_BACKEND_URL non impostato (--dart-define)');
    final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path');
    final request = http.Request(method, uri)..headers['Authorization'] = 'Bearer $apiKey';
    final response = await http.Response.fromStream(await _client.send(request).timeout(const Duration(seconds: 8)));
    if (response.statusCode != 200) throw http.ClientException('$path ha risposto HTTP ${response.statusCode}', uri);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<PosConfig> fetchConfig() async => PosConfig.fromJson(await _call('GET', '/config'));

  /// Connection token for Stripe Terminal. While offline this throws; the
  /// SDK then keeps working from its cached session for offline payments.
  Future<String> fetchConnectionToken() async => (await _call('POST', '/connection_token'))['secret'] as String;
}
