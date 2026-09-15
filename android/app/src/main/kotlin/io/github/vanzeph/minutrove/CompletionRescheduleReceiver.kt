package io.github.vanzeph.minutrove

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Re-arms deadline alarms after reboot or app update (AlarmManager state does
 * not survive either) and after a manual clock or timezone edit (RTC trigger
 * times drift with the wall clock). Protected system broadcasts only; the
 * receiver is not exported to other apps.
 */
class CompletionRescheduleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        CompletionNotifications(context).rescheduleAfterSystemChange()
    }
}
