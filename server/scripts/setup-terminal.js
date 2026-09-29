// One-off setup: creates a Stripe Terminal configuration with offline mode
// enabled and attaches it to the POS location (creating the location if needed).
//
//   STRIPE_SECRET_KEY=sk_... npm run setup:terminal
//
// Optional env: STRIPE_LOCATION_ID (reuse an existing location), and for a new
// location LOCATION_NAME, LOCATION_LINE1, LOCATION_CITY, LOCATION_POSTAL_CODE,
// LOCATION_STATE, LOCATION_COUNTRY (default IT).
import Stripe from 'stripe';

const env = process.env;
if (!env.STRIPE_SECRET_KEY) {
  console.error('STRIPE_SECRET_KEY is required');
  process.exit(1);
}
const stripe = new Stripe(env.STRIPE_SECRET_KEY);

const configuration = await stripe.terminal.configurations.create({
  name: 'Offline POS',
  offline: { enabled: true },
});
console.log(`Created configuration ${configuration.id} (offline enabled)`);

let location;
if (env.STRIPE_LOCATION_ID) {
  location = await stripe.terminal.locations.update(env.STRIPE_LOCATION_ID, {
    configuration_overrides: configuration.id,
  });
  console.log(`Attached configuration to existing location ${location.id}`);
} else {
  const address = {
    line1: env.LOCATION_LINE1,
    city: env.LOCATION_CITY,
    postal_code: env.LOCATION_POSTAL_CODE,
    state: env.LOCATION_STATE,
    country: env.LOCATION_COUNTRY || 'IT',
  };
  if (!address.line1 || !address.city || !address.postal_code) {
    console.error('Set LOCATION_LINE1, LOCATION_CITY and LOCATION_POSTAL_CODE to create a location, or pass STRIPE_LOCATION_ID.');
    process.exit(1);
  }
  location = await stripe.terminal.locations.create({
    display_name: env.LOCATION_NAME || 'Offline POS',
    address,
    configuration_overrides: configuration.id,
  });
  console.log(`Created location ${location.id}`);
}

console.log(`\nSet this on the server:\n  STRIPE_LOCATION_ID=${location.id}`);
