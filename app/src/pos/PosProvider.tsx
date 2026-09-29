import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Platform } from 'react-native';
import {
  requestNeededAndroidPermissions,
  useStripeTerminal,
  type PaymentIntent,
  type Reader,
  type StripeError,
} from '@stripe/stripe-terminal-react-native';
import { DEFAULT_CONFIG, fetchRemoteConfig, type PosConfig } from '../lib/config';
import { addTransaction, findForwarded, newTransactionId, updateTransaction, type Ledger, type PosTransaction } from '../lib/ledger';
import { decideOffline, EMPTY_SNAPSHOT, summarizeOfflineStatus, type OfflineSnapshot } from '../lib/offline';
import { loadCachedConfig, loadLedger, saveCachedConfig, saveLedger } from '../lib/storage';
import { formatAmount } from '../lib/amount';

export type DiscoveryMethod = 'bluetoothScan' | 'usb';

export type ChargePhase = 'idle' | 'creating' | 'collecting' | 'confirming';

export type ChargeResult =
  | { ok: true; tx: PosTransaction }
  | { ok: false; tx?: PosTransaction; message: string };

type PosContextValue = {
  ready: boolean;
  initError: string | null;
  config: PosConfig;
  configSource: 'default' | 'cache' | 'remote';
  offline: OfflineSnapshot;
  ledger: Ledger;
  connectedReader: Reader.Type | null | undefined;
  discoveredReaders: Reader.Type[];
  discovering: boolean;
  readerMessage: string | null;
  phase: ChargePhase;
  charge: (amount: number) => Promise<ChargeResult>;
  cancelCharge: () => Promise<void>;
  discover: (method: DiscoveryMethod, simulated: boolean) => Promise<string | null>;
  cancelDiscover: () => Promise<void>;
  connect: (reader: Reader.Type, method: DiscoveryMethod) => Promise<string | null>;
  disconnect: () => Promise<void>;
  simulateOffline: (offline: boolean) => Promise<string | null>;
  refreshConfig: () => Promise<void>;
};

const PosContext = createContext<PosContextValue | null>(null);

export function usePos(): PosContextValue {
  const value = useContext(PosContext);
  if (!value) throw new Error('usePos must be used inside <PosProvider>');
  return value;
}

const DISPLAY_MESSAGES: Record<Reader.DisplayMessage, string> = {
  insertCard: 'Inserire la carta',
  insertOrSwipeCard: 'Inserire o strisciare la carta',
  multipleContactlessCardsDetected: 'Più carte rilevate: avvicinarne una sola',
  removeCard: 'Rimuovere la carta',
  retryCard: 'Riprovare con la carta',
  swipeCard: 'Strisciare la carta',
  tryAnotherCard: 'Provare un’altra carta',
  tryAnotherReadMethod: 'Provare un altro metodo di lettura',
  checkMobileDevice: 'Controllare il telefono del cliente',
  cardRemovedTooEarly: 'Carta rimossa troppo presto',
};

function errorMessage(error: StripeError | Error | unknown): string {
  if (error && typeof error === 'object' && 'message' in error && typeof error.message === 'string') {
    return error.message;
  }
  return String(error);
}

function isCanceled(error: StripeError): boolean {
  return error.code === 'CANCELED';
}

