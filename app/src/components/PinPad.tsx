import { Pressable, StyleSheet, Text, View } from 'react-native';
import type { PinPadKey } from '../lib/amount';
import { colors } from './theme';

const ROWS: PinPadKey[][] = [
  ['1', '2', '3'],
  ['4', '5', '6'],
  ['7', '8', '9'],
  ['00', '0', 'backspace'],
];

const LABELS: Partial<Record<PinPadKey, string>> = { backspace: '⌫' };

export function PinPad({ onKey, disabled }: { onKey: (key: PinPadKey) => void; disabled?: boolean }) {
  return (
    <View style={styles.grid}>
      {ROWS.map((row) => (
        <View key={row.join()} style={styles.row}>
          {row.map((key) => (
            <Pressable
              key={key}
              accessibilityRole="button"
              accessibilityLabel={key === 'backspace' ? 'Cancella cifra' : key}
              disabled={disabled}
              onPress={() => onKey(key)}
              onLongPress={key === 'backspace' ? () => onKey('clear') : undefined}
              style={({ pressed }) => [styles.key, pressed && styles.keyPressed, disabled && styles.keyDisabled]}
            >
              <Text style={styles.keyText}>{LABELS[key] ?? key}</Text>
            </Pressable>
          ))}
        </View>
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  grid: { gap: 10 },
  row: { flexDirection: 'row', gap: 10 },
  key: {
    flex: 1,
    aspectRatio: 1.6,
    borderRadius: 14,
    backgroundColor: colors.surface,
    alignItems: 'center',
    justifyContent: 'center',
  },
  keyPressed: { backgroundColor: colors.surfaceRaised },
  keyDisabled: { opacity: 0.4 },
  keyText: { color: colors.text, fontSize: 30, fontWeight: '600' },
});
