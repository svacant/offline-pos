package com.svacant.offline_pos

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.stripe.stripeterminal.Terminal
import com.stripe.stripeterminal.external.callable.Callback
import com.stripe.stripeterminal.external.callable.Cancelable
import com.stripe.stripeterminal.external.callable.ConnectionTokenCallback
import com.stripe.stripeterminal.external.callable.ConnectionTokenProvider
import com.stripe.stripeterminal.external.callable.DiscoveryListener
import com.stripe.stripeterminal.external.callable.MobileReaderListener
import com.stripe.stripeterminal.external.callable.OfflineListener
import com.stripe.stripeterminal.external.callable.PaymentIntentCallback
import com.stripe.stripeterminal.external.callable.ReaderCallback
import com.stripe.stripeterminal.external.callable.TerminalListener
import com.stripe.stripeterminal.external.models.CaptureMethod
import com.stripe.stripeterminal.external.models.ConnectionConfiguration
import com.stripe.stripeterminal.external.models.ConnectionStatus
import com.stripe.stripeterminal.external.models.ConnectionTokenException
import com.stripe.stripeterminal.external.models.CreateConfiguration
import com.stripe.stripeterminal.external.models.DisconnectReason
import com.stripe.stripeterminal.external.models.DiscoveryConfiguration
import com.stripe.stripeterminal.external.models.LocaleConfig
import com.stripe.stripeterminal.external.models.OfflineBehavior
import com.stripe.stripeterminal.external.models.OfflineStatus
import com.stripe.stripeterminal.external.models.OfflineStatusDetails
import com.stripe.stripeterminal.external.models.PaymentIntent
import com.stripe.stripeterminal.external.models.PaymentIntentParameters
import com.stripe.stripeterminal.external.models.Reader
import com.stripe.stripeterminal.external.models.ReaderDisplayMessage
import com.stripe.stripeterminal.external.models.ReaderInputOptions
import com.stripe.stripeterminal.external.models.SimulatedOfflineMode
import com.stripe.stripeterminal.external.models.SimulatedOfflineModeConfiguration
import com.stripe.stripeterminal.external.models.TerminalErrorCode
import com.stripe.stripeterminal.external.models.TerminalException
import com.stripe.stripeterminal.log.LogLevel
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges the official Stripe Terminal Android SDK to Flutter
 * (lib/src/terminal_bridge.dart). No Flutter plugin supports Terminal's
 * offline mode, so the payment flow lives here.
 *
 * Two channels connect the worlds:
 * - `offline_pos/terminal` (MethodChannel): Dart calls native methods and
 *   awaits a single reply. Native also calls Dart on it to ask for a
 *   connection token.
 * - `offline_pos/terminal/events` (EventChannel): a stream of events the SDK
 *   produces on its own (offline status, forwarded payments, readers found,
 *   prompts for the cardholder).
 *
 * Two Android rules shape the code:
 * 1. SDK callbacks run on background threads, but Flutter channels must be
 *    used on the main thread: every reply and event goes through [main].
 * 2. `Terminal.init` runs once per process, while the Activity (and this
 *    bridge) can be recreated. The listeners given to the SDK therefore live
 *    in the companion object and forward to the bridge that is alive now.
 */
