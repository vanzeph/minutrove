package io.github.vanzeph.minutrove

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Fires at the armed run deadline. Settlement itself never happens here: the
 * Flutter session lifecycle settles from the persisted deadline when the app
 * runs again, whether or not this cue was delivered.
 */
class CompletionAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != CompletionNotifications.ALARM_ACTION) return
        val sessionId = intent.getStringExtra(CompletionNotifications.EXTRA_SESSION_ID)
        val completionId = intent.getStringExtra(CompletionNotifications.EXTRA_COMPLETION_ID)
        val revision = intent.getLongExtra(CompletionNotifications.EXTRA_SESSION_REVISION, -1)
        val deadlineUtc = intent.getLongExtra(CompletionNotifications.EXTRA_DEADLINE_UTC, -1)
        if (sessionId == null || completionId == null ||
            !CompletionNotifications.validId(sessionId) ||
            !CompletionNotifications.validId(completionId)
        ) {
            return
        }
        CompletionNotifications(context).onAlarm(sessionId, completionId, revision, deadlineUtc)
    }
}
