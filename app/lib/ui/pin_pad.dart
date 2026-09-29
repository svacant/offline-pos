import 'package:flutter/material.dart';

import '../src/money.dart';

class PinPad extends StatelessWidget {
  const PinPad({super.key, required this.onKey, this.enabled = true});

  final ValueChanged<PinPadKey> onKey;
  final bool enabled;

  static final _rows = [
    [PinPadKey.d1, PinPadKey.d2, PinPadKey.d3],
    [PinPadKey.d4, PinPadKey.d5, PinPadKey.d6],
    [PinPadKey.d7, PinPadKey.d8, PinPadKey.d9],
    [PinPadKey.doubleZero, PinPadKey.d0, PinPadKey.backspace],
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Keys stretch to fill the space the parent gives the pad, so it fits
    // phones and tablets in either orientation.
    return Column(
      children: [
        for (final row in _rows)
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final key in row)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: Material(
                        color: scheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(14),
                        child: InkWell(
                          key: ValueKey('key-${key.name}'),
                          borderRadius: BorderRadius.circular(14),
                          onTap: enabled ? () => onKey(key) : null,
                          // Long press on backspace clears the amount.
                          onLongPress: enabled && key == PinPadKey.backspace ? () => onKey(PinPadKey.clear) : null,
                          child: Center(
                            child: key == PinPadKey.backspace
                                ? Icon(Icons.backspace_outlined, size: 28, semanticLabel: 'Cancella cifra')
                                : Text(key.label, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
