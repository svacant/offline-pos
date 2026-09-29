package com.svacant.offline_pos

import android.app.Application
import com.stripe.stripeterminal.TerminalApplicationDelegate

class PosApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Required by Stripe Terminal before Terminal.init.
        TerminalApplicationDelegate.onCreate(this)
    }
}
