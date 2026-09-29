import AsyncStorage from '@react-native-async-storage/async-storage';
import type { Ledger } from './ledger';
import type { PosConfig } from './config';

const LEDGER_KEY = 'pos.ledger.v1';
const CONFIG_KEY = 'pos.config.v1';

// Keep the local history bounded; Stripe remains the long-term record.
const MAX_LEDGER_ENTRIES = 2000;

async function readJson<T>(key: string): Promise<T | null> {
  const raw = await AsyncStorage.getItem(key);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return null;
  }
}

export async function loadLedger(): Promise<Ledger> {
  return (await readJson<Ledger>(LEDGER_KEY)) ?? [];
}

export async function saveLedger(ledger: Ledger): Promise<void> {
  // Never drop sales still waiting on Stripe, whatever their age.
  const keep = ledger.filter((t, i) => i < MAX_LEDGER_ENTRIES || t.status === 'stored_offline' || t.status === 'pending');
  await AsyncStorage.setItem(LEDGER_KEY, JSON.stringify(keep));
}

export async function loadCachedConfig(): Promise<PosConfig | null> {
  return readJson<PosConfig>(CONFIG_KEY);
}

export async function saveCachedConfig(config: PosConfig): Promise<void> {
  await AsyncStorage.setItem(CONFIG_KEY, JSON.stringify(config));
}
