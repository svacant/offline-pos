import 'package:flutter/material.dart';

import '../src/money.dart';
import '../src/offline_policy.dart';
import '../src/pos_controller.dart';

class StatusBanner extends StatelessWidget {
  const StatusBanner({super.key, required this.controller});

  final PosController controller;

  @override
  Widget build(BuildContext context) {
    final offline = controller.offline;
    final reader = controller.connectedReader;
    final theme = Theme.of(context);
    final (label, color) = switch (offline.networkStatus) {
      NetworkStatus.online => ('Online', Colors.green),
      NetworkStatus.offline => ('Offline', Colors.amber),
      NetworkStatus.unknown => ('Rete sconosciuta', Colors.grey),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(
              avatar: Icon(Icons.circle, size: 12, color: color),
              label: Text(label),
            ),
            Chip(
              avatar: Icon(reader != null ? Icons.link : Icons.link_off, size: 16),
              label: Text(reader?.displayName ?? 'Nessun lettore'),
            ),
          ],
        ),
        if (offline.storedCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${offline.storedCount} pagamenti offline da inoltrare '
              '(${formatAmount(offline.storedAmount, controller.config.currency)})',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.amber),
            ),
          ),
        if (controller.initError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              controller.initError!,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}
