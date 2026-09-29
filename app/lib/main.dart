import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/config.dart';
import 'src/pos_controller.dart';
import 'src/storage.dart';
import 'src/terminal_bridge.dart';
import 'ui/checkout_screen.dart';
import 'ui/history_screen.dart';
import 'ui/reader_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Wiring: the real implementations are created here and handed to the
  // controller. Tests hand it fakes instead (see test/fakes.dart).
  final backend = Backend();
  final controller = PosController(
    terminal: MethodChannelTerminal(),
    storage: PosStorage(SharedPreferencesAsync()),
    fetchConfig: backend.fetchConfig,
    fetchConnectionToken: backend.fetchConnectionToken,
  );

  // Show the UI first, then ask for permissions: the system dialogs appear
  // over the app instead of over a black screen.
  runApp(PosApp(controller: controller));

  // Stripe Terminal needs location to take payments, Bluetooth to reach the
  // reader (Android 12+ asks for the two Bluetooth permissions separately).
  final statuses = await [
    Permission.locationWhenInUse,
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
  ].request();
  final denied = [
    for (final e in statuses.entries)
      if (!e.value.isGranted) e.key,
  ];

  await controller.start(missingPermissions: denied.isNotEmpty);
}

class PosApp extends StatelessWidget {
  const PosApp({super.key, required this.controller});

  final PosController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline POS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF22C55E), brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: HomeScreen(controller: controller),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final PosController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  static const _titles = ['Cassa', 'Transazioni', 'Lettore'];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final sandbox = !widget.controller.config.livemode;
        return Scaffold(
          appBar: AppBar(
            title: Text(_titles[_tab]),
            actions: [
              if (sandbox)
                const Padding(
                  padding: EdgeInsets.only(right: 16),
                  child: Chip(label: Text('SANDBOX'), visualDensity: VisualDensity.compact),
                ),
            ],
          ),
          body: IndexedStack(
            index: _tab,
            children: [
              CheckoutScreen(controller: widget.controller),
              HistoryScreen(controller: widget.controller),
              ReaderScreen(controller: widget.controller),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.dialpad), label: 'Cassa'),
              NavigationDestination(icon: Icon(Icons.receipt_long), label: 'Transazioni'),
              NavigationDestination(icon: Icon(Icons.contactless), label: 'Lettore'),
            ],
          ),
        );
      },
    );
  }
}
