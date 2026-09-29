import Stripe from 'stripe';
import { createApp } from './app.js';
import { loadConfig } from './config.js';

const config = loadConfig();
const stripe = new Stripe(config.stripeSecretKey);
const app = createApp({ config, stripe });

app.listen(config.port, () => {
  console.log(`offline-pos server listening on :${config.port} (${config.livemode ? 'LIVE' : 'sandbox / test mode'})`);
  if (!config.locationId) {
    console.warn('STRIPE_LOCATION_ID is not set: run `npm run setup:terminal` and set it before connecting readers.');
  }
  if (!config.webhookSecret) {
    console.warn('STRIPE_WEBHOOK_SECRET is not set: /webhook will reject events.');
  }
});
