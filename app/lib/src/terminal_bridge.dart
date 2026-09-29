import 'dart:async';

import 'package:flutter/services.dart';

// Dart side of the native Stripe Terminal bridge
// (android/app/src/main/kotlin/.../StripeTerminalBridge.kt). No Flutter
// plugin supports Stripe Terminal offline mode, so the app talks to the
// official Android SDK directly over these channels.

enum ReaderLink { bluetooth, usb }

class ReaderInfo {
  const ReaderInfo({
    required this.serialNumber,
    this.label,
    this.deviceType,
    this.batteryLevel,
    this.simulated = false,
  });

  final String serialNumber;
  final String? label;
  final String? deviceType;
  final double? batteryLevel;
  final bool simulated;

  String get displayName => (label?.isNotEmpty ?? false) ? label! : serialNumber;

  factory ReaderInfo.fromMap(Map<Object?, Object?> map) => ReaderInfo(
    serialNumber: map['serialNumber'] as String,
    label: map['label'] as String?,
    deviceType: map['deviceType'] as String?,
    batteryLevel: (map['batteryLevel'] as num?)?.toDouble(),
    simulated: map['simulated'] as bool? ?? false,
  );
}

/// Error raised by the SDK. [code] is the Stripe `TerminalErrorCode` name.
class TerminalError implements Exception {
  const TerminalError(this.code, this.message, {this.declined = false});

  final String code;
  final String message;

  /// True when the card was declined (online, or offline by the reader).
  final bool declined;

  bool get canceled => code == 'CANCELED';

  factory TerminalError.fromPlatform(PlatformException e) {
    final details = e.details;
    return TerminalError(e.code, e.message ?? e.code, declined: details is Map && details['declined'] == true);
  }

  @override
  String toString() => 'TerminalError($code): $message';
}

/// Result of a completed card payment.
class ChargeOutcome {
  const ChargeOutcome({required this.storedOffline, this.paymentIntentId, this.cardBrand, this.last4});

  /// True when the SDK stored the payment to forward it later.
  final bool storedOffline;
  final String? paymentIntentId;
  final String? cardBrand;
  final String? last4;

  factory ChargeOutcome.fromMap(Map<Object?, Object?> map) => ChargeOutcome(
    storedOffline: map['storedOffline'] as bool? ?? false,
    paymentIntentId: map['paymentIntentId'] as String?,
    cardBrand: map['cardBrand'] as String?,
    last4: map['last4'] as String?,
  );
}

sealed class TerminalEvent {
  const TerminalEvent();

  static TerminalEvent? fromMap(Map<Object?, Object?> map) {
    switch (map['type']) {
      case 'offlineStatus':
        return OfflineStatusEvent(map['status'] as Map<Object?, Object?>);
      case 'paymentForwarded':
        return PaymentForwardedEvent(
          posTxId: map['posTxId'] as String?,
          paymentIntentId: map['paymentIntentId'] as String?,
          status: map['status'] as String?,
          error: map['error'] as String?,
        );
      case 'forwardingFailure':
        return ForwardingFailureEvent(map['error'] as String? ?? '');
      case 'readers':
        return ReadersEvent([for (final r in map['readers'] as List) ReaderInfo.fromMap(r as Map<Object?, Object?>)]);
      case 'discoveryFinished':
        return DiscoveryFinishedEvent(map['error'] as String?);
      case 'connectionStatus':
        return ConnectionStatusEvent(map['status'] as String);
      case 'readerMessage':
        return ReaderMessageEvent(map['message'] as String);
      case 'disconnected':
        return const DisconnectedEvent();
    }
    return null;
  }
}

class OfflineStatusEvent extends TerminalEvent {
  const OfflineStatusEvent(this.status);
  final Map<Object?, Object?> status;
}

/// An offline payment reached Stripe. [error] is set when it was declined.
class PaymentForwardedEvent extends TerminalEvent {
  const PaymentForwardedEvent({this.posTxId, this.paymentIntentId, this.status, this.error});
  final String? posTxId;
  final String? paymentIntentId;

  /// PaymentIntent status after forwarding, e.g. `succeeded`.
  final String? status;
  final String? error;
}

