// Local, device-side record of every sale. It is the POS's own source of
// truth while offline and survives restarts (see storage.ts).

export type TxStatus =
  | 'pending' // payment started, outcome not known yet (e.g. app closed mid-payment)
  | 'succeeded' // authorised online by Stripe
  | 'stored_offline' // accepted offline, waiting to be forwarded
  | 'declined' // rejected when forwarded, or declined online
  | 'failed' // error before the card was charged
  | 'canceled'; // canceled by the operator or the customer

export type PosTransaction = {
  id: string;
  amount: number;
  currency: string;
  createdAt: string;
  updatedAt: string;
  status: TxStatus;
  paymentIntentId?: string;
  /** SDK-assigned id, the only id an offline payment has before forwarding. */
  sdkUuid?: string;
  cardBrand?: string;
  last4?: string;
  error?: string;
};

export type Ledger = PosTransaction[];

export function newTransactionId(now: number = Date.now()): string {
  return `tx_${now.toString(36)}_${Math.random().toString(36).slice(2, 10)}`;
}

export function addTransaction(ledger: Ledger, tx: PosTransaction): Ledger {
  return [tx, ...ledger.filter((t) => t.id !== tx.id)];
}

export function updateTransaction(
  ledger: Ledger,
  id: string,
  patch: Partial<Omit<PosTransaction, 'id'>>,
  now: string = new Date().toISOString(),
): Ledger {
  return ledger.map((t) => (t.id === id ? { ...t, ...patch, updatedAt: now } : t));
}

/**
 * Finds the local sale a forwarded payment belongs to: by the pos_tx_id we
 * put in the PaymentIntent metadata, falling back to the SDK uuid.
 */
export function findForwarded(ledger: Ledger, posTxId: string | undefined, sdkUuid: string | undefined) {
  return (
    (posTxId && ledger.find((t) => t.id === posTxId)) ||
    (sdkUuid && ledger.find((t) => t.sdkUuid === sdkUuid)) ||
    undefined
  );
}

export type LedgerSummary = {
  /** Sales that count as income: succeeded plus stored offline. */
  total: number;
  count: number;
  /** Portion of `total` still waiting to be forwarded to Stripe. */
  pendingForward: number;
  declined: number;
};

export function summarize(ledger: Ledger, currency: string, since?: Date): LedgerSummary {
  const summary: LedgerSummary = { total: 0, count: 0, pendingForward: 0, declined: 0 };
  for (const tx of ledger) {
    if (tx.currency !== currency) continue;
    if (since && new Date(tx.createdAt) < since) continue;
    if (tx.status === 'succeeded' || tx.status === 'stored_offline') {
      summary.total += tx.amount;
      summary.count += 1;
      if (tx.status === 'stored_offline') summary.pendingForward += tx.amount;
    } else if (tx.status === 'declined') {
      summary.declined += tx.amount;
    }
  }
  return summary;
}

export function startOfDay(date: Date = new Date()): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}