class StripeTerminalBridge(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val methods = MethodChannel(messenger, "offline_pos/terminal")
    private val events = EventChannel(messenger, "offline_pos/terminal/events")
    private val main = Handler(Looper.getMainLooper())

    private var sink: EventChannel.EventSink? = null

    // Written from SDK callback threads and read on the main thread:
    // @Volatile makes every write visible to the other thread.
    @Volatile private var discoveredReaders: List<Reader> = emptyList()
    @Volatile private var discoveryTask: Cancelable? = null
    @Volatile private var collectTask: Cancelable? = null

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        current = this
    }

    /** Called when the Flutter engine goes away (see MainActivity). */
    fun detach() {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        if (current === this) current = null
    }

    // --- EventChannel ----------------------------------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(event: Map<String, Any?>) {
        main.post { sink?.success(event) }
    }

    // --- MethodChannel: Dart -> native -----------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val reply = MainThreadResult(result, main)
        try {
            when (call.method) {
                "initialize" -> initialize(reply)
                "discoverReaders" -> discoverReaders(
                    call.argument<String>("link") ?: "bluetooth",
                    call.argument<Boolean>("simulated") ?: false,
                    reply,
                )
                "cancelDiscovery" -> cancel(discoveryTask, reply)
                "connectReader" -> connectReader(
                    call.argument<String>("serialNumber")!!,
                    call.argument<String>("locationId")!!,
                    call.argument<String>("link") ?: "bluetooth",
                    reply,
                )
                "disconnectReader" -> Terminal.getInstance().disconnectReader(object : Callback {
                    override fun onSuccess() = reply.success(null)
                    override fun onFailure(e: TerminalException) = reply.error(e)
                })
                "collectPayment" -> collectPayment(
                    call.argument<Number>("amount")!!.toLong(),
                    call.argument<String>("currency")!!,
                    call.argument<String>("posTxId")!!,
                    reply,
                )
                "cancelCollect" -> cancel(collectTask, reply)
                "setSimulatedOffline" -> {
                    // Only affects simulated readers in test mode.
                    val mode = if (call.argument<Boolean>("offline") == true) {
                        SimulatedOfflineMode.OFFLINE_IMMEDIATE
                    } else {
                        SimulatedOfflineMode.DISABLED
                    }
                    Terminal.getInstance().simulatedOfflineModeConfiguration =
                        SimulatedOfflineModeConfiguration(mode, mode)
                    reply.success(null)
                }
                else -> reply.notImplemented()
            }
        } catch (e: TerminalException) {
            reply.error(e)
        } catch (e: Exception) {
            reply.error("BRIDGE_ERROR", e.message ?: e.toString())
        }
    }

    private fun initialize(reply: MainThreadResult) {
        if (!Terminal.isInitialized()) {
            Terminal.init(
                context.applicationContext,
                LogLevel.VERBOSE,
                tokenProvider,
                terminalListener,
                offlineListener,
                // Error messages in the cardholder's language when the card says so.
                LocaleConfig.CardLanguagePreferenceIfAvailable,
            )
        }
        reply.success(offlineStatusMap(Terminal.getInstance().offlineStatus))
    }

    // --- MethodChannel: native -> Dart -----------------------------------

    /** Asks Dart (lib/src/config.dart) for a connection token from the backend. */
    private fun requestConnectionToken(callback: ConnectionTokenCallback) {
        main.post {
            methods.invokeMethod("fetchConnectionToken", null, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    val token = result as? String
                    if (token.isNullOrEmpty()) {
                        callback.onFailure(ConnectionTokenException("Empty connection token"))
                    } else {
                        callback.onSuccess(token)
                    }
                }

                // Offline the backend is unreachable and Dart throws: that is
                // expected, the SDK keeps working offline without a new token.
                override fun error(code: String, message: String?, details: Any?) =
                    callback.onFailure(ConnectionTokenException(message ?: code))

                override fun notImplemented() =
                    callback.onFailure(ConnectionTokenException("No connection token provider"))
            })
        }
    }

    // --- Readers ---------------------------------------------------------

    private fun discoverReaders(link: String, simulated: Boolean, reply: MainThreadResult) {
        val config = when (link) {
            "usb" -> DiscoveryConfiguration.UsbDiscoveryConfiguration(0, simulated)
            else -> DiscoveryConfiguration.BluetoothDiscoveryConfiguration(0, simulated)
        }
        discoveredReaders = emptyList()
        discoveryTask = Terminal.getInstance().discoverReaders(
            config,
            object : DiscoveryListener {
                override fun onUpdateDiscoveredReaders(readers: List<Reader>) {
                    discoveredReaders = readers
                    emit(mapOf("type" to "readers", "readers" to readers.map(::readerMap)))
                }
            },
            // Called when discovery ends: after a connection, a cancel or an error.
            object : Callback {
                override fun onSuccess() = emit(mapOf("type" to "discoveryFinished", "error" to null))
                override fun onFailure(e: TerminalException) =
                    emit(mapOf("type" to "discoveryFinished", "error" to e.errorMessage))
            },
        )
        // Discovery keeps running: readers arrive as events, not as this reply.
        reply.success(null)
    }

    private fun connectReader(serialNumber: String, locationId: String, link: String, reply: MainThreadResult) {
        val reader = discoveredReaders.firstOrNull { it.serialNumber == serialNumber }
        if (reader == null) {
            reply.error("READER_NOT_FOUND", "Lettore $serialNumber non trovato: ripeti la ricerca")
            return
        }
        // autoReconnectOnUnexpectedDisconnect = true: the SDK reconnects by
        // itself if Bluetooth drops for a moment.
        val config = when (link) {
            "usb" -> ConnectionConfiguration.UsbConnectionConfiguration(locationId, true, readerListener)
            else -> ConnectionConfiguration.BluetoothConnectionConfiguration(locationId, true, readerListener)
        }
        Terminal.getInstance().connectReader(reader, config, object : ReaderCallback {
            override fun onSuccess(reader: Reader) = reply.success(readerMap(reader))
            override fun onFailure(e: TerminalException) = reply.error(e)
        })
    }

    // --- Payments ----------------------------------------------------------

    /**
     * The three steps of a card-present payment:
     * 1. create  – a PaymentIntent for the amount. With PREFER_ONLINE the SDK
     *    creates it on Stripe when online, or locally when offline.
     * 2. collect – the reader waits for the card (tap, insert or swipe).
     * 3. confirm – online: Stripe authorises the card now. Offline: the SDK
     *    stores the encrypted payment and forwards it later, reporting the
     *    outcome through [OfflineListener.onPaymentIntentForwarded].
     */
    private fun collectPayment(amount: Long, currency: String, posTxId: String, reply: MainThreadResult) {
        val params = PaymentIntentParameters.Builder()
            .setAmount(amount)
            .setCurrency(currency)
            .setCaptureMethod(CaptureMethod.Automatic)
            // Our own sale id: it lets the app match the forwarded payment
            // with the sale in its local ledger.
            .setMetadata(mapOf(POS_TX_ID to posTxId))
            .build()
        val terminal = Terminal.getInstance()

        terminal.createPaymentIntent(params, object : PaymentIntentCallback {
            override fun onSuccess(paymentIntent: PaymentIntent) {
                collectTask = terminal.collectPaymentMethod(paymentIntent, object : PaymentIntentCallback {
                    override fun onSuccess(paymentIntent: PaymentIntent) {
                        collectTask = null
                        terminal.confirmPaymentIntent(paymentIntent, object : PaymentIntentCallback {
                            override fun onSuccess(paymentIntent: PaymentIntent) =
                                reply.success(outcomeMap(paymentIntent))

                            override fun onFailure(e: TerminalException) {
                                cancelQuietly(e.paymentIntent ?: paymentIntent)
                                reply.error(e)
                            }
                        })
                    }

                    override fun onFailure(e: TerminalException) {
                        collectTask = null
                        cancelQuietly(paymentIntent)
                        reply.error(e)
                    }
                })
            }

            override fun onFailure(e: TerminalException) = reply.error(e)
        }, CreateConfiguration(OfflineBehavior.PREFER_ONLINE))
    }

    /**
     * Cancels a PaymentIntent that will not be completed, so it does not stay
     * open on Stripe. Only online intents (with an id) exist on Stripe, and
     * Stripe refuses to cancel one that already succeeded, so this is safe.
     */
    private fun cancelQuietly(paymentIntent: PaymentIntent) {
        if (paymentIntent.id == null) return
        Terminal.getInstance().cancelPaymentIntent(paymentIntent, object : PaymentIntentCallback {
            override fun onSuccess(paymentIntent: PaymentIntent) {}
            override fun onFailure(e: TerminalException) {}
        })
    }

    private fun cancel(task: Cancelable?, reply: MainThreadResult) {
        if (task == null || task.isCompleted) {
            reply.success(null)
            return
        }
        task.cancel(object : Callback {
            override fun onSuccess() = reply.success(null)
            override fun onFailure(e: TerminalException) = reply.error(e)
        })
    }

    // --- Native objects -> maps Flutter can send over a channel ------------

    private fun offlineStatusMap(status: OfflineStatus): Map<String, Any?> = mapOf(
        "sdk" to detailsMap(status.sdk),
        "reader" to status.reader?.let(::detailsMap),
    )

    private fun detailsMap(details: OfflineStatusDetails): Map<String, Any?> = mapOf(
        "networkStatus" to details.networkStatus.name.lowercase(),
        "count" to details.offlinePaymentsCount,
        "amounts" to details.offlinePaymentAmountsByCurrency,
    )

    private fun readerMap(reader: Reader): Map<String, Any?> = mapOf(
        "serialNumber" to reader.serialNumber,
        "label" to reader.label,
        "deviceType" to reader.deviceType.name,
        "batteryLevel" to reader.batteryLevel?.toDouble(),
        "simulated" to reader.isSimulated,
    )

    private fun outcomeMap(paymentIntent: PaymentIntent): Map<String, Any?> {
        // A payment collected offline has offlineDetails and no Stripe id yet.
        val offline = paymentIntent.offlineDetails
        val card = offline?.cardPresentDetails
        val online = paymentIntent.paymentMethod?.cardPresentDetails
        return mapOf(
            "storedOffline" to (offline != null || paymentIntent.id == null),
            "paymentIntentId" to paymentIntent.id,
            "cardBrand" to (card?.brand ?: online?.brand),
            "last4" to (card?.last4 ?: online?.last4),
        )
    }

    /**
     * Delivers a method-channel reply on the main thread, exactly once
     * (answering the same call twice crashes Flutter).
     */
    private class MainThreadResult(private val result: MethodChannel.Result, private val main: Handler) {
        private var done = false

        private fun reply(block: () -> Unit) {
            main.post {
                if (!done) {
                    done = true
                    block()
                }
            }
        }

        fun success(value: Any?) = reply { result.success(value) }

        fun notImplemented() = reply { result.notImplemented() }

        fun error(code: String, message: String) = reply { result.error(code, message, null) }

        fun error(e: TerminalException) = reply {
            result.error(e.errorCode.name, e.errorMessage, mapOf("declined" to (e.errorCode in DECLINE_CODES)))
        }
    }

    /**
     * Listeners handed to the SDK. They are created once per process, like
     * the SDK itself, and forward to the bridge of the current Flutter engine.
     */
    private companion object {
        const val POS_TX_ID = "pos_tx_id"

        val DECLINE_CODES = setOf(
            TerminalErrorCode.DECLINED_BY_STRIPE_API,
            TerminalErrorCode.DECLINED_BY_READER,
            TerminalErrorCode.OFFLINE_TRANSACTION_DECLINED,
        )

        @Volatile var current: StripeTerminalBridge? = null

        fun emitToFlutter(event: Map<String, Any?>) {
            current?.emit(event)
        }

        val tokenProvider = object : ConnectionTokenProvider {
            override fun fetchConnectionToken(callback: ConnectionTokenCallback) {
                val bridge = current
                if (bridge == null) {
                    callback.onFailure(ConnectionTokenException("App not running"))
                } else {
                    bridge.requestConnectionToken(callback)
                }
            }
        }

        val terminalListener = object : TerminalListener {
            override fun onConnectionStatusChange(status: ConnectionStatus) {
                emitToFlutter(mapOf("type" to "connectionStatus", "status" to status.name))
            }
        }

        val offlineListener = object : OfflineListener {
            override fun onOfflineStatusChange(offlineStatus: OfflineStatus) {
                current?.let { it.emit(mapOf("type" to "offlineStatus", "status" to it.offlineStatusMap(offlineStatus))) }
            }

            override fun onPaymentIntentForwarded(paymentIntent: PaymentIntent, e: TerminalException?) {
                emitToFlutter(
                    mapOf(
                        "type" to "paymentForwarded",
                        "posTxId" to paymentIntent.metadata?.get(POS_TX_ID),
                        "paymentIntentId" to paymentIntent.id,
                        // e.g. SUCCEEDED -> "succeeded", as in the Stripe API.
                        "status" to paymentIntent.status?.name?.lowercase(),
                        "error" to e?.errorMessage,
                    )
                )
            }

            override fun onForwardingFailure(e: TerminalException) {
                emitToFlutter(mapOf("type" to "forwardingFailure", "error" to e.errorMessage))
            }
        }

        val readerListener = object : MobileReaderListener {
            override fun onRequestReaderDisplayMessage(message: ReaderDisplayMessage) {
                emitToFlutter(mapOf("type" to "readerMessage", "message" to message.name))
            }

            override fun onRequestReaderInput(options: ReaderInputOptions) {
                emitToFlutter(mapOf("type" to "readerMessage", "message" to "INPUT"))
            }

            override fun onDisconnect(reason: DisconnectReason) {
                emitToFlutter(mapOf("type" to "disconnected", "reason" to reason.name))
            }
        }
    }
}
