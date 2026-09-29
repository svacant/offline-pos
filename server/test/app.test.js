import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/app.js';
import { loadConfig } from '../src/config.js';

const silent = { info() {}, warn() {}, error() {} };
const events = [];

const fakeStripe = {
  terminal: {
    connectionTokens: {
      create: async () => ({ secret: 'pst_test_123' }),
    },
  },
  webhooks: {
    constructEvent(body, signature, secret) {
      if (signature !== `valid:${secret}`) throw new Error('bad signature');
      return JSON.parse(body.toString('utf8'));
    },
  },
};

const config = loadConfig({
  STRIPE_SECRET_KEY: 'sk_test_x',
  POS_API_KEY: 'device-key',
  STRIPE_WEBHOOK_SECRET: 'whsec_x',
  STRIPE_LOCATION_ID: 'tml_123',
  OFFLINE_MAX_TRANSACTION_AMOUNT: '5000',
});

let server;
let base;

before(async () => {
  const app = createApp({ config, stripe: fakeStripe, logger: silent, onPaymentEvent: (e) => events.push(e) });
  server = app.listen(0);
  await new Promise((resolve) => server.once('listening', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => server.close());

const auth = { authorization: 'Bearer device-key' };

test('health is public', async () => {
  const res = await fetch(`${base}/health`);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true });
});

test('connection token requires the device key', async () => {
  const denied = await fetch(`${base}/connection_token`, { method: 'POST' });
  assert.equal(denied.status, 401);

  const wrong = await fetch(`${base}/connection_token`, { method: 'POST', headers: { authorization: 'Bearer nope' } });
  assert.equal(wrong.status, 401);

  const ok = await fetch(`${base}/connection_token`, { method: 'POST', headers: auth });
  assert.equal(ok.status, 200);
  assert.deepEqual(await ok.json(), { secret: 'pst_test_123' });
});

test('config exposes location, currency and offline limits', async () => {
  const res = await fetch(`${base}/config`, { headers: auth });
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), {
    locationId: 'tml_123',
    currency: 'eur',
    offline: { maxTransactionAmount: 5000, maxStoredAmount: 100000 },
  });
});

test('webhook rejects bad signatures and forwards payment events', async () => {
  const body = JSON.stringify({
    type: 'payment_intent.payment_failed',
    data: { object: { id: 'pi_1', amount: 1200, currency: 'eur', metadata: { pos_tx_id: 'tx_1' } } },
  });

  const bad = await fetch(`${base}/webhook`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'stripe-signature': 'forged' },
    body,
  });
  assert.equal(bad.status, 400);

  const good = await fetch(`${base}/webhook`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'stripe-signature': 'valid:whsec_x' },
    body,
  });
  assert.equal(good.status, 200);
  assert.equal(events.length, 1);
  assert.equal(events[0].data.object.metadata.pos_tx_id, 'tx_1');
});

test('loadConfig validates required variables and amounts', () => {
  assert.throws(() => loadConfig({}), /STRIPE_SECRET_KEY, POS_API_KEY/);
  assert.throws(
    () => loadConfig({ STRIPE_SECRET_KEY: 'x', POS_API_KEY: 'y', OFFLINE_MAX_STORED_AMOUNT: '-1' }),
    /OFFLINE_MAX_STORED_AMOUNT/,
  );
});
