import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/src/config.dart';
import 'package:offline_pos/src/offline_policy.dart';
import 'package:offline_pos/src/pos_controller.dart';
import 'package:offline_pos/src/terminal_bridge.dart';
import 'package:offline_pos/ui/checkout_screen.dart';

import 'fakes.dart';

void main() {
  testWidgets('types an amount on the pinpad and charges it', (tester) async {
    final terminal = FakeTerminal();
    final pos = PosController(
      terminal: terminal,
      storage: MemoryStorage(),
      fetchConfig: () async => const PosConfig(
        locationId: 'tml_test',
        currency: 'eur',
        offline: OfflineLimits(maxTransactionAmount: 5000, maxStoredAmount: 8000),
      ),
      fetchConnectionToken: () async => 'x',
    );
    await pos.start();
    await pos.refreshConfig();
    await pos.connect(const ReaderInfo(serialNumber: 'SIM-1'), ReaderLink.bluetooth);

    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CheckoutScreen(controller: pos)),
      ),
    );

    String amount() =>
        (tester.widget(find.byKey(const ValueKey('amount'))) as Text).data!.replaceAll(RegExp(r'\s'), ' ');

    expect(amount(), '0,00 €');
    for (final key in ['d1', 'd2', 'd5']) {
      await tester.tap(find.byKey(ValueKey('key-$key')));
    }
    await tester.pump();
    expect(amount(), '1,25 €');

    await tester.tap(find.byKey(const ValueKey('key-backspace')));
    await tester.pump();
    expect(amount(), '0,12 €');

    await tester.tap(find.byKey(const ValueKey('key-d5')));
    await tester.tap(find.byKey(const ValueKey('key-doubleZero')));
    await tester.pump();
    expect(amount(), '125,00 €');

    await tester.tap(find.byKey(const ValueKey('charge')));
    await tester.pumpAndSettle();

    expect(terminal.charges.single['amount'], 12500);
    expect(find.textContaining('riuscito'), findsOneWidget);
    expect(amount(), '0,00 €');
  });
}
