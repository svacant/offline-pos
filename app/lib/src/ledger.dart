// Local, device-side record of every sale. It is the POS's own source of
// truth while offline and survives restarts (see ledger_store.dart).

import 'dart:math';

enum TxStatus {
  /// Payment started, outcome not known yet (e.g. app closed mid-payment).
  pending,

  /// Authorised online by Stripe.
  succeeded,

  /// Accepted offline, waiting to be forwarded.
  storedOffline,

  /// Rejected when forwarded, or declined online.
  declined,

  /// Error before the card was charged.
  failed,

  /// Canceled by the operator or the customer.
  canceled,
}

class PosTransaction {
  const PosTransaction({
    required this.id,
    required this.amount,
    required this.currency,
    required this.createdAt,
    required this.updatedAt,
    required this.status,
    this.paymentIntentId,
    this.cardBrand,
    this.last4,
    this.error,
  });

  final String id;
  final int amount;
  final String currency;
  final DateTime createdAt;
  final DateTime updatedAt;
  final TxStatus status;
  final String? paymentIntentId;
  final String? cardBrand;
  final String? last4;
  final String? error;

  PosTransaction copyWith({
    TxStatus? status,
    DateTime? updatedAt,
    String? paymentIntentId,
    String? cardBrand,
    String? last4,
    String? error,
    bool clearError = false,
  }) => PosTransaction(
    id: id,
    amount: amount,
    currency: currency,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    status: status ?? this.status,
    paymentIntentId: paymentIntentId ?? this.paymentIntentId,
    cardBrand: cardBrand ?? this.cardBrand,
    last4: last4 ?? this.last4,
    error: clearError ? null : (error ?? this.error),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'amount': amount,
    'currency': currency,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'status': status.name,
    if (paymentIntentId != null) 'paymentIntentId': paymentIntentId,
    if (cardBrand != null) 'cardBrand': cardBrand,
    if (last4 != null) 'last4': last4,
    if (error != null) 'error': error,
  };

  factory PosTransaction.fromJson(Map<String, dynamic> json) => PosTransaction(
    id: json['id'] as String,
    amount: (json['amount'] as num).toInt(),
    currency: json['currency'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    status: TxStatus.values.byName(json['status'] as String),
    paymentIntentId: json['paymentIntentId'] as String?,
    cardBrand: json['cardBrand'] as String?,
    last4: json['last4'] as String?,
    error: json['error'] as String?,
  );
}

final _random = Random();

String newTransactionId([DateTime? now]) {
  final time = (now ?? DateTime.now()).millisecondsSinceEpoch.toRadixString(36);
  final rand = List.generate(8, (_) => _random.nextInt(36).toRadixString(36)).join();
  return 'tx_${time}_$rand';
}

/// Newest first; replaces an entry with the same id.
List<PosTransaction> addTransaction(List<PosTransaction> ledger, PosTransaction tx) => [
  tx,
  ...ledger.where((t) => t.id != tx.id),
];

List<PosTransaction> updateTransaction(
  List<PosTransaction> ledger,
  String id,
  PosTransaction Function(PosTransaction) update,
) => [for (final t in ledger) t.id == id ? update(t) : t];

class LedgerSummary {
  const LedgerSummary({required this.total, required this.count, required this.pendingForward, required this.declined});

  /// Sales that count as income: succeeded plus stored offline.
  final int total;
  final int count;

  /// Portion of [total] still waiting to be forwarded to Stripe.
  final int pendingForward;
  final int declined;
}

LedgerSummary summarize(List<PosTransaction> ledger, String currency, {DateTime? since}) {
  var total = 0, count = 0, pendingForward = 0, declined = 0;
  for (final tx in ledger) {
    if (tx.currency != currency) continue;
    if (since != null && tx.createdAt.isBefore(since)) continue;
    switch (tx.status) {
      case TxStatus.succeeded:
      case TxStatus.storedOffline:
        total += tx.amount;
        count += 1;
        if (tx.status == TxStatus.storedOffline) pendingForward += tx.amount;
      case TxStatus.declined:
        declined += tx.amount;
      default:
        break;
    }
  }
  return LedgerSummary(total: total, count: count, pendingForward: pendingForward, declined: declined);
}

DateTime startOfDay([DateTime? date]) {
  final d = date ?? DateTime.now();
  return DateTime(d.year, d.month, d.day);
}
