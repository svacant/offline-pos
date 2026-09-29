# Offline POS

POS offline-first con pinpad per l'importo e pagamenti con carta tramite **Stripe Terminal in modalità offline**.

```
app/      App mobile Expo / React Native (Android e iOS)
server/   Backend Node: connection token Stripe, configurazione POS, webhook
render.yaml  Blueprint Render per il deploy del backend
```

## Come funziona

- **Pinpad**: l'importo si digita come su un registratore di cassa (`1`, `2`, `5` → 1,25 €), con `00`, cancella cifra e reset (pressione lunga su ⌫). Gli importi sono interi in centesimi, mai float.
- **Pagamento**: ogni PaymentIntent è creato dall'SDK con `offlineBehavior: 'prefer_online'`. Con rete va online su Stripe; senza rete l'SDK salva il pagamento cifrato sul dispositivo e lo **inoltra da solo** quando torna la connessione.
- **Limiti di rischio offline**: un pagamento offline viene autorizzato solo quando è inoltrato, quindi può essere rifiutato più tardi. Il POS blocca da offline gli importi sopra `OFFLINE_MAX_TRANSACTION_AMOUNT` e smette di accettare carte offline quando il totale in attesa supera `OFFLINE_MAX_STORED_AMOUNT` (entrambi configurati sul server).
- **Registro locale**: ogni vendita è salvata sul dispositivo (AsyncStorage) con stato `Riuscito`, `Offline, da inoltrare`, `Rifiutato`, `Annullato`, `Errore`. Quando l'SDK inoltra un pagamento (`onDidForwardPaymentIntent`) la voce viene aggiornata, abbinandola tramite `metadata.pos_tx_id`. La schermata Transazioni mostra il totale del giorno e quanto è ancora da inoltrare.
- **Config in cache**: location, valuta e limiti arrivano da `GET /config` e vengono salvati sul dispositivo, così l'app parte anche senza rete.

La modalità offline richiede l'SDK nativo: per questo l'app è React Native e non web (l'SDK JavaScript di Stripe Terminal non supporta l'offline). Lettori supportati dall'app: Bluetooth (Stripe M2, BBPOS WisePad 3) e USB su Android. Tap to Pay non supporta i pagamenti offline.

## Deploy

### 1. Stripe: location con modalità offline

```bash
cd server
npm ci
STRIPE_SECRET_KEY=sk_test_... \
LOCATION_NAME="Negozio" LOCATION_LINE1="Via Roma 1" LOCATION_CITY="Milano" LOCATION_POSTAL_CODE="20100" \
npm run setup:terminal
```

Crea una Terminal Configuration con `offline.enabled = true` e la assegna a una nuova location (oppure a una esistente passando `STRIPE_LOCATION_ID`). Stampa lo `STRIPE_LOCATION_ID` da usare sul server.

### 2. Backend su Render

1. Su [Render](https://render.com) → **New → Blueprint** → seleziona questo repository: viene letto `render.yaml`.
2. Inserisci `STRIPE_SECRET_KEY`, `STRIPE_LOCATION_ID` e (dopo il passo 3) `STRIPE_WEBHOOK_SECRET`. `POS_API_KEY` viene generata da Render: copiala, serve all'app.
3. Nella dashboard Stripe → **Developers → Webhooks** aggiungi `https://<tuo-servizio>.onrender.com/webhook` con gli eventi `payment_intent.succeeded`, `payment_intent.payment_failed`, `payment_intent.canceled`, e copia il signing secret in `STRIPE_WEBHOOK_SECRET`.

Il server è un normale container (`server/Dockerfile`), quindi va bene anche Fly.io, Railway, Cloud Run, ecc. Variabili in `server/.env.example`.

| Endpoint | Auth | Descrizione |
| --- | --- | --- |
| `GET /health` | — | health check |
| `GET /config` | Bearer `POS_API_KEY` | location, valuta, limiti offline |
| `POST /connection_token` | Bearer `POS_API_KEY` | connection token Stripe Terminal |
| `POST /webhook` | firma Stripe | esiti dei pagamenti (inclusi quelli offline inoltrati) |

### 3. App con EAS Build

```bash
cd app
npm ci
npx eas-cli@latest login
npx eas-cli@latest init            # collega il progetto al tuo account Expo
npx eas-cli@latest build --profile preview --platform android   # APK installabile
```

Prima della build imposta le variabili dell'app (vedi `app/.env.example`) su expo.dev → progetto → **Environment variables**, per gli ambienti `preview` e `production`:
`EXPO_PUBLIC_POS_BACKEND_URL=https://<tuo-servizio>.onrender.com` e `EXPO_PUBLIC_POS_API_KEY=<POS_API_KEY>`.

In alternativa: aggiungi il secret `EXPO_TOKEN` al repository e lancia il workflow **EAS build** da GitHub Actions. Per iOS servono un account Apple Developer e l'entitlement Bluetooth; `bundleIdentifier`/`package` sono in `app/app.json` (`com.svacant.offlinepos`, cambiali se serve).

L'app **non** gira in Expo Go (contiene codice nativo): per lo sviluppo usa una development build (`eas build --profile development` oppure `npx expo run:android`).

## Prima messa in servizio del lettore

1. Con rete attiva: tab **Lettore** → Cerca lettori → Collega. Il primo collegamento deve avvenire **online** sulla location configurata: l'SDK scarica configurazione e chiavi che servono per l'offline.
2. Da quel momento, se cade la rete, l'SDK può ricollegare lo stesso lettore e accettare carte offline. Tieni l'app aperta e collegata finché i pagamenti in attesa non sono stati inoltrati (il banner ne mostra numero e importo).
3. Per provare senza hardware: attiva **Lettore simulato**, collega il lettore simulato e usa **Simula rete offline**.

Consulta la guida Stripe sui pagamenti offline per le condizioni aggiornate (durata massima di conservazione, carte e paesi supportati): <https://docs.stripe.com/terminal/features/operate-offline/overview>.

## Sviluppo

```bash
cd server && npm test                                   # test del backend
cd app && npm run typecheck && npm run lint && npm test # typecheck, lint e test della logica POS
```

Logica pura e testata in `app/src/lib/`: `amount.ts` (pinpad e formattazione), `offline.ts` (stato offline e limiti), `ledger.ts` (registro vendite). L'integrazione con l'SDK è in `app/src/pos/PosProvider.tsx`.

## Sicurezza

`EXPO_PUBLIC_POS_API_KEY` finisce nel bundle dell'app: protegge il backend da accessi casuali, non da chi ha in mano un dispositivo. Con questa chiave si possono solo ottenere connection token, cioè incassare sul tuo account. Se i dispositivi escono dal tuo controllo, ruota la chiave su Render e ricompila l'app.