export function PosProvider({ children }: { children: ReactNode }) {
  const [ready, setReady] = useState(false);
  const [initError, setInitError] = useState<string | null>(null);
  const [config, setConfig] = useState<PosConfig>(DEFAULT_CONFIG);
  const [configSource, setConfigSource] = useState<PosContextValue['configSource']>('default');
  const [offline, setOffline] = useState<OfflineSnapshot>(EMPTY_SNAPSHOT);
  const [ledger, setLedger] = useState<Ledger>([]);
  const [discovering, setDiscovering] = useState(false);
  const [readerMessage, setReaderMessage] = useState<string | null>(null);
  const [phase, setPhase] = useState<ChargePhase>('idle');

  // Callbacks from the SDK outlive renders, so they go through refs.
  const ledgerRef = useRef<Ledger>([]);
  const configRef = useRef(config);
  useEffect(() => {
    configRef.current = config;
  }, [config]);

  const mutateLedger = useCallback((fn: (current: Ledger) => Ledger) => {
    const next = fn(ledgerRef.current);
    ledgerRef.current = next;
    setLedger(next);
    saveLedger(next).catch((err) => console.warn('Failed to persist ledger', err));
  }, []);

  const {
    initialize,
    discoverReaders,
    cancelDiscovering,
    connectReader,
    disconnectReader,
    createPaymentIntent,
    collectPaymentMethod,
    confirmPaymentIntent,
    cancelCollectPaymentMethod,
    cancelPaymentIntent,
    getOfflineStatus,
    setSimulatedOfflineMode,
    connectedReader,
    discoveredReaders,
  } = useStripeTerminal({
    onDidChangeOfflineStatus: (status) => {
      setOffline(summarizeOfflineStatus(status, configRef.current.currency));
    },
    onDidForwardPaymentIntent: (paymentIntent: PaymentIntent.Type, error?: StripeError) => {
      const tx = findForwarded(ledgerRef.current, paymentIntent.metadata?.pos_tx_id, paymentIntent.sdkUuid);
      if (!tx) return;
      if (error) {
        mutateLedger((l) => updateTransaction(l, tx.id, { status: 'declined', error: errorMessage(error) }));
      } else if (paymentIntent.status === 'succeeded') {
        mutateLedger((l) => updateTransaction(l, tx.id, { status: 'succeeded', paymentIntentId: paymentIntent.id, error: undefined }));
      } else if (paymentIntent.status === 'requiresPaymentMethod' || paymentIntent.status === 'canceled') {
        mutateLedger((l) => updateTransaction(l, tx.id, { status: 'declined', paymentIntentId: paymentIntent.id }));
      } else {
        mutateLedger((l) => updateTransaction(l, tx.id, { paymentIntentId: paymentIntent.id }));
      }
    },
    onDidForwardingFailure: (error) => {
      console.warn('Offline payment forwarding failed', error);
    },
    onDidRequestReaderDisplayMessage: (message) => {
      setReaderMessage(DISPLAY_MESSAGES[message] ?? message);
    },
    onDidRequestReaderInput: () => {
      setReaderMessage('Avvicinare, inserire o strisciare la carta');
    },
    onFinishDiscoveringReaders: () => {
      setDiscovering(false);
    },
  });

  const refreshConfig = useCallback(async () => {
    try {
      const remote = await fetchRemoteConfig();
      const merged: PosConfig = { ...remote, locationId: remote.locationId ?? DEFAULT_CONFIG.locationId };
      setConfig(merged);
      setConfigSource('remote');
      await saveCachedConfig(merged);
    } catch (err) {
      console.warn('Using cached POS config:', errorMessage(err));
    }
  }, []);

  // Boot: restore local state first so the POS is usable without network,
  // then initialise the SDK and try to refresh the config.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const [storedLedger, cached] = await Promise.all([loadLedger(), loadCachedConfig()]);
      if (cancelled) return;
      ledgerRef.current = storedLedger;
      setLedger(storedLedger);
      if (cached) {
        setConfig(cached);
        setConfigSource('cache');
      }

      if (Platform.OS === 'android') {
        const { error } = await requestNeededAndroidPermissions({
          accessFineLocation: {
            title: 'Permesso posizione',
            message: 'Stripe Terminal richiede la posizione per accettare pagamenti con carta.',
            buttonPositive: 'Consenti',
          },
        });
        if (error) {
          setInitError('Permessi Android negati: i lettori di carte non saranno disponibili.');
        }
      }

      const { error } = await initialize();
      if (cancelled) return;
      if (error) setInitError(`Stripe Terminal non inizializzato: ${error.message}`);
      setReady(true);

      refreshConfig();
      try {
        const status = await getOfflineStatus();
        if (!cancelled) setOffline(summarizeOfflineStatus(status, (cached ?? DEFAULT_CONFIG).currency));
      } catch {
        // Status arrives through onDidChangeOfflineStatus as well.
      }
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const charge = useCallback(
    async (amount: number): Promise<ChargeResult> => {
      const { currency, offline: limits } = configRef.current;
      if (!connectedReader) return { ok: false, message: 'Nessun lettore collegato' };
      if (amount <= 0) return { ok: false, message: 'Importo non valido' };

      const decision = decideOffline(amount, offline, limits);
      if (!decision.allowed) {
        const message =
          decision.reason === 'over_transaction_limit'
            ? `Offline sono accettati importi fino a ${formatAmount(limits.maxTransactionAmount, currency)}`
            : `Limite di pagamenti offline in attesa raggiunto (${formatAmount(limits.maxStoredAmount, currency)})`;
        return { ok: false, message };
      }

      const now = new Date().toISOString();
      const txId = newTransactionId();
      mutateLedger((l) =>
        addTransaction(l, { id: txId, amount, currency, createdAt: now, updatedAt: now, status: 'pending' }),
      );
      const finish = (patch: Partial<PosTransaction>): PosTransaction => {
        mutateLedger((l) => updateTransaction(l, txId, patch));
        return ledgerRef.current.find((t) => t.id === txId)!;
      };

      try {
        setPhase('creating');
        const created = await createPaymentIntent({
          amount,
          currency,
          captureMethod: 'automatic',
          offlineBehavior: decision.offlineBehavior,
          metadata: { pos_tx_id: txId },
        });
        if (created.error) {
          const tx = finish({ status: 'failed', error: created.error.message });
          return { ok: false, tx, message: created.error.message };
        }

        setPhase('collecting');
        const collected = await collectPaymentMethod({ paymentIntent: created.paymentIntent });
        if (collected.error) {
          if (created.paymentIntent.id) {
            cancelPaymentIntent({ paymentIntent: created.paymentIntent }).catch(() => {});
          }
          const canceled = isCanceled(collected.error);
          const tx = finish({ status: canceled ? 'canceled' : 'failed', error: collected.error.message });
          return { ok: false, tx, message: canceled ? 'Pagamento annullato' : collected.error.message };
        }

        setPhase('confirming');
        const confirmed = await confirmPaymentIntent({ paymentIntent: collected.paymentIntent });
        if (confirmed.error) {
          const declined = confirmed.error.paymentIntent?.status === 'requiresPaymentMethod';
          const tx = finish({ status: declined ? 'declined' : 'failed', error: confirmed.error.message });
          return { ok: false, tx, message: confirmed.error.message };
        }

        const pi = confirmed.paymentIntent;
        const storedOffline = Boolean(pi.offlineDetails) || !pi.id;
        const card = pi.offlineDetails?.cardPresentDetails ?? pi.paymentMethod?.cardPresentDetails;
        const tx = finish({
          status: storedOffline ? 'stored_offline' : 'succeeded',
          paymentIntentId: pi.id || undefined,
          sdkUuid: pi.sdkUuid,
          cardBrand: card?.brand,
          last4: card?.last4,
          error: undefined,
        });
        return { ok: true, tx };
      } catch (err) {
        const tx = finish({ status: 'failed', error: errorMessage(err) });
        return { ok: false, tx, message: errorMessage(err) };
      } finally {
        setPhase('idle');
        setReaderMessage(null);
      }
    },
    [connectedReader, offline, mutateLedger, createPaymentIntent, collectPaymentMethod, confirmPaymentIntent, cancelPaymentIntent],
  );

  const cancelCharge = useCallback(async () => {
    await cancelCollectPaymentMethod();
  }, [cancelCollectPaymentMethod]);

  const discover = useCallback(
    async (method: DiscoveryMethod, simulated: boolean) => {
      setDiscovering(true);
      const { error } = await discoverReaders({ discoveryMethod: method, simulated });
      setDiscovering(false);
      return error && !isCanceled(error) ? error.message : null;
    },
    [discoverReaders],
  );

  const cancelDiscover = useCallback(async () => {
    await cancelDiscovering();
    setDiscovering(false);
  }, [cancelDiscovering]);

  const connect = useCallback(
    async (reader: Reader.Type, method: DiscoveryMethod) => {
      const locationId = reader.locationId ?? configRef.current.locationId;
      if (!locationId) return 'Location Stripe non configurata (STRIPE_LOCATION_ID sul server)';
      const { error } = await connectReader({
        discoveryMethod: method,
        reader,
        locationId,
        autoReconnectOnUnexpectedDisconnect: true,
      });
      return error ? error.message : null;
    },
    [connectReader],
  );

  const disconnect = useCallback(async () => {
    await disconnectReader();
  }, [disconnectReader]);

  const simulateOffline = useCallback(
    async (value: boolean) => {
      const { error } = await setSimulatedOfflineMode(value);
      return error ? error.message : null;
    },
    [setSimulatedOfflineMode],
  );

  const value = useMemo<PosContextValue>(
    () => ({
      ready,
      initError,
      config,
      configSource,
      offline,
      ledger,
      connectedReader,
      discoveredReaders,
      discovering,
      readerMessage,
      phase,
      charge,
      cancelCharge,
      discover,
      cancelDiscover,
      connect,
      disconnect,
      simulateOffline,
      refreshConfig,
    }),
    [
      ready, initError, config, configSource, offline, ledger, connectedReader, discoveredReaders, discovering,
      readerMessage, phase, charge, cancelCharge, discover, cancelDiscover, connect, disconnect, simulateOffline, refreshConfig,
    ],
  );

  return <PosContext.Provider value={value}>{children}</PosContext.Provider>;
}