class ForwardingFailureEvent extends TerminalEvent {
  const ForwardingFailureEvent(this.error);
  final String error;
}

class ReadersEvent extends TerminalEvent {
  const ReadersEvent(this.readers);
  final List<ReaderInfo> readers;
}

class DiscoveryFinishedEvent extends TerminalEvent {
  const DiscoveryFinishedEvent(this.error);
  final String? error;
}

class ConnectionStatusEvent extends TerminalEvent {
  const ConnectionStatusEvent(this.status);
  final String status;
}

/// Prompt to show the cardholder, e.g. `INSERT_CARD`.
class ReaderMessageEvent extends TerminalEvent {
  const ReaderMessageEvent(this.message);
  final String message;
}

class DisconnectedEvent extends TerminalEvent {
  const DisconnectedEvent();
}

/// Operations the POS needs from Stripe Terminal. Implemented over platform
/// channels by [MethodChannelTerminal]; tests use a fake.
abstract interface class TerminalApi {
  Stream<TerminalEvent> get events;

  /// Initialises the SDK. [tokenProvider] is called whenever the SDK needs a
  /// connection token. Returns the current offline status.
  Future<Map<Object?, Object?>> initialize(Future<String> Function() tokenProvider);

  Future<void> discoverReaders({required ReaderLink link, required bool simulated});

  Future<void> cancelDiscovery();

  Future<ReaderInfo> connectReader({
    required String serialNumber,
    required String locationId,
    required ReaderLink link,
  });

  Future<void> disconnectReader();

  /// Creates, collects and confirms a payment with `prefer_online` behaviour.
  Future<ChargeOutcome> collectPayment({required int amount, required String currency, required String posTxId});

  Future<void> cancelCollect();

  /// Test mode only: makes the SDK behave as if the network were down.
  Future<void> setSimulatedOffline(bool offline);
}

class MethodChannelTerminal implements TerminalApi {
  MethodChannelTerminal()
    : _methods = const MethodChannel('offline_pos/terminal'),
      _events = const EventChannel('offline_pos/terminal/events');

  final MethodChannel _methods;
  final EventChannel _events;

  late final Stream<TerminalEvent> _stream = _events
      .receiveBroadcastStream()
      .map((e) => TerminalEvent.fromMap(e as Map<Object?, Object?>))
      .where((e) => e != null)
      .cast<TerminalEvent>();

  @override
  Stream<TerminalEvent> get events => _stream;

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _methods.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw TerminalError.fromPlatform(e);
    }
  }

  @override
  Future<Map<Object?, Object?>> initialize(Future<String> Function() tokenProvider) async {
    _methods.setMethodCallHandler((call) async {
      if (call.method == 'fetchConnectionToken') return tokenProvider();
      throw MissingPluginException(call.method);
    });
    return (await _invoke<Map<Object?, Object?>>('initialize'))!;
  }

  @override
  Future<void> discoverReaders({required ReaderLink link, required bool simulated}) =>
      _invoke<void>('discoverReaders', {'link': link.name, 'simulated': simulated});

  @override
  Future<void> cancelDiscovery() => _invoke<void>('cancelDiscovery');

  @override
  Future<ReaderInfo> connectReader({
    required String serialNumber,
    required String locationId,
    required ReaderLink link,
  }) async => ReaderInfo.fromMap(
    (await _invoke<Map<Object?, Object?>>('connectReader', {
      'serialNumber': serialNumber,
      'locationId': locationId,
      'link': link.name,
    }))!,
  );

  @override
  Future<void> disconnectReader() => _invoke<void>('disconnectReader');

  @override
  Future<ChargeOutcome> collectPayment({
    required int amount,
    required String currency,
    required String posTxId,
  }) async => ChargeOutcome.fromMap(
    (await _invoke<Map<Object?, Object?>>('collectPayment', {
      'amount': amount,
      'currency': currency,
      'posTxId': posTxId,
    }))!,
  );

  @override
  Future<void> cancelCollect() => _invoke<void>('cancelCollect');

  @override
  Future<void> setSimulatedOffline(bool offline) => _invoke<void>('setSimulatedOffline', {'offline': offline});
}
