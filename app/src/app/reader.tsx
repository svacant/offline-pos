import { useState } from 'react';
import { ActivityIndicator, Platform, Pressable, ScrollView, StyleSheet, Switch, Text, View } from 'react-native';
import { StatusBanner } from '../components/StatusBanner';
import { colors } from '../components/theme';
import { BACKEND_URL } from '../lib/config';
import { usePos, type DiscoveryMethod } from '../pos/PosProvider';

const METHODS: { value: DiscoveryMethod; label: string }[] = [
  { value: 'bluetoothScan', label: 'Bluetooth' },
  ...(Platform.OS === 'android' ? [{ value: 'usb' as const, label: 'USB' }] : []),
];

export default function ReaderScreen() {
  const pos = usePos();
  const [method, setMethod] = useState<DiscoveryMethod>('bluetoothScan');
  const [simulated, setSimulated] = useState(__DEV__);
  const [simOffline, setSimOffline] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [connectingId, setConnectingId] = useState<string | null>(null);

  const run = async (fn: () => Promise<string | null>) => {
    setError(null);
    setError(await fn());
  };

  const reader = pos.connectedReader;

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      <StatusBanner />

      {reader ? (
        <View style={styles.card}>
          <Text style={styles.title}>{reader.label || reader.serialNumber}</Text>
          <Text style={styles.meta}>
            {reader.deviceType} · {reader.serialNumber}
            {reader.batteryLevel != null ? ` · batteria ${Math.round(reader.batteryLevel * 100)}%` : ''}
          </Text>
          {reader.simulated && (
            <View style={styles.switchRow}>
              <Text style={styles.label}>Simula rete offline</Text>
              <Switch
                value={simOffline}
                onValueChange={(value) => {
                  setSimOffline(value);
                  run(() => pos.simulateOffline(value));
                }}
              />
            </View>
          )}
          <Pressable style={[styles.button, styles.danger]} onPress={() => pos.disconnect()}>
            <Text style={styles.buttonText}>Scollega</Text>
          </Pressable>
        </View>
      ) : (
        <View style={styles.card}>
          <Text style={styles.title}>Collega un lettore</Text>
          <View style={styles.segment}>
            {METHODS.map((m) => (
              <Pressable
                key={m.value}
                onPress={() => setMethod(m.value)}
                style={[styles.segmentItem, method === m.value && styles.segmentActive]}
              >
                <Text style={styles.segmentText}>{m.label}</Text>
              </Pressable>
            ))}
          </View>
          <View style={styles.switchRow}>
            <Text style={styles.label}>Lettore simulato (test)</Text>
            <Switch value={simulated} onValueChange={setSimulated} />
          </View>

          {pos.discovering ? (
            <Pressable style={[styles.button, styles.secondary]} onPress={() => pos.cancelDiscover()}>
              <ActivityIndicator color={colors.text} />
              <Text style={styles.buttonTextLight}>Ricerca… (tocca per fermare)</Text>
            </Pressable>
          ) : (
            <Pressable
              style={[styles.button, !pos.ready && styles.disabled]}
              disabled={!pos.ready}
              onPress={() => run(() => pos.discover(method, simulated))}
            >
              <Text style={styles.buttonText}>Cerca lettori</Text>
            </Pressable>
          )}

          {pos.discoveredReaders.map((r) => (
            <Pressable
              key={r.serialNumber}
              style={styles.readerRow}
              disabled={connectingId !== null}
              onPress={async () => {
                setConnectingId(r.serialNumber);
                await run(() => pos.connect(r, method));
                setConnectingId(null);
              }}
            >
              <View style={{ flex: 1 }}>
                <Text style={styles.label}>{r.label || r.serialNumber}</Text>
                <Text style={styles.meta}>{r.deviceType}</Text>
              </View>
              {connectingId === r.serialNumber ? (
                <ActivityIndicator color={colors.info} />
              ) : (
                <Text style={styles.link}>Collega</Text>
              )}
            </Pressable>
          ))}
        </View>
      )}

      {error && <Text style={styles.error}>{error}</Text>}

      <View style={styles.card}>
        <Text style={styles.title}>Configurazione</Text>
        <Text style={styles.meta}>Backend: {BACKEND_URL || 'non impostato'}</Text>
        <Text style={styles.meta}>Location: {pos.config.locationId ?? 'non impostata'}</Text>
        <Text style={styles.meta}>Valuta: {pos.config.currency.toUpperCase()}</Text>
        <Text style={styles.meta}>Origine: {pos.configSource}</Text>
        <Pressable style={[styles.button, styles.secondary]} onPress={() => pos.refreshConfig()}>
          <Text style={styles.buttonTextLight}>Aggiorna dal server</Text>
        </Pressable>
      </View>

      <Text style={styles.note}>
        Per i pagamenti offline il lettore deve essersi collegato almeno una volta online a questa location. Da offline
        il POS accetta carte entro i limiti impostati sul server e le inoltra a Stripe al ritorno della rete.
      </Text>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.background },
  content: { padding: 16, gap: 16 },
  card: { backgroundColor: colors.surface, borderRadius: 14, padding: 16, gap: 12 },
  title: { color: colors.text, fontSize: 18, fontWeight: '700' },
  label: { color: colors.text, fontSize: 15 },
  meta: { color: colors.textMuted, fontSize: 13 },
  link: { color: colors.info, fontWeight: '600' },
  switchRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  segment: { flexDirection: 'row', backgroundColor: colors.background, borderRadius: 10, padding: 4 },
  segmentItem: { flex: 1, paddingVertical: 8, borderRadius: 8, alignItems: 'center' },
  segmentActive: { backgroundColor: colors.surfaceRaised },
  segmentText: { color: colors.text, fontWeight: '600' },
  button: {
    backgroundColor: colors.primary,
    borderRadius: 10,
    paddingVertical: 12,
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row',
    gap: 8,
  },
  secondary: { backgroundColor: colors.surfaceRaised },
  danger: { backgroundColor: colors.danger },
  disabled: { opacity: 0.4 },
  buttonText: { color: colors.primaryText, fontWeight: '700', fontSize: 16 },
  buttonTextLight: { color: colors.text, fontWeight: '600', fontSize: 15 },
  readerRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: 8 },
  error: { color: colors.danger },
  note: { color: colors.textMuted, fontSize: 12, lineHeight: 18 },
});
