# Offline POS

POS offline-first in **Flutter** con pinpad per l'importo e pagamenti con carta tramite **Stripe Terminal in modalità offline**. Tutto gira in **sandbox** (Stripe test mode, lettore simulato).

```
app/         App Flutter (Android) + bridge nativo Kotlin verso l'SDK Stripe Terminal
server/      Backend Node: connection token, configurazione POS, webhook
render.yaml  Blueprint Render per il deploy del backend
```

## Perché un bridge nativo

Nessun plugin Flutter supporta la modalità offline di Stripe Terminal (`mek_stripe_terminal`, il più aggiornato, lo dichiara esplicitamente). L'app usa quindi direttamente l'**SDK ufficiale Stripe Terminal Android 5.8.1** tramite un bridge Kotlin (`app/android/app/src/main/kotlin/com/svacant/offline_pos/StripeTerminalBridge.kt`) esposto a Dart con un `MethodChannel` e un `EventChannel` (`app/lib/src/terminal_bridge.dart`).

Solo Android per ora: per iOS andrebbe scritto l'equivalente Swift sull'SDK iOS.

## Come funziona

- **Pinpad**: l'importo si digita come su un registratore di cassa (`1`, `2`, `5` → 1,25 €), con `00`, cancella cifra e reset (pressione lunga su ⌫). Gli importi sono interi in centesimi, mai float.
- **Pagamento**: il bridge crea il PaymentIntent con `OfflineBehavior.PREFER_ONLINE`, poi collect e confirm. Con rete va online su Stripe; senza rete l'SDK salva il pagamento cifrato sul dispositivo e lo **inoltra da solo** quando torna la connessione.
- **Limiti di rischio offline**: un pagamento offline viene autorizzato solo quando è inoltrato, quindi può essere rifiutato più tardi. Da offline il POS rifiuta gli importi sopra `OFFLINE_MAX_TRANSACTION_AMOUNT` e smette di accettare carte quando il totale in attesa supera `OFFLINE_MAX_STORED_AMOUNT` (configurati sul server).
- **Registro locale**: ogni vendita è salvata sul dispositivo (`shared_preferences`) con stato `Riuscito`, `Offline, da inoltrare`, `Rifiutato`, `Annullato`, `Errore`. Quando l'SDK inoltra un pagamento (`OfflineListener.onPaymentIntentForwarded`) la voce viene aggiornata tramite `metadata.pos_tx_id`. La schermata Transazioni mostra il totale del giorno e quanto resta da inoltrare.
- **Config in cache**: location, valuta e limiti arrivano da `GET /config` e restano sul dispositivo, così l'app parte anche senza rete.
- **Sandbox**: il server rifiuta le chiavi live (`sk_live_…`) a meno di `ALLOW_LIVE_MODE=true`; l'app mostra il badge **SANDBOX** e usa il lettore simulato di default, con l'interruttore **Simula rete offline** (`SimulatedOfflineModeConfiguration` dell'SDK).

## Deploy (sandbox)

### 1. Stripe test mode: location con offline abilitato

Usa la chiave segreta **di test** dalla dashboard Stripe (Sviluppatori → Chiavi API, con "Modalità test" attiva).

```bash
cd server
npm ci
STRIPE_SECRET_KEY=sk_test_... \
LOCATION_NAME="Negozio" LOCATION_LINE1="Via Roma 1" LOCATION_CITY="Milano" LOCATION_POSTAL_CODE="20100" \
npm run setup:terminal
```

Crea una Terminal Configuration con `offline.enabled = true` e la assegna a una nuova location (o a una esistente con `STRIPE_LOCATION_ID`). Stampa lo `STRIPE_LOCATION_ID`.

### 2. Backend su Render

1. [Render](https://render.com) → **New → Blueprint** → questo repository (legge `render.yaml`).
2. Inserisci `STRIPE_SECRET_KEY` (test), `STRIPE_LOCATION_ID` e, dopo il punto 3, `STRIPE_WEBHOOK_SECRET`. `POS_API_KEY` la genera Render: copiala per l'app.
3. Dashboard Stripe (test mode) → **Webhooks** → endpoint `https://<servizio>.onrender.com/webhook` con `payment_intent.succeeded`, `payment_intent.payment_failed`, `payment_intent.canceled`; copia il signing secret in `STRIPE_WEBHOOK_SECRET`.

Il server è un container qualsiasi (`server/Dockerfile`): va bene anche Fly.io, Railway, Cloud Run. Variabili in `server/.env.example`.

| Endpoint | Auth | Descrizione |
| --- | --- | --- |
| `GET /health` | — | health check |
| `GET /config` | Bearer `POS_API_KEY` | sandbox/live, location, valuta, limiti offline |
| `POST /connection_token` | Bearer `POS_API_KEY` | connection token Stripe Terminal |
| `POST /webhook` | firma Stripe | esiti dei pagamenti (inclusi quelli offline inoltrati) |

### 3. APK Android

**Da GitHub Actions**: nel repository imposta la variabile `POS_BACKEND_URL` (e opzionalmente `STRIPE_LOCATION_ID`) e il secret `POS_API_KEY`. Il workflow **CI** compila l'APK e lo pubblica come artifact `offline-pos-apk`.

**In locale** (Flutter 3.47, Android SDK, JDK 17):

```bash
cd app
flutter build apk --release \
  --dart-define=POS_BACKEND_URL=https://<servizio>.onrender.com \
  --dart-define=POS_API_KEY=<POS_API_KEY>
```

`minSdk` è 26 (requisito dell'SDK Stripe). L'`applicationId` è `com.svacant.offline_pos`; la build release è firmata con la chiave di debug, sufficiente per la sandbox.

## Prova in sandbox

1. Tab **Lettore** → lascia attivo **Lettore simulato** → Cerca lettori → Collega (con rete: il primo collegamento a una location deve avvenire online).
2. Tab **Cassa** → digita l'importo → **Incassa**: il lettore simulato paga con una carta di test.
3. Torna su **Lettore** → attiva **Simula rete offline** → incassa di nuovo: la vendita risulta "Offline, da inoltrare" e il banner mostra i pagamenti in attesa.
4. Disattiva la simulazione: l'SDK inoltra i pagamenti e il registro passa a "Riuscito" (o "Rifiutato").

Per un lettore fisico (Stripe M2, BBPOS WisePad 3) disattiva "Lettore simulato". Condizioni aggiornate sui pagamenti offline: <https://docs.stripe.com/terminal/features/operate-offline/overview>.

## Sviluppo

```bash
cd server && npm test
cd app && flutter analyze && flutter test
```

Logica pura e testata in `app/lib/src/`: `money.dart` (pinpad e formattazione), `offline_policy.dart` (stato offline e limiti), `ledger.dart` (registro vendite), `pos_controller.dart` (flusso di pagamento, testato con un terminale finto in `app/test/fakes.dart`).

## Sicurezza

`POS_API_KEY` finisce nell'APK: protegge il backend da accessi casuali, non da chi ha in mano un dispositivo. Con la chiave si ottengono solo connection token, cioè si incassa sul tuo account. Se un dispositivo esce dal tuo controllo, ruota la chiave su Render e ricompila.
