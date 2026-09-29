import { useMemo } from 'react';
import { FlatList, StyleSheet, Text, View } from 'react-native';
import { colors } from '../components/theme';
import { formatAmount } from '../lib/amount';
import { startOfDay, summarize, type PosTransaction, type TxStatus } from '../lib/ledger';
import { usePos } from '../pos/PosProvider';

const STATUS: Record<TxStatus, { label: string; color: string }> = {
  pending: { label: 'Da verificare', color: colors.textMuted },
  succeeded: { label: 'Riuscito', color: colors.primary },
  stored_offline: { label: 'Offline, da inoltrare', color: colors.warning },
  declined: { label: 'Rifiutato', color: colors.danger },
  failed: { label: 'Errore', color: colors.danger },
  canceled: { label: 'Annullato', color: colors.textMuted },
};

export default function HistoryScreen() {
  const { ledger, config } = usePos();
  const today = useMemo(() => summarize(ledger, config.currency, startOfDay()), [ledger, config.currency]);
  const fmt = (amount: number) => formatAmount(amount, config.currency);

  return (
    <View style={styles.container}>
      <View style={styles.summary}>
        <Text style={styles.summaryTitle}>Oggi</Text>
        <Text style={styles.summaryTotal}>{fmt(today.total)}</Text>
        <Text style={styles.summaryLine}>{today.count} incassi</Text>
        {today.pendingForward > 0 && (
          <Text style={[styles.summaryLine, { color: colors.warning }]}>di cui {fmt(today.pendingForward)} offline da inoltrare</Text>
        )}
        {today.declined > 0 && (
          <Text style={[styles.summaryLine, { color: colors.danger }]}>{fmt(today.declined)} rifiutati</Text>
        )}
      </View>

      <FlatList
        data={ledger}
        keyExtractor={(tx) => tx.id}
        renderItem={({ item }) => <Row tx={item} fmt={fmt} />}
        ItemSeparatorComponent={() => <View style={styles.separator} />}
        ListEmptyComponent={<Text style={styles.empty}>Nessuna transazione</Text>}
      />
    </View>
  );
}

function Row({ tx, fmt }: { tx: PosTransaction; fmt: (amount: number) => string }) {
  const status = STATUS[tx.status];
  const time = new Date(tx.createdAt).toLocaleString('it-IT', { dateStyle: 'short', timeStyle: 'short' });
  return (
    <View style={styles.row}>
      <View style={{ flex: 1 }}>
        <Text style={styles.rowAmount}>{fmt(tx.amount)}</Text>
        <Text style={styles.rowMeta}>
          {time}
          {tx.last4 ? ` · ${tx.cardBrand ?? ''} •••• ${tx.last4}` : ''}
        </Text>
        {tx.error && <Text style={styles.rowError}>{tx.error}</Text>}
      </View>
      <Text style={[styles.rowStatus, { color: status.color }]}>{status.label}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.background },
  summary: { padding: 16, backgroundColor: colors.surface, gap: 2 },
  summaryTitle: { color: colors.textMuted, fontSize: 13, textTransform: 'uppercase' },
  summaryTotal: { color: colors.text, fontSize: 32, fontWeight: '700' },
  summaryLine: { color: colors.textMuted, fontSize: 14 },
  row: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 16, paddingVertical: 12, gap: 12 },
  rowAmount: { color: colors.text, fontSize: 18, fontWeight: '600' },
  rowMeta: { color: colors.textMuted, fontSize: 13 },
  rowError: { color: colors.danger, fontSize: 12 },
  rowStatus: { fontSize: 13, fontWeight: '600' },
  separator: { height: StyleSheet.hairlineWidth, backgroundColor: colors.surfaceRaised },
  empty: { color: colors.textMuted, textAlign: 'center', marginTop: 32 },
});
