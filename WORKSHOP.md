# Workshop: POS offline-first con Flutter e Stripe Terminal

Guida per chi partecipa. L'obiettivo non è solo far funzionare il POS, ma capire **perché** è fatto così: come si incassa con una carta fisica, cosa succede quando cade la rete e come si scrive codice di pagamento che si può testare.

Tutto gira in **sandbox**: chiavi Stripe di test, lettore simulato, nessun soldo vero.

## Cosa impari

1. Il flusso di un pagamento con carta presente: **create → collect → confirm**.
2. Come Stripe Terminal incassa **offline** (*store and forward*) e quali rischi comporta.
3. Come Flutter parla con codice nativo Android (**MethodChannel** ed **EventChannel**).
4. Come separare la logica dalla UI e dall'hardware per poterla **testare senza lettore**.

## Prerequisiti

- Flutter 3.47 e un dispositivo o emulatore Android (API 26+). Il lettore simulato funziona anche sull'emulatore.
- Un account Stripe in **modalità test**.
- Il backend avviato (vedi README): serve per i *connection token*.

## L'architettura in una figura

```
┌───────────────────────── App Flutter (Dart) ─────────────────────────┐
│                                                                       │
│  ui/ (schermate)  ──usa──▶  PosController  ──▶  PosPersistence        │
│   checkout, history,        (pos_controller.dart)   (storage.dart)    │
│   reader                         │                                    │
│                                  ▼                                    │
│                        TerminalApi (interfaccia)                      │
│                                  │                                    │
│                     MethodChannelTerminal (terminal_bridge.dart)      │
└──────────────────────────────────┼────────────────────────────────────┘
               MethodChannel "offline_pos/terminal"   ▲ EventChannel
                                   ▼                  │ ".../events"
┌──────────────────────── Android (Kotlin) ───────────┴────────────────┐
│               StripeTerminalBridge.kt                                 │
│                                  │                                    │
│               SDK ufficiale Stripe Terminal Android                   │
└──────────────────────────────────┼────────────────────────────────────┘
                     Bluetooth/USB ▼            ▲ HTTPS (quando c'è rete)
                     Lettore di carte           Stripe API
                                                  ▲
       server/ (Node) ── connection token, config, webhook ──┘
```

Una regola tiene tutto insieme: **la UI parla solo con `PosController`**, e `PosController` parla con il lettore solo attraverso l'interfaccia `TerminalApi`. Nei test al posto del lettore vero c'è `FakeTerminal` (`app/test/fakes.dart`).

## Percorso di lettura del codice

Leggi i file in quest'ordine: ogni passo usa il precedente.

| # | File | Cosa guardare |
|---|------|---------------|
| 1 | `app/lib/src/money.dart` | Importi come **interi in centesimi**, mai `double`. Il pinpad "da registratore di cassa". |
| 2 | `app/lib/src/offline_policy.dart` | Quando accettare un pagamento offline: limite per singolo pagamento e limite sul totale in attesa. |
| 3 | `app/lib/src/ledger.dart` | Il registro locale delle vendite e gli stati di una vendita. |
| 4 | `app/lib/src/terminal_bridge.dart` | Il contratto con il lato nativo: metodi, eventi, errori. |
| 5 | `app/lib/src/pos_controller.dart` | Il cuore: `charge()` e la riconciliazione in `_onForwarded()`. |
| 6 | `app/android/.../StripeTerminalBridge.kt` | Le chiamate reali all'SDK: `collectPayment()` e i listener offline. |
| 7 | `server/src/app.js` | Perché serve un backend anche se l'app incassa offline. |
| 8 | `app/test/pos_controller_test.dart` | Come si testa un flusso di pagamento senza hardware. |

## Concetti chiave

### 1. Soldi in centesimi

`12,50 €` è `1250`. Stripe vuole gli importi nell'unità più piccola della valuta, e con i `double` `0.1 + 0.2` non fa `0.3`. Per le valute senza decimali (JPY) l'unità è già quella intera: vedi `minorUnitDigits()`.

### 2. Connection token

L'app non contiene la chiave segreta Stripe: la chiede al **backend** sotto forma di *connection token* a breve scadenza (`POST /connection_token`). La chiave segreta resta solo sul server.

### 3. create → collect → confirm

In `StripeTerminalBridge.collectPayment()`:

1. **create**: si crea il PaymentIntent (importo, valuta, `metadata.pos_tx_id`).
2. **collect**: il lettore aspetta la carta; si può annullare (`cancelCollect`).
3. **confirm**: la carta viene autorizzata.

Se un passo fallisce dopo il create, il PaymentIntent viene annullato (`cancelQuietly`) per non lasciarlo aperto su Stripe.

### 4. Offline: *store and forward*

