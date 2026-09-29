import { timingSafeEqual } from 'node:crypto';
import express from 'express';

function safeEqual(a, b) {
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  return left.length === right.length && timingSafeEqual(left, right);
}

/**
 * Builds the HTTP app. `stripe` is injected so tests can pass a fake client.
 * `onPaymentEvent` receives the webhook events relevant to the POS ledger.
 */
export function createApp({ config, stripe, logger = console, onPaymentEvent = () => {} }) {
  const app = express();
  app.disable('x-powered-by');

  const requireDevice = (req, res, next) => {
    const header = req.get('authorization') || '';
    const token = header.startsWith('Bearer ') ? header.slice('Bearer '.length) : '';
    if (!token || !safeEqual(token, config.posApiKey)) {
      return res.status(401).json({ error: 'unauthorized' });
    }
    next();
  };

  app.get('/health', (_req, res) => {
    res.json({ ok: true });
  });

  // Webhooks need the raw body for signature verification, so this route is
  // registered before the JSON parser.
  app.post('/webhook', express.raw({ type: 'application/json' }), (req, res) => {
    if (!config.webhookSecret) {
      return res.status(503).json({ error: 'webhook secret not configured' });
    }
    let event;
    try {
      event = stripe.webhooks.constructEvent(req.body, req.get('stripe-signature'), config.webhookSecret);
    } catch (err) {
      logger.warn(`Webhook signature verification failed: ${err.message}`);
      return res.status(400).json({ error: 'invalid signature' });
    }

    switch (event.type) {
      case 'payment_intent.succeeded':
      case 'payment_intent.payment_failed':
      case 'payment_intent.canceled': {
        const pi = event.data.object;
        // Offline payments are authorised only when the device forwards them,
        // so a decline shows up here as payment_intent.payment_failed.
        logger.info(`[webhook] ${event.type} ${pi.id} ${pi.amount} ${pi.currency} pos_tx=${pi.metadata?.pos_tx_id ?? '-'}`);
        onPaymentEvent(event);
        break;
      }
      default:
        break;
    }
    res.json({ received: true });
  });

  app.use(express.json());

  app.get('/config', requireDevice, (_req, res) => {
    res.json({
      locationId: config.locationId,
      currency: config.currency,
      offline: config.offline,
    });
  });

  app.post('/connection_token', requireDevice, async (_req, res) => {
    try {
      const token = await stripe.terminal.connectionTokens.create();
      res.json({ secret: token.secret });
    } catch (err) {
      logger.error(`Failed to create connection token: ${err.message}`);
      res.status(502).json({ error: 'connection token unavailable' });
    }
  });

  app.use((_req, res) => {
    res.status(404).json({ error: 'not found' });
  });

  return app;
}
