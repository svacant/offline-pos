import 'package:flutter/material.dart';

import '../src/config.dart';
import '../src/pos_controller.dart';
import '../src/terminal_bridge.dart';
import 'status_banner.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.controller});

  final PosController controller;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  ReaderLink _link = ReaderLink.bluetooth;
  // Sandbox first: the simulated reader works without hardware.
  bool _simulated = true;
  bool _simOffline = false;
  String? _error;
  String? _connecting;

  PosController get _pos => widget.controller;

  Future<void> _run(Future<String?> Function() action) async {
    setState(() => _error = null);
    final error = await action();
    if (mounted) setState(() => _error = error);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _pos,
      builder: (context, _) {
        final reader = _pos.connectedReader;
        final theme = Theme.of(context);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            StatusBanner(controller: _pos),
            const SizedBox(height: 16),
            if (reader != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(reader.displayName, style: theme.textTheme.titleLarge),
                      Text(
                        [
                          reader.deviceType ?? '',
                          reader.serialNumber,
                          if (reader.batteryLevel != null) 'batteria ${(reader.batteryLevel! * 100).round()}%',
                        ].join(' · '),
                      ),
                      if (reader.simulated)
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Simula rete offline'),
                          value: _simOffline,
                          onChanged: (value) {
                            setState(() => _simOffline = value);
                            _run(() => _pos.simulateOffline(value));
                          },
                        ),
                      const SizedBox(height: 8),
                      FilledButton.tonal(onPressed: () => _run(_pos.disconnect), child: const Text('Scollega')),
                    ],
                  ),
                ),
              )
            else
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Collega un lettore', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 12),
                      SegmentedButton<ReaderLink>(
                        segments: const [
                          ButtonSegment(
                            value: ReaderLink.bluetooth,
                            label: Text('Bluetooth'),
                            icon: Icon(Icons.bluetooth),
                          ),
                          ButtonSegment(value: ReaderLink.usb, label: Text('USB'), icon: Icon(Icons.usb)),
                        ],
                        selected: {_link},
                        onSelectionChanged: (s) => setState(() => _link = s.first),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Lettore simulato (sandbox)'),
                        value: _simulated,
                        onChanged: (v) => setState(() => _simulated = v),
                      ),
                      if (_pos.discovering)
                        OutlinedButton.icon(
                          onPressed: _pos.cancelDiscovery,
                          icon: const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          label: const Text('Ricerca… tocca per fermare'),
                        )
                      else
                        FilledButton(
                          onPressed: _pos.ready ? () => _run(() => _pos.discover(_link, simulated: _simulated)) : null,
                          child: const Text('Cerca lettori'),
                        ),
                      for (final r in _pos.discoveredReaders)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(r.displayName),
                          subtitle: Text(r.deviceType ?? ''),
                          trailing: _connecting == r.serialNumber
                              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('Collega'),
                          onTap: _connecting != null
                              ? null
                              : () async {
                                  setState(() => _connecting = r.serialNumber);
                                  await _run(() => _pos.connect(r, _link));
                                  if (mounted) setState(() => _connecting = null);
                                },
                        ),
                    ],
                  ),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Configurazione', style: theme.textTheme.titleLarge),
                    Text('Ambiente: ${_pos.config.livemode ? 'LIVE' : 'Sandbox (Stripe test mode)'}'),
                    Text('Backend: ${backendUrl.isEmpty ? 'non impostato' : backendUrl}'),
                    Text('Location: ${_pos.config.locationId ?? 'non impostata'}'),
                    Text('Valuta: ${_pos.config.currency.toUpperCase()}'),
                    Text('Origine: ${_pos.configSource.name}'),
                    const SizedBox(height: 8),
                    OutlinedButton(onPressed: _pos.refreshConfig, child: const Text('Aggiorna dal server')),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Per i pagamenti offline il lettore deve essersi collegato almeno una volta online a questa '
              'location. Da offline il POS accetta carte entro i limiti impostati sul server e le inoltra '
              'a Stripe al ritorno della rete.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }
}