Con `OfflineBehavior.PREFER_ONLINE`:

- **con rete** il pagamento va subito su Stripe;
- **senza rete** l'SDK cifra e salva il pagamento sul dispositivo; la vendita risulta `storedOffline`;
- quando la rete torna, l'SDK lo **inoltra da solo** e chiama `onPaymentIntentForwarded`. L'app ritrova la vendita tramite `metadata.pos_tx_id` e la aggiorna a `succeeded` o `declined`.

⚠️ **Il rischio**: offline la carta non viene autorizzata dalla banca, quindi il pagamento può essere **rifiutato ore dopo**, quando il cliente è già uscito con la merce. Per questo `checkOfflineLimits()` pone due tetti, decisi dal server: importo massimo per pagamento e totale massimo in attesa.

Per l'offline Stripe richiede anche che il lettore si sia collegato **almeno una volta online** a quella location.

### 5. Thread e canali

Le callback dell'SDK arrivano su thread in background, ma i canali Flutter si usano solo sul **main thread**. Per questo ogni risposta passa da `main.post { ... }` (vedi `MainThreadResult`). Un altro dettaglio: `Terminal.init` si esegue una volta per processo, mentre l'Activity può essere ricreata. Per questo i listener dati all'SDK stanno nel `companion object` e inoltrano al bridge attivo in quel momento.

### 6. Testabilità

`PosController` riceve nel costruttore le sue dipendenze: terminale, storage e funzioni verso il backend. `main.dart` passa quelle vere, i test quelle finte. Così `pos_controller_test.dart` prova pagamento online, offline, inoltro, rifiuto e limiti in pochi millisecondi, senza lettore.

## Esercizi

Dal più semplice al più impegnativo. Per ognuno scrivi prima un test.

1. **Tasto "+"**: permetti di sommare più importi (più articoli) prima di incassare. *Dove*: `money.dart`, `pin_pad.dart`, `checkout_screen.dart`.
2. **Dettaglio vendita**: toccando una riga in Transazioni, mostra id PaymentIntent, stato, carta ed errore. *Dove*: `history_screen.dart`.
3. **Vendite "Da verificare"**: se l'app si chiude durante un pagamento, la vendita resta `pending`. Al riavvio mostrale in evidenza e aggiungi un'azione per marcarle come verificate a mano. *Dove*: `pos_controller.dart` (`start`).
4. **Limiti offline più sicuri**: oggi il limite sul totale usa il conteggio dell'SDK. Confrontalo con la somma delle vendite `storedOffline` nel registro e usa il valore più alto. Scrivi il test che dimostra perché serve.
5. **Webhook utile**: in `server/src/app.js` salva gli eventi `payment_intent.payment_failed` e aggiungi un endpoint `GET /declined` che la app può mostrare.
6. **Avanzato: iOS**. Scrivi il bridge Swift sull'SDK Stripe Terminal iOS che rispetti lo stesso contratto di `terminal_bridge.dart`. Il codice Dart non deve cambiare.

## Da non copiare in produzione

Questo progetto è pensato per imparare in sandbox. Prima di usarlo con soldi veri:

- **`POS_API_KEY` dentro l'APK**: chiunque abbia il dispositivo può estrarla. In produzione serve un'autenticazione per dispositivo o per operatore.
- **Firma di debug**: la build release è firmata con la chiave di debug. Serve un keystore vero.
- **Registro su `shared_preferences`**: comodo per imparare, ma non è un database. Per molte vendite usa SQLite (per esempio `sqflite` o `drift`).
- **Nessun login operatore** e nessuna chiusura cassa.
- **`ALLOW_LIVE_MODE`**: il server rifiuta le chiavi live apposta. Non attivarlo finché i punti sopra non sono risolti.

## Problemi comuni

| Sintomo | Causa probabile |
|---|---|
| "Location Stripe non configurata" | Manca `STRIPE_LOCATION_ID` sul server, oppure l'app non ha mai raggiunto il backend. |
| Offline il lettore non si collega | Non si è mai collegato online a quella location, o la location non ha la configurazione con `offline.enabled`. Rilancia `npm run setup:terminal`. |
| "Simula rete offline" non fa nulla | Funziona solo con il **lettore simulato**. |
| "Stripe Terminal non disponibile su questa piattaforma" | Stai eseguendo su iOS, web o desktop: il bridge esiste solo su Android. |
| Nessun lettore trovato | Permessi di posizione o Bluetooth negati: abilitali nelle impostazioni di Android. |
| Il server non parte: "live key" | Stai usando `sk_live_…`: usa la chiave di test `sk_test_…`. |

Documentazione Stripe sull'offline: <https://docs.stripe.com/terminal/features/operate-offline/overview>
