package io.github.vanzeph.minutrove

import android.content.Context
import android.os.SystemClock
import android.provider.Settings

class DurableClock(private val context: Context) {
    fun now(): Map<String, Any> {
        // BOOT_COUNT is readable from API 24, our minimum OS. Do not replace an
        // unavailable boot marker with an inferred wall-time boot date.
        val boot = Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT)
        check(boot >= 0)
        val monotonic = SystemClock.elapsedRealtime() // Includes deep sleep.
        val utc = System.currentTimeMillis()
        return mapOf(
            "utcMilliseconds" to utc,
            "monotonicMilliseconds" to monotonic,
            "bootId" to "android-boot-$boot"
        )
    }
}
