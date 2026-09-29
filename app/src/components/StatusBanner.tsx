import { StyleSheet, Text, View } from 'react-native';
import { formatAmount } from '../lib/amount';
import { usePos } from '../pos/PosProvider';
import { colors } from './theme';

export function StatusBanner() {
  const { offline, config, connectedReader, initError } = usePos();

  const online = offline.networkStatus === 'online';
  const networkLabel = online ? 'Online' : offline.networkStatus === 'offline' ? 'Offline' : 'Rete sconosciuta';
  const readerLabel = connectedReader ? connectedReader.label || connectedReader.serialNumber : 'Nessun lettore';

  return (
    <View>
      <View style={styles.row}>
        <View style={[styles.pill, { backgroundColor: online ? colors.primary : colors.warning }]}>
          <Text style={styles.pillText}>{networkLabel}</Text>
        </View>
        <View style={[styles.pill, { backgroundColor: connectedReader ? colors.info : colors.surfaceRaised }]}>
          <Text style={styles.pillText}>{readerLabel}</Text>
        </View>
      </View>
      {offline.storedCount > 0 && (
        <Text style={styles.stored}>
          {offline.storedCount} pagamenti offline da inoltrare ({formatAmount(offline.storedAmount, config.currency)})
        </Text>
      )}
      {initError && <Text style={styles.error}>{initError}</Text>}
    </View>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', gap: 8, flexWrap: 'wrap' },
  pill: { paddingHorizontal: 12, paddingVertical: 6, borderRadius: 999 },
  pillText: { color: colors.background, fontWeight: '700', fontSize: 13 },
  stored: { color: colors.warning, marginTop: 8, fontSize: 13 },
  error: { color: colors.danger, marginTop: 8, fontSize: 13 },
});
