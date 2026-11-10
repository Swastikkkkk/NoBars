package app.nobars.android

import android.app.Application

class NoBarsApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Notifier.createChannels(this)
    }
}
