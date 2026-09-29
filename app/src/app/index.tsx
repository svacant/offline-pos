import { useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';
import { PinPad } from '../components/PinPad';
import { StatusBanner } from '../components/StatusBanner';
import { colors } from '../components/theme';
import { formatAmount, pressKey, type PinPadKey } from '../lib/amount';
import { usePos, type ChargePhase, type ChargeResult } from '../pos/PosProvider';

const PHASE_LABELS: Record<ChargePhase, string> = {
  idle: '',
  creating: 'Preparazione pagamento…',
  collecting: 'In attesa della carta…',
  confirming: 'Autorizzazione…',
};

export default function CheckoutScreen() {
  const { config, connectedReader, phase, readerMessage, charge, cancelCharge, ready } = usePos();
  const [amount, setAmount] = useState(0);
  const [result, setResult] = useState<ChargeResult | null>(null);

  const busy = phase !== 'idle';
  const canCharge = ready && amount > 0 && !!connectedReader && !busy;

  const onKey = (key: PinPadKey) => {
    setResult(null);
    setAmount((current) => pressKey(current, key));
  };

  const onCharge = async () => {
    setResult(null);
    const outcome = await charge(amount);
    setResult(outcome);
    if (outcome.ok) setAmount(0);
  };

  return (
    <View style={styles.container}>
      <StatusBanner />

      <View style={styles.display}>
        <Text style={styles.amount} numberOfLines={1} adjustsFontSizeToFit>
          {formatAmount(amount, config.currency)}
        </Text>
        {busy ? (
          <View style={styles.progress}>
            <ActivityIndicator color={colors.info} />
            <Text style={styles.progressText}>{readerMessage ?? PHASE_LABELS[phase]}</Text>
          </View>
        ) : (
          result && <ResultLine result={result} currency={config.currency} />
        )}
      </View>

      <PinPad onKey={onKey} disabled={busy} />

      {busy ? (
        <Pressable
          style={[styles.action, styles.cancel]}
          onPress={cancelCharge}
          disabled={phase !== 'collecting'}
          accessibilityRole="button"
        >
          <Text style={styles.actionText}>Annulla</Text>
        </Pressable>
      ) : (
        <Pressable
          style={[styles.action, !canCharge && styles.actionDisabled]}
          onPress={onCharge}
          disabled={!canCharge}
          accessibilityRole="button"
        >
          <Text style={styles.actionText}>
            {connectedReader ? `Incassa ${formatAmount(amount, config.currency)}` : 'Collega un lettore'}
          </Text>
        </Pressable>
      )}
    </View>
  );
}

function ResultLine({ result, currency }: { result: ChargeResult; currency: string }) {
  if (!result.ok) {
    return <Text style={[styles.result, { color: colors.danger }]}>{result.message}</Text>;
  }
  const { tx } = result;
  const card = tx.last4 ? ` · ${tx.cardBrand ?? 'carta'} •••• ${tx.last4}` : '';
  if (tx.status === 'stored_offline') {
    return (
      <Text style={[styles.result, { color: colors.warning }]}>
        {formatAmount(tx.amount, currency)} accettato offline{card}. Verrà inoltrato a Stripe appena torna la rete.
      </Text>
    );
  }
  return (
    <Text style={[styles.result, { color: colors.primary }]}>
      Pagamento di {formatAmount(tx.amount, currency)} riuscito{card}
    </Text>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, padding: 16, gap: 16, backgroundColor: colors.background },
  display: { flex: 1, justifyContent: 'center', alignItems: 'center', gap: 12 },
  amount: { color: colors.text, fontSize: 64, fontWeight: '700', fontVariant: ['tabular-nums'] },
  progress: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  progressText: { color: colors.info, fontSize: 16 },
  result: { fontSize: 15, textAlign: 'center' },
  action: {
    backgroundColor: colors.primary,
    borderRadius: 14,
    paddingVertical: 18,
    alignItems: 'center',
  },
  actionDisabled: { opacity: 0.4 },
  cancel: { backgroundColor: colors.danger },
  actionText: { color: colors.primaryText, fontSize: 20, fontWeight: '700' },
});
