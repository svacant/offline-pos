import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../src/ledger.dart';
import '../src/money.dart';
import '../src/pos_controller.dart';

const _statusLabels = {
  TxStatus.pending: ('Da verificare', Colors.grey),
  TxStatus.succeeded: ('Riuscito', Colors.green),
  TxStatus.storedOffline: ('Offline, da inoltrare', Colors.amber),
  TxStatus.declined: ('Rifiutato', Colors.red),
  TxStatus.failed: ('Errore', Colors.red),
  TxStatus.canceled: ('Annullato', Colors.grey),
};

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key, required this.controller});

  final PosController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final currency = controller.config.currency;
        final today = summarize(controller.ledger, currency, since: startOfDay());
        final theme = Theme.of(context);
        String fmt(int amount) => formatAmount(amount, currency);

        return Column(
          children: [
            Container(
              width: double.infinity,
              color: theme.colorScheme.surfaceContainer,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('OGGI', style: theme.textTheme.labelMedium),
                  Text(fmt(today.total), style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                  Text('${today.count} incassi'),
                  if (today.pendingForward > 0)
                    Text(
                      'di cui ${fmt(today.pendingForward)} offline da inoltrare',
                      style: const TextStyle(color: Colors.amber),
                    ),
                  if (today.declined > 0)
                    Text('${fmt(today.declined)} rifiutati', style: const TextStyle(color: Colors.red)),
                ],
              ),
            ),
            Expanded(
              child: controller.ledger.isEmpty
                  ? const Center(child: Text('Nessuna transazione'))
                  : ListView.separated(
                      itemCount: controller.ledger.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final tx = controller.ledger[i];
                        final (label, color) = _statusLabels[tx.status]!;
                        final time = DateFormat('dd/MM/yy HH:mm').format(tx.createdAt.toLocal());
                        final card = tx.last4 == null ? '' : ' · ${tx.cardBrand ?? ''} •••• ${tx.last4}';
                        return ListTile(
                          title: Text(fmt(tx.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text('$time$card${tx.error != null ? '\n${tx.error}' : ''}'),
                          isThreeLine: tx.error != null,
                          trailing: Text(
                            label,
                            style: TextStyle(color: color, fontWeight: FontWeight.w600),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
