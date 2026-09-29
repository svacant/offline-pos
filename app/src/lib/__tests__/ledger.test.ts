import { addTransaction, findForwarded, summarize, updateTransaction, type PosTransaction } from '../ledger';

const tx = (over: Partial<PosTransaction>): PosTransaction => ({
  id: 'tx',
  amount: 1000,
  currency: 'eur',
  createdAt: '2026-09-29T10:00:00.000Z',
  updatedAt: '2026-09-29T10:00:00.000Z',
  status: 'succeeded',
  ...over,
});

describe('ledger', () => {
  it('adds newest first and updates in place', () => {
    let ledger = addTransaction([], tx({ id: 'a' }));
    ledger = addTransaction(ledger, tx({ id: 'b', status: 'pending' }));
    expect(ledger.map((t) => t.id)).toEqual(['b', 'a']);

    ledger = updateTransaction(ledger, 'b', { status: 'stored_offline', sdkUuid: 'uuid-b' }, 'later');
    expect(ledger[0]).toMatchObject({ id: 'b', status: 'stored_offline', sdkUuid: 'uuid-b', updatedAt: 'later' });
    expect(ledger[1].updatedAt).toBe('2026-09-29T10:00:00.000Z');
  });

  it('matches forwarded payments by metadata, then by sdk uuid', () => {
    const ledger = [tx({ id: 'a', sdkUuid: 'u1' }), tx({ id: 'b', sdkUuid: 'u2' })];
    expect(findForwarded(ledger, 'b', 'u1')?.id).toBe('b');
    expect(findForwarded(ledger, undefined, 'u1')?.id).toBe('a');
    expect(findForwarded(ledger, 'missing', 'missing')).toBeUndefined();
  });

  it('summarizes income, pending forwards and declines', () => {
    const ledger = [
      tx({ id: '1', amount: 1000, status: 'succeeded' }),
      tx({ id: '2', amount: 500, status: 'stored_offline' }),
      tx({ id: '3', amount: 700, status: 'declined' }),
      tx({ id: '4', amount: 900, status: 'canceled' }),
      tx({ id: '5', amount: 800, status: 'succeeded', currency: 'usd' }),
      tx({ id: '6', amount: 300, status: 'succeeded', createdAt: '2026-09-28T10:00:00.000Z' }),
    ];
    expect(summarize(ledger, 'eur', new Date('2026-09-29T00:00:00.000Z'))).toEqual({
      total: 1500,
      count: 2,
      pendingForward: 500,
      declined: 700,
    });
  });
});
