import 'package:flutter/material.dart';

import '../src/ledger.dart';
import '../src/money.dart';
import '../src/pos_controller.dart';
import 'pin_pad.dart';
import 'status_banner.dart';

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key, required this.controller});

  final PosController controller;

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  int _amount = 0;
  ChargeResult? _result;

  PosController get _pos => widget.controller;

  void _onKey(PinPadKey key) => setState(() {
    _result = null;
    _amount = pressKey(_amount, key);
  });

  Future<void> _charge() async {
    setState(() => _result = null);
    final result = await _pos.charge(_amount);
    if (!mounted) return;
    setState(() {
      _result = result;
      if (result is ChargeSucceeded) _amount = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _pos,
      builder: (context, _) {
        final currency = _pos.config.currency;
        final busy = _pos.phase != ChargePhase.idle;
        final hasReader = _pos.connectedReader != null;
        final canCharge = _pos.ready && _amount > 0 && hasReader && !busy;

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                StatusBanner(controller: _pos),
                Expanded(
                  flex: 2,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FittedBox(
                        child: Text(
                          formatAmount(_amount, currency),
                          key: const ValueKey('amount'),
                          style: const TextStyle(
                            fontSize: 64,
                            fontWeight: FontWeight.bold,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (busy)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                            const SizedBox(width: 8),
                            Text(_pos.readerMessage ?? 'In attesa della carta…'),
                          ],
                        )
                      else if (_result != null)
                        _ResultLine(result: _result!, currency: currency),
                    ],
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: PinPad(onKey: _onKey, enabled: !busy),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 64,
                  child: busy
                      ? FilledButton.tonal(
                          onPressed: _pos.cancelCharge,
                          child: const Text('Annulla', style: TextStyle(fontSize: 20)),
                        )
                      : FilledButton(
                          key: const ValueKey('charge'),
                          onPressed: canCharge ? _charge : null,
                          child: Text(
                            hasReader ? 'Incassa ${formatAmount(_amount, currency)}' : 'Collega un lettore',
                            style: const TextStyle(fontSize: 20),
                          ),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ResultLine extends StatelessWidget {
  const _ResultLine({required this.result, required this.currency});

  final ChargeResult result;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (result) {
      ChargeFailed(:final message) => (message, Theme.of(context).colorScheme.error),
      ChargeSucceeded(:final tx) when tx.status == TxStatus.storedOffline => (
        '${formatAmount(tx.amount, currency)} accettato offline${_card(tx)}. '
            'Verrà inoltrato a Stripe appena torna la rete.',
        Colors.amber,
      ),
      ChargeSucceeded(:final tx) => (
        'Pagamento di ${formatAmount(tx.amount, currency)} riuscito${_card(tx)}',
        Colors.green,
      ),
    };
    return Text(
      text,
      key: const ValueKey('result'),
      textAlign: TextAlign.center,
      style: TextStyle(color: color),
    );
  }

  static String _card(PosTransaction tx) => tx.last4 == null ? '' : ' · ${tx.cardBrand ?? 'carta'} •••• ${tx.last4}';
}
