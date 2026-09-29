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
 * offline mode, so the payment flow lives here:
 *
 * - `offline_pos/terminal` method channel: Dart -> native calls, plus the
 *   native -> Dart `fetchConnectionToken` call.
 * - `offline_pos/terminal/events` event channel: offline status, forwarded
 *   payments, discovered readers and reader prompts.
 *
 * SDK callbacks arrive on background threads; every reply to Flutter is
 * posted to the main thread.
 */
class StripeTerminalBridge(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val methods = MethodChannel(messenger, "offline_pos/terminal")
    private val events = EventChannel(messenger, "offline_pos/terminal/events")
    private val main = Handler(Looper.getMainLooper())

    private var sink: EventChannel.EventSink? = null
    private var discoveredReaders: List<Reader> = emptyList()
    private var discoveryTask: Cancelable? = null
    private var collectTask: Cancelable? = null

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(event: Map<String, Any?>) {
        main.post { sink?.success(event) }
    }

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
                    (call.argument<Number>("amount")!!).toLong(),
                    call.argument<String>("currency")!!,
                    call.argument<String>("posTxId")!!,
                    reply,
                )
                "cancelCollect" -> cancel(collectTask, reply)
                "setSimulatedOffline" -> {
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

    // --- Initialisation --------------------------------------------------

    private val tokenProvider = object : ConnectionTokenProvider {
        override fun fetchConnectionToken(callback: ConnectionTokenCallback) {
            // The backend call lives in Dart (lib/src/config.dart).
            main.post {
                methods.invokeMethod("fetchConnectionToken", null, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        val token = result as? String
                        if (token != null) {
                            callback.onSuccess(token)
                        } else {
                            callback.onFailure(ConnectionTokenException("Empty connection token"))
                        }
                    }

                    override fun error(code: String, message: String?, details: Any?) =
                        callback.onFailure(ConnectionTokenException(message ?: code))

                    override fun notImplemented() =
                        callback.onFailure(ConnectionTokenException("No connection token provider"))
                })
            }
        }
    }

    private val terminalListener = object : TerminalListener {
        override fun onConnectionStatusChange(status: ConnectionStatus) {
            emit(mapOf("type" to "connectionStatus", "status" to status.name))
        }
    }

    private val offlineListener = object : OfflineListener {
        override fun onOfflineStatusChange(offlineStatus: OfflineStatus) {
            emit(mapOf("type" to "offlineStatus", "status" to offlineStatusMap(offlineStatus)))
        }

        override fun onPaymentIntentForwarded(paymentIntent: PaymentIntent, e: TerminalException?) {
            emit(
                mapOf(
                    "type" to "paymentForwarded",
                    "posTxId" to paymentIntent.metadata?.get(POS_TX_ID),
                    "paymentIntentId" to paymentIntent.id,
                    "status" to paymentIntent.status?.name?.lowercase(),
                    "error" to e?.errorMessage,
                )
            )
        }

        override fun onForwardingFailure(e: TerminalException) {
            emit(mapOf("type" to "forwardingFailure", "error" to e.errorMessage))
        }
    }

    private fun initialize(reply: MainThreadResult) {
        if (!Terminal.isInitialized()) {
            Terminal.init(
                context,
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

    // --- Readers ---------------------------------------------------------

    private val readerListener = object : MobileReaderListener {
        override fun onRequestReaderDisplayMessage(message: ReaderDisplayMessage) {
            emit(mapOf("type" to "readerMessage", "message" to message.name))
        }

        override fun onRequestReaderInput(options: ReaderInputOptions) {
            emit(mapOf("type" to "readerMessage", "message" to "INPUT"))
        }

        override fun onDisconnect(reason: DisconnectReason) {
            emit(mapOf("type" to "disconnected", "reason" to reason.name))
        }
    }

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
            object : Callback {
                override fun onSuccess() = emit(mapOf("type" to "discoveryFinished", "error" to null))
                override fun onFailure(e: TerminalException) =
                    emit(mapOf("type" to "discoveryFinished", "error" to e.errorMessage))
            },
        )
        reply.success(null)
    }

    private fun connectReader(serialNumber: String, locationId: String, link: String, reply: MainThreadResult) {
        val reader = discoveredReaders.firstOrNull { it.serialNumber == serialNumber }
        if (reader == null) {
            reply.error("READER_NOT_FOUND", "Lettore $serialNumber non trovato: ripeti la ricerca")
            return
        }
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
     * create -> collect -> confirm with PREFER_ONLINE: online when Stripe is
     * reachable, otherwise the SDK stores the payment and forwards it later
     * (reported through [OfflineListener.onPaymentIntentForwarded]).
     */
    private fun collectPayment(amount: Long, currency: String, posTxId: String, reply: MainThreadResult) {
        val params = PaymentIntentParameters.Builder()
            .setAmount(amount)
            .setCurrency(currency)
            .setCaptureMethod(CaptureMethod.Automatic)
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

                            override fun onFailure(e: TerminalException) = reply.error(e)
                        })
                    }

                    override fun onFailure(e: TerminalException) {
                        collectTask = null
                        if (paymentIntent.id != null) {
                            terminal.cancelPaymentIntent(paymentIntent, object : PaymentIntentCallback {
                                override fun onSuccess(paymentIntent: PaymentIntent) {}
                                override fun onFailure(e: TerminalException) {}
                            })
                        }
                        reply.error(e)
                    }
                })
            }

            override fun onFailure(e: TerminalException) = reply.error(e)
        }, CreateConfiguration(OfflineBehavior.PREFER_ONLINE))
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

    // --- Serialisation -----------------------------------------------------

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

    /** Delivers a method-channel reply on the main thread, exactly once. */
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

    private companion object {
        const val POS_TX_ID = "pos_tx_id"

        val DECLINE_CODES = setOf(
            TerminalErrorCode.DECLINED_BY_STRIPE_API,
            TerminalErrorCode.DECLINED_BY_READER,
            TerminalErrorCode.OFFLINE_TRANSACTION_DECLINED,
        )
    }
}
